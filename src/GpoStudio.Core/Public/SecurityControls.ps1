<#
    Sigurnosne kontrole: katalog jednostavnih postavki (kvačice i izbori) za korisnike koji ne
    poznaju Group Policy. Svaka kontrola ima jednu ili više opcija; opcija je skup registry
    vrijednosti, [System Access] postavki (secedit) i podkategorija revizije (auditpol).

    Odabir (selection) je uređeni rječnik  id kontrole -> id opcije  ($null = ne mijenja se).
    Razine 1 (Osnovno), 2 (Preporučeno) i 3 (Strogo) daju zadani odabir; preset je razina +
    popis promjena u odnosu na nju. Iz odabira nastaje običan Policy Set, pa primjena lokalno i
    u domenu ide postojećim cmdletima.

    Opcije jedne kontrole poredane su od najblaže do najstrože. Vrijednost koju koristi bilo koja
    opcija kontrole "pripada" toj kontroli: odabrana opcija briše vrijednosti ostalih opcija koje
    sama ne postavlja, pa prelazak s "Zabranjeno" na "Samo čitanje" ne ostavlja staru zabranu.
#>

$script:GpsDataRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Data'
$script:GpsSecurityKeys = @(
    'MinimumPasswordLength', 'PasswordComplexity', 'PasswordHistorySize', 'MaximumPasswordAge', 'MinimumPasswordAge',
    'LockoutBadCount', 'LockoutDuration', 'ResetLockoutCount', 'EnableGuestAccount', 'EnableAdminAccount',
    'ClearTextPassword', 'LSAAnonymousNameLookup', 'ForceLogoffWhenHourExpire'
)

function Get-GpsOptionalProperty {
    # Svojstvo JSON objekta ili rječnika; $null ako ne postoji (i pod Set-StrictMode).
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function ConvertTo-GpsDictionary {
    # PSCustomObject (iz JSON-a) ili rječnik -> uređeni rječnik.
    param($InputObject)
    $result = [ordered]@{}
    if ($null -eq $InputObject) { return $result }
    if ($InputObject -is [System.Collections.IDictionary]) { foreach ($k in $InputObject.Keys) { $result[[string]$k] = $InputObject[$k] } }
    else { foreach ($p in $InputObject.PSObject.Properties) { $result[$p.Name] = $p.Value } }
    $result
}

function Get-GpsControlOption {
    param($Control, [string]$OptionId)
    foreach ($o in @($Control.options)) { if ($o.id -eq $OptionId) { return $o } }
    $null
}

function Get-GpsControlLevelOption {
    # Id opcije koju razina (1-3) bira za kontrolu, ili $null.
    param($Control, [int]$Level)
    if ($Level -lt 1) { return $null }
    $value = Get-GpsOptionalProperty (Get-GpsOptionalProperty $Control 'levels') ([string]$Level)
    if ($value) { [string]$value } else { $null }
}

function Get-GpsControlOptionSettings {
    <#
    .SYNOPSIS
        Registry postavke odabrane opcije, uključujući brisanje vrijednosti koje postavljaju druge opcije iste kontrole.
    #>
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)][string]$OptionId)
    $option = Get-GpsControlOption $Control $OptionId
    if (-not $option) { throw "Kontrola '$($Control.id)' nema opciju '$OptionId'." }

    $own = @{}
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(Get-GpsOptionalProperty $option 'settings')) {
        if ($null -eq $s) { continue }
        $scope = if (Get-GpsOptionalProperty $s 'scope') { $s.scope } else { 'Machine' }
        $own["$scope\$($s.key)\$($s.valueName)".ToLowerInvariant()] = $true
        $result.Add([pscustomobject]@{
                scope = $scope; key = $s.key; valueName = [string]$s.valueName
                type = if (Get-GpsOptionalProperty $s 'type') { $s.type } else { 'REG_DWORD' }
                data = Get-GpsOptionalProperty $s 'data'
                action = if (Get-GpsOptionalProperty $s 'action') { $s.action } else { 'Set' }
                implied = $false
            })
    }
    foreach ($other in @($Control.options)) {
        if ($other.id -eq $OptionId) { continue }
        foreach ($s in @(Get-GpsOptionalProperty $other 'settings')) {
            if ($null -eq $s) { continue }
            $scope = if (Get-GpsOptionalProperty $s 'scope') { $s.scope } else { 'Machine' }
            $k = "$scope\$($s.key)\$($s.valueName)".ToLowerInvariant()
            if ($own.ContainsKey($k)) { continue }
            $own[$k] = $true
            $result.Add([pscustomobject]@{
                    scope = $scope; key = $s.key; valueName = [string]$s.valueName
                    type = if (Get-GpsOptionalProperty $s 'type') { $s.type } else { 'REG_DWORD' }
                    data = $null; action = 'Delete'; implied = $true
                })
        }
    }
    , $result
}

function Test-GpsControlCatalog {
    <#
    .SYNOPSIS
        Provjerava katalog sigurnosnih kontrola; vraća poruke o greškama (ništa = ispravan).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)

    $errors = [System.Collections.Generic.List[string]]::new()
    if ((Get-GpsOptionalProperty $Catalog 'schemaVersion') -ne 1) { $errors.Add('schemaVersion mora biti 1.') }

    $standards = @{}
    foreach ($s in @(Get-GpsOptionalProperty $Catalog 'standards')) { if ($s) { $standards[[string]$s.id] = $s } }
    $categories = @{}
    foreach ($c in @(Get-GpsOptionalProperty $Catalog 'categories')) {
        if (-not $c) { continue }
        if ($categories.ContainsKey([string]$c.id)) { $errors.Add("Kategorija '$($c.id)' je navedena dvaput.") }
        $categories[[string]$c.id] = $c
    }

    $controlIds = @{}
    $valueOwner = @{}
    $controls = @(Get-GpsOptionalProperty $Catalog 'controls')
    if ($controls.Count -eq 0) { $errors.Add('Katalog nema kontrola.') }
    foreach ($c in $controls) {
        if (-not $c) { continue }
        $id = [string](Get-GpsOptionalProperty $c 'id')
        if (-not $id) { $errors.Add('Kontrola bez id-a.'); continue }
        if ($controlIds.ContainsKey($id)) { $errors.Add("Kontrola '$id' je navedena dvaput.") }
        $controlIds[$id] = $true
        foreach ($field in 'title', 'description') {
            if (-not (Get-GpsOptionalProperty $c $field)) { $errors.Add("${id}: nedostaje '$field'.") }
        }
        if (-not $categories.ContainsKey([string](Get-GpsOptionalProperty $c 'category'))) { $errors.Add("${id}: nepoznata kategorija '$(Get-GpsOptionalProperty $c 'category')'.") }

        $options = @(Get-GpsOptionalProperty $c 'options')
        if ($options.Count -eq 0) { $errors.Add("${id}: nema opcija.") }
        $optionIds = @{}
        foreach ($o in $options) {
            $oid = [string](Get-GpsOptionalProperty $o 'id')
            if (-not $oid) { $errors.Add("${id}: opcija bez id-a."); continue }
            if ($optionIds.ContainsKey($oid)) { $errors.Add("${id}: opcija '$oid' je navedena dvaput.") }
            $optionIds[$oid] = $true
            if (-not (Get-GpsOptionalProperty $o 'title')) { $errors.Add("${id}/${oid}: nedostaje 'title'.") }
            $mode = Get-GpsOptionalProperty $o 'matchMode'
            if ($mode -and $mode -notin 'exact', 'atLeast', 'atMost') { $errors.Add("${id}/${oid}: nepoznat matchMode '$mode'.") }

            $settings = @(Get-GpsOptionalProperty $o 'settings' | Where-Object { $null -ne $_ })
            $security = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $o 'security')
            $audit = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $o 'audit')
            if ($settings.Count -eq 0 -and $security.Count -eq 0 -and $audit.Count -eq 0) { $errors.Add("${id}/${oid}: opcija ništa ne postavlja.") }
            foreach ($s in $settings) {
                $p = @{ Key = [string](Get-GpsOptionalProperty $s 'key'); ValueName = [string](Get-GpsOptionalProperty $s 'valueName') }
                foreach ($f in 'scope', 'type', 'data', 'action') { $v = Get-GpsOptionalProperty $s $f; if ($null -ne $v) { $p[$f] = $v } }
                try { $null = New-GpsPolicySetting @p }
                catch { $errors.Add("${id}/${oid}: $($_.Exception.Message)") }
                $scope = if ($p.Contains('scope')) { $p.scope } else { 'Machine' }
                $k = "$scope\$($p.Key)\$($p.ValueName)".ToLowerInvariant()
                if ($valueOwner.ContainsKey($k) -and $valueOwner[$k] -ne $id) { $errors.Add("${id}: vrijednost $k već koristi kontrola '$($valueOwner[$k])'.") }
                $valueOwner[$k] = $id
            }
            foreach ($k in $security.Keys) {
                if ($k -notin $script:GpsSecurityKeys) { $errors.Add("${id}/${oid}: nepoznata [System Access] postavka '$k'.") }
                elseif ($security[$k] -isnot [ValueType] -and -not ([string]$security[$k] -match '^-?\d+$')) { $errors.Add("${id}/${oid}: '$k' mora biti broj.") }
            }
            foreach ($k in $audit.Keys) {
                if ([string]$audit[$k] -notmatch '^(Success|Failure|Success,\s*Failure|None)$') { $errors.Add("${id}/${oid}: revizija '$k' ima neispravnu vrijednost '$($audit[$k])'.") }
            }
        }

        $levels = Get-GpsOptionalProperty $c 'levels'
        foreach ($lvl in 1..3) {
            $v = Get-GpsOptionalProperty $levels ([string]$lvl)
            if ($v -and -not $optionIds.ContainsKey([string]$v)) { $errors.Add("${id}: razina $lvl upućuje na nepostojeću opciju '$v'.") }
        }
        foreach ($b in @(Get-GpsOptionalProperty $c 'benchmarks')) {
            if (-not $b) { continue }
            if (-not $standards.ContainsKey([string]$b.standard)) { $errors.Add("${id}: nepoznat standard '$($b.standard)'.") }
            $satisfied = @(Get-GpsOptionalProperty $b 'satisfiedBy')
            if ($satisfied.Count -eq 0) { $errors.Add("${id}: preporuka '$($b.standard)' nema satisfiedBy.") }
            foreach ($sid in $satisfied) { if (-not $optionIds.ContainsKey([string]$sid)) { $errors.Add("${id}: satisfiedBy upućuje na nepostojeću opciju '$sid'.") } }
        }
    }
    $errors
}

function Get-GpsControlCatalog {
    <#
    .SYNOPSIS
        Učitava i provjerava katalog sigurnosnih kontrola (zadano: Data\security-controls.json uz modul).
    .EXAMPLE
        $catalog = Get-GpsControlCatalog
        $catalog.controls | Select-Object id, title
    #>
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:GpsDataRoot 'security-controls.json' }
    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $errors = @(Test-GpsControlCatalog -Catalog $catalog)
    if ($errors.Count -gt 0) { throw "Katalog '$Path' nije ispravan:`n - " + ($errors -join "`n - ") }
    $catalog
}

function Get-GpsControlSelection {
    <#
    .SYNOPSIS
        Odabir opcija za razinu (0 = ništa, 1 Osnovno, 2 Preporučeno, 3 Strogo), uz opcionalne promjene.
    .EXAMPLE
        Get-GpsControlSelection -Catalog $catalog -Level 2 -Override @{ 'usb.storage' = 'blocked' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [ValidateRange(0, 3)][int]$Level = 2,
        [System.Collections.IDictionary]$Override
    )
    $selection = [ordered]@{}
    $index = @{}
    foreach ($c in @($Catalog.controls)) {
        $selection[$c.id] = Get-GpsControlLevelOption $c $Level
        $index[$c.id] = $c
    }
    if ($Override) {
        foreach ($k in @($Override.Keys)) {
            $value = $Override[$k]
            if (-not $index.ContainsKey([string]$k)) { Write-Warning "Kontrola '$k' ne postoji u katalogu i preskače se."; continue }
            if ($value -and -not (Get-GpsControlOption $index[[string]$k] ([string]$value))) {
                Write-Warning "Kontrola '$k' nema opciju '$value' i preskače se."
                continue
            }
            $selection[[string]$k] = if ($value) { [string]$value } else { $null }
        }
    }
    $selection
}

function ConvertTo-GpsControlPolicySet {
    <#
    .SYNOPSIS
        Pretvara odabir sigurnosnih kontrola u Policy Set (registry + security + audit).
    .EXAMPLE
        $set = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 2)
        Set-GpsLocalPolicy -PolicySet $set -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Selection,
        [string]$Name = 'Sigurnosne postavke',
        [string]$Description = ''
    )
    $set = New-GpsPolicySet -Name $Name -Description $Description
    $positions = @{}
    foreach ($c in @($Catalog.controls)) {
        if (-not $Selection.Contains($c.id)) { continue }
        $optionId = $Selection[$c.id]
        if (-not $optionId) { continue }
        $option = Get-GpsControlOption $c ([string]$optionId)
        if (-not $option) { throw "Kontrola '$($c.id)' nema opciju '$optionId'." }

        foreach ($s in (Get-GpsControlOptionSettings -Control $c -OptionId $option.id)) {
            $p = @{
                Scope = $s.scope; Key = $s.key; ValueName = $s.valueName; Type = $s.type; Action = $s.action
                Id = "$($c.id)/$($s.valueName)"; DisplayName = "$($c.title): $($option.title)"
            }
            if ($s.action -eq 'Set') { $p.Data = $s.data }
            $setting = New-GpsPolicySetting @p
            $k = "$($setting.scope)\$($setting.key)\$($setting.valueName)".ToLowerInvariant()
            if ($positions.ContainsKey($k)) { $set.settings[$positions[$k]] = $setting }
            else { $positions[$k] = $set.settings.Count; $set.settings.Add($setting) }
        }
        foreach ($section in 'security', 'audit') {
            $values = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $option $section)
            foreach ($k in $values.Keys) {
                if ($set.$section.Contains($k) -and [string]$set.$section[$k] -ne [string]$values[$k]) {
                    Write-Warning "$section '$k': kontrola '$($c.id)' mijenja ranije postavljenu vrijednost '$($set.$section[$k])' u '$($values[$k])'."
                }
                $set.$section[$k] = $values[$k]
            }
        }
    }
    $set
}

function Get-GpsControlCompliance {
    <#
    .SYNOPSIS
        Uspoređuje odabir (ili otkriveno stanje računala) s preporukama standarda iz kataloga.
    .DESCRIPTION
        Za svaki standard vraća broj preporuka iz kataloga, broj zadovoljenih i postotak.
        Postotak se odnosi samo na preporuke koje katalog poznaje, ne na cijeli standard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Selection
    )
    $categoryTitles = @{}
    foreach ($cat in @($Catalog.categories)) { $categoryTitles[$cat.id] = $cat.title }

    foreach ($std in @($Catalog.standards)) {
        $family = @([string]$std.id) + @(Get-GpsOptionalProperty $std 'includes' | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $rows = foreach ($c in @($Catalog.controls)) {
            $entries = @(Get-GpsOptionalProperty $c 'benchmarks' | Where-Object { $_ -and [string]$_.standard -in $family })
            if ($entries.Count -eq 0) { continue }
            # Vlastita preporuka standarda ima prednost pred naslijeđenom (npr. CIS L2 pred L1).
            $entry = @($entries | Where-Object { [string]$_.standard -eq [string]$std.id }) + $entries | Select-Object -First 1
            $selected = if ($Selection.Contains($c.id)) { $Selection[$c.id] } else { $null }
            $option = if ($selected) { Get-GpsControlOption $c ([string]$selected) } else { $null }
            $status = if (-not $selected) { 'NotSet' } elseif ([string]$selected -in @($entry.satisfiedBy | ForEach-Object { [string]$_ })) { 'OK' } else { 'Deviates' }
            [pscustomobject]@{
                StandardId     = [string]$std.id
                Source         = [string]$entry.standard
                ControlId      = $c.id
                Control        = $c.title
                Category       = $categoryTitles[$c.category]
                Recommendation = $entry.recommendation
                Reference      = Get-GpsOptionalProperty $entry 'reference'
                Selected       = if ($option) { $option.title } else { $null }
                SelectedId     = if ($option) { $option.id } else { $null }
                Status         = $status
            }
        }
        $rows = @($rows)
        $ok = @($rows | Where-Object Status -eq 'OK').Count
        [pscustomobject]@{
            Id        = [string]$std.id
            Title     = $std.title
            Source    = Get-GpsOptionalProperty $std 'source'
            Note      = Get-GpsOptionalProperty $std 'note'
            Total     = $rows.Count
            Satisfied = $ok
            Score     = if ($rows.Count) { [int][math]::Round(100 * $ok / $rows.Count) } else { 0 }
            Rows      = $rows
        }
    }
}

#region Preseti

function ConvertTo-GpsControlPreset {
    param($InputObject, [string]$Path, [bool]$BuiltIn)
    $name = [string](Get-GpsOptionalProperty $InputObject 'name')
    if (-not $name) { throw "Preset '$Path' nema naziv (name)." }
    $level = Get-GpsOptionalProperty $InputObject 'level'
    if ($null -eq $level -or [int]$level -lt 0 -or [int]$level -gt 3) { throw "Preset '$name' nema ispravnu razinu (level 0-3)." }
    [pscustomobject]@{
        PSTypeName  = 'GpoStudio.ControlPreset'
        Name        = $name
        Description = [string](Get-GpsOptionalProperty $InputObject 'description')
        Level       = [int]$level
        Changes     = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $InputObject 'changes')
        BuiltIn     = $BuiltIn
        Path        = $Path
    }
}

function Import-GpsControlPreset {
    <#
    .SYNOPSIS
        Učitava preset sigurnosnih kontrola iz JSON datoteke.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$BuiltIn)
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    ConvertTo-GpsControlPreset -InputObject $json -Path $Path -BuiltIn ([bool]$BuiltIn)
}

function Get-GpsControlPresetFolder {
    <# Mapa za vlastite presete (dijele je svi administratori ovog računala). #>
    $base = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
    Join-Path $base 'GpoStudio\Presets'
}

function Get-GpsControlPreset {
    <#
    .SYNOPSIS
        Ugrađeni preseti (Data\Presets uz modul) i vlastiti preseti (zadano %ProgramData%\GpoStudio\Presets).
    #>
    [CmdletBinding()]
    param([string]$UserFolder = (Get-GpsControlPresetFolder), [string]$BuiltInFolder = (Join-Path $script:GpsDataRoot 'Presets'))
    foreach ($folder in @(@{ Path = $BuiltInFolder; BuiltIn = $true }, @{ Path = $UserFolder; BuiltIn = $false })) {
        if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder.Path -Filter *.json -File | Sort-Object Name) {
            try { Import-GpsControlPreset -Path $file.FullName -BuiltIn:$folder.BuiltIn }
            catch { Write-Warning "Preset '$($file.Name)' se ne može učitati: $($_.Exception.Message)" }
        }
    }
}

function Resolve-GpsControlPreset {
    <#
    .SYNOPSIS
        Odabir koji preset daje: razina preseta + njegove promjene.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$Preset)
    Get-GpsControlSelection -Catalog $Catalog -Level $Preset.Level -Override $Preset.Changes
}

function New-GpsControlPreset {
    <#
    .SYNOPSIS
        Pravi preset iz trenutnog odabira: sprema razinu i samo razlike u odnosu na nju.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [ValidateRange(0, 3)][int]$Level = 2,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Selection
    )
    $base = Get-GpsControlSelection -Catalog $Catalog -Level $Level
    $changes = [ordered]@{}
    foreach ($k in $base.Keys) {
        $current = if ($Selection.Contains($k)) { $Selection[$k] } else { $null }
        if ([string]$current -ne [string]$base[$k]) { $changes[$k] = $current }
    }
    [pscustomobject]@{
        PSTypeName = 'GpoStudio.ControlPreset'
        Name = $Name; Description = $Description; Level = $Level; Changes = $changes; BuiltIn = $false; Path = $null
    }
}

function Export-GpsControlPreset {
    <#
    .SYNOPSIS
        Sprema preset u JSON. Bez -Path sprema u mapu vlastitih preseta pod imenom izvedenim iz naziva.
    .OUTPUTS
        Putanja spremljene datoteke.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preset, [string]$Path, [switch]$Force)
    if (-not $Path) {
        $folder = Get-GpsControlPresetFolder
        $null = New-Item -ItemType Directory -Path $folder -Force
        $fileName = ($Preset.Name -replace '[\\/:*?"<>|]', '-').Trim()
        if (-not $fileName) { $fileName = 'preset' }
        $Path = Join-Path $folder "$fileName.json"
    }
    if ((Test-Path -LiteralPath $Path) -and -not $Force) { throw "Datoteka '$Path' već postoji." }
    [ordered]@{
        schemaVersion = 1
        name          = $Preset.Name
        description   = $Preset.Description
        level         = $Preset.Level
        changes       = $Preset.Changes
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}

#endregion

#region Stanje računala

function Get-GpsControlStateQuery {
    <#
    .SYNOPSIS
        Popis registry vrijednosti, [System Access] postavki i podkategorija revizije koje treba pročitati na računalu.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)
    $registry = [ordered]@{}
    $security = [ordered]@{}
    $audit = [ordered]@{}
    foreach ($c in @($Catalog.controls)) {
        foreach ($o in @($c.options)) {
            foreach ($s in @(Get-GpsOptionalProperty $o 'settings' | Where-Object { $null -ne $_ })) {
                $scope = if (Get-GpsOptionalProperty $s 'scope') { $s.scope } else { 'Machine' }
                $registry["$scope\$($s.key)\$($s.valueName)".ToLowerInvariant()] = [pscustomobject]@{ scope = $scope; key = $s.key; valueName = [string]$s.valueName }
            }
            foreach ($k in (ConvertTo-GpsDictionary (Get-GpsOptionalProperty $o 'security')).Keys) { $security[$k] = $true }
            foreach ($k in (ConvertTo-GpsDictionary (Get-GpsOptionalProperty $o 'audit')).Keys) { $audit[$k] = $true }
        }
    }
    [pscustomobject]@{ registry = @($registry.Values); security = @($security.Keys); audit = @($audit.Keys) }
}

function ConvertTo-GpsAuditFlags {
    # 'Success,Failure' / 'Success' / 'Failure' / 'None' -> normalizirani zapis.
    param([string]$Value)
    $success = $Value -match 'Success'
    $failure = $Value -match 'Failure'
    if ($success -and $failure) { 'Success,Failure' } elseif ($success) { 'Success' } elseif ($failure) { 'Failure' } else { 'None' }
}

function Test-GpsControlValue {
    # $true / $false / $null (nepoznato) za jednu očekivanu vrijednost.
    param($Actual, $Expected, [string]$Mode)
    if ($null -eq $Actual) { return $false }
    $a = 0.0; $e = 0.0
    $numeric = [double]::TryParse([string]$Actual, [ref]$a) -and [double]::TryParse([string]$Expected, [ref]$e)
    switch ($Mode) {
        'atLeast' { if ($numeric) { return $a -ge $e } }
        'atMost' { if ($numeric) { return $a -gt 0 -and $a -le $e } }
    }
    if ($numeric) { return $a -eq $e }
    (ConvertTo-GpsComparable $Actual) -eq (ConvertTo-GpsComparable $Expected)
}

function Resolve-GpsControlState {
    <#
    .SYNOPSIS
        Iz pročitanog stanja računala određuje koja je opcija svake kontrole trenutno na snazi.
    .DESCRIPTION
        State: Registry (ključ 'scope\key\valuename' malim slovima -> Exists, Type, Data), Security
        ([System Access] ključ -> vrijednost), Audit (podkategorija -> 'Success,Failure' / ... / 'None').
        Vrijednost koje nema u State.Registry (npr. korisnički dio na udaljenom računalu) je nepoznata.
        Kad odgovara više opcija, vrijedi najstroža (zadnja u popisu).
    .OUTPUTS
        Objekt sa Selection (id kontrole -> id opcije ili $null) i Details po kontroli.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$State)

    $registry = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $State 'Registry')
    $security = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $State 'Security')
    $audit = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $State 'Audit')
    $selection = [ordered]@{}
    $details = foreach ($c in @($Catalog.controls)) {
        $matched = $null
        $unknown = $false
        foreach ($o in @($c.options)) {
            $mode = [string](Get-GpsOptionalProperty $o 'matchMode')
            $ok = $true
            foreach ($s in (Get-GpsControlOptionSettings -Control $c -OptionId $o.id)) {
                $k = "$($s.scope)\$($s.key)\$($s.valueName)".ToLowerInvariant()
                if (-not $registry.Contains($k)) { $unknown = $true; $ok = $false; break }
                $r = $registry[$k]
                $exists = [bool](Get-GpsOptionalProperty $r 'Exists')
                if ($s.action -eq 'Delete') { if ($exists) { $ok = $false; break } else { continue } }
                if (-not $exists -or -not (Test-GpsControlValue (Get-GpsOptionalProperty $r 'Data') $s.data $mode)) { $ok = $false; break }
            }
            if ($ok) {
                $values = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $o 'security')
                foreach ($k in $values.Keys) {
                    if (-not $security.Contains($k) -or -not (Test-GpsControlValue $security[$k] $values[$k] $mode)) { $ok = $false; break }
                }
            }
            if ($ok) {
                $values = ConvertTo-GpsDictionary (Get-GpsOptionalProperty $o 'audit')
                foreach ($k in $values.Keys) {
                    if (-not $audit.Contains($k)) { $unknown = $true; $ok = $false; break }
                    if ((ConvertTo-GpsAuditFlags $audit[$k]) -ne (ConvertTo-GpsAuditFlags $values[$k])) { $ok = $false; break }
                }
            }
            if ($ok) { $matched = $o }
        }
        $selection[$c.id] = if ($matched) { $matched.id } else { $null }
        [pscustomobject]@{
            ControlId = $c.id
            Control   = $c.title
            OptionId  = if ($matched) { $matched.id } else { $null }
            Option    = if ($matched) { $matched.title } else { $null }
            Status    = if ($matched) { 'Detected' } elseif ($unknown) { 'Unknown' } else { 'Other' }
        }
    }
    [pscustomobject]@{
        ComputerName = Get-GpsOptionalProperty $State 'ComputerName'
        Selection    = $selection
        Details      = @($details)
    }
}

#endregion

#region Izvještaj

function ConvertTo-GpsComplianceHtml {
    <#
    .SYNOPSIS
        HTML izvještaj usporedbe sa standardima (svijetla, ispisna Auxilium tema).
    .PARAMETER Subject
        Što se uspoređuje, npr. 'Odabir: Preporučeno' ili 'Računalo PC01'.
    .EXAMPLE
        ConvertTo-GpsComplianceHtml -Catalog $catalog -Selection $state.Selection -Subject 'Računalo PC01' | Set-Content izvjestaj.html -Encoding UTF8
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Selection,
        [string]$Subject = 'Odabir sigurnosnih postavki',
        [datetime]$Date = (Get-Date),
        [string]$NotSetText = 'Ne mijenja se'
    )
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $statusWord = @{ OK = 'U REDU'; Deviates = 'ODSTUPA'; NotSet = 'NIJE POSTAVLJENO' }
    $statusClass = @{ OK = 'good'; Deviates = 'bad'; NotSet = 'warn' }
    $results = @(Get-GpsControlCompliance -Catalog $Catalog -Selection $Selection)
    $enabled = @($Selection.Values | Where-Object { $_ }).Count

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append(@"
<!DOCTYPE html>
<html lang="hr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>GPO Studio – usporedba sa standardima</title>
<style>
:root{--text:#1c1e24;--muted:#585c68;--line:#ced1d9;--good:#12804a;--warn:#b06c00;--bad:#c6202c;--zebra:#f4f5f8;--th:#161f30;--band:#090c14;--amber:#ffc94a;--bar:#e1e4ea}
*{box-sizing:border-box}body{margin:0;background:#e9ebf0;color:var(--text);font:14px/1.45 "Segoe UI",Arial,sans-serif}
.page{max-width:1080px;margin:24px auto;background:#fff;border:1px solid #d5d8df}
.band{background:var(--band);color:#fff;padding:22px 28px 18px;border-bottom:3px solid var(--amber);display:flex;justify-content:space-between;align-items:flex-end;gap:16px;flex-wrap:wrap}
.logo{font:700 26px/1 Bahnschrift,"Segoe UI Semibold",sans-serif;letter-spacing:0}.logo .x{color:#e63946}.logo .d{color:var(--amber)}
.logo small{display:block;margin-top:6px;font:400 11px/1 "Segoe UI",sans-serif;letter-spacing:3px;color:#c0c4ce}
.band h1{margin:0;font:700 18px/1.2 Bahnschrift,"Segoe UI",sans-serif;text-align:right}.band p{margin:4px 0 0;color:#c0c4ce;text-align:right}
.content{padding:24px 28px}h2{font:700 15px/1.3 Bahnschrift,"Segoe UI",sans-serif;margin:28px 0 10px;padding-left:10px;border-left:4px solid #b08014}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.tile{border:1px solid var(--line);padding:12px 14px;background:#f9f9fb}.tile h3{margin:0;font:700 11px/1.2 "Segoe UI",sans-serif;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.tile .n{font:700 28px/1.2 Bahnschrift,"Segoe UI",sans-serif;margin:4px 0}.bar{height:8px;background:var(--bar)}.bar span{display:block;height:100%}
.good{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}.bg-good{background:var(--good)}.bg-warn{background:var(--warn)}.bg-bad{background:var(--bad)}
table{width:100%;border-collapse:collapse;font-size:13px}td.ref{font-family:Consolas,monospace;font-size:11px;color:#5d6478;max-width:96px}th{background:var(--th);color:#fff;text-align:left;font-weight:600;letter-spacing:.04em;padding:7px 8px;font-size:11px;text-transform:uppercase}
td{padding:6px 8px;border-bottom:1px solid #e1e3e9;vertical-align:top}tr:nth-child(even) td{background:var(--zebra)}td.s{font-weight:700;white-space:nowrap}
.note{margin-top:28px;padding:10px 14px;border-left:3px solid #3d6fb6;background:#f3f6fb;color:var(--muted);font-size:12.5px}
.foot{padding:12px 28px 18px;color:var(--muted);font-size:12px;border-top:1px solid var(--line)}
@media print{body{background:#fff}.page{margin:0;border:0}th{-webkit-print-color-adjust:exact;print-color-adjust:exact}.band,.bar span{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
</style></head><body><div class="page">
<div class="band"><div class="logo">AU<span class="x">X</span>ILIUM<span class="d">.</span><small>INFORMATIKA</small></div>
<div><h1>Usporedba sa sigurnosnim standardima</h1><p>
"@)
    $null = $sb.Append((& $enc $Subject)).Append('  ·  ').Append($Date.ToString('dd.MM.yyyy. HH:mm')).Append("</p></div></div>`n<div class=""content"">`n")
    $null = $sb.Append("<p>Uključeno postavki: <b>$enabled</b> od $(@($Catalog.controls).Count). Katalog: $(& $enc (Get-GpsOptionalProperty $Catalog 'catalogVersion')).</p>`n<div class=""tiles"">`n")
    foreach ($r in $results) {
        $cls = if ($r.Total -eq 0) { '' } elseif ($r.Score -ge 80) { 'good' } elseif ($r.Score -ge 50) { 'warn' } else { 'bad' }
        $null = $sb.Append("<div class=""tile""><h3>$(& $enc $r.Title)</h3><div class=""n $cls"">$($r.Score) %</div>")
        $null = $sb.Append("<div class=""bar""><span class=""bg-$cls"" style=""width:$($r.Score)%""></span></div>")
        $null = $sb.Append("<div style=""margin-top:6px"">$($r.Satisfied) od $($r.Total) preporuka</div></div>`n")
    }
    $null = $sb.Append("</div>`n")
    foreach ($r in $results) {
        $null = $sb.Append("<h2>$(& $enc $r.Title)</h2>`n")
        if ($r.Source) { $null = $sb.Append("<p style=""margin:0 0 8px;color:#585c68"">$(& $enc $r.Source)</p>`n") }
        if ($r.Note) { $null = $sb.Append("<p style=""margin:-4px 0 8px;color:#7a7f8c;font-size:12px"">$(& $enc $r.Note)</p>`n") }
        $null = $sb.Append("<table><thead><tr><th>Područje</th><th>Postavka</th><th>Oznaka</th><th>Preporuka</th><th>Odabir / stanje</th><th>Status</th></tr></thead><tbody>`n")
        foreach ($row in @($r.Rows | Sort-Object @{ Expression = { switch ($_.Status) { 'Deviates' { 0 } 'NotSet' { 1 } default { 2 } } } }, Category, Control)) {
            $selected = if ($row.Selected) { $row.Selected } else { $NotSetText }
            $null = $sb.Append("<tr><td>$(& $enc $row.Category)</td><td>$(& $enc $row.Control)</td><td class=""ref"">$(& $enc $row.Reference)</td><td>$(& $enc $row.Recommendation)</td><td>$(& $enc $selected)</td>")
            $null = $sb.Append("<td class=""s $($statusClass[$row.Status])"">$($statusWord[$row.Status])</td></tr>`n")
        }
        $null = $sb.Append("</tbody></table>`n")
    }
    $null = $sb.Append(@"
<div class="note">Postotak se računa samo za preporuke koje GPO Studio može postaviti, a standardi sadrže
stotine preporuka. Izvještaj nije potvrda sukladnosti sa standardom.</div>
</div><div class="foot">GPO Studio · Auxilium Informatika · www.auxilium.hr</div></div></body></html>
"@)
    $sb.ToString()
}

#endregion
