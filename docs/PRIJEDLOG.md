# GPO Studio: prijedlog rješenja

**Cilj:** Windows aplikacija s grafičkim sučeljem (GUI) koja u pozadini koristi PowerShell, a služi za
slaganje, pregled, primjenu i vraćanje **lokalnih Group Policy postavki** (po računalu) i
**domenskih (AD) GPO-ova** preko domain controllera, sve iz jednog alata.

---

## 1. Sažetak prijedloga

| Odluka | Prijedlog |
|---|---|
| Pozadinski sloj (engine) | PowerShell moduli (`GpoStudio.Core`, `.Local`, `.Domain`); svaka GUI akcija je cmdlet koji se može pokrenuti i iz skripte |
| GUI, faza 1 | **PowerShell + WPF (XAML)**, s runspaceovima za asinkroni rad; bez kompajliranja, brzo za iteriranje |
| GUI, faza 2 (opcija) | C# WPF / WinUI 3 aplikacija koja hosta PowerShell (`System.Management.Automation`) i koristi iste module |
| Središnji pojam | **Policy Set**: JSON definicija skupa postavki neovisna o cilju, koja se primjenjuje na *lokalno računalo / više računala* ili na *domenski GPO* |
| Katalog postavki | Parsiranje **ADMX/ADML** predložaka (lokalno `C:\Windows\PolicyDefinitions` ili *Central Store* u SYSVOL-u), s podrškom za hr-HR i en-US |
| Lokalni GP | Vlastiti čitač/pisač `Registry.pol` datoteka + `secedit` (sigurnosne postavke) + `auditpol` (napredna revizija); daljinski preko WinRM-a |
| Domenski GP | RSAT **GroupPolicy** modul (`New-GPO`, `Set-GPRegistryValue`, `New-GPLink`, `Backup-GPO`…) + izravno pisanje u SYSVOL za postavke koje cmdleti ne pokrivaju |
| Sigurnost | Najmanje potrebne ovlasti, delegirane AD grupe, opcionalno JEA endpoint, revizijski zapis svake promjene, automatski backup prije svake primjene |
| Tijek rada | *Nacrt → Usporedba (diff) → Odobrenje → Primjena → Provjera (RSoP) → Vraćanje (rollback)* |

---

## 2. Zašto PowerShell + GUI (i zašto ne samo GPMC)

GPMC i `gpedit.msc` dobro rade za ručno uređivanje jedne politike, ali nemaju:

- **ponovljivost**: istu bazu (baseline) primijeniti na 50 samostalnih računala, a zatim isto pretvoriti u domenski GPO;
- **verzioniranje i diff**: što se točno promijenilo između dviju verzija GPO-a;
- **lokalni GP na više računala odjednom**: `gpedit.msc` radi samo lokalno;
- **predloške po ulogama** (npr. "Radna stanica – računovodstvo", "Kiosk", "Server – IIS");
- **revizijski trag**: tko je, kada i zašto mijenjao.

PowerShell je službeni i dobro podržan način automatizacije u Microsoftovom okruženju (RSAT
GroupPolicy modul, ActiveDirectory modul, WinRM). GUI je tanki sloj iznad cmdleta, pa je sve što
se klikne moguće i skriptirati (CI/CD, zakazani zadaci).

---

## 3. Arhitektura

```
┌──────────────────────────────────────────────────────────────────────┐
│                         GPO Studio GUI (WPF)                          │
│  Katalog  │  Uređivač Policy Seta  │  Ciljevi  │  Diff  │  Povijest   │
└───────────────┬──────────────────────────────────────────────────────┘
                │  poziva cmdlete (asinkrono, runspace pool)
┌───────────────▼──────────────────────────────────────────────────────┐
│ GpoStudio.Core                                                        │
│  • ADMX/ADML parser → katalog postavki                               │
│  • Policy Set model (JSON), validacija, diff                          │
│  • Registry.pol čitač/pisač (binarni PReg format)                     │
│  • Revizijski zapis, backup spremište                                 │
├──────────────────────────────┬───────────────────────────────────────┤
│ GpoStudio.Local (adapter)    │ GpoStudio.Domain (adapter)            │
│  • %windir%\System32\         │  • RSAT GroupPolicy modul              │
│    GroupPolicy\{Machine,User}│  • SYSVOL (GptTmpl.inf, Registry.pol)  │
│  • secedit / auditpol        │  • GPLink, sigurnosno filtriranje,     │
│  • gpt.ini verzije           │    WMI filteri, nasljeđivanje          │
│  • WinRM za udaljena računala│  • Backup/Restore/Import, RSoP         │
└──────────────┬───────────────┴──────────────────┬────────────────────┘
               ▼                                  ▼
       Samostalna računala /               Domain Controller (PDC emulator)
       računala u radnoj grupi              → replikacija SYSVOL-a (DFSR)
```

### 3.1. Ključno načelo: jedan model, dva cilja

Korisnik slaže **Policy Set** (popis postavki). Isti set se može:

1. **primijeniti lokalno** na jedno ili više računala (izvan domene, DMZ, kiosci, testni strojevi), ili
2. **objaviti kao domenski GPO** i povezati na OU, domenu ili site.

Primjer Policy Seta (`examples/radna-stanica-baseline.json`):

```json
{
  "name": "Radna stanica - baseline",
  "version": "1.2.0",
  "settings": [
    {
      "id": "Windows.WindowsUpdate.AutoUpdateCfg",
      "scope": "Machine",
      "key": "Software\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU",
      "valueName": "NoAutoUpdate",
      "type": "REG_DWORD",
      "data": 0
    }
  ],
  "security": { "MinimumPasswordLength": 14, "LockoutBadCount": 5 },
  "audit": { "Logon": "Success,Failure" }
}
```

---

## 4. Lokalne grupne politike (po računalu)

### 4.1. Kako lokalni GP radi "ispod haube"

| Područje | Lokacija / alat |
|---|---|
| Administrativni predlošci (Computer) | `%windir%\System32\GroupPolicy\Machine\Registry.pol` |
| Administrativni predlošci (User) | `%windir%\System32\GroupPolicy\User\Registry.pol` |
| Verzija / ekstenzije | `%windir%\System32\GroupPolicy\gpt.ini` (`Version`, `gPCMachineExtensionNames`) |
| Lokalni GP za korisnika/grupu (MLGPO) | `%windir%\System32\GroupPolicyUsers\<SID>\User\Registry.pol` |
| Sigurnosne postavke (lozinke, prava korisnika…) | `secedit /export` i `secedit /configure` s `.inf` predloškom |
| Napredna revizija | `auditpol /get` i `auditpol /set`, ili `audit.csv` |
| Primjena | `gpupdate /force` (lokalno ili kroz `Invoke-Command`) |

Microsoft **nema službene PowerShell cmdlete za lokalni GP**. Postoje tri opcije:

1. **`LGPO.exe`** (Microsoft Security Compliance Toolkit): pouzdan za uvoz/izvoz, ali je vanjski exe.
2. **`PolicyFileEditor`** modul (PSGallery): uređuje `Registry.pol`.
3. **Vlastiti čitač/pisač `Registry.pol`** *(preporuka)*: format je jednostavan i dokumentiran
   (zaglavlje `PReg` + verzija 1, zatim zapisi `[ključ;vrijednost;tip;veličina;podaci]` u UTF-16LE).
   Bez vanjskih ovisnosti, potpuno pod našom kontrolom. Implementiran je u ovom PoC-u
   (`src/GpoStudio.Core/Public/RegistryPol.ps1`) i pokriven testovima.

LGPO.exe ostaje kao opcionalna rezerva za uvoz Microsoft Security Baseline paketa.

### 4.2. Tijek primjene lokalnog Policy Seta

1. **Backup**: kopija cijelog `%windir%\System32\GroupPolicy`, `secedit /export` i `auditpol /backup /file:audit.csv`
   u spremište, uz manifest `gpostudio-backup.json` (vraćanje bez manifesta se odbija).
2. **Čitanje** postojećeg `Registry.pol`, zatim **spajanje** (merge) s Policy Setom.
   Brisanje vrijednosti radi se zapisom `**del.<ValueName>`, kao što radi i GPMC.
3. **Zapis** novog `Registry.pol`.
4. **Povećanje verzije u `gpt.ini`** i upis CSE GUID-ova u `gPCMachineExtensionNames` /
   `gPCUserExtensionNames`. Bez toga klijent može ignorirati promjenu.
5. Sigurnosne postavke: generiraj `.inf`, zatim `secedit /configure /db <nova-baza>.sdb /cfg x.inf /overwrite /areas SECURITYPOLICY /quiet`.
   Za svako pokretanje koristi se nova baza koja se nakon primjene briše; inače secedit iznova primjenjuje
   i predloške iz ranijih pokretanja. Napredna revizija: `auditpol /set /subcategory:{GUID} ...`.
6. `gpupdate /target:computer /force`.
7. **Provjera**: ponovno pročitaj registry i usporedi s ciljem; rezultat prikaži u GUI-u.

### 4.3. Više računala

- `Invoke-Command -ComputerName $lista -ScriptBlock {...} -ThrottleLimit 16` preko WinRM-a (HTTPS 5986 za računala izvan domene).
- Moduli se na cilj prenose kao script block (bez instalacije na cilju) ili kroz `Copy-Item -ToSession`.
- Rezultati se skupljaju u tablicu u GUI-u (uspjeh/greška po računalu, diff).
- Za računala bez WinRM-a: izvoz paketa (`.zip` s `Registry.pol`, `.inf`, `apply.ps1`) za ručnu primjenu.

---

## 5. Domenski GPO-ovi preko DC-a

### 5.1. Što pokriva RSAT GroupPolicy modul

| Potreba | Cmdlet |
|---|---|
| Popis / dohvat | `Get-GPO -All`, `Get-GPOReport -ReportType Xml` |
| Kreiranje / kopiranje | `New-GPO`, `Copy-GPO`, `New-GPStarterGPO` |
| Administrativni predlošci | `Set-GPRegistryValue`, `Get-GPRegistryValue`, `Remove-GPRegistryValue` |
| Preferences (registry) | `Set-GPPrefRegistryValue` |
| Povezivanje | `New-GPLink`, `Set-GPLink` (Enforced, LinkEnabled, Order), `Remove-GPLink` |
| Nasljeđivanje | `Get-GPInheritance`, `Set-GPInheritance -IsBlocked` |
| Ovlasti / sigurnosno filtriranje | `Set-GPPermission`, `Get-GPPermission` |
| Backup / vraćanje / migracija | `Backup-GPO`, `Restore-GPO`, `Import-GPO` (+ migration table) |
| Dijagnostika | `Get-GPResultantSetOfPolicy`, `Invoke-GPUpdate` |

### 5.2. Što cmdleti NE pokrivaju i kako to riješiti

| Područje | Rješenje |
|---|---|
| Security Settings (lozinke, User Rights, Restricted Groups) | Pisanje `\\domena\SYSVOL\domena\Policies\{GUID}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf`, zatim ažuriranje `versionNumber` na AD objektu i u `GPT.INI`, te dodavanje CSE GUID-a u `gPCMachineExtensionNames` |
| Advanced Audit Policy | `...\Machine\Microsoft\Windows NT\Audit\audit.csv` + odgovarajući CSE |
| WMI filteri | AD objekti klase `msWMI-Som` u `CN=SomContainer,CN=WMIPolicy,CN=System,...` (ActiveDirectory modul) i atribut `gPCWMIFilter` na GPO-u |
| Ostale Preferences (mape, pisači, zadaci) | XML datoteke pod `...\Preferences\` (faza 3) |

Pravilo: **sve promjene se rade na PDC emulatoru** (`(Get-ADDomain).PDCEmulator`), parametrom
`-Server`, kao što to radi i GPMC, da se izbjegnu konflikti u replikaciji.

### 5.3. Tijek objave domenskog GPO-a

1. Odabir: *novi GPO* ili *postojeći GPO* (za postojeći se prvo radi `Backup-GPO`).
2. **Diff**: `Get-GPOReport -ReportType Xml` za trenutno stanje naspram Policy Seta; GUI prikazuje dodano, promijenjeno i obrisano.
3. **Odobrenje** (opcionalno četiri oka): spremanje zahtjeva u repozitorij promjena.
4. **Primjena**: `Set-GPRegistryValue` po stavci + SYSVOL za sigurnosne postavke.
5. **Povezivanje**: `New-GPLink -Target "OU=Racunovodstvo,DC=firma,DC=local" -LinkEnabled Yes`.
6. **Filtriranje**: `Set-GPPermission -TargetType Group -PermissionLevel GpoApply`.
7. **Provjera replikacije**: usporedba verzija GPO-a na svim DC-ovima (`Get-GPO -Server $dc`).
8. **Provjera učinka**: `Invoke-GPUpdate` na testnom računalu + `Get-GPResultantSetOfPolicy`.

---

## 6. Katalog postavki (ADMX/ADML)

Ovo je srce "slaganja" u GUI-u: korisnik ne upisuje registry ključeve ručno nego bira politike
kao u `gpedit.msc`.

- Izvor: Central Store `\\domena\SYSVOL\domena\Policies\PolicyDefinitions`, a ako ne postoji, lokalni `C:\Windows\PolicyDefinitions`.
- Parser čita `*.admx` (struktura: kategorije, politike, registry ključ, `valueName`, elementi
  `boolean`, `decimal`, `text`, `enum`, `list`, `multiText`) i `*.adml` (prijevodi, `presentation`).
- Rezultat je **indeksirani katalog** (keširan kao JSON radi brzine) sa stablom kategorija i pretraživanjem.
- Svaka politika generira GUI formu automatski prema svojim elementima: checkbox, numeric, dropdown, lista.
- Podrška za dodatne ADMX pakete (Office, Edge, Chrome, OneDrive) ubacivanjem u katalog.

PoC parser: `src/GpoStudio.Core/Public/Get-GpsAdmxCatalog.ps1`.

---

## 7. GUI: prijedlog ekrana

```
┌ GPO Studio ───────────────────────────────────────────────────────────────┐
│ [Cilj: ● Lokalno  ○ Domena]  Računala: PC01, PC02 ▾   Domena: firma.local │
├───────────────┬───────────────────────────────────────────┬───────────────┤
│ KATALOG       │ POLICY SET: "Radna stanica - baseline"     │ DETALJI       │
│ 🔍 pretraga    │ ┌──────────────────────────────────────┐ │ Naziv politike│
│ ▸ Computer    │ │ ✔ Windows Update: Configure AU   [3] │ │ Opis (ADML)   │
│   ▸ Windows   │ │ ✔ Disable Store                     │ │ Registry:     │
│     Components│ │ ✔ Min. password length = 14         │ │  HKLM\...     │
│ ▸ User        │ └──────────────────────────────────────┘ │ ○ Not conf.   │
│ ▸ Security    │ [Dodaj] [Ukloni] [Uvezi GPO] [Izvezi JSON] │ ● Enabled     │
│ ▸ Audit       │                                           │ ○ Disabled    │
├───────────────┴───────────────────────────────────────────┴───────────────┤
│ [Usporedi (Diff)]  [Primijeni]  [Backup]  [Vrati]   Status: ✓ 2/2 računala│
└───────────────────────────────────────────────────────────────────────────┘
```

Kartice:
1. **Katalog i uređivač**: stablo ADMX kategorija, forma politike, Policy Set.
2. **Ciljevi**: lokalna računala (lista, uvoz iz CSV-a/AD-a), domena: stablo OU-ova s povezanim GPO-ovima (kao GPMC).
3. **Diff**: usporedba u dva stupca (trenutno ↔ željeno), s bojama.
4. **Povijest i backup**: popis backupova, vraćanje jednim klikom.
5. **Izvještaji**: HTML izvještaj GPO-a, RSoP za računalo/korisnika, *GPO zdravlje* (prazni GPO-ovi, nepovezani GPO-ovi, GPO-ovi s neusklađenim verzijama AD/SYSVOL).
6. **Log**: konzola s točnim PowerShell naredbama koje su izvršene (transparentnost i učenje).

Tehnički: XAML se učitava kroz `[Windows.Markup.XamlReader]`, a dugotrajne operacije idu u
zaseban runspace da GUI ne zamrzava. Kostur je u `src/GpoStudio.Gui/`.

---

## 8. Sigurnost i upravljanje promjenama

- **Ovlasti**: aplikacija radi s pravima prijavljenog korisnika. Preporučene delegirane grupe:
  - `GPS-GPO-Editors`: uređivanje određenih GPO-ova (`Set-GPPermission -PermissionLevel GpoEdit`);
  - `GPS-GPO-Linkers`: delegirano pravo *Link GPO* na određenim OU-ovima;
  - `Group Policy Creator Owners`: samo onima koji smiju kreirati nove GPO-ove.
- **JEA (Just Enough Administration)**, opcija: endpoint na upravljačkom serveru koji izlaže samo GpoStudio cmdlete, tako da korisnik ne treba Domain Admin prava.
- **Tier model**: GUI se pokreće s PAW / admin jump hosta, nikad s običnog korisničkog računala.
- **Revizijski zapis** (JSON lines + opcionalno Windows Event Log izvor `GpoStudio`): tko, kada, cilj, diff, rezultat.
- **Obavezan backup prije svake primjene**, s mogućnošću vraćanja.
- **Potpisivanje skripti** (Authenticode) i `AllSigned` politika izvršavanja u produkciji.
- **Zaštita od grešaka**: "dry-run" način (`-WhatIf`), upozorenje kad se mijenja *Default Domain Policy* ili *Default Domain Controllers Policy*, potvrda za GPO-ove povezane na korijen domene.
- **Verzioniranje Policy Setova u Gitu** (JSON je čitljiv u diffu): pull request kao proces odobrenja.

---

## 9. Tehnički preduvjeti

| Komponenta | Zahtjev |
|---|---|
| OS (admin stanica) | Windows 10/11 ili Windows Server 2016+ |
| PowerShell | Windows PowerShell 5.1, 64-bitni (obavezno za GUI/WPF i domenski dio); PS 7.4+ podržan za Core i lokalni dio |
| RSAT | Windows 10/11: `Rsat.GroupPolicy.Management.Tools` i `Rsat.ActiveDirectory.DS-LDS.Tools`; Windows Server: značajke `GPMC` i `RSAT-AD-PowerShell` |
| Mreža | WinRM (5985/5986) prema ciljanim računalima; prema DC-ovima: ADWS (TCP 9389, ActiveDirectory modul), LDAP (389), SMB (445, SYSVOL), Kerberos (88) i DNS (53) |
| Ovlasti | Lokalni administrator na ciljevima (lokalni GP); delegirane GPO ovlasti (domena) |

Instalacija RSAT-a:
```powershell
# Windows 10/11
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# Windows Server 2016+
Install-WindowsFeature GPMC, RSAT-AD-PowerShell
```

---

## 10. Plan razvoja (roadmap)

| Faza | Trajanje (okvirno) | Isporuka |
|---|---|---|
| **0 – PoC** *(ovaj repozitorij)* | 1 tjedan | Registry.pol čitač/pisač, ADMX parser, Policy Set model, osnovni cmdleti za lokalno/domenu, WPF kostur |
| **1 – MVP lokalno** | 3–4 tjedna | GUI katalog + uređivač, lokalna primjena na više računala, backup/restore, diff, log |
| **2 – MVP domena** | 3–4 tjedna | OU stablo, kreiranje/uređivanje/povezivanje GPO-ova, sigurnosno filtriranje, HTML izvještaji, RSoP |
| **3 – Napredno** | 4–6 tjedana | Sigurnosne postavke i audit u domeni (SYSVOL), WMI filteri, Preferences, uvoz Microsoft Security Baselinea, zdravlje GPO-ova |
| **4 – Enterprise** | po potrebi | JEA endpoint, proces odobrenja, Event Log integracija, C#/WinUI GUI, MSI instalacija, Intune izvještaj (Group Policy Analytics) za migraciju u cloud |

---

## 11. Rizici i kako ih umanjiti

| Rizik | Mjera |
|---|---|
| Pogrešan GPO na korijenu domene utječe na sva računala | Testni OU + "staging" tijek; upozorenja; obavezan backup; `-WhatIf` |
| AD i SYSVOL verzije se raziđu kod izravnog pisanja u SYSVOL | Uvijek se piše preko PDC emulatora, ažurira se verzija u oba izvora, provjera nakon primjene |
| Oštećen `Registry.pol` | Pisanje u privremenu datoteku + validacija ponovnim čitanjem + atomarna zamjena (`File.Replace`); backup |
| Parsiranje velikog broja ADMX-ova je sporo | Keširanje kataloga (JSON) s hashom izvornih datoteka |
| GroupPolicy modul u PS7 | Domenski dio radi samo u Windows PowerShellu 5.1. Kroz `-UseWindowsPowerShell` objekti stižu deserijalizirani, pa ugniježđena svojstva (`GpoLinks`, verzije GPO-a) postaju stringovi. GUI se sam ponovno pokreće u 64-bitnom `powershell.exe` |
| Lokalni GP nadjačan domenskim | GUI upozorava kad je računalo u domeni (LGPO ima najniži prioritet u LSDOU redoslijedu) |

---

## 12. Struktura repozitorija (PoC)

```
docs/PRIJEDLOG.md                 ← ovaj dokument
src/GpoStudio.Core/               ← model, Registry.pol, ADMX katalog
src/GpoStudio.Local/              ← adapter za lokalni GP
src/GpoStudio.Domain/             ← adapter za domenske GPO-ove
src/GpoStudio.Gui/                ← WPF XAML + Start-GpoStudio.ps1
examples/                         ← primjeri Policy Setova
tests/                            ← Pester testovi (Core radi i na Linuxu/CI-ju)
```

## 13. Sljedeći koraci

1. Potvrditi opseg MVP-a: lokalno, domena ili oboje paralelno.
2. Osigurati testni lab: 1–2 DC-a (Windows Server 2022/2025), 2–3 klijenta, jedno samostalno računalo.
3. Dogovoriti delegacijski model (grupe, OU-ovi) i gdje se čuvaju backupovi i revizijski zapis.
4. Pokrenuti fazu 1 na temelju PoC kostura iz ovog repozitorija.
