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
    # Zadano: DC01 / 10.10.10.10 za Forest, DC02 / 10.10.10.11 za AdditionalDC.
    [string]$ComputerName,
    [string]$IPAddress,
    [string]$Gateway = '10.10.10.1',
    # Za Forest: DNS je on sam (127.0.0.1). Za AdditionalDC: adresa DC01.
    [string]$DnsServer,
    [string]$DomainName = 'gpslab.test',
    [string]$NetbiosName = 'GPSLAB',
    [string[]]$DnsForwarder = @('1.1.1.1', '8.8.8.8')
)

$ErrorActionPreference = 'Stop'
if (-not $ComputerName) { $ComputerName = if ($Role -eq 'Forest') { 'DC01' } else { 'DC02' } }
if (-not $IPAddress) { $IPAddress = if ($Role -eq 'Forest') { '10.10.10.10' } else { '10.10.10.11' } }
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

# Sukob adresa: adresu koju već koristi drugo računalo Windows označi kao Duplicate i ne koristi je,
# pa ovo računalo ne dolazi ni do koga u mreži.
$dup = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq 'Duplicate')
if ($dup) {
    throw ("Adresa {0} je u sukobu s drugim računalom u mreži i Windows je ne koristi. U tablici adresa (docs/TESTNI-LAB.md, " +
        "poglavlje 1) provjerite kojem računalu pripada. Ako pripada ovom računalu, uklonite je na drugom VM-u (na hostu: " +
        "Get-VMNetworkAdapter -VMName * | Select-Object VMName, IPAddresses). Ako pripada drugom, ovom je računalu zadana pogrešna " +
        "adresa: zamijenite je ovdje (Remove-NetIPAddress -IPAddress {0}, zatim New-NetIPAddress s ispravnom adresom). " +
        "Na kraju ovdje pokrenite Restart-NetAdapter -Name '{1}' i ponovno ovu skriptu.") -f $dup[0].IPAddress, $dup[0].InterfaceAlias
}

if ($Role -eq 'AdditionalDC') {
    # Bez DNS-a na DC01 Install-ADDSDomainController javlja nejasnu grešku o vjerodajnicama ("could not be contacted").
    $srvName = "_ldap._tcp.dc._msdcs.$DomainName"
    try { $null = Resolve-DnsName -Name $srvName -Type SRV -Server $DnsServer -DnsOnly -ErrorAction Stop }
    catch {
        throw ("DNS server {0} ne vraća zapis {1} ({2}). Je li GPS-DC01 upaljen i spojen na switch GpsLab? Na hostu: " +
            "Get-VMNetworkAdapter -VMName GPS-DC01, GPS-DC02 | Select-Object VMName, SwitchName, IPAddresses") -f $DnsServer, $srvName, $_.Exception.Message
    }
    Write-Host "DC za $DomainName je dostupan preko DNS-a $DnsServer." -ForegroundColor Green
}

$null = Install-WindowsFeature AD-Domain-Services, GPMC -IncludeManagementTools
$dsrm = Read-Host -AsSecureString 'Lozinka za DSRM (Directory Services Restore Mode)'
if ($Role -eq 'Forest') {
    Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $NetbiosName -InstallDns `
        -SafeModeAdministratorPassword $dsrm -Force
}
else {
    $cred = Get-Credential -UserName "$DomainName\Administrator" -Message "Domain Admin za $DomainName (lozinka Administratora s DC01)"
    if (-not $cred) { throw 'Unos korisničkog imena i lozinke je otkazan.' }
    Install-ADDSDomainController -DomainName $DomainName -InstallDns -Credential $cred `
        -SafeModeAdministratorPassword $dsrm -Force
}
# Install-ADDS* sam restarta računalo. Nakon restarta pokrenite skriptu još jednom za DNS forwardere (samo DC01).
