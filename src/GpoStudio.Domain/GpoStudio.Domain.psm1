<#
    GpoStudio.Domain: objava Policy Seta kao domenskog GPO-a preko RSAT GroupPolicy modula.

    Sve operacije idu na PDC emulator (kao u GPMC-u) da se izbjegnu konflikti u replikaciji.
    Preduvjet: RSAT GroupPolicy i ActiveDirectory moduli (u PS7: -UseWindowsPowerShell).
#>
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\GpoStudio.Core\GpoStudio.Core.psd1') -Global

$script:GpsTypeToKind = @{
    REG_SZ        = 'String'
    REG_EXPAND_SZ = 'ExpandString'
    REG_BINARY    = 'Binary'
    REG_DWORD     = 'DWord'
    REG_MULTI_SZ  = 'MultiString'
    REG_QWORD     = 'QWord'
}
$script:GpsProtectedGpos = @(
    '31B2F340-016D-11D2-945F-00C04FB984F9' # Default Domain Policy
    '6AC1786C-016F-11D2-945F-00C04FB984F9' # Default Domain Controllers Policy
)

function Import-GpsRsatModules {
    foreach ($m in 'GroupPolicy', 'ActiveDirectory') {
        if (Get-Module $m) { continue }
        if (-not (Get-Module $m -ListAvailable)) {
            throw "Modul '$m' nije instaliran. Instalirajte RSAT: Add-WindowsCapability -Online -Name Rsat.$(if ($m -eq 'GroupPolicy') { 'GroupPolicy.Management.Tools' } else { 'ActiveDirectory.DS-LDS.Tools' })~~~~0.0.1.0"
        }
        $p = @{ Name = $m; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSEdition -eq 'Core' -and $m -eq 'GroupPolicy') { $p.UseWindowsPowerShell = $true }
        Import-Module @p -Global
    }
}

function Get-GpsDomainContext {
    <#
    .SYNOPSIS
        Vraća domenu i PDC emulator na koji se šalju sve promjene.
    #>
    [CmdletBinding()]
    param([string]$Domain)
    Import-GpsRsatModules
    $p = @{}
    if ($Domain) { $p.Identity = $Domain }
    $d = Get-ADDomain @p
    [pscustomobject]@{ Domain = $d.DNSRoot; DistinguishedName = $d.DistinguishedName; Server = $d.PDCEmulator }
}

function Get-GpsHivePath {
    param($Setting)
    $hive = if ($Setting.scope -eq 'User') { 'HKCU' } else { 'HKLM' }
    "$hive\$($Setting.key)"
}

function Get-GpsDomainOuTree {
    <#
    .SYNOPSIS
        Popis OU-ova s povezanim GPO-ovima i stanjem nasljeđivanja (za stablo u GUI-u).
    #>
    [CmdletBinding()]
    param([string]$Domain)
    $ctx = Get-GpsDomainContext -Domain $Domain
    $containers = @([pscustomobject]@{ Name = $ctx.Domain; DistinguishedName = $ctx.DistinguishedName }) +
        @(Get-ADOrganizationalUnit -Filter * -Server $ctx.Server | Sort-Object DistinguishedName)
    foreach ($c in $containers) {
        $inh = Get-GPInheritance -Target $c.DistinguishedName -Domain $ctx.Domain -Server $ctx.Server
        [pscustomobject]@{
            Name              = $c.Name
            DistinguishedName = $c.DistinguishedName
            InheritanceBlocked = $inh.GpoInheritanceBlocked
            LinkedGpos        = @($inh.GpoLinks | ForEach-Object {
                    [pscustomobject]@{ DisplayName = $_.DisplayName; Enabled = $_.Enabled; Enforced = $_.Enforced; Order = $_.Order }
                })
        }
    }
}

function Get-GpsDomainPolicyState {
    <#
    .SYNOPSIS
        Čita trenutne vrijednosti iz GPO-a za postavke iz Policy Seta (format kompatibilan s Compare-GpsPolicySet).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PolicySet,
        [Parameter(Mandatory)][guid]$Guid,
        [Parameter(Mandatory)]$Context
    )
    $kindToType = @{}
    foreach ($k in $script:GpsTypeToKind.Keys) { $kindToType[$script:GpsTypeToKind[$k]] = $k }
    foreach ($s in $PolicySet.settings) {
        $v = Get-GPRegistryValue -Guid $Guid -Key (Get-GpsHivePath $s) -ValueName $s.valueName `
            -Domain $Context.Domain -Server $Context.Server -ErrorAction SilentlyContinue
        if (-not $v) { continue }
        if ([string]$v.PolicyState -eq 'Delete') {
            [pscustomobject]@{ Key = $s.key; ValueName = '**del.' + $s.valueName; Type = 'REG_SZ'; Data = ' ' }
        }
        else {
            $type = $kindToType[[string]$v.Type]
            $data = if ($type -eq 'REG_DWORD') { [uint32]([int64]$v.Value -band 0xFFFFFFFF) } else { $v.Value }
            [pscustomobject]@{ Key = $s.key; ValueName = $s.valueName; Type = $type; Data = $data }
        }
    }
}

function Compare-GpsDomainPolicy {
    <#
    .SYNOPSIS
        Diff između postojećeg domenskog GPO-a i Policy Seta (bez promjena).
    .EXAMPLE
        Compare-GpsDomainPolicy -PolicySet $set -GpoName 'WS - Baseline'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PolicySet,
        [Parameter(Mandatory)][string]$GpoName,
        [string]$Domain
    )
    $ctx = Get-GpsDomainContext -Domain $Domain
    $gpo = Get-GPO -Name $GpoName -Domain $ctx.Domain -Server $ctx.Server -ErrorAction SilentlyContinue
    $current = if ($gpo) { @(Get-GpsDomainPolicyState -PolicySet $PolicySet -Guid $gpo.Id -Context $ctx) } else { @() }
    Compare-GpsPolicySet -Current $current -Setting @($PolicySet.settings)
}

function Publish-GpsDomainPolicy {
    <#
    .SYNOPSIS
        Kreira ili ažurira domenski GPO prema Policy Setu, povezuje ga i postavlja sigurnosno filtriranje.
    .DESCRIPTION
        1. Na PDC emulatoru dohvati ili kreira GPO (postojeći se prvo backupira).
        2. Upiše administrativne predloške (Set-GPRegistryValue; Delete -> -Disable, tj. **del.).
        3. Opcionalno poveže GPO na OU/domenu (New-GPLink).
        4. Opcionalno ograniči primjenu na grupu (Set-GPPermission GpoApply), uz zadržano
           čitanje za Authenticated Users (MS16-072).
        Sigurnosne postavke i revizija za domenu (GptTmpl.inf, audit.csv u SYSVOL-u) su faza 3.
    .EXAMPLE
        Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS - Baseline' -LinkTarget 'OU=Racunala,DC=firma,DC=local' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$PolicySet,
        [Parameter(Mandatory)][string]$GpoName,
        [string]$Domain,
        [string]$LinkTarget,
        [string]$ApplyToGroup,
        [string]$BackupPath = $(Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }) 'GpoStudio\GpoBackup'),
        [switch]$Force
    )
    $ctx = Get-GpsDomainContext -Domain $Domain
    $common = @{ Domain = $ctx.Domain; Server = $ctx.Server }

    $gpo = Get-GPO -Name $GpoName @common -ErrorAction SilentlyContinue
    if ($gpo -and $gpo.Id.ToString().ToUpperInvariant() -in $script:GpsProtectedGpos -and -not $Force) {
        throw "'$GpoName' je zadani domenski GPO. Promjene na njemu zahtijevaju -Force."
    }

    $diff = @(if ($gpo) {
            Compare-GpsPolicySet -Current @(Get-GpsDomainPolicyState -PolicySet $PolicySet -Guid $gpo.Id -Context $ctx) -Setting @($PolicySet.settings)
        } else {
            Compare-GpsPolicySet -Current @() -Setting @($PolicySet.settings)
        })
    $changes = @($diff | Where-Object Status -ne 'Unchanged')

    $action = "Objava Policy Seta '$($PolicySet.name)': $($changes.Count) promjena" + $(if ($LinkTarget) { ", link na $LinkTarget" })
    if (-not $PSCmdlet.ShouldProcess("$GpoName ($($ctx.Server))", $action)) {
        return [pscustomobject]@{ GpoName = $GpoName; Server = $ctx.Server; Status = 'WhatIf'; Diff = $diff; Backup = $null }
    }

    $backup = $null
    if ($gpo) {
        $null = New-Item -ItemType Directory -Path $BackupPath -Force
        $backup = Backup-GPO -Guid $gpo.Id -Path $BackupPath -Comment "GpoStudio prije '$($PolicySet.name)' $($PolicySet.version)" @common
    }
    else {
        $gpo = New-GPO -Name $GpoName -Comment "$($PolicySet.description) [GpoStudio $($PolicySet.name) $($PolicySet.version)]" @common
    }

    $wanted = @{}
    foreach ($c in $changes) { $wanted[(Get-GpsHivePath ([pscustomobject]@{ scope = $c.Scope; key = $c.Key })) + '\' + $c.ValueName] = $true }

    foreach ($s in $PolicySet.settings) {
        $keyPath = Get-GpsHivePath $s
        if (-not $wanted.ContainsKey("$keyPath\$($s.valueName)")) { continue }
        if ($s.action -eq 'Delete') {
            $null = Set-GPRegistryValue -Guid $gpo.Id -Key $keyPath -ValueName $s.valueName -Disable @common
        }
        else {
            $value = $s.data
            # Set-GPRegistryValue očekuje Int32 za DWord; vrijednosti iznad 2^31 prevodimo bit-po-bit.
            if ($s.type -eq 'REG_DWORD') { $value = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$s.data), 0) }
            if ($s.type -eq 'REG_QWORD') { $value = [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$s.data), 0) }
            $null = Set-GPRegistryValue -Guid $gpo.Id -Key $keyPath -ValueName $s.valueName -Type $script:GpsTypeToKind[$s.type] -Value $value @common
        }
    }

    if ($LinkTarget) {
        $linked = (Get-GPInheritance -Target $LinkTarget @common).GpoLinks | Where-Object GpoId -eq $gpo.Id
        if (-not $linked) { $null = New-GPLink -Guid $gpo.Id -Target $LinkTarget -LinkEnabled Yes @common }
    }

    if ($ApplyToGroup) {
        $null = Set-GPPermission -Guid $gpo.Id -TargetName $ApplyToGroup -TargetType Group -PermissionLevel GpoApply @common
        $null = Set-GPPermission -Guid $gpo.Id -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoRead -Replace @common
    }

    $hasSecurity = $PolicySet.PSObject.Properties['security'] -and $PolicySet.security -and @($PolicySet.security.Keys).Count -gt 0
    $hasAudit = $PolicySet.PSObject.Properties['audit'] -and $PolicySet.audit -and @($PolicySet.audit.Keys).Count -gt 0
    if ($hasSecurity -or $hasAudit) {
        Write-Warning 'Sigurnosne postavke i revizija za domenske GPO-ove još nisu implementirane (faza 3, GptTmpl.inf/audit.csv u SYSVOL-u).'
    }

    Write-GpsAuditLog -Action 'Publish-GpsDomainPolicy' -Target "$($ctx.Domain)/$GpoName" -Details @{
        gpoId     = "$($gpo.Id)"; server = $ctx.Server; policySet = $PolicySet.name; version = $PolicySet.version
        link      = $LinkTarget; filter = $ApplyToGroup; backupId = if ($backup) { "$($backup.Id)" } else { $null }
        changes   = @($changes | ForEach-Object { "$($_.Status): $($_.Scope)\$($_.Key)\$($_.ValueName)" })
    }

    [pscustomobject]@{ GpoName = $GpoName; GpoId = $gpo.Id; Server = $ctx.Server; Status = 'OK'; Diff = $diff; Backup = $backup }
}

function Test-GpsDomainGpoReplication {
    <#
    .SYNOPSIS
        Uspoređuje AD i SYSVOL verzije GPO-a na svim domain controllerima.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GpoName, [string]$Domain)
    $ctx = Get-GpsDomainContext -Domain $Domain
    $reference = Get-GPO -Name $GpoName -Domain $ctx.Domain -Server $ctx.Server
    foreach ($dc in Get-ADDomainController -Filter * -Server $ctx.Server) {
        try {
            $g = Get-GPO -Guid $reference.Id -Domain $ctx.Domain -Server $dc.HostName -ErrorAction Stop
            $ok = $g.Computer.DSVersion -eq $reference.Computer.DSVersion -and $g.Computer.SysvolVersion -eq $reference.Computer.SysvolVersion -and
                  $g.User.DSVersion -eq $reference.User.DSVersion -and $g.User.SysvolVersion -eq $reference.User.SysvolVersion
            [pscustomobject]@{
                DomainController = $dc.HostName
                ComputerAD = $g.Computer.DSVersion; ComputerSysvol = $g.Computer.SysvolVersion
                UserAD = $g.User.DSVersion; UserSysvol = $g.User.SysvolVersion
                InSync = $ok
            }
        }
        catch {
            [pscustomobject]@{ DomainController = $dc.HostName; ComputerAD = $null; ComputerSysvol = $null; UserAD = $null; UserSysvol = $null; InSync = $false; Error = "$_" }
        }
    }
}

function Get-GpsDomainGpoReport {
    <#
    .SYNOPSIS
        HTML izvještaj GPO-a (za karticu Izvještaji u GUI-u).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GpoName, [string]$Domain, [string]$Path)
    $ctx = Get-GpsDomainContext -Domain $Domain
    $p = @{ Name = $GpoName; ReportType = 'Html'; Domain = $ctx.Domain; Server = $ctx.Server }
    if ($Path) { $p.Path = $Path }
    Get-GPOReport @p
}

Export-ModuleMember -Function Get-GpsDomainContext, Get-GpsDomainOuTree, Compare-GpsDomainPolicy, Publish-GpsDomainPolicy,
    Test-GpsDomainGpoReplication, Get-GpsDomainGpoReport
