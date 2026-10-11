<#
    Policy Set: skup postavki neovisan o cilju (lokalno računalo ili domenski GPO).

    {
      "name": "...", "description": "...", "version": "1.0.0",
      "settings": [ { "id", "displayName", "scope": "Machine|User", "key", "valueName",
                      "type": "REG_DWORD|REG_SZ|...", "data", "action": "Set|Delete" } ],
      "security": { "MinimumPasswordLength": 14, ... },   # [System Access] u secedit .inf
      "audit":    { "Logon": "Success,Failure", ... }      # auditpol podkategorije
    }
#>

function ConvertTo-GpsComparable {
    param($Value, [string]$Type)
    if ($null -eq $Value) { return '' }
    # Nakon JSON-a REG_BINARY stiže kao niz brojeva, a iz Registry.pol kao byte[].
    if ($Type -eq 'REG_BINARY' -and $Value -isnot [byte[]]) { try { $Value = [byte[]]@($Value) } catch { } }
    if ($Value -is [byte[]]) { return 'hex:' + [BitConverter]::ToString($Value) }
    if ($Value -is [array]) { return (@($Value) | ForEach-Object { [string]$_ }) -join "`n" }
    return [string]$Value
}

function Get-GpsSettingKey {
    param($Key, $ValueName)
    ('{0}\{1}' -f $Key, $ValueName).ToLowerInvariant()
}

function New-GpsPolicySetting {
    <#
    .SYNOPSIS
        Kreira jednu postavku Policy Seta.
    .EXAMPLE
        New-GpsPolicySetting -Scope Machine -Key 'Software\Policies\Microsoft\WindowsStore' -ValueName RemoveWindowsStore -Type REG_DWORD -Data 1
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Machine', 'User')][string]$Scope = 'Machine',
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ValueName,
        [ValidateSet('REG_SZ', 'REG_EXPAND_SZ', 'REG_BINARY', 'REG_DWORD', 'REG_MULTI_SZ', 'REG_QWORD')]
        [string]$Type = 'REG_DWORD',
        $Data,
        [ValidateSet('Set', 'Delete')][string]$Action = 'Set',
        [string]$Id,
        [string]$DisplayName
    )

    # Dopuštamo i unos s prefiksom hive-a; on ujedno određuje scope.
    if ($Key -match '^(HKLM|HKEY_LOCAL_MACHINE)\\(.+)$') { $Scope = 'Machine'; $Key = $Matches[2] }
    elseif ($Key -match '^(HKCU|HKEY_CURRENT_USER)\\(.+)$') { $Scope = 'User'; $Key = $Matches[2] }

    if ($Action -eq 'Set' -and $null -eq $Data) { throw "Postavka $Key\$ValueName nema vrijednost (Data)." }
    if ($Type -in 'REG_DWORD', 'REG_QWORD' -and $Action -eq 'Set') {
        $max = if ($Type -eq 'REG_DWORD') { [uint32]::MaxValue } else { [uint64]::MaxValue }
        if ([decimal]$Data -lt 0 -or [decimal]$Data -gt $max) { throw "Vrijednost '$Data' nije valjana za $Type ($Key\$ValueName)." }
    }

    [pscustomobject]@{
        id          = if ($Id) { $Id } else { "$Scope\$Key\$ValueName" }
        displayName = if ($DisplayName) { $DisplayName } else { $ValueName }
        scope       = $Scope
        key         = $Key.TrimEnd('\')
        valueName   = $ValueName
        type        = $Type
        data        = $Data
        action      = $Action
    }
}

function New-GpsPolicySet {
    <#
    .SYNOPSIS
        Kreira prazan Policy Set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [string]$Version = '1.0.0',
        [object[]]$Setting = @()
    )
    [pscustomobject]@{
        name        = $Name
        description = $Description
        version     = $Version
        settings    = [System.Collections.Generic.List[object]]@($Setting)
        security    = [ordered]@{}
        audit       = [ordered]@{}
    }
}

function ConvertTo-GpsPolicySet {
    <#
    .SYNOPSIS
        Normalizira Policy Set iz bilo kojeg izvora (JSON objekt, hashtable, postojeći set) i validira postavke.
    .DESCRIPTION
        Nedostajući opcionalni dijelovi dobivaju zadane vrijednosti (description '', version '1.0.0',
        prazni security/audit), pa ih cmdleti mogu čitati i pod Set-StrictMode -Version Latest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$InputObject)

    process {
        $get = {
            param($o, [string]$n)
            if ($null -eq $o) { return }
            if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { $o[$n] } }
            elseif ($o.PSObject.Properties[$n]) { $o.PSObject.Properties[$n].Value }
        }

        $name = & $get $InputObject 'name'
        if (-not $name) { throw 'Policy Set nema naziv (name).' }
        $settings = foreach ($s in @(& $get $InputObject 'settings')) {
            if ($null -eq $s) { continue }
            if (-not (& $get $s 'key')) { throw "Postavka u Policy Setu '$name' nema registry ključ (key)." }
            $p = @{
                Key       = & $get $s 'key'
                ValueName = [string](& $get $s 'valueName')
            }
            foreach ($field in 'scope', 'type', 'data', 'action', 'id', 'displayName') {
                $value = & $get $s $field
                if ($null -ne $value) { $p[$field] = $value }
            }
            New-GpsPolicySetting @p
        }

        $version = & $get $InputObject 'version'
        $set = New-GpsPolicySet -Name $name -Description ([string](& $get $InputObject 'description')) `
            -Version $(if ($version) { [string]$version } else { '1.0.0' }) -Setting @($settings)
        foreach ($section in 'security', 'audit') {
            $source = & $get $InputObject $section
            if ($null -eq $source) { continue }
            if ($source -is [System.Collections.IDictionary]) { foreach ($k in $source.Keys) { $set.$section[$k] = $source[$k] } }
            else { foreach ($prop in $source.PSObject.Properties) { $set.$section[$prop.Name] = $prop.Value } }
        }
        $set
    }
}

function Import-GpsPolicySet {
    <#
    .SYNOPSIS
        Učitava i validira Policy Set iz JSON datoteke.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    try { ConvertTo-GpsPolicySet -InputObject $json }
    catch { throw "Neispravan Policy Set '$Path': $($_.Exception.Message)" }
}

function Export-GpsPolicySet {
    <#
    .SYNOPSIS
        Sprema Policy Set u JSON (čitljiv u Git diffu).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PolicySet,
        [Parameter(Mandatory)][string]$Path
    )
    $PolicySet | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Merge-GpsPolicySet {
    <#
    .SYNOPSIS
        Spaja postojeće Registry.pol zapise s postavkama jednog scopea (Machine ili User).
    .DESCRIPTION
        Set    -> zamjenjuje postojeću vrijednost (i uklanja eventualni **del. zapis).
        Delete -> uklanja vrijednost i dodaje **del.<ValueName> zapis, kao GPMC kod "Disabled"
                  stanja koje briše vrijednost na klijentu.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Existing = @(),
        [AllowEmptyCollection()][object[]]$Setting = @()
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Existing) { if ($null -ne $e) { $result.Add($e) } }

    foreach ($s in $Setting) {
        $target = Get-GpsSettingKey $s.key $s.valueName
        $delMarker = Get-GpsSettingKey $s.key ('**del.' + $s.valueName)
        for ($i = $result.Count - 1; $i -ge 0; $i--) {
            $k = Get-GpsSettingKey $result[$i].Key $result[$i].ValueName
            if ($k -eq $target -or $k -eq $delMarker) { $result.RemoveAt($i) }
        }

        if ($s.action -eq 'Delete') {
            $result.Add([pscustomobject]@{ Key = $s.key; ValueName = '**del.' + $s.valueName; Type = 'REG_SZ'; Data = ' ' })
        }
        else {
            $result.Add([pscustomobject]@{ Key = $s.key; ValueName = $s.valueName; Type = $s.type; Data = $s.data })
        }
    }
    return , $result
}

function Compare-GpsPolicySet {
    <#
    .SYNOPSIS
        Uspoređuje trenutno stanje (Registry.pol zapisi ili GPO vrijednosti) sa željenim postavkama.
    .OUTPUTS
        Objekti sa Status = Added | Changed | Removed | Unchanged.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Current = @(),
        [AllowEmptyCollection()][object[]]$Setting = @()
    )

    $index = @{}
    foreach ($c in $Current) { if ($null -ne $c) { $index[(Get-GpsSettingKey $c.Key $c.ValueName)] = $c } }

    foreach ($s in $Setting) {
        $cur = $index[(Get-GpsSettingKey $s.key $s.valueName)]
        $hasDel = $index.ContainsKey((Get-GpsSettingKey $s.key ('**del.' + $s.valueName)))

        $status = if ($s.action -eq 'Delete') {
            if ($cur) { 'Removed' } elseif ($hasDel) { 'Unchanged' } else { 'Added' }
        }
        elseif (-not $cur) { 'Added' }
        elseif ($cur.Type -ne $s.type -or (ConvertTo-GpsComparable $cur.Data $cur.Type) -ne (ConvertTo-GpsComparable $s.data $s.type)) { 'Changed' }
        else { 'Unchanged' }

        [pscustomobject]@{
            Status    = $status
            Scope     = $s.scope
            Key       = $s.key
            ValueName = $s.valueName
            Current   = if ($cur) { ConvertTo-GpsComparable $cur.Data $cur.Type } else { $null }
            Desired   = if ($s.action -eq 'Delete') { '<obrisano>' } else { ConvertTo-GpsComparable $s.data $s.type }
            Action    = $s.action
        }
    }
}
