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
.EXAMPLE
    .\03-Initialize-GpsLabAD.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipCentralStore
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

$password = Read-Host -AsSecureString 'Lozinka za lab korisnike (gps.admin, gps.editor, gps.user)'
foreach ($u in @(
        @{ Sam = 'gps.admin'; Name = 'GPS Admin'; Groups = @('Domain Admins') }
        @{ Sam = 'gps.editor'; Name = 'GPS Editor'; Groups = @('Group Policy Creator Owners', 'GPS-GPO-Editors') }
        @{ Sam = 'gps.user'; Name = 'GPS User'; Groups = @() }
    )) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $u.Name -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@$($domain.DNSRoot)" `
            -Path $usersOu -AccountPassword $password -Enabled $true -PasswordNeverExpires $true
        Write-Host "Korisnik $($u.Sam)" -ForegroundColor Green
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
