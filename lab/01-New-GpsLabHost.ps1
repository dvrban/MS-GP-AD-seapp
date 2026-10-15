#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Priprema Hyper-V host za GPO Studio testni lab: interni switch, NAT i virtualne mašine.
.DESCRIPTION
    Pokreće se na fizičkom računalu s Hyper-V-om (Windows 10/11 Pro/Enterprise ili Windows Server).
    Stvara:
      - interni switch 'GpsLab' s adresom hosta 10.10.10.1/24 i NAT-om prema internetu,
      - Gen2 virtualne mašine s DVD-om (ISO), Secure Bootom i vTPM-om (potreban za Windows 11).
    Switch nema DHCP: IP adrese gosti dobivaju tek skriptama 02 i 04.
    Instalacija operacijskog sustava je ručna (vidi docs/TESTNI-LAB.md, poglavlje 3.2).
    Postojeće switcheve, NAT i VM-ove preskače (ne popravlja ih). VM čija konfiguracija ne uspije
    uklanja se zajedno s diskom, pa ga ponovno pokretanje stvara iznova.
    ISO datoteke držite na lokalnom disku hosta: Hyper-V ih čita kao račun računala, pa mrežne
    putanje (UNC, NAS) često ne rade.
.PARAMETER ServerIso
    Putanja do Windows Server 2022/2025 ISO-a (npr. Evaluation verzija).
.PARAMETER ClientIso
    Putanja do Windows 11 Enterprise ISO-a (npr. Evaluation verzija).
.PARAMETER VmPath
    Mapa za VHDX datoteke i konfiguraciju VM-ova.
.PARAMETER IncludeSecondDc
    Stvara i DC02 (za test replikacije GPO-a između dva DC-a).
.EXAMPLE
    .\01-New-GpsLabHost.ps1 -ServerIso D:\ISO\WS2025.iso -ClientIso D:\ISO\Win11Ent.iso -VmPath D:\GpsLab -IncludeSecondDc
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ServerIso,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ClientIso,
    [string]$VmPath = 'C:\GpsLab',
    [string]$SwitchName = 'GpsLab',
    [string]$HostAddress = '10.10.10.1',
    [string]$Prefix = '10.10.10.0/24',
    [switch]$IncludeSecondDc
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V nije instaliran. Klijent: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All; Server: Install-WindowsFeature Hyper-V -IncludeManagementTools (zatim restart).'
}

# Uloge, memorija i disk po VM-u. Statičke IP adrese postavljaju se kasnije unutar gosta (skripte 02 i 04).
$vms = @(
    @{ Name = 'GPS-DC01'; Iso = $ServerIso; Memory = 2GB; Disk = 60GB; Tpm = $false }
    @{ Name = 'GPS-ADMIN01'; Iso = $ClientIso; Memory = 4GB; Disk = 80GB; Tpm = $true }
    @{ Name = 'GPS-WS01'; Iso = $ClientIso; Memory = 4GB; Disk = 64GB; Tpm = $true }
    @{ Name = 'GPS-WS02'; Iso = $ClientIso; Memory = 4GB; Disk = 64GB; Tpm = $true }
    @{ Name = 'GPS-STANDALONE01'; Iso = $ClientIso; Memory = 4GB; Disk = 64GB; Tpm = $true }
)
if ($IncludeSecondDc) { $vms += @{ Name = 'GPS-DC02'; Iso = $ServerIso; Memory = 2GB; Disk = 60GB; Tpm = $false } }

# 1. Interni switch + adresa hosta + NAT
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($SwitchName, 'Stvaranje internog Hyper-V switcha')) {
        $null = New-VMSwitch -Name $SwitchName -SwitchType Internal
    }
}
$alias = "vEthernet ($SwitchName)"
if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $HostAddress -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($alias, "Adresa $HostAddress/24")) {
        $null = New-NetIPAddress -InterfaceAlias $alias -IPAddress $HostAddress -PrefixLength 24
    }
}
if (-not (Get-NetNat -ErrorAction SilentlyContinue | Where-Object InternalIPInterfaceAddressPrefix -eq $Prefix)) {
    if ($PSCmdlet.ShouldProcess($Prefix, 'NAT prema internetu')) {
        $null = New-NetNat -Name "$SwitchName-NAT" -InternalIPInterfaceAddressPrefix $Prefix
    }
}

# 2. Virtualne mašine
$null = New-Item -ItemType Directory -Path $VmPath -Force
foreach ($vm in $vms) {
    if (Get-VM -Name $vm.Name -ErrorAction SilentlyContinue) {
        Write-Host "VM $($vm.Name) već postoji, preskačem." -ForegroundColor Yellow
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Stvaranje VM-a')) { continue }

    $vhd = Join-Path $VmPath "$($vm.Name).vhdx"
    $null = New-VM -Name $vm.Name -Generation 2 -MemoryStartupBytes $vm.Memory -NewVHDPath $vhd `
        -NewVHDSizeBytes $vm.Disk -SwitchName $SwitchName -Path $VmPath
    try {
        Set-VMProcessor -VMName $vm.Name -Count 2
        Set-VMMemory -VMName $vm.Name -DynamicMemoryEnabled $true -MinimumBytes 1GB -StartupBytes $vm.Memory -MaximumBytes ($vm.Memory * 2)
        # Lab koristi ručne checkpointe ("Clean"), automatski bi samo trošili disk.
        Set-VM -Name $vm.Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard

        $dvd = Add-VMDvdDrive -VMName $vm.Name -Path $vm.Iso -Passthru
        Set-VMFirmware -VMName $vm.Name -FirstBootDevice $dvd -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        if ($vm.Tpm) {
            # Windows 11 traži TPM 2.0; lokalni key protector je dovoljan za lab.
            Set-VMKeyProtector -VMName $vm.Name -NewLocalKeyProtector
            Enable-VMTPM -VMName $vm.Name
        }
    }
    catch {
        Write-Warning "Konfiguracija VM-a $($vm.Name) nije uspjela; uklanjam djelomično stvoreni VM i $vhd."
        Remove-VM -Name $vm.Name -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $vhd -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "Stvoren VM $($vm.Name)." -ForegroundColor Green
}

Write-Host ''
Write-Host 'Sljedeći korak: pokrenite svaki VM, odmah pritisnite tipku za boot s DVD-a i instalirajte OS' -ForegroundColor Cyan
Write-Host '(docs/TESTNI-LAB.md, poglavlje 3.2). Prije instalacije: Start-VM -Name GPS-DC01; vmconnect localhost GPS-DC01' -ForegroundColor Cyan
