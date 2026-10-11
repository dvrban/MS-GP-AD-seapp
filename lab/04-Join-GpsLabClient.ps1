#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Priprema Windows 11 klijent laba: mreža, ime, pridruživanje domeni (ili radna grupa) i PowerShell Remoting.
.DESCRIPTION
    Pokreće se UNUTAR klijentskog VM-a, dvaput:
      1. prvo pokretanje: statička IP adresa, DNS i preimenovanje, zatim restart;
      2. drugo pokretanje: pridruživanje domeni u zadani OU (ili radna grupa uz -Workgroup) i
         uključivanje PowerShell Remotinga, zatim restart.
    GPO Studio do ciljanih računala dolazi preko WinRM-a (Invoke-Command), pa je Remoting obavezan
    na WS01, WS02 i STANDALONE01. Na Windows klijentima nije uključen po zadanom.
.PARAMETER Workgroup
    Računalo ostaje izvan domene (STANDALONE01). Uključuje se WinRM preko HTTP-a (5985), a admin
    stanica ga dodaje u TrustedHosts (skripta 05). Uključuje se i LocalAccountTokenFilterPolicy, jer
    lokalni administrator koji nije ugrađeni 'Administrator' inače preko mreže dobiva filtrirani token.
.EXAMPLE
    .\04-Join-GpsLabClient.ps1 -ComputerName WS01 -IPAddress 10.10.10.31 -OUPath 'OU=Pilot,OU=Racunala,OU=GpsLab,DC=gpslab,DC=test'
.EXAMPLE
    .\04-Join-GpsLabClient.ps1 -ComputerName STANDALONE01 -IPAddress 10.10.10.40 -Workgroup
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string]$IPAddress,
    [string]$Gateway = '10.10.10.1',
    [string]$DnsServer = '10.10.10.10',
    [string]$DomainName = 'gpslab.test',
    [string]$OUPath,
    [switch]$Workgroup
)

$ErrorActionPreference = 'Stop'

# Faza 1: mreža i ime
if ($env:COMPUTERNAME -ne $ComputerName) {
    $nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $nic) { throw 'Nije pronađen aktivni mrežni adapter.' }
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    $null = New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -PrefixLength 24 -DefaultGateway $Gateway
    $dns = if ($Workgroup) { @($DnsServer, '1.1.1.1') } else { @($DnsServer) }
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $dns
    Write-Host "Adresa $IPAddress. Preimenujem u $ComputerName i restartam; zatim ponovno pokrenite skriptu." -ForegroundColor Cyan
    Rename-Computer -NewName $ComputerName -Restart -Force
    return
}

$cs = Get-CimInstance Win32_ComputerSystem

if ($Workgroup) {
    # Javni mrežni profil blokira WinRM; lab mreža je privatna.
    Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | Set-NetConnectionProfile -NetworkCategory Private
    Enable-PSRemoting -Force
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
    Write-Host "$ComputerName je u radnoj grupi; WinRM (HTTP 5985) je uključen." -ForegroundColor Green
    return
}

if (-not $cs.PartOfDomain) {
    if (-not $OUPath) { throw 'Za pridruživanje domeni zadajte -OUPath (vidi izlaz skripte 03).' }
    $cred = Get-Credential -Message "Račun s pravom pridruživanja računala domeni $DomainName (npr. GPSLAB\gps.admin)"
    # Remoting se uključuje prije pridruživanja; nakon restarta pravilo vatrozida vrijedi i za Domain profil.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Add-Computer -DomainName $DomainName -OUPath $OUPath -Credential $cred -Restart -Force
    return
}

Enable-PSRemoting -Force
Write-Host "$ComputerName je u domeni $($cs.Domain); PowerShell Remoting je uključen." -ForegroundColor Green
