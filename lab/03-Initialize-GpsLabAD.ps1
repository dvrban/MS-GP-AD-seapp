#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Priprema Active Directory za testiranje GPO Studija: OU-ovi, grupe, korisnici i Central Store.
.DESCRIPTION
    Pokreće se na DC01 nakon promocije (Domain Admin). Idempotentna je: postojeće objekte preskače.
    Stvara:
      OU=GpsLab
        OU=Racunala
          OU=Pilot          <- WS01 i WS02 (GPO se povezuje ovdje)
        OU=Admin            <- ADMIN01
        OU=Korisnici
        OU=Grupe
      Grupe:   GPS-Pilot-PC (računala u pilotu), GPS-GPO-Editors (delegirano uređivanje GPO-ova)
      Korisnici: gps.admin (Domain Admins, za rad s GPO Studijem), gps.editor (Group Policy Creator Owners
                 + GPS-GPO-Editors, za test delegacije), gps.user (običan korisnik)
      Central Store: kopija %windir%\PolicyDefinitions u SYSVOL.
      Članstvo:  WS01 u GPS-Pilot-PC, ako je WS01 već pridružen domeni.
.EXAMPLE
    .\03-Initialize-GpsLabAD.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipCentralStore,
    # Računala koja ulaze u GPS-Pilot-PC; dodaju se ako već postoje u AD-u (skriptu pokrenite
    # ponovno nakon pridruživanja WS01, vidi docs/TESTNI-LAB.md 3.6).
    [string[]]$PilotMember = @('WS01')
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain = Get-ADDomain
$root = $domain.DistinguishedName

function New-GpsLabOU([string]$Name, [string]$Path) {
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path
        Write-Host "OU $dn" -ForegroundColor Green
    }
    $dn
}

$labOu = New-GpsLabOU 'GpsLab' $root
$computersOu = New-GpsLabOU 'Racunala' $labOu
$pilotOu = New-GpsLabOU 'Pilot' $computersOu
$adminOu = New-GpsLabOU 'Admin' $labOu
$usersOu = New-GpsLabOU 'Korisnici' $labOu
$groupsOu = New-GpsLabOU 'Grupe' $labOu

foreach ($g in @(
        @{ Name = 'GPS-Pilot-PC'; Description = 'Računala na kojima se primjenjuju pilot GPO-ovi (sigurnosno filtriranje)' }
        @{ Name = 'GPS-GPO-Editors'; Description = 'Delegirano uređivanje GPO-ova laba' }
    )) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g.Name -GroupScope Global -GroupCategory Security -Path $groupsOu -Description $g.Description
        Write-Host "Grupa $($g.Name)" -ForegroundColor Green
    }
}

$labUsers = @(
    @{ Sam = 'gps.admin'; Name = 'GPS Admin'; Groups = @('Domain Admins') }
    @{ Sam = 'gps.editor'; Name = 'GPS Editor'; Groups = @('Group Policy Creator Owners', 'GPS-GPO-Editors') }
    @{ Sam = 'gps.user'; Name = 'GPS User'; Groups = @() }
)

# Lozinka se traži samo ako neki korisnik nedostaje ili je onemogućen, i unosi se dvaput.
# Mora zadovoljiti politiku domene (zadano: barem 7 znakova i 3 vrste znakova).
$needPassword = @($labUsers | Where-Object {
        $existing = Get-ADUser -Filter "SamAccountName -eq '$($_.Sam)'" -Properties Enabled -ErrorAction SilentlyContinue
        -not $existing -or -not $existing.Enabled
    }).Count -gt 0
if ($needPassword) {
    $plain = { param($secure) [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)) }
    do {
        $password = Read-Host -AsSecureString 'Lozinka za lab korisnike (gps.admin, gps.editor, gps.user)'
        $again = Read-Host -AsSecureString 'Ponovite lozinku'
        $match = (& $plain $password) -ceq (& $plain $again)
        if (-not $match) { Write-Host 'Lozinke se ne podudaraju, pokušajte ponovno.' -ForegroundColor Yellow }
    } until ($match)
}

foreach ($u in $labUsers) {
    $user = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -Properties Enabled -ErrorAction SilentlyContinue
    if (-not $user) {
        try {
            New-ADUser -Name $u.Name -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@$($domain.DNSRoot)" `
                -Path $usersOu -AccountPassword $password -Enabled $true -PasswordNeverExpires $true
        }
        catch {
            # New-ADUser stvori račun i kad lozinka ne prođe politiku (ostaje onemogućen); uklanjamo ga.
            Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" | Remove-ADUser -Confirm:$false
            throw "Korisnik $($u.Sam) nije stvoren (lozinka možda ne zadovoljava politiku domene): $_"
        }
        Write-Host "Korisnik $($u.Sam)" -ForegroundColor Green
    }
    elseif (-not $user.Enabled) {
        # Ponovno pokretanje popravlja račun ostao onemogućen nakon ranije neuspjele lozinke.
        Set-ADAccountPassword -Identity $u.Sam -Reset -NewPassword $password
        Enable-ADAccount -Identity $u.Sam
        Write-Host "Korisnik $($u.Sam): lozinka postavljena i račun omogućen" -ForegroundColor Green
    }
    foreach ($group in $u.Groups) {
        $user = Get-ADUser -Identity $u.Sam
        if (@(Get-ADGroupMember -Identity $group | ForEach-Object DistinguishedName) -notcontains $user.DistinguishedName) {
            Add-ADGroupMember -Identity $group -Members $user
        }
    }
}

# Central Store: GPO Studio (i GPMC) tada čitaju iste ADMX predloške sa svih računala.
if (-not $SkipCentralStore) {
    $central = Join-Path $env:windir "SYSVOL\domain\Policies\PolicyDefinitions"
    if (-not (Test-Path -LiteralPath $central)) {
        Copy-Item -Path (Join-Path $env:windir 'PolicyDefinitions') -Destination $central -Recurse
        Write-Host "Central Store: $central" -ForegroundColor Green
    }
    else {
        Write-Host "Central Store već postoji: $central" -ForegroundColor Yellow
    }
}

foreach ($name in $PilotMember) {
    $computer = Get-ADComputer -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
    if (-not $computer) { Write-Host "$name još nije u domeni; GPS-Pilot-PC ćete popuniti ponovnim pokretanjem nakon pridruživanja." -ForegroundColor Yellow; continue }
    if (@(Get-ADGroupMember -Identity 'GPS-Pilot-PC' | ForEach-Object DistinguishedName) -notcontains $computer.DistinguishedName) {
        Add-ADGroupMember -Identity 'GPS-Pilot-PC' -Members $computer
        Write-Host "$name dodan u GPS-Pilot-PC (članstvo računalo vidi nakon restarta)." -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Rezultat:' -ForegroundColor Cyan
[pscustomobject]@{
    Domena    = $domain.DNSRoot
    PilotOU   = $pilotOu
    AdminOU   = $adminOu
    Grupe     = $groupsOu
    Korisnici = $usersOu
} | Format-List
Write-Host "Za klijente (skripta 04): -OUPath '$pilotOu' (WS01, WS02) i -OUPath '$adminOu' (ADMIN01)." -ForegroundColor Cyan
