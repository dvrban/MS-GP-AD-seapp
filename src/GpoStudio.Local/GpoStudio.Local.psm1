<#
    GpoStudio.Local: primjena Policy Seta na lokalni Group Policy jednog ili više računala.

    Na ciljanom računalu ništa se ne instalira: potrebne funkcije se šalju kao tekst kroz
    Invoke-Command (WinRM), a za lokalno računalo pozivaju se izravno.
#>
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\GpoStudio.Core\GpoStudio.Core.psd1') -Global

$script:GpsLocalNames = $null

# Client-side extension za Administrative Templates + GUID alata (Machine / User).
$script:GpsAdmCse = @{
    Machine = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
    User    = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F73-3407-48AE-BA88-E8213C6761F1}]'
}

# Nazivi podkategorija u auditpol-u su lokalizirani, pa ih mapiramo na GUID-ove.
$script:GpsAuditGuids = @{
    'Credential Validation'     = '{0CCE923F-69AE-11D9-BED3-505054503030}'
    'Logon'                     = '{0CCE9215-69AE-11D9-BED3-505054503030}'
    'Logoff'                    = '{0CCE9216-69AE-11D9-BED3-505054503030}'
    'Account Lockout'           = '{0CCE9217-69AE-11D9-BED3-505054503030}'
    'Special Logon'             = '{0CCE921B-69AE-11D9-BED3-505054503030}'
    'Process Creation'          = '{0CCE922B-69AE-11D9-BED3-505054503030}'
    'User Account Management'   = '{0CCE9235-69AE-11D9-BED3-505054503030}'
    'Security Group Management' = '{0CCE9237-69AE-11D9-BED3-505054503030}'
}

#region Funkcije koje se izvršavaju NA CILJANOM računalu

function ConvertTo-GpsHashtable {
    param($InputObject)
    $h = [ordered]@{}
    if ($null -eq $InputObject) { return $h }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in $InputObject.Keys) { $h[$k] = $InputObject[$k] }
    }
    else {
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    }
    $h
}

function Get-GpsLocalGpRoot {
    # 32-bitni proces na 64-bitnom Windowsu WOW64 preusmjerava System32 u SysWOW64,
    # koji Group Policy servis ne čita; Sysnative vodi na pravi System32.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $env:windir 'Sysnative\GroupPolicy')
    }
    Join-Path $env:windir 'System32\GroupPolicy'
}

function Update-GpsGptIni {
    <# Povećava verziju u gpt.ini i upisuje CSE GUID-ove; bez toga klijent ignorira promjenu. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string[]]$Scope,
        [Parameter(Mandatory)][hashtable]$ExtensionNames
    )
    $path = Join-Path $Root 'gpt.ini'
    $lines = if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path) } else { @('[General]') }

    $values = [ordered]@{}
    foreach ($line in $lines) { if ($line -match '^\s*([^=\[]+?)\s*=\s*(.*)$') { $values[$Matches[1]] = $Matches[2] } }

    $version = if ($values.Contains('Version')) { [uint32]$values['Version'] } else { [uint32]0 }
    $user = $version -shr 16
    $machine = $version -band 0xFFFF
    if ('Machine' -in $Scope) { $machine = ($machine + 1) % 0x10000 }
    if ('User' -in $Scope) { $user = ($user + 1) % 0x10000 }
    $values['Version'] = [string](([uint32]$user -shl 16) -bor $machine)

    foreach ($s in $Scope) {
        $attr = if ($s -eq 'Machine') { 'gPCMachineExtensionNames' } else { 'gPCUserExtensionNames' }
        $current = if ($values.Contains($attr)) { $values[$attr] } else { '' }
        # Svaka [ ] grupa je CSE GUID + GUID-ovi alata. gpedit uz Administrative Templates zna dodati
        # još alata, pa se naš alat spaja u postojeću grupu istog CSE-a umjesto da se dodaje duplikat.
        # Grupe se sortiraju po CSE GUID-u, a alati unutar grupe uzlazno (kao GPMC).
        $map = @{}
        foreach ($group in [regex]::Matches($current + $ExtensionNames[$s], '\[([^\]]*)\]')) {
            $guids = @([regex]::Matches($group.Groups[1].Value, '\{[0-9A-Fa-f-]+\}') | ForEach-Object { $_.Value.ToUpperInvariant() })
            if ($guids.Count -eq 0) { continue }
            if (-not $map.ContainsKey($guids[0])) { $map[$guids[0]] = [System.Collections.Generic.List[string]]::new() }
            foreach ($tool in @($guids | Select-Object -Skip 1)) { if (-not $map[$guids[0]].Contains($tool)) { $map[$guids[0]].Add($tool) } }
        }
        $cses = [string[]]@($map.Keys)
        [Array]::Sort($cses, [StringComparer]::OrdinalIgnoreCase)
        $values[$attr] = -join @(foreach ($cse in $cses) {
                $tools = [string[]]@($map[$cse])
                [Array]::Sort($tools, [StringComparer]::OrdinalIgnoreCase)
                '[' + $cse + (-join $tools) + ']'
            })
    }

    $out = @('[General]') + @($values.Keys | ForEach-Object { "$_=$($values[$_])" })
    Set-Content -LiteralPath $path -Value $out -Encoding ASCII
}

function Get-GpsLocalPolicyCore {
    param([string[]]$Scope)
    foreach ($s in $Scope) {
        foreach ($e in @(Read-GpsRegistryPol -Path (Join-Path (Get-GpsLocalGpRoot) "$s\Registry.pol"))) {
            [pscustomobject]@{ ComputerName = [Environment]::MachineName; Scope = $s; Key = $e.Key; ValueName = $e.ValueName; Type = $e.Type; Data = $e.Data }
        }
    }
}

function Backup-GpsLocalPolicyCore {
    <# Sprema GroupPolicy mapu, sigurnosnu politiku i reviziju; manifest se piše zadnji. #>
    param([string]$Destination)
    if (-not $Destination) {
        $Destination = Join-Path $env:ProgramData ("GpoStudio\Backup\{0:yyyyMMdd-HHmmss}" -f (Get-Date))
    }
    $null = New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop
    $gpRoot = Get-GpsLocalGpRoot
    $gpExisted = Test-Path -LiteralPath $gpRoot
    if ($gpExisted) { Copy-Item -LiteralPath $gpRoot -Destination (Join-Path $Destination 'GroupPolicy') -Recurse -Force -ErrorAction Stop }

    $secInf = Join-Path $Destination 'secpol.inf'
    $output = & secedit.exe /export /cfg $secInf /areas SECURITYPOLICY /quiet 2>&1
    if ($LASTEXITCODE -ne 0) { throw "secedit /export nije uspio ($LASTEXITCODE): $output" }
    $auditCsv = Join-Path $Destination 'audit.csv'
    $output = & auditpol.exe /backup "/file:$auditCsv" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $auditCsv)) { throw "auditpol /backup nije uspio ($LASTEXITCODE): $output" }

    [ordered]@{ computerName = [Environment]::MachineName; created = (Get-Date).ToString('o'); gpRootExisted = $gpExisted } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'gpostudio-backup.json') -Encoding UTF8
    [pscustomobject]@{ ComputerName = [Environment]::MachineName; BackupPath = $Destination }
}

function Restore-GpsLocalPolicyCore {
    <# Vraća backup; prije ikakve promjene provjerava da je putanja stvarno backup GPO Studija. #>
    param([Parameter(Mandatory)][string]$BackupPath)
    $messages = [System.Collections.Generic.List[string]]::new()
    try {
        $manifestPath = Join-Path $BackupPath 'gpostudio-backup.json'
        if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) { throw "Backup '$BackupPath' ne postoji." }
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw "'$BackupPath' nije backup GPO Studija (nema gpostudio-backup.json)." }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

        # Trenutnu mapu preimenujemo i brišemo tek kad je kopija uspjela.
        $gpRoot = Get-GpsLocalGpRoot
        $savedGp = Join-Path $BackupPath 'GroupPolicy'
        $old = $null
        if (Test-Path -LiteralPath $gpRoot) {
            $old = '{0}.gpostudio-old-{1:yyyyMMddHHmmss}' -f $gpRoot, (Get-Date)
            Rename-Item -LiteralPath $gpRoot -NewName (Split-Path -Leaf $old) -ErrorAction Stop
        }
        try {
            if ($manifest.gpRootExisted) { Copy-Item -LiteralPath $savedGp -Destination $gpRoot -Recurse -Force -ErrorAction Stop }
        }
        catch {
            if (Test-Path -LiteralPath $gpRoot) { Remove-Item -LiteralPath $gpRoot -Recurse -Force }
            if ($old) { Rename-Item -LiteralPath $old -NewName (Split-Path -Leaf $gpRoot) }
            throw
        }
        if ($old) { Remove-Item -LiteralPath $old -Recurse -Force }
        # Verzija mora porasti i nakon vraćanja, inače klijent preskače obradu.
        if (Test-Path -LiteralPath $gpRoot) { Update-GpsGptIni -Root $gpRoot -Scope Machine, User -ExtensionNames $script:GpsAdmCse }

        $inf = Join-Path $BackupPath 'secpol.inf'
        if (Test-Path -LiteralPath $inf) {
            $db = Join-Path $env:TEMP ('gpostudio-restore-{0}.sdb' -f [guid]::NewGuid().ToString('N'))
            try {
                $output = & secedit.exe /configure /db $db /cfg $inf /overwrite /areas SECURITYPOLICY /quiet 2>&1
                if ($LASTEXITCODE -ne 0) { $messages.Add("secedit /configure završio s kodom ${LASTEXITCODE}: $output") }
            }
            finally { Remove-Item -LiteralPath $db, ([IO.Path]::ChangeExtension($db, '.jfm')) -Force -ErrorAction SilentlyContinue }
        }
        $csv = Join-Path $BackupPath 'audit.csv'
        if (Test-Path -LiteralPath $csv) {
            $output = & auditpol.exe /restore "/file:$csv" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "auditpol /restore nije uspio ($LASTEXITCODE): $output" }
        }
        $null = & gpupdate.exe /force
        $status = 'OK'
    }
    catch {
        $messages.Add("Greška: $_")
        $status = 'Error'
    }
    [pscustomobject]@{ ComputerName = [Environment]::MachineName; Status = $status; BackupPath = $BackupPath; Messages = $messages }
}

function Set-GpsSecurityPolicyCore {
    <# Primjenjuje [System Access] postavke (lozinke, zaključavanje računa) preko secedit-a. #>
    param([System.Collections.IDictionary]$Security)
    if (-not $Security -or $Security.Count -eq 0) { return }
    # Nova baza za svaki poziv i /overwrite: inače secedit iznova primjenjuje i predloške iz ranijih pokretanja.
    $id = [guid]::NewGuid().ToString('N')
    $inf = Join-Path $env:TEMP "gpostudio-security-$id.inf"
    $db = Join-Path $env:TEMP "gpostudio-security-$id.sdb"
    $content = @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[System Access]') +
        @($Security.Keys | ForEach-Object { "$_ = $($Security[$_])" })
    try {
        Set-Content -LiteralPath $inf -Value $content -Encoding Unicode
        $output = & secedit.exe /configure /db $db /cfg $inf /overwrite /areas SECURITYPOLICY /quiet 2>&1
        if ($LASTEXITCODE -ne 0) { throw "secedit nije uspio ($LASTEXITCODE): $output" }
    }
    finally {
        Remove-Item -LiteralPath $inf, $db, ([IO.Path]::ChangeExtension($db, '.jfm')) -Force -ErrorAction SilentlyContinue
    }
}

function Set-GpsAuditPolicyCore {
    <# Primjenjuje naprednu reviziju, npr. @{ 'Logon' = 'Success,Failure' }. #>
    param([System.Collections.IDictionary]$Audit)
    if (-not $Audit) { return }
    foreach ($name in $Audit.Keys) {
        $flags = [string]$Audit[$name]
        # Contains, ne ContainsKey: na udaljenom računalu ovo je OrderedDictionary iz payloada.
        $sub = if ($script:GpsAuditGuids.Contains($name)) { $script:GpsAuditGuids[$name] } else { $name }
        $success = if ($flags -match 'Success') { 'enable' } else { 'disable' }
        $failure = if ($flags -match 'Failure') { 'enable' } else { 'disable' }
        $output = & auditpol.exe /set "/subcategory:$sub" "/success:$success" "/failure:$failure" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "auditpol nije uspio za '$name': $output" }
    }
}

function Invoke-GpsLocalApplyCore {
    <# Cijeli tijek primjene na jednom računalu: backup, merge, zapis, gpt.ini, secedit, auditpol, gpupdate. #>
    param(
        [Parameter(Mandatory)][string]$PolicySetJson,
        [bool]$WhatIfMode,
        [bool]$NoGpUpdate
    )
    $set = $PolicySetJson | ConvertFrom-Json
    $gpRoot = Get-GpsLocalGpRoot
    $messages = [System.Collections.Generic.List[string]]::new()
    $diff = @()
    $backup = $null

    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
        $messages.Add('Računalo je u domeni: domenski GPO-ovi imaju prednost pred lokalnim postavkama.')
    }

    try {
        $byScope = @{}
        foreach ($s in @($set.settings)) { if ($s) { $byScope[$s.scope] += @($s) } }

        foreach ($scope in $byScope.Keys) {
            $polPath = Join-Path $gpRoot "$scope\Registry.pol"
            $current = @(Read-GpsRegistryPol -Path $polPath)
            $diff += @(Compare-GpsPolicySet -Current $current -Setting $byScope[$scope])
        }
        $changedScopes = @($diff | Where-Object Status -ne 'Unchanged' | ForEach-Object Scope | Sort-Object -Unique)
        $securityProp = $set.PSObject.Properties['security']
        $auditProp = $set.PSObject.Properties['audit']
        $security = ConvertTo-GpsHashtable $(if ($securityProp) { $securityProp.Value })
        $audit = ConvertTo-GpsHashtable $(if ($auditProp) { $auditProp.Value })

        if ($WhatIfMode) {
            return [pscustomobject]@{ ComputerName = [Environment]::MachineName; Status = 'WhatIf'; Diff = $diff; BackupPath = $null; Messages = $messages }
        }

        $backup = (Backup-GpsLocalPolicyCore).BackupPath
        foreach ($scope in $changedScopes) {
            $polPath = Join-Path $gpRoot "$scope\Registry.pol"
            $merged = Merge-GpsPolicySet -Existing @(Read-GpsRegistryPol -Path $polPath) -Setting $byScope[$scope]
            Write-GpsRegistryPol -Path $polPath -Entry $merged -Confirm:$false
        }
        if ($changedScopes.Count -gt 0) { Update-GpsGptIni -Root $gpRoot -Scope $changedScopes -ExtensionNames $script:GpsAdmCse }

        Set-GpsSecurityPolicyCore -Security $security
        Set-GpsAuditPolicyCore -Audit $audit

        if (-not $NoGpUpdate) { $null = & gpupdate.exe /target:computer /force }
        $status = 'OK'
    }
    catch {
        $messages.Add("Greška: $_")
        $status = 'Error'
    }
    [pscustomobject]@{ ComputerName = [Environment]::MachineName; Status = $status; Diff = $diff; BackupPath = $backup; Messages = $messages }
}

#endregion

#region Javni cmdleti (izvršavaju se na admin stanici)

$script:GpsRemoteFunctions = @(
    'ConvertFrom-GpsRegistryPolBytes', 'ConvertTo-GpsRegistryPolBytes', 'ConvertTo-GpsRegTypeName',
    'Read-GpsRegistryPol', 'Write-GpsRegistryPol', 'Merge-GpsPolicySet', 'Compare-GpsPolicySet',
    'ConvertTo-GpsComparable', 'Get-GpsSettingKey',
    'ConvertTo-GpsHashtable', 'Get-GpsLocalGpRoot', 'Update-GpsGptIni', 'Get-GpsLocalPolicyCore', 'Backup-GpsLocalPolicyCore',
    'Restore-GpsLocalPolicyCore', 'Set-GpsSecurityPolicyCore', 'Set-GpsAuditPolicyCore', 'Invoke-GpsLocalApplyCore'
)

function Get-GpsRemotePayload {
    # Definicije funkcija i varijabli koje se šalju na udaljeno računalo.
    $core = Get-Module GpoStudio.Core
    $sb = [System.Text.StringBuilder]::new()
    foreach ($name in $script:GpsRemoteFunctions) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = & $core { param($n) Get-Command -Name $n -CommandType Function } $name }
        $null = $sb.AppendLine("function $name {`n$($cmd.Definition)`n}")
    }
    $toLiteral = {
        param($h)
        $pairs = foreach ($k in $h.Keys) {
            $v = $h[$k]
            $literal = if ($v -is [int] -or $v -is [uint32]) { "$v" } else { "'" + ([string]$v).Replace("'", "''") + "'" }
            "'$k' = $literal"
        }
        '[ordered]@{ ' + ($pairs -join '; ') + ' }'
    }
    $variables = @{
        GpsRegTypes   = & $core { $script:GpsRegTypes }
        GpsAdmCse     = $script:GpsAdmCse
        GpsAuditGuids = $script:GpsAuditGuids
    }
    foreach ($name in $variables.Keys) { $null = $sb.AppendLine("`$script:$name = $(& $toLiteral $variables[$name])") }
    $sb.ToString()
}

function Get-GpsLocalNameSet {
    # Sva imena pod kojima je admin stanica dostupna: NetBIOS, DNS ime, FQDN i lokalne IP adrese.
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @('.', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME, [System.Net.Dns]::GetHostName())) {
        if ($n) { $null = $names.Add($n) }
    }
    try {
        $ip = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        if ($ip.DomainName) { $null = $names.Add("$($ip.HostName).$($ip.DomainName)") }
    }
    catch { }
    try { $null = $names.Add([System.Net.Dns]::GetHostEntry('').HostName) } catch { }
    try { foreach ($a in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) { $null = $names.Add($a.IPAddressToString) } } catch { }
    , $names
}

function Test-GpsIsLocalComputer([string]$ComputerName) {
    if (-not $ComputerName) { return $true }
    if (-not $script:GpsLocalNames) { $script:GpsLocalNames = Get-GpsLocalNameSet }
    $name = $ComputerName.Trim()
    # '.' je lokalno računalo; točka na kraju FQDN-a (ADMIN01.firma.local.) se ignorira.
    $script:GpsLocalNames.Contains($name) -or $script:GpsLocalNames.Contains($name.TrimEnd('.'))
}

function Invoke-GpsOnTarget {
    param([string[]]$ComputerName, [string]$Function, [object[]]$ArgumentList, [pscredential]$Credential, [int]$ThrottleLimit = 16)

    $local = @($ComputerName | Where-Object { Test-GpsIsLocalComputer $_ })
    $remote = @($ComputerName | Where-Object { -not (Test-GpsIsLocalComputer $_) })

    if ($local.Count -gt 0 -or -not $ComputerName) { & $Function @ArgumentList }

    if ($remote.Count -gt 0) {
        $p = @{
            ComputerName  = $remote
            ThrottleLimit = $ThrottleLimit
            ArgumentList  = @((Get-GpsRemotePayload), $Function, $ArgumentList)
            ScriptBlock   = {
                param($payload, $fn, $fnArgs)
                . ([scriptblock]::Create($payload))
                & $fn @fnArgs
            }
        }
        if ($Credential) { $p.Credential = $Credential }
        Invoke-Command @p -ErrorAction Continue | Select-Object * -ExcludeProperty RunspaceId, PSShowComputerName
    }
}

function Get-GpsLocalPolicy {
    <#
    .SYNOPSIS
        Čita Registry.pol zapise lokalnog GP-a (Machine/User) s jednog ili više računala.
    .EXAMPLE
        Get-GpsLocalPolicy -ComputerName PC01, PC02 -Scope Machine
    #>
    [CmdletBinding()]
    param(
        [string[]]$ComputerName,
        [ValidateSet('Machine', 'User')][string[]]$Scope = @('Machine', 'User'),
        [pscredential]$Credential
    )
    Invoke-GpsOnTarget -ComputerName $ComputerName -Function 'Get-GpsLocalPolicyCore' -ArgumentList @(, $Scope) -Credential $Credential
}

function Set-GpsLocalPolicy {
    <#
    .SYNOPSIS
        Primjenjuje Policy Set na lokalni GP jednog ili više računala.
    .DESCRIPTION
        Za svako računalo: backup -> diff -> merge u Registry.pol -> gpt.ini -> secedit -> auditpol -> gpupdate.
        S -WhatIf vraća samo diff, bez ikakvih promjena.
    .EXAMPLE
        $set = Import-GpsPolicySet .\examples\radna-stanica-baseline.json
        Set-GpsLocalPolicy -PolicySet $set -ComputerName PC01, PC02 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$PolicySet,
        [string[]]$ComputerName,
        [pscredential]$Credential,
        [switch]$NoGpUpdate,
        [int]$ThrottleLimit = 16
    )
    # Normalizacija prije bilo kakve promjene: kasnije čitanje name/version ne smije pasti pod StrictMode.
    $PolicySet = ConvertTo-GpsPolicySet -InputObject $PolicySet
    $targets = if ($ComputerName) { $ComputerName -join ', ' } else { [Environment]::MachineName }
    $json = $PolicySet | ConvertTo-Json -Depth 10 -Compress
    $whatIfMode = -not $PSCmdlet.ShouldProcess($targets, "Primjena Policy Seta '$($PolicySet.name)' na lokalni GP")

    $results = @(Invoke-GpsOnTarget -ComputerName $ComputerName -Function 'Invoke-GpsLocalApplyCore' `
            -ArgumentList @($json, $whatIfMode, [bool]$NoGpUpdate) -Credential $Credential -ThrottleLimit $ThrottleLimit)

    if (-not $whatIfMode) {
        foreach ($r in $results) {
            Write-GpsAuditLog -Action 'Set-GpsLocalPolicy' -Target $r.ComputerName -Result $r.Status -Details @{
                policySet = $PolicySet.name; version = $PolicySet.version; backup = $r.BackupPath
                changes   = @($r.Diff | Where-Object Status -ne 'Unchanged' | ForEach-Object { "$($_.Status): $($_.Key)\$($_.ValueName)" })
            }
        }
    }
    $results
}

function Backup-GpsLocalPolicy {
    <#
    .SYNOPSIS
        Sprema kopiju lokalnog GP-a, sigurnosne politike i revizije (na ciljanom računalu).
    .OUTPUTS
        Objekti s ComputerName i BackupPath.
    #>
    [CmdletBinding()]
    param([string[]]$ComputerName, [pscredential]$Credential)
    Invoke-GpsOnTarget -ComputerName $ComputerName -Function 'Backup-GpsLocalPolicyCore' -ArgumentList @() -Credential $Credential
}

function Restore-GpsLocalPolicy {
    <#
    .SYNOPSIS
        Vraća lokalni GP iz backupa koji je napravio Backup-GpsLocalPolicy ili Set-GpsLocalPolicy.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$ComputerName,
        [pscredential]$Credential
    )
    $target = if ($ComputerName) { $ComputerName } else { [Environment]::MachineName }
    if ($PSCmdlet.ShouldProcess($target, "Vraćanje lokalnog GP-a iz $BackupPath")) {
        $results = @(Invoke-GpsOnTarget -ComputerName $ComputerName -Function 'Restore-GpsLocalPolicyCore' -ArgumentList @($BackupPath) -Credential $Credential)
        foreach ($r in $results) {
            Write-GpsAuditLog -Action 'Restore-GpsLocalPolicy' -Target $r.ComputerName -Result $r.Status -Details @{ backup = $BackupPath; messages = @($r.Messages) }
        }
        $results
    }
}

#endregion

Export-ModuleMember -Function Get-GpsLocalPolicy, Set-GpsLocalPolicy, Backup-GpsLocalPolicy, Restore-GpsLocalPolicy
