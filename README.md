# GPO Studio

PowerShell aplikacija s grafičkim sučeljem (WPF) za **slaganje i primjenu grupnih politika** u
Microsoftovom okruženju:

- **lokalni Group Policy** na jednom ili više računala (i izvan domene), preko WinRM-a;
- **domenski GPO-ovi** preko domain controllera (PDC emulator), uz RSAT GroupPolicy modul.

Središnji pojam je **Policy Set**: JSON skup postavki koji se može primijeniti lokalno ili objaviti
kao domenski GPO. Postavke se biraju iz kataloga izgrađenog iz ADMX/ADML predložaka, kao u `gpedit.msc`.

➡ **Detaljan prijedlog arhitekture, sigurnosti i plana razvoja: [docs/PRIJEDLOG.md](docs/PRIJEDLOG.md)**

> Status: **proof of concept (faza 0)**. Lokalna primjena i objava domenskog GPO-a rade za
> administrativne predloške (registry); lokalno su podržane i sigurnosne postavke (`secedit`) i
> revizija (`auditpol`). Sigurnosne postavke i revizija za domenske GPO-ove dolaze u fazi 3.

## Struktura

| Mapa | Sadržaj |
|---|---|
| `src/GpoStudio.Core` | Registry.pol čitač/pisač, ADMX katalog, Policy Set model, diff, revizijski zapis |
| `src/GpoStudio.Local` | Primjena na lokalni GP (gpt.ini, secedit, auditpol, gpupdate, backup/restore, WinRM) |
| `src/GpoStudio.Domain` | Objava GPO-a, povezivanje, sigurnosno filtriranje, provjera replikacije |
| `src/GpoStudio.Gui` | WPF sučelje (`Start-GpoStudio.ps1` + `MainWindow.xaml`) |
| `examples` | Primjer Policy Seta |
| `tests` | Pester testovi (Core i dijelovi Local/Domain rade i na Linuxu) |

## Pokretanje GUI-a

```powershell
# Windows 10/11 ili Server, kao administrator
.\src\GpoStudio.Gui\Start-GpoStudio.ps1
```

GUI radi u 64-bitnom Windows PowerShellu 5.1. Pokrene li se iz PowerShella 7 ili 32-bitnog
procesa, sam se ponovno pokreće u `powershell.exe`. Domenski cmdleti (`GpoStudio.Domain`) također
traže Windows PowerShell 5.1, a Core i lokalni dio rade i u PowerShellu 7.

Za domenski način potreban je RSAT:

```powershell
# Windows 10/11
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# Windows Server
Install-WindowsFeature GPMC, RSAT-AD-PowerShell
```

## Korištenje iz skripte (bez GUI-a)

```powershell
Import-Module .\src\GpoStudio.Local\GpoStudio.Local.psm1
Import-Module .\src\GpoStudio.Domain\GpoStudio.Domain.psm1

$set = Import-GpsPolicySet .\examples\radna-stanica-baseline.json

# Lokalno: prvo diff, zatim primjena na dva računala
Set-GpsLocalPolicy -PolicySet $set -ComputerName PC01, PC02 -WhatIf
Set-GpsLocalPolicy -PolicySet $set -ComputerName PC01, PC02

# Domena: diff, objava i povezivanje na OU
Compare-GpsDomainPolicy -PolicySet $set -GpoName 'WS - Baseline'
Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS - Baseline' -LinkTarget 'OU=Racunala,DC=firma,DC=local'
Test-GpsDomainGpoReplication -GpoName 'WS - Baseline'

# Slaganje iz ADMX kataloga
$policy = Get-GpsAdmxCatalog | Where-Object DisplayName -like '*Store*' | Select-Object -First 1
$set.settings.AddRange(@(ConvertTo-GpsPolicySetting -Policy $policy -State Enabled))
```

## Testovi

```powershell
Invoke-Pester ./tests
```

Testovi se u CI-ju (GitHub Actions) pokreću na Windows PowerShellu 5.1, PowerShellu 7 i Linuxu.
