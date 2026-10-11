#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Pretvara svježe instalirani Windows Server u domain controller laba (DC01 ili DC02).
.DESCRIPTION
    Pokreće se UNUTAR VM-a, dvaput:
      1. prvo pokretanje: statička IP adresa, DNS i preimenovanje računala, zatim restart;
      2. drugo pokretanje: instalacija AD DS-a i nova šuma (Forest) ili dodatni DC (AdditionalDC), zatim restart.
    Skripta sama prepoznaje fazu po imenu računala i ulozi.
.PARAMETER Role
    Forest  = prvi DC, nova domena (DC01).
    AdditionalDC = drugi DC u postojećoj domeni (DC02, za test replikacije).
.EXAMPLE
    # DC01 (dvaput)
    .\02-Install-GpsLabDC.ps1 -Role Forest
.EXAMPLE
    # DC02 (dvaput)
    .\02-Install-GpsLabDC.ps1 -Role AdditionalDC -ComputerName DC02 -IPAddress 10.10.10.11 -DnsServer 10.10.10.10
#>
[CmdletBinding()]
param(
    [ValidateSet('Forest', 'AdditionalDC')][string]$Role = 'Forest',
    [string]$ComputerName = 'DC01',
    [string]$IPAddress = '10.10.10.10',
    [string]$Gateway = '10.10.10.1',
    # Za Forest: DNS je on sam (127.0.0.1). Za AdditionalDC: adresa DC01.
    [string]$DnsServer,
    [string]$DomainName = 'gpslab.test',
    [string]$NetbiosName = 'GPSLAB',
    [string[]]$DnsForwarder = @('1.1.1.1', '8.8.8.8')
)

$ErrorActionPreference = 'Stop'
if (-not $DnsServer) { $DnsServer = if ($Role -eq 'Forest') { '127.0.0.1' } else { '10.10.10.10' } }

# Faza 1: mreža i ime
if ($env:COMPUTERNAME -ne $ComputerName) {
    $nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $nic) { throw 'Nije pronađen aktivni mrežni adapter.' }
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    $null = New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -PrefixLength 24 -DefaultGateway $Gateway
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DnsServer
    Write-Host "Adresa $IPAddress, DNS $DnsServer. Preimenujem u $ComputerName i restartam; zatim ponovno pokrenite skriptu." -ForegroundColor Cyan
    Rename-Computer -NewName $ComputerName -Restart -Force
    return
}

# Faza 2: AD DS
$isDc = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
if ($isDc) {
    Write-Host "$ComputerName je već domain controller." -ForegroundColor Green
    if ($Role -eq 'Forest' -and $DnsForwarder) {
        foreach ($f in $DnsForwarder) {
            if (-not ((Get-DnsServerForwarder).IPAddress.IPAddressToString -contains $f)) { Add-DnsServerForwarder -IPAddress $f }
        }
        Write-Host "DNS forwarderi: $($DnsForwarder -join ', ')" -ForegroundColor Green
    }
    return
}

$null = Install-WindowsFeature AD-Domain-Services, GPMC -IncludeManagementTools
$dsrm = Read-Host -AsSecureString 'Lozinka za DSRM (Directory Services Restore Mode)'
if ($Role -eq 'Forest') {
    Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $NetbiosName -InstallDns `
        -SafeModeAdministratorPassword $dsrm -Force
}
else {
    $cred = Get-Credential -Message "Domain Admin za $DomainName (npr. $NetbiosName\Administrator)"
    Install-ADDSDomainController -DomainName $DomainName -InstallDns -Credential $cred `
        -SafeModeAdministratorPassword $dsrm -Force
}
# Install-ADDS* sam restarta računalo. Nakon restarta pokrenite skriptu još jednom za DNS forwardere (samo DC01).
