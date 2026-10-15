# GPO Studio: upute za testni lab

Ove upute opisuju kako izgraditi izolirani testni lab i u njemu prvi put isprobati GPO Studio na
stvarnim Windows računalima i u stvarnoj domeni. CI provjerava logiku modula, ali sljedeće se može
provjeriti samo u labu:

- GUI (WPF) u Windows PowerShellu 5.1 i ponovno pokretanje iz PowerShella 7 / 32-bitnog procesa;
- stvarnu primjenu lokalnog GP-a (`Registry.pol`, `gpt.ini`, `secedit`, `auditpol`, `gpupdate`) i vraćanje iz backupa;
- primjenu na udaljena računala preko WinRM-a (u domeni i u radnoj grupi);
- objavu domenskog GPO-a preko RSAT-a, povezivanje, sigurnosno filtriranje i replikaciju između DC-ova.

Lab je namjerno izoliran (interna mreža s NAT-om) i koristi zasebnu domenu `gpslab.test`, tako da
ništa ne može utjecati na produkcijsko okruženje.

> **Nikad ne pokrećite lab skripte ni smoke test u produkcijskoj domeni.** Skripte stvaraju OU-ove,
> korisnike i GPO-ove, mijenjaju sigurnosnu politiku i reviziju na računalima te brišu testne GPO-ove.

---

## 1. Topologija

```
                      Internet
                         │
               ┌─────────┴──────────┐
               │  Hyper-V host      │  vEthernet (GpsLab) 10.10.10.1/24 + NAT
               └─────────┬──────────┘
                         │ interni switch "GpsLab"  10.10.10.0/24
   ┌──────────┬──────────┼───────────┬───────────┬────────────────┐
   │          │          │           │           │                │
 DC01       DC02*     ADMIN01      WS01        WS02        STANDALONE01
 .10        .11        .20          .31         .32           .40
 AD DS,DNS  dodatni    GPO Studio,  Pilot OU,   Pilot OU,    radna grupa,
 Central    DC         RSAT, Pester član grupe  NIJE član    lokalni GP
 Store                              GPS-Pilot-PC              preko WinRM-a
                                                       (* opcionalno, za test replikacije)
```

| VM u Hyper-V-u | Ime računala | Operacijski sustav | IP adresa | Uloga | RAM |
|---|---|---|---|---|---|
| GPS-DC01 | DC01 | Windows Server 2025 (Desktop Experience) | 10.10.10.10 | AD DS, DNS, Central Store | 2 GB |
| GPS-DC02 *(opcija)* | DC02 | Windows Server 2025 (Desktop Experience) | 10.10.10.11 | dodatni DC, test replikacije | 2 GB |
| GPS-ADMIN01 | ADMIN01 | Windows 11 Enterprise | 10.10.10.20 | admin stanica: GPO Studio, RSAT, Pester | 4 GB |
| GPS-WS01 | WS01 | Windows 11 Enterprise | 10.10.10.31 | klijent u `OU=Pilot`, član `GPS-Pilot-PC` | 4 GB |
| GPS-WS02 | WS02 | Windows 11 Enterprise | 10.10.10.32 | klijent u `OU=Pilot`, **nije** član grupe | 4 GB |
| GPS-STANDALONE01 | STANDALONE01 | Windows 11 Enterprise | 10.10.10.40 | radna grupa, lokalni GP preko WinRM-a | 4 GB |

- **Domena:** `gpslab.test` (NetBIOS `GPSLAB`). Nastavak `.test` je rezerviran (RFC 2606), pa se
  ne može sudariti s pravom domenom.
- **AD struktura** (skripta 03):
  - `OU=GpsLab` s podjedinicama `OU=Racunala` → `OU=Pilot`, `OU=Admin`, `OU=Korisnici` i `OU=Grupe`;
  - grupe `GPS-Pilot-PC` i `GPS-GPO-Editors`;
  - korisnici `gps.admin` (Domain Admins), `gps.editor` (Group Policy Creator Owners) i `gps.user`.
- **Zašto WS01 i WS02 u istom OU-u:** GPO se povezuje na `OU=Pilot`, a sigurnosno filtriranje na
  `GPS-Pilot-PC` mora ga ograničiti na WS01. Tako jedan test provjerava i link i filtriranje.

---

## 2. Što treba

| Stavka | Zahtjev |
|---|---|
| Host | Windows 10/11 Pro, Enterprise ili Education, ili Windows Server, s uključenim Hyper-V-om; CPU s virtualizacijom (VT-x/AMD-V, SLAT) |
| RAM | najmanje 24 GB bez DC02 (oko 28 GB s DC02), jer Hyper-V za pokretanje VM-a traži punu početnu memoriju; preporučeno 32 GB. Za host sa 16 GB vidi napomenu u 3.2 |
| Disk | SSD, oko 120 GB stvarno zauzeto (VHDX diskovi su dinamični, nazivno do ~400 GB) |
| ISO | Windows Server 2025 (ili 2022) Evaluation, vrijedi 180 dana; Windows 11 Enterprise Evaluation, vrijedi 90 dana; oba s Microsoft Evaluation Centera |
| Internet | potreban je VM-ovima (preko NAT-a) za RSAT (Features on Demand) i Pester |
| Vrijeme | prva izgradnja oko 3–4 sata, najviše zbog instalacije operacijskih sustava |

Uključivanje Hyper-V-a na hostu (zatim restart):

```powershell
# Windows 10/11
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
# Windows Server
Install-WindowsFeature Hyper-V -IncludeManagementTools
```

Skripta 01 je specifična za Hyper-V. Skripte 02–05 i smoke test rade i na drugim hipervizorima
(npr. VMware, Proxmox); tamo VM-ove i mrežu napravite ručno prema tablici gore. Na Azureu skripte
02 i 04 nemojte koristiti: one unutar gosta postavljaju statičku IP adresu, što na Azureu prekida
mrežu VM-a.

### Skripte

| Skripta | Gdje se pokreće | Što radi |
|---|---|---|
| `lab/01-New-GpsLabHost.ps1` | Hyper-V host | switch, NAT, VM-ovi (Gen2, Secure Boot, vTPM) |
| `lab/02-Install-GpsLabDC.ps1` | DC01 (i DC02) | IP, ime, AD DS, nova šuma ili dodatni DC, DNS forwarderi |
| `lab/03-Initialize-GpsLabAD.ps1` | DC01 | OU-ovi, grupe, korisnici, Central Store |
| `lab/04-Join-GpsLabClient.ps1` | WS01, WS02, ADMIN01, STANDALONE01 | IP, ime, domena ili radna grupa, PowerShell Remoting |
| `lab/05-Install-GpsLabAdmin.ps1` | ADMIN01 | RSAT, GPO Studio, ExecutionPolicy, PowerShell 7, Pester i testovi, TrustedHosts |
| `lab/Test-GpsLabSmoke.ps1` | ADMIN01 | automatizirani smoke test (poglavlje 4) |

Sve skripte traže povišeni PowerShell (*Run as administrator*). Skripte koje se pokreću dvaput
same prepoznaju u kojoj su fazi.

---

## 3. Izgradnja korak po korak

### 3.0. Repozitorij na hostu

Preuzmite repozitorij (`Code → Download ZIP` ili `git clone`) i raspakirajte ga, npr. u `D:\GpoStudio`.
Datoteke iz preuzetog ZIP-a označene su kao "preuzete s interneta", pa ih otključajte i dopustite
izvršavanje skripti u trenutnoj sesiji:

```powershell
Get-ChildItem D:\GpoStudio -Recurse -File | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**Kako prenijeti skripte u VM-ove.** Možete koristiti Enhanced Session (kopiraj/zalijepi, dijeljeni
disk), preuzeti repozitorij u svakom VM-u ili koristiti `Copy-VMFile` s hosta. Potonje radi nakon
instalacije OS-a, uz uključen *Guest Service Interface*:

```powershell
Enable-VMIntegrationService -VMName GPS-DC01 -Name 'Guest Service Interface'
Copy-VMFile -Name GPS-DC01 -SourcePath D:\GpoStudio\lab\02-Install-GpsLabDC.ps1 `
    -DestinationPath C:\Lab\02-Install-GpsLabDC.ps1 -FileSource Host -CreateFullPath
```

Na lokaliziranom hostu naziv integracijske usluge može biti preveden; točan naziv daje
`Get-VMIntegrationService -VMName GPS-DC01`.

### 3.1. Hyper-V host

```powershell
cd D:\GpoStudio\lab
.\01-New-GpsLabHost.ps1 -ServerIso D:\ISO\WS2025_EVAL.iso -ClientIso D:\ISO\Win11_Ent_EVAL.iso -VmPath D:\GpsLab -IncludeSecondDc
```

Bez `-IncludeSecondDc` lab nema DC02, a test replikacije provjerava samo jedan DC.

- ISO datoteke držite na lokalnom disku hosta: Hyper-V ih čita kao račun računala, pa mrežne
  putanje (UNC, NAS) često ne rade.
- Switch `GpsLab` nema DHCP: VM-ovi nemaju mrežu dok im skripte 02 i 04 ne postave statičke adrese.

### 3.2. Instalacija operacijskih sustava

Za svaki VM:

1. `Start-VM -Name GPS-DC01; vmconnect localhost GPS-DC01`
2. Odmah pritisnite tipku kad se pojavi *Press any key to boot from CD or DVD*. Ako propustite,
   isključite VM (`Stop-VM -TurnOff`) i pokušajte ponovno.
3. **Server:** odaberite izdanje *Desktop Experience*. Postavite lozinku ugrađenog Administratora.
4. **Windows 11 Enterprise:** VM u ovoj fazi nema mrežu (switch nema DHCP). Na ekranu
   *Let's connect you to a network* odaberite *I don't have internet* (ako se ponudi, i
   *Continue with limited setup*) i stvorite lokalni račun `labadmin`. Ako VM ipak ima internet,
   isti rezultat daje *Sign-in options → Domain join instead*. Koristite istu lozinku na svim
   klijentima, jer smoke test na STANDALONE01 traži lokalnog administratora.
5. Nakon instalacije postavite boot s diska, da VM više ne čeka DVD:
   `Set-VMFirmware -VMName GPS-DC01 -FirstBootDevice (Get-VMHardDiskDrive -VMName GPS-DC01)`

**Host sa 16 GB RAM-a:** instalacija Windowsa 11 traži 4 GB, ali nakon nje klijentima (osim ADMIN01)
možete smanjiti početnu memoriju dok su isključeni:
`Set-VMMemory -VMName GPS-WS01, GPS-WS02, GPS-STANDALONE01 -StartupBytes 2GB`.
VM-ove tada pokrećite postupno (poglavlje 8).

### 3.3. DC01: domain controller

Na DC01, prijavljeni kao Administrator, u povišenom PowerShellu:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
C:\Lab\02-Install-GpsLabDC.ps1 -Role Forest     # 1. pokretanje: IP 10.10.10.10, ime DC01, restart
C:\Lab\02-Install-GpsLabDC.ps1 -Role Forest     # 2. pokretanje: AD DS + šuma gpslab.test, traži DSRM lozinku, restart
C:\Lab\02-Install-GpsLabDC.ps1 -Role Forest     # 3. pokretanje (prijava kao GPSLAB\Administrator): DNS forwarderi
```

### 3.4. DC02 (opcionalno)

```powershell
C:\Lab\02-Install-GpsLabDC.ps1 -Role AdditionalDC -ComputerName DC02 -IPAddress 10.10.10.11 -DnsServer 10.10.10.10   # IP, ime, restart
C:\Lab\02-Install-GpsLabDC.ps1 -Role AdditionalDC -ComputerName DC02 -IPAddress 10.10.10.11 -DnsServer 10.10.10.10   # dodatni DC: DSRM lozinka, zatim gpslab.test\Administrator
```

Adresu 10.10.10.11 ne smije imati nijedno drugo računalo; klijenti adrese dobivaju tek skriptom 04.
Prije promocije skripta provjerava sukob adresa i dohvaća SRV zapis domene s DNS-a na DC01, pa
nedostupan DC01 javi odmah, a ne kao grešku o vjerodajnicama (*Verification of user credential
permissions failed … could not be contacted*).

### 3.5. Active Directory za testove

Na DC01:

```powershell
C:\Lab\03-Initialize-GpsLabAD.ps1
```

Skripta traži jednu lozinku za `gps.admin`, `gps.editor` i `gps.user` i na kraju ispisuje DN-ove
OU-ova za sljedeći korak.

### 3.6. Klijenti

Na Windows klijentima izvršavanje skripti je po zadanom isključeno, pa u svakoj povišenoj sesiji
prvo pokrenite `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

Svaku skriptu pokrenite dvaput: prvi put za IP i ime (uz restart), drugi put za pridruživanje
domeni (uz restart). Kod pridruživanja unesite `GPSLAB\gps.admin`.

```powershell
# WS01 i WS02: Pilot OU
C:\Lab\04-Join-GpsLabClient.ps1 -ComputerName WS01 -IPAddress 10.10.10.31 -OUPath 'OU=Pilot,OU=Racunala,OU=GpsLab,DC=gpslab,DC=test'
C:\Lab\04-Join-GpsLabClient.ps1 -ComputerName WS02 -IPAddress 10.10.10.32 -OUPath 'OU=Pilot,OU=Racunala,OU=GpsLab,DC=gpslab,DC=test'

# ADMIN01: Admin OU
C:\Lab\04-Join-GpsLabClient.ps1 -ComputerName ADMIN01 -IPAddress 10.10.10.20 -OUPath 'OU=Admin,OU=GpsLab,DC=gpslab,DC=test'

# STANDALONE01: ostaje u radnoj grupi
C:\Lab\04-Join-GpsLabClient.ps1 -ComputerName STANDALONE01 -IPAddress 10.10.10.40 -Workgroup
```

Nakon pridruživanja pokrenite skriptu još jednom na WS01 i WS02. Treće pokretanje samo potvrđuje
da je PowerShell Remoting uključen i za domenski mrežni profil. GPO Studio do ciljanih računala
dolazi preko WinRM-a, a na Windows klijentima on nije uključen po zadanom.

Kad je WS01 u domeni, na DC01 ponovno pokrenite skriptu 03. Ona dodaje WS01 u grupu
`GPS-Pilot-PC` (već postojeće objekte preskače i ne traži lozinku), zatim restartajte WS01 da
računalo dobije novo članstvo:

```powershell
C:\Lab\03-Initialize-GpsLabAD.ps1                              # na DC01
Invoke-Command -ComputerName WS01 { Restart-Computer -Force }   # na DC01, preko WinRM-a
```

`Restart-Computer -ComputerName` u Windows PowerShellu 5.1 po zadanom koristi DCOM/WMI, koji vatrozid
Windowsa 11 blokira; zato restart ide preko WinRM-a (ili WS01 restartajte s njegove konzole).

### 3.7. Admin stanica

Na ADMIN01 se prijavite kao `GPSLAB\gps.admin`, kopirajte ZIP repozitorija (ili ga klonirajte u
`C:\GpoStudio`) i u povišenom **Windows PowerShellu 5.1** pokrenite:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
C:\Lab\05-Install-GpsLabAdmin.ps1 -RepoZip C:\Users\gps.admin\Downloads\MS-GP-AD-seapp-main.zip
```

Skripta instalira RSAT, postavlja ExecutionPolicy `RemoteSigned` za 64-bitni i 32-bitni Windows
PowerShell (GUI testovi pokreću skripte u novim procesima), instalira PowerShell 7 i Pester 5.7.1,
pokreće Pester testove (moraju svi proći) i dodaje STANDALONE01 u WinRM TrustedHosts. RSAT i
PowerShell 7 preuzimaju se s interneta.

### 3.8. Checkpoint "Clean"

Kad je sve spremno, na hostu napravite checkpoint svih VM-ova. To je polazna točka za svako
ponovno testiranje:

```powershell
Get-VM GPS-* | Checkpoint-VM -SnapshotName Clean
```

Checkpointe uvijek vraćajte **za sve VM-ove zajedno** (poglavlje 8). Ako vratite samo jedno
računalo, njegova lozinka računa računala u AD-u može se razlikovati od one na DC-u, pa se
izgubi povjerenje s domenom (*trust relationship failed*). S dva DC-a nakon vraćanja provjerite
SYSVOL (poglavlje 8).

### 3.9. Nadogradnja GPO Studija u postojećem labu

Nova verzija treba samo na **ADMIN01**: tamo rade GUI, cmdleti i smoke test. DC-ovi, WS01, WS02 i
STANDALONE01 ne trebaju ništa, jer GPO Studio pri primjeni šalje potreban kod preko WinRM-a. Lab
skripte (`lab\01`–`05`) se nisu mijenjale, pa lab ne treba graditi ponovno.

1. **Na hostu vratite sve VM-ove na *Clean*** (poglavlje 8), da nadogradnja krene od čistog stanja,
   bez postavki iz ranijih testova. Vraćanje briše i sve što je na VM-ovima nastalo nakon checkpointa
   (vlastiti preseti, sigurnosne kopije, `lab-results-*.json`); što vam treba, prije toga kopirajte s
   ADMIN01. S dva DC-a provjerite SYSVOL (poglavlje 8) i ne nastavljajte dok nije spreman na oba DC-a.
   Za samu nadogradnju dovoljni su DC01 i ADMIN01; na hostu s malo memorije ostale ne palite odmah.
2. **Kopirajte novi ZIP na ADMIN01** (npr. preuzet na host u `D:\GpoStudio.zip`). Integracijska usluga
   *Guest Service Interface* traži se po Id-u, jer je na lokaliziranom hostu naziv preveden:

   ```powershell
   Get-VMIntegrationService -VMName GPS-ADMIN01 | Where-Object { $_.Id -match '6C09BB55-D683-4DA0-8931-C9BF705F6480' } |
       Enable-VMIntegrationService
   Start-Sleep -Seconds 5
   Copy-VMFile -Name GPS-ADMIN01 -SourcePath D:\GpoStudio.zip -DestinationPath C:\Lab\GpoStudio.zip `
       -FileSource Host -CreateFullPath -Force
   ```

3. **Na ADMIN01** (prijava `GPSLAB\gps.admin`, povišeni **Windows PowerShell 5.1**, ne PowerShell 7)
   zatvorite GPO Studio i zamijenite staru verziju. Brisanje stare mape osigurava da ne ostanu stare
   datoteke; `C:\ProgramData\GpoStudio` se ne briše.

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   cd C:\
   Remove-Item C:\GpoStudio -Recurse -Force -ErrorAction SilentlyContinue
   C:\Lab\05-Install-GpsLabAdmin.ps1 -RepoZip C:\Lab\GpoStudio.zip
   (Import-PowerShellDataFile C:\GpoStudio\src\GpoStudio.Core\GpoStudio.Core.psd1).ModuleVersion   # nova verzija, npr. 0.2.0
   ```

   Skripta preskače ono što je već instalirano (RSAT, PowerShell 7, Pester), raspakira ZIP u
   `C:\GpoStudio`, otključa datoteke i pokrene Pester testove: redak *Pester: … prošlo, 0 palo* mora
   biti zelen. Završnu poruku skripte (*Sljedeći korak: checkpoint "Clean" …*) pri nadogradnji
   zanemarite: ne radi se novi *Clean*, nego *Clean-v2* (korak 4). Ako je `C:\GpoStudio` git klon,
   umjesto brisanja i ZIP-a osvježite ga (`git -C C:\GpoStudio pull`) i pokrenite skriptu bez `-RepoZip`.

4. **Na hostu napravite novi checkpoint** svih VM-ova i ubuduće vraćajte njega (stari *Clean* ima
   staru verziju GPO Studija). Checkpoint upaljenih VM-ova sprema i njihovu memoriju (ukupno nekoliko
   desetaka GB), pa prije toga provjerite slobodan prostor na disku hosta.

   ```powershell
   Get-VM GPS-* | Checkpoint-VM -SnapshotName Clean-v2
   ```

5. **Smoke test** (poglavlje 4) mora proći kao i prije (za njega moraju raditi svi VM-ovi), a zatim
   slijede ručni GUI testovi (5.1).

Primjena razine *Preporučeno* na ADMIN01 odmah uvodi strožu udaljenu radnu površinu (Enhanced Session
može tražiti lozinku i ne dijeli diskove; kopiraj/zalijepi i dalje radi) i UAC potvrdu na sigurnoj
radnoj površini, a nakon restarta i zaključavanje zaslona nakon 15 minuta, zaštitu LSA i obavezno
potpisivanje SMB-a.

Razinu *Strogo* isprobajte na WS01 (cilj *Druga računala*), a ne na ADMIN01. Dio postavki vrijedi tek
nakon restarta WS01 (`Invoke-Command -ComputerName WS01 { Restart-Computer -Force }`). Tada WS01
zabranjuje udaljenu radnu površinu (Enhanced Session može prestati raditi; u prozoru VM-a isključite
*View → Enhanced Session*), traži Ctrl+Alt+Del (u konzoli VM-a Ctrl+Alt+End ili gumb na alatnoj
traci), skriva zadnjeg korisnika (upišite `GPSLAB\gps.admin`) i uključuje zaštitu administratora.
Trajnu zaštitu LSA (zaključanu u UEFI-ju) *Vrati prethodno stanje* ne može isključiti, pa je jedini
potpuni povratak checkpoint *Clean-v2* za sve VM-ove zajedno. Isto vrijedi ako ADMIN01 nakon toga više
ne može doći do WS01.

---

## 4. Automatizirani smoke test

Na ADMIN01, kao `GPSLAB\gps.admin`, u povišenom Windows PowerShellu 5.1:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\GpoStudio
.\lab\Test-GpsLabSmoke.ps1
```

Skripta traži lozinku lokalnog administratora na STANDALONE01 (`STANDALONE01\labadmin`) i traje
oko 10–15 minuta. Svaki korak stvarno mijenja računala i zatim provjerava rezultat na samom
računalu (registry, secedit, auditpol, AD), a ne samo ono što cmdlet vrati. Testne vrijednosti
pišu se pod `HKLM\Software\Policies\GpoStudioLab`, pa ne mijenjaju ponašanje Windowsa. Na kraju
se sve vraća.

| ID | Što se provjerava |
|---|---|
| **L1** | ADMX katalog se učitava (više od 500 politika); na računalu u domeni izvor mora biti Central Store |
| **L2** | `-WhatIf` vraća diff i ništa ne mijenja |
| **L3** | primjena na ADMIN01 vraća status OK, a backup s manifestom postoji |
| **L4** | vrijednosti su u HKLM nakon `gpupdate`; korisnička postavka je u HKCU nakon `gpupdate /target:user`; User verzija u `gpt.ini` je porasla |
| **L5** | ponovni diff: sve je `Unchanged` (idempotentnost) |
| **L6** | revizijski zapis u `C:\ProgramData\GpoStudio\audit.jsonl` |
| **L7** | vraćanje s pogrešnom putanjom vraća grešku i ne dira `GroupPolicy` mapu |
| **L7b** | akcija *Delete* upisuje `**del.TestDword` u `Registry.pol`, vrijednost nestaje iz registryja, a ponovni diff je `Unchanged` |
| **L8** | vraćanje iz backupa uklanja testne vrijednosti (HKLM i HKCU) |
| **R1** | WinRM do STANDALONE01; početno stanje lozinki i revizije (secedit, auditpol) |
| **R2** | udaljena primjena registryja + `MinimumPasswordLength` + revizije Logon |
| **R3** | na STANDALONE01 su stvarno postavljeni registry, duljina lozinke i revizija |
| **R4** | udaljeno vraćanje vraća sve na početno stanje |
| **D0** | WS01/WS02 su u Pilot OU; WS01 je član `GPS-Pilot-PC`, WS02 nije; Kerberos tiketi računala se osvježe |
| **D1** | `-WhatIf` za novi GPO ne stvara GPO |
| **D2** | objava novog GPO-a `GPS-LAB-Smoke` |
| **D3** | link na Pilot OU je uključen; `GPS-Pilot-PC` ima GpoApply, a Authenticated Users samo GpoRead |
| **D4** | `Compare-GpsDomainPolicy` daje sve `Unchanged` |
| **D5** | AD i SYSVOL verzije su usklađene na svim DC-ovima (čeka do 3 minute) |
| **D6** | nakon `gpupdate` WS01 ima testne vrijednosti, a WS02 nema (filtriranje radi) |
| **D7** | ponovna objava s promjenom radi backup GPO-a; WS01 dobiva novu vrijednost |
| **D7b** | akcija *Delete* u domenskom GPO-u: diff `Removed`, `Get-GPRegistryValue` vraća `PolicyState Delete`, ponovni `Compare` je `Unchanged`, a vrijednost nestaje s WS01 |
| **D8** | objava na *Default Domain Policy* bez `-Force` se odbija |
| **D9** | nepostojeća grupa za filtriranje: greška, a GPO se ne stvara |
| **D10** | revizijski zapisi objave (D2, D7, D7b) |
| **D11** | brisanje testnog GPO-a uklanja vrijednosti s WS01 |

Provjere na klijentu (D6, D7, D7b, D11) ponavljaju `gpupdate` do 3 minute, jer WS01 može čitati s
DC02 prije nego što replikacija stigne.

Rezultat je tablica PASS/FAIL/SKIP i JSON datoteka
`C:\ProgramData\GpoStudio\lab-results-<vrijeme>.json`. Izlazni kod je 1 ako je ijedan korak pao.

Korisni parametri:

```powershell
.\lab\Test-GpsLabSmoke.ps1 -Area Local, Remote          # bez domene (radi i u PowerShellu 7)
.\lab\Test-GpsLabSmoke.ps1 -Area Domain -KeepArtifacts   # ostavlja GPO GPS-LAB-Smoke za ručni pregled u GPMC-u
```

Smoke test pokrenite **dvaput zaredom**: drugo pokretanje provjerava da se test može ponoviti na
istom labu. D0 prije domenskih koraka briše testne GPO-ove ostale od prekinutog pokretanja.

---

## 5. Ručni testni slučajevi

Ovi slučajevi pokrivaju ono što smoke test ne može: GUI i rubne situacije. Testove radite od
checkpointa *Clean* (nakon nadogradnje *Clean-v2*). U stupac *Rezultat* upišite ✅, ❌ ili ⚠️ i napomenu.

Za slučajeve koji koriste cmdlete (5.2 i 5.3) prvo u Windows PowerShellu 5.1 na ADMIN01 pokrenite:

```powershell
cd C:\GpoStudio
Import-Module .\src\GpoStudio.Local\GpoStudio.Local.psm1, .\src\GpoStudio.Domain\GpoStudio.Domain.psm1
$set = Import-GpsPolicySet .\examples\radna-stanica-baseline.json
```

Lokalna primjena (N1, N3) traži povišenu sesiju kao `gps.admin`; A1 i A2 se namjerno pokreću kao
`gps.editor` u običnoj sesiji.

### 5.1. GUI

Sučelje ima stranice u lijevoj navigaciji (*Pregled*, *Sigurnosne postavke*, *Preseti*, *Usporedba*,
*Promjene*, *Napredno (gpedit)*, *Dnevnik*), traku **CILJ** ispod zaglavlja i traku radnji na dnu
(*Sigurnosna kopija*, *Vrati prethodno stanje*, *Pregledaj promjene*, *Primijeni*). Traka radnji radi s
izvorom koji piše uz *Primjenjuje se*: na stranici *Napredno* to je napredni Policy Set, inače
sigurnosne postavke.

| ID | Koraci | Očekivano | Rezultat |
|---|---|---|---|
| G1 | `powershell.exe -File C:\GpoStudio\src\GpoStudio.Gui\Start-GpoStudio.ps1` (povišeno) | tamni prozor s logotipom Auxilium i naslovom GPO STUDIO; čip *ADMINISTRATOR*; odabrana razina *Preporučeno*; pločice usklađenosti pokazuju postotke | |
| G2 | isto iz `pwsh` (PowerShell 7) | `pwsh` se odmah vraća, a GUI se otvara u `powershell.exe` | |
| G3 | isto iz `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` (32-bitni) | GUI se otvara u 64-bitnom procesu (Task Manager: bez oznake *32 bit*) | |
| G4 | `Set-ExecutionPolicy Restricted -Scope LocalMachine` u `powershell.exe`, zatim pokretanje iz `pwsh` gdje je politika RemoteSigned | GUI se ipak otvara (politika se prosljeđuje); zatim vratite `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` | |
| G5 | pokretanje kao standardni korisnik (bez *Run as administrator*) | čip *STANDARDNI KORISNIK*; u *Dnevniku* upozorenje da primjena traži administratora | |
| G6 | *Pregled*: redom kliknite *Osnovno*, *Strogo*, *Preporučeno* | mijenjaju se broj postavki, sažetak po područjima i postoci usklađenosti; *Osnovno* ima najmanje postavki | |
| G7 | *Sigurnosne postavke* → *USB i prijenosni mediji* → za *USB memorije i memorijske kartice* odaberite *Zabranjeno* | redak dobiva oznaku *IZVAN RAZINE* i napomenu *Razina Preporučeno predlaže: Bez pokretanja programa*; naslov na *Pregledu* je *Prilagođeno (temelj: Preporučeno)* | |
| G8 | promijenite razinu na *Pregledu* dok postoji ručna promjena iz G7 | pitanje *Imate ručne promjene…*; *Odustani* ostavlja odabir, *Promijeni razinu* ga poništava | |
| G9 | *Sigurnosne postavke*: pretraga *lozinka*, zatim filtri *Uključene* i *Izvan razine*; *Vrati na razinu* | pretraga prikazuje postavke iz više područja; filtri prikazuju samo odgovarajuće retke; *Vrati na razinu* uklanja ručne promjene | |
| G10 | *Pregled* → *Brzi odabir* → *Javno računalo / kiosk* | naslov *Preset: Javno računalo / kiosk* (bez oznake *prilagođeno*); za *USB memorije i memorijske kartice* odabrano *Zabranjeno*, a u području *Preglednik i aplikacije* za *Microsoft Store* odabrano *Isključen* | |
| G11 | *Preseti* → *Spremi trenutni odabir*, naziv *Lab test*; zatim *Izvezi…* u Dokumente, *Obriši*, *Uvezi preset* iz Dokumenata | kartica *VLASTITI PRESET* nastaje, nestaje i vraća se; datoteka postoji u `C:\ProgramData\GpoStudio\Presets` | |
| G12 | razina *Preporučeno*, cilj *Ovo računalo*: *Pregledaj promjene* | stranica *Promjene* s nazivima postavki (npr. *Vatrozid uključen na svim mrežama: Uključen, strogo*), statusima *DODAJE SE* / *BEZ PROMJENE* i retcima *POSTAVLJA SE* za lozinke i reviziju; ništa se ne mijenja | |
| G13 | *Primijeni* → *Primijeni* | potvrda navodi cilj; *Primijenjene promjene* i u *Dnevniku* putanja sigurnosne kopije; `net accounts` pokazuje *Minimum password length: 14*; `Get-ItemProperty HKLM:\Software\Policies\Microsoft\WindowsFirewall\PublicProfile` pokazuje `EnableFirewall = 1` | |
| G14 | *Usporedba* → *Provjeri računalo* (prije i poslije G13 na svježem checkpointu) | izvor *Stanje računala*; nakon G13 postotci su znatno viši nego prije; tablica pokazuje *U REDU* / *ODSTUPA* / *NIJE POSTAVLJENO* | |
| G15 | *Usporedba* → *Izvezi izvještaj*; zatim *Preuzmi kao odabir* | HTML izvještaj se otvara u pregledniku (svijetla tema, tablice po standardu); nakon preuzimanja naslov odabira je *Stanje računala ADMIN01* | |
| G16 | *Vrati prethodno stanje* | popis sigurnosnih kopija s datumom; odabir najnovije i *Vrati* → u *Dnevniku* status OK i redak *Vraćeno registry vrijednosti: N*; vrijednosti iz G13 nestaju, a i vrijednosti izvan grane Policies vraćene su na staro (npr. `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa -Name RunAsPPL` ne postoji ako ga prije nije bilo); nakon restarta *Provjeri računalo* pokazuje postotke kao prije G13 | |
| G17 | *Napredno (gpedit)* | katalog se učita pri prvom otvaranju; pretraga *Store*; *Dodaj: uključeno* za politiku s elementima otvara dijalog; *Primjenjuje se* pokazuje napredni Policy Set | |
| G18 | *Napredno*: *Otvori…* → `examples\radna-stanica-baseline.json`, *Pregledaj promjene* | 5 postavki u tablici; promjene se odnose na napredni set, ne na sigurnosne postavke | |
| G19 | cilj *Druga računala*: `WS01, WS02`; *Pregledaj promjene*, zatim *Primijeni* | rezultat po računalu na stranici *Promjene*; poruka da su računala u domeni | |
| G20 | cilj *Domenski GPO*, prazan naziv GPO-a, *Pregledaj promjene* | upozorenje *Upišite naziv GPO-a*; ništa se ne pokreće | |
| G21 | domena: GPO `GPS-LAB-GUI`, poveži na `OU=Pilot,OU=Racunala,OU=GpsLab,DC=gpslab,DC=test`, grupa `GPS-Pilot-PC`; *Primijeni* | potvrda navodi link, grupu i da se lozinke i revizija ne objavljuju u domenu; u GPMC-u se vide GPO, link i Security Filtering | |
| G22 | *Provjeri replikaciju* (vidljivo samo za domenski cilj) | poruka da je GPO jednak na svim DC-ovima; tablica u *Dnevniku* | |
| G23 | zatvaranje prozora dok radnja traje (npr. tijekom G19) | pitanje za potvrdu | |

Nakon G21 obrišite GPO `GPS-LAB-GUI` u GPMC-u ili s `Remove-GPO -Name GPS-LAB-GUI`.

### 5.2. Domena: ovlasti i PowerShell 7

Revizijski zapis i backupovi pišu se u `C:\ProgramData\GpoStudio`, gdje običan korisnik po zadanom
nema pravo pisanja. Prije A1 i A2 jednom, kao `gps.admin` u povišenoj sesiji, dodijelite pravo
grupi urednika:

```powershell
New-Item C:\ProgramData\GpoStudio -ItemType Directory -Force | Out-Null
icacls C:\ProgramData\GpoStudio /grant "GPSLAB\GPS-GPO-Editors:(OI)(CI)M"
```

Bez toga operacija i dalje radi, ali revizijski zapis se ne upisuje (GPO Studio to javlja upozorenjem).

| ID | Koraci | Očekivano | Rezultat |
|---|---|---|---|
| A1 | na ADMIN01 kao `GPSLAB\gps.editor` (Group Policy Creator Owners), uz preambulu iz 5. poglavlja: `Publish-GpsDomainPolicy -PolicySet $set -GpoName GPS-LAB-Editor -LinkTarget 'OU=Pilot,OU=Racunala,OU=GpsLab,DC=gpslab,DC=test'` | GPO se stvara, link ne uspijeva (nema delegiranog prava *Link GPO*); greška *Objava GPO-a … nije dovršena*; u `audit.jsonl` je `result: Error`, `linked: false` | |
| A2 | kao A1 (uz `-BackupPath $env:USERPROFILE\GpoBackup`), nakon što u GPMC-u (*Pilot → Delegation*) dodate `GPS-GPO-Editors` s pravom *Link GPOs* | objava s linkom uspijeva; očekivano je upozorenje *Sigurnosne postavke i revizija za domenske GPO-ove još nisu implementirane* (primjer sadrži security/audit; u A1 se ne pojavljuje jer objava završi greškom prije tog koraka) | |
| A3 | u `pwsh` (instalira ga skripta 05): `Import-Module .\src\GpoStudio.Domain\GpoStudio.Domain.psm1; Get-GpsDomainContext` | jasna poruka da domenski dio traži Windows PowerShell 5.1 | |

### 5.3. Otpornost i negativni slučajevi

| ID | Koraci | Očekivano | Rezultat |
|---|---|---|---|
| N1 | na WS02 `Stop-Service WinRM`; zatim `Set-GpsLocalPolicy -PolicySet $set -ComputerName WS01, WS02 -Confirm:$false` | WS01: status OK; WS02: greška veze; WS01 se ipak primijeni. Nakon testa `Start-Service WinRM` | |
| N2 | na testnom računalu u `C:\Windows\System32\GroupPolicy\Machine\Registry.pol` upišite smeće; zatim primjena | status Error (*Neispravno zaglavlje*), datoteka se ne prepisuje; vratite checkpoint | |
| N3 | `$min = Import-GpsPolicySet <vlastiti.json>` (JSON samo s `name` i `settings`); u povišenoj sesiji kao `gps.admin`: `Set-GpsLocalPolicy -PolicySet $min -Confirm:$false` | primjena uspijeva, revizijski zapis ima `version: 1.0.0` | |
| N4 | u GUI-ju *Dodaj: Enabled* za politiku s elementom tipa *list* (npr. *Allow installation of devices that match any of these device IDs*) | dodaje se samo glavna vrijednost (npr. `AllowDeviceIDs = 1`), a log pokazuje *UPOZORENJE: Element tipa 'list' … nije podržan i izostavlja se* | |
| N5 | na STANDALONE01 u `gpedit.msc` uključite jednu Administrative Templates postavku i zapišite redak `gPCMachineExtensionNames` iz `C:\Windows\System32\GroupPolicy\gpt.ini`; zatim `.\lab\Test-GpsLabSmoke.ps1 -Area Remote` | nakon testa (R4 vraća backup i ponovno upisuje `gpt.ini` istom funkcijom kao primjena) u retku je točno jedna grupa koja počinje s `{35378EAC-683F-11D2-A89A-00C04FBBCFA2}`, a GUID-ovi alata iz gpedita su i dalje u njoj; postavka iz gpedita je i dalje u registryju i `gpedit.msc` je prikazuje kao *Enabled*; u *GroupPolicy/Operational* nema grešaka | |

---

## 6. Bilježenje rezultata i prijava grešaka

Za svako testiranje zabilježite:

- datum, verziju (commit) repozitorija i tko je testirao;
- JSON smoke testa (`C:\ProgramData\GpoStudio\lab-results-*.json`);
- tablice iz poglavlja 5 s rezultatima.

Za svaki ❌ otvorite issue u repozitoriju `dvrban/MS-GP-AD-seapp`:

```
Naslov:   [Lab] G12: Primijeni ne prikazuje putanju backupa
Test:     G12 (docs/TESTNI-LAB.md)
Okruženje: ADMIN01, Windows 11 24H2, Windows PowerShell 5.1, commit <sha>
Koraci:   …
Očekivano: …
Dobiveno: …
Prilozi:  vidi dolje
```

Korisni prilozi:

| Prilog | Kako ga dobiti |
|---|---|
| Revizijski zapis | `Get-Content C:\ProgramData\GpoStudio\audit.jsonl -Tail 20` |
| Log iz GUI-a | kartica *Log*: označite sve i kopirajte |
| Rezultat Group Policyja na klijentu | `gpresult /h "$env:TEMP\gpresult.html" /f` (povišeno) |
| Izvještaj GPO-a | uz preambulu iz 5. poglavlja: `Get-GpsDomainGpoReport -GpoName <naziv> -Path "$env:TEMP\gpo.html"` |
| Događaji Group Policyja | Event Viewer → *Applications and Services Logs → Microsoft → Windows → GroupPolicy → Operational* |
| Verzije | `$PSVersionTable`, `winver`, `git rev-parse HEAD` |

---

## 7. Poznata ograničenja (ne prijavljivati kao grešku)

- **Sigurnosne postavke i revizija za domenske GPO-ove** nisu implementirane (faza 3).
  `Publish-GpsDomainPolicy` za njih ispisuje upozorenje; lokalno se primjenjuju.
- **WinRM:** GPO Studio koristi zadani `Invoke-Command` (HTTP 5985, Kerberos u domeni, NTLM uz
  TrustedHosts u radnoj grupi). HTTPS (5986) i drugi portovi zasad nisu podržani.
- **GUI nema polje za vjerodajnice:** prema udaljenim računalima radi s trenutnim korisnikom. Za
  STANDALONE01 koristite cmdlete s `-Credential` (kao smoke test).
- **ADMX elementi tipa `list`** nisu podržani: politika se dodaje bez njih, uz upozorenje. Ne koristite
  takve politike za stvarne postavke.
- **Korisničke postavke (User scope)** kod lokalne primjene: kad se promijeni korisnički dio,
  *Primijeni* i `Set-GpsLocalPolicy` nakon `gpupdate /target:computer` pokreću i
  `gpupdate /target:user /force /wait:60`, ali samo za račun koji pokreće primjenu (na drugim
  računalima to je račun WinRM sesije). Ostali korisnici dobivaju korisničke postavke pri sljedećoj
  prijavi ili nakon `gpupdate /target:user /force`. U domeni, korisničke postavke u GPO-u povezanom
  na OU s računalima (kao `OU=Pilot`) ne primjenjuju se na korisnike; to je standardno ponašanje
  Group Policyja (bez loopbacka).
- **Revizijski zapis** u `C:\ProgramData\GpoStudio` traži pravo pisanja; bez njega operacija radi,
  ali se zapis ne upisuje (upozorenje). Vidi 5.2.
- **Jezik kataloga:** Central Store kopiran s engleskog sustava ima samo `en-US` ADML, pa se
  politike prikazuju na engleskom i kad je odabran hrvatski.
- **Domenski dio** radi samo u Windows PowerShellu 5.1.
- **Lokalni GP na računalu u domeni** ima najniži prioritet: domenski GPO s istom postavkom ga
  nadjačava. GUI to javlja porukom u logu.

---

## 8. Vraćanje i uklanjanje laba

Vraćanje svih VM-ova na *Clean* (uvijek zajedno, vidi 3.8). Nakon nadogradnje GPO Studija (3.9) u
naredbama umjesto *Clean* koristite *Clean-v2*:

```powershell
Get-VM GPS-* | Stop-VM -TurnOff -Force
Get-VM GPS-* | ForEach-Object { Restore-VMCheckpoint -VMName $_.Name -Name Clean -Confirm:$false }
Get-VM GPS-DC* | Start-VM; Start-Sleep -Seconds 120
foreach ($vm in 'GPS-ADMIN01', 'GPS-WS01', 'GPS-WS02', 'GPS-STANDALONE01') { Start-VM -Name $vm; Start-Sleep -Seconds 30 }
```

DC-ovi se pokreću prvi, da klijenti pri pokretanju nađu domenu; klijenti se pokreću postupno, da
host ne mora odjednom imati svu početnu memoriju.

**S dva DC-a provjerite SYSVOL prije testiranja.** Vraćanje checkpointa mijenja VM-GenerationID, pa
DC pokreće neautoritativnu sinkronizaciju SYSVOL-a. Ako se to dogodi na oba DC-a, nijedan nema
autoritativnu kopiju i SYSVOL može ostati nedostupan. Oko 2 minute nakon pokretanja na DC01 i DC02:

```powershell
Get-SmbShare SYSVOL, NETLOGON                                                  # oba sharea moraju postojati
(Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters).SysvolReady   # mora biti 1
dcdiag /test:sysvolcheck /test:advertising
```

Ako SYSVOL nije spreman ni na jednom DC-u, na DC01 je uvijek potrebna autoritativna sinkronizacija,
a DC02 se zatim sinkronizira neautoritativno, prema Microsoftovom članku *How to force
authoritative and non-authoritative synchronization for DFSR-replicated SYSVOL* (na DC01:
`msDFSR-Options=1` na objektu *SYSVOL Subscription*, zatim `msDFSR-Enabled` FALSE/TRUE i
`dfsrdiag pollad`). Ponovna izgradnja DC02 ne pomaže dok DC01 nema SYSVOL.
Nakon popravka zamijenite checkpoint koji vraćate (prije nadogradnje *Clean*, nakon nje *Clean-v2*),
inače se problem ponavlja pri svakom vraćanju: prvo obrišite stari, da dva checkpointa nemaju isto ime
(npr. `Get-VM GPS-* | Remove-VMCheckpoint -Name Clean-v2`), zatim
`Get-VM GPS-* | Checkpoint-VM -SnapshotName Clean-v2`.

Evaluacijske verzije: Windows 11 Enterprise vrijedi 90 dana, a Windows Server 180 dana. Preostalo
vrijeme pokazuje `slmgr /dlv`. Kad istekne, lab izgradite ponovno.

Potpuno uklanjanje laba s hosta:

```powershell
Get-VM GPS-* | Stop-VM -TurnOff -Force
Get-VM GPS-* | Remove-VM -Force
Remove-Item D:\GpsLab -Recurse -Force
Remove-NetNat -Name GpsLab-NAT -Confirm:$false
Remove-VMSwitch -Name GpsLab -Force
```
