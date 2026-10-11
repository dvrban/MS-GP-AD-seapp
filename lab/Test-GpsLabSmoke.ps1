#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automatizirani smoke test GPO Studija u testnom labu (lokalno, udaljeno, domena).
.DESCRIPTION
    Pokreće se na ADMIN01 kao GPSLAB\gps.admin, u povišenom Windows PowerShellu 5.1.
    Svaki korak stvarno mijenja računala laba i zatim provjerava rezultat na samom računalu
    (registry, secedit, auditpol, AD), a ne samo povratnu vrijednost cmdleta.

    Sve testne vrijednosti pišu se pod HKLM\Software\Policies\GpoStudioLab, pa ne utječu na
    ponašanje Windowsa. Na kraju se sve vraća (backup/restore, brisanje testnog GPO-a), osim uz
    -KeepArtifacts.

    Područja:
      Local  - lokalni GP na ADMIN01: diff, primjena (HKLM i HKCU), akcija Delete, revizija,
               vraćanje (i s pogrešnom putanjom)
      Remote - lokalni GP na STANDALONE01 (radna grupa, WinRM): registry + secedit + auditpol, vraćanje
      Domain - domenski GPO na Pilot OU s filtriranjem na GPS-Pilot-PC: WS01 ga dobiva, WS02 ne;
               replikacija, ponovna objava s backupom, akcija Delete, negativni slučajevi, uklanjanje.
               Provjere na klijentu čekaju replikaciju (do 3 min), jer klijent može koristiti bilo koji DC.
    Domain traži Windows PowerShell 5.1; u PowerShellu 7 ta se područja preskaču.
.OUTPUTS
    Tablica rezultata (PASS/FAIL/SKIP) i JSON u C:\ProgramData\GpoStudio\lab-results-<vrijeme>.json.
    Izlazni kod 1 ako je ijedan korak pao.
.EXAMPLE
    .\Test-GpsLabSmoke.ps1
.EXAMPLE
    .\Test-GpsLabSmoke.ps1 -Area Domain -KeepArtifacts
#>
[CmdletBinding()]
param(
    [string]$RepoPath = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Local', 'Remote', 'Domain')][string[]]$Area = @('Local', 'Remote', 'Domain'),
    [string]$StandaloneComputer = 'STANDALONE01',
    [pscredential]$StandaloneCredential,
    [string]$PilotComputer = 'WS01',
    [string]$OtherComputer = 'WS02',
    [string]$PilotOU,
    [string]$PilotGroup = 'GPS-Pilot-PC',
    [string]$GpoName = 'GPS-LAB-Smoke',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RepoPath 'src\GpoStudio.Local\GpoStudio.Local.psm1') -Force
Import-Module (Join-Path $RepoPath 'src\GpoStudio.Domain\GpoStudio.Domain.psm1') -Force

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$startUtc = (Get-Date).ToUniversalTime()
$labKey = 'Software\Policies\GpoStudioLab'
$labRegPath = "HKLM:\$labKey"
$logonAuditGuid = '{0CCE9215-69AE-11D9-BED3-505054503030}'
$results = [System.Collections.Generic.List[object]]::new()

#region Pomoćne funkcije

function Invoke-LabStep {
    # Korak prolazi ako scriptblock ne baci grešku; vraćeni tekst ide u detalje, 'SKIP: ...' označava preskakanje.
    param([string]$Id, [string]$Name, [scriptblock]$Test)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = (@(& $Test) | ForEach-Object { "$_" }) -join '; '
        $result = if ($detail -like 'SKIP:*') { 'SKIP' } else { 'PASS' }
    }
    catch {
        $detail = $_.Exception.Message
        $result = 'FAIL'
    }
    $results.Add([pscustomobject]@{
            Id       = $Id
            Test     = $Name
            Rezultat = $result
            Trajanje = '{0:n1} s' -f $sw.Elapsed.TotalSeconds
            Detalji  = $detail
        })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow' }[$result]
    Write-Host ("[{0}] {1} {2}" -f $result, $Id, $Name) -ForegroundColor $color
    if ($result -eq 'FAIL') { Write-Host "       $detail" -ForegroundColor DarkRed }
}

function Assert-Lab([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-LabPolicySet([int]$Dword, [string]$Text) {
    New-GpsPolicySet -Name "GPS lab smoke $runId" -Description 'Automatski smoke test laba' -Setting @(
        New-GpsPolicySetting -Key $labKey -ValueName 'TestDword' -Type REG_DWORD -Data $Dword -DisplayName 'Lab: DWORD'
        New-GpsPolicySetting -Key $labKey -ValueName 'TestString' -Type REG_SZ -Data $Text -DisplayName 'Lab: tekst'
    )
}

function Get-LabGptUserVersion {
    # Gornjih 16 bitova Version u gpt.ini lokalnog GPO-a je verzija User dijela.
    $ini = Join-Path $env:windir 'System32\GroupPolicy\gpt.ini'
    if (-not (Test-Path -LiteralPath $ini)) { return 0 }
    $line = Get-Content -LiteralPath $ini | Where-Object { $_ -match '^\s*Version\s*=\s*(\d+)' } | Select-Object -First 1
    if (-not $line) { return 0 }
    $null = $line -match '(\d+)'
    [uint32]$Matches[1] -shr 16
}

function Wait-LabClientState {
    # Klijent može koristiti bilo koji DC, ne samo PDC na koji GPO Studio piše, pa se čeka da AD i
    # SYSVOL (DFSR) repliciraju: gpupdate i provjera se ponavljaju dok uvjet ne vrijedi.
    param([string]$Computer, [scriptblock]$Condition, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0
    $last = ''
    do {
        $attempt++
        try { $state = Invoke-Command -ComputerName $Computer -ScriptBlock $refreshAndRead -ArgumentList $labKey -ErrorAction Stop }
        catch { $state = $null; $last = " Zadnja greška: $_" }
        if ($state -and (& $Condition $state)) { return "$Computer, $attempt. pokušaj" }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    throw "$($Computer): očekivano stanje nije postignuto u $TimeoutSec s (TestDword=$($state.TestDword), TestString=$($state.TestString)).$last"
}

function Get-LabAuditEntry([string]$Action) {
    $path = Join-Path $env:ProgramData 'GpoStudio\audit.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        try { $e = $line | ConvertFrom-Json } catch { continue }
        # PS7 pretvara ISO datume u DateTime (Utc), 5.1 ih ostavlja kao string; ToUniversalTime izjednačava oba.
        if ($e.action -eq $Action -and ([datetime]$e.timestamp).ToUniversalTime() -ge $startUtc) { $e }
    }
}

# Stanje sigurnosne politike i revizije na računalu, neovisno o jeziku sustava
# (secedit /export i auditpol /backup daju brojčane vrijednosti).
$probe = {
    param($Key, $AuditGuid)
    $id = [guid]::NewGuid().ToString('N')
    $inf = Join-Path $env:TEMP "gps-probe-$id.inf"
    $csv = Join-Path $env:TEMP "gps-probe-$id.csv"
    try {
        $null = secedit.exe /export /cfg $inf /areas SECURITYPOLICY /quiet
        $null = auditpol.exe /backup "/file:$csv"
        $m = Select-String -LiteralPath $inf -Pattern '^\s*MinimumPasswordLength\s*=\s*(\d+)' | Select-Object -First 1
        $a = Import-Csv -LiteralPath $csv | Where-Object { $_.'Subcategory GUID' -eq $AuditGuid } | Select-Object -First 1
        $p = Get-ItemProperty -Path "HKLM:\$Key" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            ComputerName          = $env:COMPUTERNAME
            MinimumPasswordLength = if ($m) { [int]$m.Matches[0].Groups[1].Value } else { -1 }
            LogonAudit            = if ($a) { [int]$a.'Setting Value' } else { -1 }
            TestDword             = if ($p) { $p.TestDword } else { $null }
            TestString            = if ($p) { $p.TestString } else { $null }
        }
    }
    finally { Remove-Item -LiteralPath $inf, $csv -Force -ErrorAction SilentlyContinue }
}

# gpupdate na klijentima i čitanje testnih vrijednosti.
$refreshAndRead = {
    param($Key)
    $null = gpupdate.exe /target:computer /force
    $p = Get-ItemProperty -Path "HKLM:\$Key" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        TestDword    = if ($p) { $p.TestDword } else { $null }
        TestString   = if ($p) { $p.TestString } else { $null }
    }
}

#endregion

Write-Host "GPO Studio lab smoke test $runId (PowerShell $($PSVersionTable.PSVersion), $($PSVersionTable.PSEdition))" -ForegroundColor Cyan

#region Local: lokalni GP na ovom računalu

if ('Local' -in $Area) {
    $text = "smoke-$runId"
    $set = New-LabPolicySet -Dword 1 -Text $text
    # Jedna postavka u User scopeu: User\Registry.pol, gornja polovica verzije u gpt.ini i HKCU.
    $set.settings.Add((New-GpsPolicySetting -Scope User -Key $labKey -ValueName 'TestUser' -Type REG_SZ -Data $text -DisplayName 'Lab: korisnik'))
    $userVersionBefore = Get-LabGptUserVersion

    Invoke-LabStep 'L1' 'ADMX katalog (Central Store ili PolicyDefinitions)' {
        $catalog = @(Get-GpsAdmxCatalog)
        Assert-Lab ($catalog.Count -gt 500) "Katalog ima samo $($catalog.Count) politika."
        $centralPath = if ($env:USERDNSDOMAIN) { "\\$env:USERDNSDOMAIN\SYSVOL\$env:USERDNSDOMAIN\Policies\PolicyDefinitions" }
        $central = [bool]($centralPath -and (Test-Path -LiteralPath $centralPath))
        # Na računalu u domeni katalog mora doći iz Central Storea (Get-GpsAdmxCatalog inače tiho koristi lokalni).
        Assert-Lab (-not $env:USERDNSDOMAIN -or $central) "Central Store nije dostupan ($centralPath): pokrenite lab/03 bez -SkipCentralStore ili pričekajte replikaciju SYSVOL-a."
        "$($catalog.Count) politika; Central Store: $central"
    }

    Invoke-LabStep 'L2' 'Diff (WhatIf) ne mijenja ništa' {
        $before = Get-ItemProperty -Path $labRegPath -ErrorAction SilentlyContinue
        $r = @(Set-GpsLocalPolicy -PolicySet $set -WhatIf)
        Assert-Lab ($r.Count -eq 1 -and $r[0].Status -eq 'WhatIf') "Očekivan jedan rezultat sa statusom WhatIf, dobiveno: $($r.Status -join ',')"
        $statuses = @($r[0].Diff.Status | Sort-Object -Unique)
        Assert-Lab (-not ($statuses | Where-Object { $_ -notin 'Added', 'Changed' })) "Neočekivani statusi: $($statuses -join ',')"
        $after = Get-ItemProperty -Path $labRegPath -ErrorAction SilentlyContinue
        Assert-Lab ("$($before.TestString)" -eq "$($after.TestString)") 'WhatIf je promijenio registry.'
        "Diff: $($r[0].Diff.Status -join ', ')"
    }

    Invoke-LabStep 'L3' 'Primjena s backupom' {
        $r = @(Set-GpsLocalPolicy -PolicySet $set -Confirm:$false)
        Assert-Lab ($r[0].Status -eq 'OK') "Status $($r[0].Status): $($r[0].Messages -join ' | ')"
        Assert-Lab ($r[0].BackupPath -and (Test-Path -LiteralPath (Join-Path $r[0].BackupPath 'gpostudio-backup.json'))) "Backup nije pronađen: $($r[0].BackupPath)"
        $script:localBackup = $r[0].BackupPath
        "Backup: $($r[0].BackupPath)"
    }

    Invoke-LabStep 'L4' 'Vrijednosti su u registryju nakon gpupdate (HKLM i HKCU)' {
        $p = Get-ItemProperty -Path $labRegPath -ErrorAction SilentlyContinue
        Assert-Lab ($p -and $p.TestDword -eq 1 -and $p.TestString -eq $text) "Registry: TestDword=$($p.TestDword), TestString=$($p.TestString)"
        # Set-GpsLocalPolicy osvježava samo računalo; korisnički dio se primjenjuje pri prijavi ili ovako.
        $null = gpupdate.exe /target:user /force
        $u = Get-ItemProperty -Path "HKCU:\$labKey" -ErrorAction SilentlyContinue
        Assert-Lab ($u -and $u.TestUser -eq $text) "HKCU: TestUser=$($u.TestUser)"
        $userVersionAfter = Get-LabGptUserVersion
        Assert-Lab ($userVersionAfter -gt $userVersionBefore) "User verzija u gpt.ini nije porasla ($userVersionBefore -> $userVersionAfter)."
        "HKLM TestDword=1, TestString=$text; HKCU TestUser; gpt.ini User verzija $userVersionBefore -> $userVersionAfter"
    }

    Invoke-LabStep 'L5' 'Ponovni diff: sve Unchanged' {
        $r = @(Set-GpsLocalPolicy -PolicySet $set -WhatIf)
        $statuses = @($r[0].Diff.Status | Sort-Object -Unique)
        Assert-Lab ($statuses.Count -eq 1 -and $statuses[0] -eq 'Unchanged') "Statusi: $($statuses -join ',')"
    }

    Invoke-LabStep 'L6' 'Revizijski zapis primjene' {
        $entries = @(Get-LabAuditEntry 'Set-GpsLocalPolicy' | Where-Object result -eq 'OK')
        Assert-Lab ($entries.Count -ge 1) 'Nema zapisa Set-GpsLocalPolicy u audit.jsonl.'
        "$($entries.Count) zapis(a)"
    }

    Invoke-LabStep 'L7' 'Vraćanje s pogrešnom putanjom ne mijenja ništa' {
        $gpIni = Join-Path $env:windir 'System32\GroupPolicy\gpt.ini'
        $existed = Test-Path -LiteralPath $gpIni
        $r = @(Restore-GpsLocalPolicy -BackupPath "C:\GpsLab-nema-backupa-$runId" -Confirm:$false)
        Assert-Lab ($r[0].Status -eq 'Error') "Očekivan status Error, dobiveno $($r[0].Status)."
        Assert-Lab ((Test-Path -LiteralPath $gpIni) -eq $existed) 'gpt.ini je promijenjen.'
        $p = Get-ItemProperty -Path $labRegPath -ErrorAction SilentlyContinue
        Assert-Lab ($p.TestString -eq $text) 'Testna vrijednost je nestala.'
        "Poruka: $($r[0].Messages -join ' | ')"
    }

    Invoke-LabStep 'L7b' 'Akcija Delete: **del. zapis i uklanjanje vrijednosti' {
        $delete = New-GpsPolicySet -Name "GPS lab delete $runId" -Setting @(
            New-GpsPolicySetting -Key $labKey -ValueName 'TestDword' -Action Delete
        )
        $r = @(Set-GpsLocalPolicy -PolicySet $delete -Confirm:$false)
        Assert-Lab ($r[0].Status -eq 'OK') "Status $($r[0].Status): $($r[0].Messages -join ' | ')"
        $pol = @(Read-GpsRegistryPol -Path (Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol'))
        Assert-Lab ([bool]($pol | Where-Object { $_.ValueName -eq '**del.TestDword' -and $_.Type -eq 'REG_SZ' })) 'Registry.pol nema zapis **del.TestDword.'
        $p = Get-ItemProperty -Path $labRegPath -ErrorAction SilentlyContinue
        Assert-Lab ($null -eq $p.TestDword -and $p.TestString -eq $text) "Registry: TestDword=$($p.TestDword), TestString=$($p.TestString)"
        $again = @(Set-GpsLocalPolicy -PolicySet $delete -WhatIf)
        Assert-Lab (@($again[0].Diff | Where-Object Status -ne 'Unchanged').Count -eq 0) "Ponovni diff: $($again[0].Diff.Status -join ',')"
        'TestDword uklonjen, TestString ostao, ponovni diff Unchanged'
    }

    Invoke-LabStep 'L8' 'Vraćanje iz backupa uklanja postavke (HKLM i HKCU)' {
        if (-not $script:localBackup) { return 'SKIP: nema backupa iz L3' }
        $r = @(Restore-GpsLocalPolicy -BackupPath $script:localBackup -Confirm:$false)
        Assert-Lab ($r[0].Status -eq 'OK') "Status $($r[0].Status): $($r[0].Messages -join ' | ')"
        $p = Get-ItemProperty -Path $labRegPath -ErrorAction SilentlyContinue
        Assert-Lab (-not $p -or $null -eq $p.TestString) "Vrijednost je ostala nakon vraćanja: TestString=$($p.TestString)"
        $u = Get-ItemProperty -Path "HKCU:\$labKey" -ErrorAction SilentlyContinue
        Assert-Lab (-not $u -or $null -eq $u.TestUser) "Korisnička vrijednost je ostala nakon vraćanja: TestUser=$($u.TestUser)"
    }
}

#endregion

#region Remote: lokalni GP na samostalnom računalu preko WinRM-a

if ('Remote' -in $Area) {
    if (-not $StandaloneCredential) {
        $StandaloneCredential = Get-Credential -Message "Lokalni administrator na $StandaloneComputer (npr. $StandaloneComputer\labadmin)"
    }
    $remote = @{ ComputerName = $StandaloneComputer; Credential = $StandaloneCredential }
    $text = "remote-$runId"
    $script:remoteBaseline = $null

    Invoke-LabStep 'R1' "WinRM do $StandaloneComputer i početno stanje" {
        $script:remoteBaseline = Invoke-Command @remote -ScriptBlock $probe -ArgumentList $labKey, $logonAuditGuid
        Assert-Lab ($script:remoteBaseline.MinimumPasswordLength -ge 0) 'secedit /export nije vratio MinimumPasswordLength.'
        Assert-Lab ($script:remoteBaseline.LogonAudit -ge 0) 'auditpol /backup nije vratio Logon podkategoriju.'
        "MinimumPasswordLength=$($script:remoteBaseline.MinimumPasswordLength), Logon audit=$($script:remoteBaseline.LogonAudit)"
    }

    Invoke-LabStep 'R2' 'Primjena: registry + secedit + auditpol' {
        if (-not $script:remoteBaseline) { return 'SKIP: R1 nije prošao' }
        $set = New-LabPolicySet -Dword 7 -Text $text
        # Ciljane vrijednosti biraju se tako da se razlikuju od početnih.
        $script:targetMinLen = if ($script:remoteBaseline.MinimumPasswordLength -eq 12) { 11 } else { 12 }
        $script:targetAudit = if ($script:remoteBaseline.LogonAudit -eq 3) { 2 } else { 3 }
        $set.security['MinimumPasswordLength'] = $script:targetMinLen
        $set.audit['Logon'] = if ($script:targetAudit -eq 3) { 'Success,Failure' } else { 'Failure' }

        $r = @(Set-GpsLocalPolicy -PolicySet $set @remote -Confirm:$false)
        Assert-Lab ($r.Count -eq 1 -and $r[0].Status -eq 'OK') "Status $($r[0].Status): $($r[0].Messages -join ' | ')"
        $script:remoteBackup = $r[0].BackupPath
        "Backup na $($StandaloneComputer): $($r[0].BackupPath)"
    }

    Invoke-LabStep 'R3' 'Provjera na udaljenom računalu' {
        if (-not $script:remoteBackup) { return 'SKIP: R2 nije prošao' }
        $s = Invoke-Command @remote -ScriptBlock $probe -ArgumentList $labKey, $logonAuditGuid
        Assert-Lab ($s.TestDword -eq 7 -and $s.TestString -eq $text) "Registry: TestDword=$($s.TestDword), TestString=$($s.TestString)"
        Assert-Lab ($s.MinimumPasswordLength -eq $script:targetMinLen) "MinimumPasswordLength=$($s.MinimumPasswordLength), očekivano $($script:targetMinLen)"
        Assert-Lab ($s.LogonAudit -eq $script:targetAudit) "Logon audit=$($s.LogonAudit), očekivano $($script:targetAudit)"
        "Registry, lozinke ($($s.MinimumPasswordLength)) i revizija ($($s.LogonAudit)) primijenjeni"
    }

    Invoke-LabStep 'R4' 'Vraćanje na udaljenom računalu' {
        if (-not $script:remoteBackup) { return 'SKIP: nema backupa iz R2' }
        $r = @(Restore-GpsLocalPolicy -BackupPath $script:remoteBackup @remote -Confirm:$false)
        Assert-Lab ($r[0].Status -eq 'OK') "Status $($r[0].Status): $($r[0].Messages -join ' | ')"
        $s = Invoke-Command @remote -ScriptBlock $probe -ArgumentList $labKey, $logonAuditGuid
        Assert-Lab ($null -eq $s.TestString) "Registry vrijednost je ostala: $($s.TestString)"
        Assert-Lab ($s.MinimumPasswordLength -eq $script:remoteBaseline.MinimumPasswordLength) "MinimumPasswordLength=$($s.MinimumPasswordLength), početno $($script:remoteBaseline.MinimumPasswordLength)"
        Assert-Lab ($s.LogonAudit -eq $script:remoteBaseline.LogonAudit) "Logon audit=$($s.LogonAudit), početno $($script:remoteBaseline.LogonAudit)"
    }
}

#endregion

#region Domain: domenski GPO

if ('Domain' -in $Area) {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        Invoke-LabStep 'D0' 'Domenski dio' { 'SKIP: traži Windows PowerShell 5.1' }
    }
    else {
        $text = "domain-$runId"
        $script:ctx = $null

        Invoke-LabStep 'D0' 'Priprema: OU, grupa i Kerberos tiketi klijenata' {
            $script:ctx = Get-GpsDomainContext
            if (-not $PilotOU) { $script:pilotOu = "OU=Pilot,OU=Racunala,OU=GpsLab,$($script:ctx.DistinguishedName)" } else { $script:pilotOu = $PilotOU }
            $common = @{ Server = $script:ctx.Server }
            foreach ($c in $PilotComputer, $OtherComputer) {
                $dn = (Get-ADComputer -Identity $c @common).DistinguishedName
                Assert-Lab ($dn -like "*,$($script:pilotOu)") "$c nije u $($script:pilotOu) ($dn)."
            }
            $members = @(Get-ADGroupMember -Identity $PilotGroup @common | ForEach-Object DistinguishedName)
            $pilot = Get-ADComputer -Identity $PilotComputer @common
            $other = Get-ADComputer -Identity $OtherComputer @common
            if ($members -notcontains $pilot.DistinguishedName) { Add-ADGroupMember -Identity $PilotGroup -Members $pilot @common }
            if ($members -contains $other.DistinguishedName) { Remove-ADGroupMember -Identity $PilotGroup -Members $other -Confirm:$false @common }
            # Nova članstva u grupi računalo vidi tek s novim Kerberos tiketom računala.
            Invoke-Command -ComputerName $PilotComputer, $OtherComputer -ScriptBlock { $null = klist.exe -li 0x3e7 purge }
            foreach ($name in $GpoName, "$GpoName-Neg") {
                if (Get-GPO -Name $name -Domain $script:ctx.Domain -Server $script:ctx.Server -ErrorAction SilentlyContinue) {
                    Remove-GPO -Name $name -Domain $script:ctx.Domain -Server $script:ctx.Server
                }
            }
            "PDC: $($script:ctx.Server); OU: $($script:pilotOu); $PilotComputer u $PilotGroup, $OtherComputer nije"
        }

        $gpoCommon = { @{ Domain = $script:ctx.Domain; Server = $script:ctx.Server } }
        $publish = { param($Set, [switch]$WhatIfOnly)
            $p = @{ PolicySet = $Set; GpoName = $GpoName; LinkTarget = $script:pilotOu; ApplyToGroup = $PilotGroup }
            if ($WhatIfOnly) { Publish-GpsDomainPolicy @p -WhatIf } else { Publish-GpsDomainPolicy @p -Confirm:$false }
        }

        Invoke-LabStep 'D1' 'Diff za novi GPO (WhatIf) ne stvara GPO' {
            if (-not $script:ctx) { return 'SKIP: D0 nije prošao' }
            $c = & $gpoCommon
            $r = & $publish (New-LabPolicySet -Dword 1 -Text $text) -WhatIfOnly
            Assert-Lab ($r.Status -eq 'WhatIf') "Status $($r.Status)"
            Assert-Lab (@($r.Diff | Where-Object Status -ne 'Added').Count -eq 0) "Statusi: $($r.Diff.Status -join ',')"
            Assert-Lab (-not (Get-GPO -Name $GpoName @c -ErrorAction SilentlyContinue)) 'WhatIf je stvorio GPO.'
        }

        Invoke-LabStep 'D2' 'Objava novog GPO-a' {
            if (-not $script:ctx) { return 'SKIP: D0 nije prošao' }
            $r = & $publish (New-LabPolicySet -Dword 1 -Text $text)
            Assert-Lab ($r.Status -eq 'OK') "Status $($r.Status)"
            $script:gpoId = $r.GpoId
            "GPO $($r.GpoId)"
        }

        Invoke-LabStep 'D3' 'GPO, link i sigurnosno filtriranje u AD-u' {
            if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
            $c = & $gpoCommon
            $link = @((Get-GPInheritance -Target $script:pilotOu @c).GpoLinks) | Where-Object { $_.GpoId -eq $script:gpoId }
            Assert-Lab ([bool]$link -and $link.Enabled) 'GPO nije (uključeno) povezan na Pilot OU.'
            $group = Get-GPPermission -Guid $script:gpoId -TargetName $PilotGroup -TargetType Group @c
            Assert-Lab ("$($group.Permission)" -eq 'GpoApply') "$PilotGroup ima $($group.Permission), očekivano GpoApply."
            $au = ([Security.Principal.SecurityIdentifier]'S-1-5-11').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
            $auPerm = Get-GPPermission -Guid $script:gpoId -TargetName $au -TargetType Group @c
            Assert-Lab ("$($auPerm.Permission)" -eq 'GpoRead') "$au ima $($auPerm.Permission), očekivano GpoRead."
            "Link uključen; $PilotGroup=GpoApply; $au=GpoRead"
        }

        Invoke-LabStep 'D4' 'Compare-GpsDomainPolicy: sve Unchanged' {
            if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
            $d = @(Compare-GpsDomainPolicy -PolicySet (New-LabPolicySet -Dword 1 -Text $text) -GpoName $GpoName)
            Assert-Lab (@($d | Where-Object Status -ne 'Unchanged').Count -eq 0) "Statusi: $($d.Status -join ',')"
        }

        Invoke-LabStep 'D5' 'Replikacija na sve DC-ove (do 3 min)' {
            if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
            $deadline = (Get-Date).AddMinutes(3)
            do {
                $rep = @(Test-GpsDomainGpoReplication -GpoName $GpoName)
                if (@($rep | Where-Object { -not $_.InSync }).Count -eq 0) { return "$($rep.Count) DC(a) usklađeno" }
                Start-Sleep -Seconds 15
            } while ((Get-Date) -lt $deadline)
            throw "Nije usklađeno: $(($rep | Where-Object { -not $_.InSync }).DomainController -join ', ')"
        }

        Invoke-LabStep 'D6' "Filtriranje: $PilotComputer dobiva GPO, $OtherComputer ne" {
            if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
            $wait = Wait-LabClientState -Computer $PilotComputer -Condition { param($w) $w.TestString -eq $text }
            # Kad je WS01 dobio GPO, replikacija je gotova; WS02 ga ne smije dobiti.
            $other = Invoke-Command -ComputerName $OtherComputer -ScriptBlock $refreshAndRead -ArgumentList $labKey
            Assert-Lab ($null -eq $other.TestString) "$($OtherComputer) je dobio GPO: TestString=$($other.TestString)"
            "$PilotComputer ima GPO ($wait), $OtherComputer nema"
        }

        Invoke-LabStep 'D7' 'Ponovna objava s promjenom radi backup postojećeg GPO-a' {
            if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
            $r = & $publish (New-LabPolicySet -Dword 2 -Text $text)
            Assert-Lab ($r.Status -eq 'OK' -and $r.Backup -and $r.Backup.Id) "Status $($r.Status), backup: $($r.Backup.Id)"
            Assert-Lab (@($r.Diff | Where-Object Status -eq 'Changed').Count -eq 1) "Diff: $($r.Diff.Status -join ',')"
            $wait = Wait-LabClientState -Computer $PilotComputer -Condition { param($w) $w.TestDword -eq 2 }
            "Backup $($r.Backup.Id) u $($r.Backup.BackupDirectory); $wait"
        }

        Invoke-LabStep 'D7b' 'Akcija Delete u domenskom GPO-u (-Disable, PolicyState Delete)' {
            if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
            $c = & $gpoCommon
            $delete = New-GpsPolicySet -Name "GPS lab smoke $runId" -Setting @(
                New-GpsPolicySetting -Key $labKey -ValueName 'TestDword' -Action Delete
                New-GpsPolicySetting -Key $labKey -ValueName 'TestString' -Type REG_SZ -Data $text
            )
            $r = & $publish $delete
            Assert-Lab ($r.Status -eq 'OK') "Status $($r.Status)"
            $removed = @($r.Diff | Where-Object Status -eq 'Removed')
            Assert-Lab ($removed.Count -eq 1 -and $removed[0].ValueName -eq 'TestDword') "Diff: $(($r.Diff | ForEach-Object { "$($_.ValueName)=$($_.Status)" }) -join ', ')"
            $v = Get-GPRegistryValue -Guid $script:gpoId -Key "HKLM\$labKey" -ValueName 'TestDword' @c
            Assert-Lab ("$($v.PolicyState)" -eq 'Delete') "Get-GPRegistryValue: PolicyState=$($v.PolicyState)"
            $d = @(Compare-GpsDomainPolicy -PolicySet $delete -GpoName $GpoName)
            Assert-Lab (@($d | Where-Object Status -ne 'Unchanged').Count -eq 0) "Compare nakon objave: $(($d | ForEach-Object { "$($_.ValueName)=$($_.Status)" }) -join ', ')"
            $wait = Wait-LabClientState -Computer $PilotComputer -Condition { param($w) $null -eq $w.TestDword -and $w.TestString -eq $text }
            "PolicyState Delete; Compare Unchanged; $wait"
        }

        Invoke-LabStep 'D8' 'Default Domain Policy bez -Force se odbija' {
            if (-not $script:ctx) { return 'SKIP: D0 nije prošao' }
            try {
                $null = Publish-GpsDomainPolicy -PolicySet (New-LabPolicySet -Dword 1 -Text $text) -GpoName 'Default Domain Policy' -Confirm:$false
            }
            catch {
                Assert-Lab ("$_" -like '*-Force*') "Neočekivana greška: $_"
                return 'Odbijeno'
            }
            throw 'Objava na Default Domain Policy nije odbijena!'
        }

        Invoke-LabStep 'D9' 'Nepostojeća grupa za filtriranje: ništa se ne stvara' {
            if (-not $script:ctx) { return 'SKIP: D0 nije prošao' }
            $c = & $gpoCommon
            $failed = $false
            try {
                $null = Publish-GpsDomainPolicy -PolicySet (New-LabPolicySet -Dword 1 -Text $text) -GpoName "$GpoName-Neg" `
                    -LinkTarget $script:pilotOu -ApplyToGroup "GPS-Ne-Postoji-$runId" -Confirm:$false
            }
            catch { $failed = $true }
            Assert-Lab $failed 'Objava s nepostojećom grupom nije bacila grešku.'
            Assert-Lab (-not (Get-GPO -Name "$GpoName-Neg" @c -ErrorAction SilentlyContinue)) 'GPO je ipak stvoren.'
        }

        Invoke-LabStep 'D10' 'Revizijski zapisi objave' {
            $ok = @(Get-LabAuditEntry 'Publish-GpsDomainPolicy' | Where-Object result -eq 'OK')
            Assert-Lab ($ok.Count -ge 3) "Očekivana barem 3 uspješna zapisa (D2, D7, D7b), pronađeno $($ok.Count)."
            "$($ok.Count) zapis(a)"
        }

        if (-not $KeepArtifacts) {
            Invoke-LabStep 'D11' 'Brisanje testnog GPO-a uklanja postavke s klijenta' {
                if (-not $script:gpoId) { return 'SKIP: D2 nije prošao' }
                $c = & $gpoCommon
                Remove-GPO -Guid $script:gpoId @c
                Wait-LabClientState -Computer $PilotComputer -Condition { param($w) $null -eq $w.TestString }
            }
        }
    }
}

#endregion

$results | Format-Table Id, Rezultat, Trajanje, Test -AutoSize | Out-Host
$failedSteps = @($results | Where-Object Rezultat -eq 'FAIL')
foreach ($f in $failedSteps) { Write-Host "FAIL $($f.Id): $($f.Detalji)" -ForegroundColor Red }

$outDir = Join-Path $env:ProgramData 'GpoStudio'
$null = New-Item -ItemType Directory -Path $outDir -Force
$outFile = Join-Path $outDir "lab-results-$runId.json"
[pscustomobject]@{
    runId      = $runId
    computer   = $env:COMPUTERNAME
    user       = "$env:USERDOMAIN\$env:USERNAME"
    powershell = "$($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
    area       = $Area
    results    = $results
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outFile -Encoding UTF8

$summary = "{0} PASS, {1} FAIL, {2} SKIP. Rezultati: {3}" -f @($results | Where-Object Rezultat -eq 'PASS').Count, $failedSteps.Count, @($results | Where-Object Rezultat -eq 'SKIP').Count, $outFile
Write-Host $summary -ForegroundColor $(if ($failedSteps.Count) { 'Red' } else { 'Green' })
if ($failedSteps.Count) { exit 1 }
