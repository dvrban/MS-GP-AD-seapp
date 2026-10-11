#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Priprema admin stanicu (ADMIN01): RSAT, GPO Studio, Pester i pristup samostalnom računalu.
.DESCRIPTION
    Pokreće se na ADMIN01 u Windows PowerShellu 5.1, prijavljen kao GPSLAB\gps.admin.
      1. instalira RSAT GroupPolicy i ActiveDirectory (klijent: Features on Demand, Server: značajke),
      2. raspakira GPO Studio iz ZIP-a (ako je zadan) i uklanja oznaku "preuzeto s interneta" (Unblock-File),
      3. instalira Pester 5.7.1 (isti kao u CI-ju) i pokreće testove,
      4. dodaje samostalno računalo u WinRM TrustedHosts (izvan domene nema Kerberosa).
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

# 3. Pester 5.7.1
if (-not (Get-Module Pester -ListAvailable | Where-Object Version -eq '5.7.1')) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
}
if (-not $SkipTests) {
    Import-Module Pester -RequiredVersion 5.7.1
    $result = Invoke-Pester -Path (Join-Path $RepoPath 'tests') -PassThru -Output Normal
    $color = if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' }
    Write-Host "Pester: $($result.PassedCount) prošlo, $($result.FailedCount) palo." -ForegroundColor $color
}

# 4. TrustedHosts za samostalno računalo (izvan domene WinRM koristi NTLM)
if ($TrustedHost) {
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
    $missing = @($TrustedHost | Where-Object { ($current -split ',') -notcontains $_ })
    if ($missing) {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($missing -join ',') -Concatenate -Force
        Write-Host "TrustedHosts: dodano $($missing -join ', ')" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Sljedeći korak: Checkpoint-VM na hostu ("Clean"), zatim lab\Test-GpsLabSmoke.ps1 (docs/TESTNI-LAB.md, korak 6).' -ForegroundColor Cyan
