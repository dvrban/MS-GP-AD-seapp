# GPO Studio

PowerShell aplikacija s grafičkim sučeljem (WPF) za **slaganje i primjenu grupnih politika** u
Microsoftovom okruženju:

- **lokalni Group Policy** na jednom ili više računala (i izvan domene), preko WinRM-a;
- **domenski GPO-ovi** preko domain controllera (PDC emulator), uz RSAT GroupPolicy modul.

Središnji pojam je **Policy Set**: JSON skup postavki koji se može primijeniti lokalno ili objaviti
kao domenski GPO.

Sučelje je napravljeno za korisnike koji ne poznaju Group Policy (izgled: Auxilium Informatika):

- **tri razine zaštite** (Osnovno, Preporučeno, Strogo) i **gotovi preseti** (javno računalo/kiosk,
  prijenosno računalo, učionica...);
- **kontrolna ploča sigurnosnih postavki**: kvačice i izbori po područjima (lozinke i prijava,
  ažuriranja, USB, Microsoft Defender, mreža i vatrozid, preglednik i Office, privatnost, sustav,
  revizija), s objašnjenjem na hrvatskom i utjecajem na korisnike;
- **vlastiti preseti** (predlošci) koji se spremaju, izvoze i uvoze;
- **usporedba sa standardima**: odabir ili stvarno stanje računala prema CIS benchmarku za
  Windows 11 (razine 1 i 2) i Microsoftovom sigurnosnom baselineu;
- **pregled promjena** prije primjene, sigurnosna kopija prije svake primjene i vraćanje s popisa;
- **napredni način**: katalog ADMX politika s pretragom, kao `gpedit.msc`.

➡ **Detaljan prijedlog arhitekture, sigurnosti i plana razvoja: [docs/PRIJEDLOG.md](docs/PRIJEDLOG.md)**
➡ **Upute za testni lab (Hyper-V, domena `gpslab.test`, smoke test): [docs/TESTNI-LAB.md](docs/TESTNI-LAB.md)**

> Status: **proof of concept (faza 0)**. Lokalna primjena i objava domenskog GPO-a rade za
> administrativne predloške (registry); lokalno su podržane i sigurnosne postavke (`secedit`) i
> revizija (`auditpol`). Sigurnosne postavke i revizija za domenske GPO-ove dolaze u fazi 3.

## Struktura

| Mapa | Sadržaj |
|---|---|
| `src/GpoStudio.Core` | Registry.pol čitač/pisač, ADMX katalog, Policy Set model, diff, revizijski zapis, sigurnosne kontrole i preseti |
| `src/GpoStudio.Core/Data` | Katalog sigurnosnih kontrola (`security-controls.json`) i ugrađeni preseti (`Presets`) |
| `src/GpoStudio.Local` | Primjena na lokalni GP (gpt.ini, secedit, auditpol, gpupdate, backup/restore, WinRM) |
| `src/GpoStudio.Domain` | Objava GPO-a, povezivanje, sigurnosno filtriranje, provjera replikacije |
| `src/GpoStudio.Gui` | WPF sučelje (`Start-GpoStudio.ps1`, `MainWindow.xaml`, `Gui.*.ps1`) i Auxilium tema (`Theme/Auxilium.xaml`) |
| `examples` | Primjer Policy Seta |
| `lab` | Skripte za izgradnju testnog laba i automatizirani smoke test |
| `tests` | Pester testovi (Core i dijelovi Local/Domain rade i na Linuxu) |

## Pokretanje GUI-a

```powershell
# Windows 10/11 ili Server, kao administrator
.\src\GpoStudio.Gui\Start-GpoStudio.ps1
```

GUI radi u 64-bitnom Windows PowerShellu 5.1. Pokrene li se iz PowerShella 7 ili 32-bitnog
procesa, sam se ponovno pokreće u `powershell.exe`. Fontovi marke (Orbitron, Sora, IBM Plex Mono;
licenca OFL) koriste se ako su u mapi `src\GpoStudio.Gui\Fonts`; bez njih sučelje koristi
Bahnschrift, Segoe UI i Consolas. Domenski cmdleti (`GpoStudio.Domain`) također
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

### Sigurnosne postavke iz skripte

```powershell
Import-Module .\src\GpoStudio.Local\GpoStudio.Local.psm1

$catalog = Get-GpsControlCatalog
$selection = Get-GpsControlSelection -Catalog $catalog -Level 2 -Override @{ 'usb.storage' = 'readonly' }
$set = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection $selection
Set-GpsLocalPolicy -PolicySet $set -WhatIf

# Usporedba odabira i stvarnog stanja računala sa standardima
Get-GpsControlCompliance -Catalog $catalog -Selection $selection | Select-Object Id, Score, Satisfied, Total
$state = Get-GpsControlState -Catalog $catalog -ComputerName PC01
Get-GpsControlCompliance -Catalog $catalog -Selection $state.Selection

# Preseti
Get-GpsControlPreset | Select-Object Name, Level, BuiltIn
$preset = New-GpsControlPreset -Catalog $catalog -Name 'Recepcija' -Level 2 -Selection $selection
Export-GpsControlPreset -Preset $preset
```

## Testovi

```powershell
Invoke-Pester ./tests
```

Testovi se u CI-ju (GitHub Actions) pokreću na Windows PowerShellu 5.1, PowerShellu 7 i Linuxu.
