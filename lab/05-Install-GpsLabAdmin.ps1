#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Priprema admin stanicu (ADMIN01): RSAT, GPO Studio, Pester i pristup samostalnom računalu.
.DESCRIPTION
    Pokreće se na ADMIN01 u Windows PowerShellu 5.1, prijavljen kao GPSLAB\gps.admin.
      1. instalira RSAT GroupPolicy i ActiveDirectory (klijent: Features on Demand, Server: značajke),
      2. raspakira GPO Studio iz ZIP-a (ako je zadan) i uklanja oznaku "preuzeto s interneta" (Unblock-File),
      3. postavlja ExecutionPolicy RemoteSigned (LocalMachine) za 64-bitni i 32-bitni Windows PowerShell,
         jer je na Windows klijentima zadano Restricted, a GUI testovi pokreću skripte u novim procesima,
      4. instalira PowerShell 7 (MSI), potreban za GUI testove ponovnog pokretanja i provjeru u PS7,
      5. instalira Pester 5.7.1 (isti kao u CI-ju) i pokreće testove,
      6. dodaje samostalno računalo u WinRM TrustedHosts (izvan domene nema Kerberosa).
.PARAMETER RepoZip
    ZIP s GitHuba (Code -> Download ZIP). Ako se repozitorij klonira gitom, izostavite ga i zadajte -RepoPath.
.EXAMPLE
    .\05-Install-GpsLabAdmin.ps1 -RepoZip C:\Users\gps.admin\Downloads\MS-GP-AD-seapp-main.zip
#>
[CmdletBinding()]
param(
    [string]$RepoZip,
    [string]$RepoPath = 'C:\GpoStudio',
    [string[]]$TrustedHost = @('STANDALONE01', '10.10.10.40'),
    [string]$PwshVersion = '7.4.6',
    [switch]$SkipPwsh,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Pokrenite u Windows PowerShellu 5.1 (powershell.exe).' }

# 1. RSAT
$isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
if ($isServer) {
    $null = Install-WindowsFeature GPMC, RSAT-AD-PowerShell
}
else {
    foreach ($cap in 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0', 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0') {
        if ((Get-WindowsCapability -Online -Name $cap).State -ne 'Installed') {
            Write-Host "Instaliram $cap (traži internet, traje nekoliko minuta)..." -ForegroundColor Cyan
            $null = Add-WindowsCapability -Online -Name $cap
        }
    }
}
Write-Host 'RSAT je instaliran.' -ForegroundColor Green

# 2. GPO Studio
if ($RepoZip) {
    $tmp = Join-Path $env:TEMP 'gpostudio-zip'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $RepoZip -DestinationPath $tmp
    # GitHub ZIP sadrži jednu mapu (npr. MS-GP-AD-seapp-main); njezin sadržaj ide u $RepoPath.
    $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    $null = New-Item -ItemType Directory -Path $RepoPath -Force
    Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $RepoPath -Recurse -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $RepoPath 'src\GpoStudio.Core\GpoStudio.Core.psd1'))) {
    throw "GPO Studio nije pronađen u $RepoPath. Zadajte -RepoZip ili klonirajte repozitorij u tu mapu."
}
# Datoteke iz preuzetog ZIP-a nose Zone.Identifier; uz RemoteSigned politiku inače se ne bi smjele izvršiti.
Get-ChildItem -LiteralPath $RepoPath -Recurse -File | Unblock-File
Write-Host "GPO Studio: $RepoPath" -ForegroundColor Green

# 3. ExecutionPolicy za 64-bitni i 32-bitni Windows PowerShell. Dok je u ovoj sesiji aktivan
#    Process Bypass, Set-ExecutionPolicy baca "overridden by a more specific scope" (vrijednost je
#    ipak upisana), pa se greška hvata i rezultat provjerava.
try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force } catch { }
$wow = Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $wow) {
    & $wow -NoProfile -ExecutionPolicy Bypass -Command 'try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force } catch { }' 2>$null
}
if ((Get-ExecutionPolicy -Scope LocalMachine) -ne 'RemoteSigned') {
    Write-Warning "ExecutionPolicy LocalMachine je $(Get-ExecutionPolicy -Scope LocalMachine) (možda ga nadjačava Group Policy)."
}

# 4. PowerShell 7
if (-not $SkipPwsh -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $msi = Join-Path $env:TEMP "PowerShell-$PwshVersion-win-x64.msi"
    Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/PowerShell-$PwshVersion-win-x64.msi" -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', 'ADD_PATH=1' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Instalacija PowerShella 7 nije uspjela (msiexec $($p.ExitCode))." }
    Write-Host "PowerShell $PwshVersion je instaliran." -ForegroundColor Green
}

# 5. Pester 5.7.1
if (-not (Get-Module Pester -ListAvailable | Where-Object Version -eq '5.7.1')) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
}
if (-not $SkipTests) {
    # Testovi rade u zasebnom procesu: zamjenske funkcije i mockovi iz testova ne smiju ostati u ovoj sesiji,
    # u kojoj se poslije pokreću smoke test i GUI.
    $pesterRun = @'
Import-Module Pester -RequiredVersion 5.7.1
$result = Invoke-Pester -Path $env:GPS_TESTS_PATH -PassThru -Output Normal
$color = if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' }
Write-Host "Pester: $($result.PassedCount) prošlo, $($result.FailedCount) palo." -ForegroundColor $color
'@
    $env:GPS_TESTS_PATH = Join-Path $RepoPath 'tests'
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -OutputFormat Text `
        -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pesterRun)))
    Remove-Item Env:\GPS_TESTS_PATH
}

# 6. TrustedHosts za samostalno računalo (izvan domene WinRM koristi NTLM)
if ($TrustedHost) {
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
    $missing = @($TrustedHost | Where-Object { ($current -split ',') -notcontains $_ })
    if ($missing) {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($missing -join ',') -Concatenate -Force
        Write-Host "TrustedHosts: dodano $($missing -join ', ')" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Sljedeći korak: checkpoint na hostu ("Clean" pri izgradnji, "Clean-v2" pri nadogradnji; docs/TESTNI-LAB.md, 3.8 i 3.9), zatim lab\Test-GpsLabSmoke.ps1 (poglavlje 4).' -ForegroundColor Cyan
