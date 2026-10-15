#Requires -Version 5.1
<#
.SYNOPSIS
    Pokreće GPO Studio: sučelje za sigurnosne postavke računala i grupne politike (lokalno i u domeni).
.DESCRIPTION
    Početna stranica nudi tri razine zaštite i gotove presete; sigurnosne postavke su kvačice i izbori
    po područjima (lozinke, ažuriranja, USB, zaštita od zlonamjernog softvera, mreža...), uz usporedbu
    s CIS benchmarkom i Microsoftovim sigurnosnim baselineom. Napredna stranica zadržava katalog ADMX
    politika s pretragom, kao gpedit.msc.

    GUI je tanki sloj iznad modula GpoStudio.Core / .Local / .Domain. Dugotrajne radnje idu u
    pozadinski runspace (sučelje se ne zamrzava), a ekvivalentna PowerShell naredba upisuje se u Dnevnik.
    Izgled: Auxilium stil (Theme\Auxilium.xaml).
.PARAMETER AdmxPath
    Mapa s ADMX predlošcima za naprednu stranicu. Zadano: Central Store u SYSVOL-u, inače %windir%\PolicyDefinitions.
.PARAMETER NoShow
    Izgradi prozor bez prikaza (za automatske testove; skriptu tada pozovite dot-sourceom).
.EXAMPLE
    .\Start-GpoStudio.ps1
#>
[CmdletBinding()]
param([string]$AdmxPath, [switch]$NoShow)

# GUI radi u 64-bitnom Windows PowerShellu 5.1 sa STA dretvom: WPF traži STA, domenski dio
# traži 5.1 (RSAT GroupPolicy), a 32-bitni proces bi pisao u SysWOW64\GroupPolicy.
$is32on64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
if (-not $NoShow -and ($PSVersionTable.PSEdition -eq 'Core' -or $is32on64 -or
        [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA')) {
    $folder = if ($is32on64) { 'Sysnative' } else { 'System32' }
    $exe = Join-Path $env:windir "$folder\WindowsPowerShell\v1.0\powershell.exe"
    # powershell.exe ima vlastiti ExecutionPolicy (zadano Restricted na klijentima); prosljeđujemo
    # efektivnu politiku roditelja (Process scope, Group Policy i dalje ima prednost).
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', (Get-ExecutionPolicy).ToString(), '-File', "`"$PSCommandPath`"")
    # Kosa crta prije zatvarajućeg navodnika bi ga escapeala (pravila CommandLineToArgvW), pa je udvostručujemo.
    if ($AdmxPath) { $argList += @('-AdmxPath', ('"{0}"' -f ($AdmxPath -replace '(\\+)$', '$1$1'))) }
    $child = Start-Process -FilePath $exe -ArgumentList $argList -PassThru
    if ($child.WaitForExit(3000) -and $child.ExitCode -ne 0) {
        Write-Error "Windows PowerShell 5.1 nije pokrenuo GPO Studio (izlazni kod $($child.ExitCode)). Pokrenite skriptu izravno iz powershell.exe da vidite grešku."
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$GuiRoot = $PSScriptRoot
$srcRoot = Split-Path -Parent $GuiRoot
$ModulePaths = @(
    (Join-Path $srcRoot 'GpoStudio.Core\GpoStudio.Core.psd1')
    (Join-Path $srcRoot 'GpoStudio.Local\GpoStudio.Local.psm1')
    (Join-Path $srcRoot 'GpoStudio.Domain\GpoStudio.Domain.psm1')
)
Import-Module $ModulePaths -Force
$GpsVersion = (Import-PowerShellDataFile -Path $ModulePaths[0]).ModuleVersion

. (Join-Path $GuiRoot 'Gui.Common.ps1')
Initialize-AuxTheme -GuiRoot $GuiRoot

#region Učitavanje prozora

[xml]$xaml = Get-Content -LiteralPath (Join-Path $GuiRoot 'MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*')) {
    $name = $node.GetAttribute('Name', $xamlNs)
    if ($name) { $ui[$name] = $window.FindName($name) }
}

#endregion

. (Join-Path $GuiRoot 'Gui.Advanced.ps1')
. (Join-Path $GuiRoot 'Gui.Security.ps1')
. (Join-Path $GuiRoot 'Gui.Actions.ps1')

#region Navigacija

$Pages = [ordered]@{
    Pregled   = @{ Page = 'pgPregled'; Nav = 'navPregled' }
    Sigurnost = @{ Page = 'pgSigurnost'; Nav = 'navSigurnost' }
    Preseti   = @{ Page = 'pgPreseti'; Nav = 'navPreseti' }
    Usporedba = @{ Page = 'pgUsporedba'; Nav = 'navUsporedba' }
    Promjene  = @{ Page = 'pgPromjene'; Nav = 'navPromjene' }
    Napredno  = @{ Page = 'pgNapredno'; Nav = 'navNapredno' }
    Dnevnik   = @{ Page = 'pgDnevnik'; Nav = 'navDnevnik' }
}

function Show-Page([string]$Name) {
    foreach ($key in $Pages.Keys) {
        $ui[$Pages[$key].Page].Visibility = if ($key -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    $nav = $ui[$Pages[$Name].Nav]
    if (-not $nav.IsChecked) { $nav.IsChecked = $true }
    switch ($Name) {
        'Usporedba' { Update-ComparePage }
        'Napredno' { if (-not $State.CatalogLoaded -and -not $Gui.Job) { Start-CatalogLoad } }
    }
    Update-ActionSource
}

foreach ($key in $Pages.Keys) {
    $nav = $ui[$Pages[$key].Nav]
    $nav.Add_Checked({
            foreach ($k in $Pages.Keys) { if ($Pages[$k].Nav -eq $this.Name) { Show-Page $k } }
        })
}

#endregion

#region Događaji

# Cilj
foreach ($rb in 'rbTargetLocal', 'rbTargetRemote', 'rbTargetDomain') { $ui[$rb].Add_Checked({ Update-TargetUi }) }
foreach ($tb in 'txtComputers', 'txtGpoName') { $ui[$tb].Add_TextChanged({ Update-TargetUi }) }

# Razine (rbLevelN.Tag nije potreban: razina se čita iz imena)
foreach ($l in 1..3) {
    $ui["rbLevel$l"].Add_Checked({
            if ($Sec.Updating) { return }
            $level = [int]($this.Name.Substring($this.Name.Length - 1))
            if ($level -ne $Sec.Level -or (Test-HasManualChanges) -or $Sec.Preset) { Set-SecurityLevel $level }
        })
}
$ui.btnOverviewCompare.Add_Click({ Show-Page 'Usporedba' })

# Sigurnosne postavke
$ui.lbCategories.Add_SelectionChanged({
        $item = $ui.lbCategories.SelectedItem
        if (-not $item) { return }
        $Sec.Category = $item.Tag
        if ($ui.txtControlSearch.Text) { $ui.txtControlSearch.Text = '' }
        if (-not $ui.rbFilterAll.IsChecked) { $ui.rbFilterAll.IsChecked = $true }
        Update-ControlFilter
    })
$SearchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$SearchTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$SearchTimer.Add_Tick({ $SearchTimer.Stop(); Update-ControlFilter })
$ui.txtControlSearch.Add_TextChanged({ $SearchTimer.Stop(); $SearchTimer.Start() })
foreach ($rb in 'rbFilterAll', 'rbFilterSelected', 'rbFilterChanged') { $ui[$rb].Add_Checked({ Update-ControlFilter }) }
$ui.btnResetToLevel.Add_Click({ Set-SecurityLevel $Sec.Level })
$ui.btnSavePresetFromControls.Add_Click({ Save-UiPreset })

# Preseti
$ui.btnPresetSave.Add_Click({ Save-UiPreset })
$ui.btnPresetImport.Add_Click({ Import-UiPreset })

# Usporedba
$ui.btnCheckComputer.Add_Click({ Start-ComputerCheck })
$ui.btnUseState.Add_Click({ Use-DetectedState })
$ui.btnExportReport.Add_Click({ Export-UiComplianceReport })
foreach ($rb in 'rbCmpSelection', 'rbCmpState') { $ui[$rb].Add_Checked({ Update-ComparePage }) }

# Napredno
if ($AdmxPath) { $ui.txtAdmxPath.Text = $AdmxPath }
$ui.dgSettings.ItemsSource = $State.Settings
$ui.btnLoadCatalog.Add_Click({ Start-CatalogLoad })
$CatalogSearchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$CatalogSearchTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$CatalogSearchTimer.Add_Tick({ $CatalogSearchTimer.Stop(); Update-CatalogTree })
$ui.txtSearch.Add_TextChanged({ $CatalogSearchTimer.Stop(); $CatalogSearchTimer.Start() })
$ui.tvCatalog.Add_SelectedItemChanged({ if ($ui.tvCatalog.SelectedItem) { Show-PolicyDetails $ui.tvCatalog.SelectedItem.Tag } })
$ui.tvCatalog.Add_MouseDoubleClick({ if ($ui.tvCatalog.SelectedItem -and $ui.tvCatalog.SelectedItem.Tag) { Add-SelectedPolicy 'Enabled' } })
$ui.btnEnable.Add_Click({ Add-SelectedPolicy 'Enabled' })
$ui.btnDisable.Add_Click({ Add-SelectedPolicy 'Disabled' })
$ui.btnRemove.Add_Click({
        foreach ($s in @($ui.dgSettings.SelectedItems)) { $null = $State.Settings.Remove($s) }
        Update-ActionSource
    })
$ui.btnOpen.Add_Click({ Open-UiAdvancedPolicySet })
$ui.btnSave.Add_Click({ Save-UiAdvancedPolicySet })
$ui.txtSetName.Add_TextChanged({ Update-ActionSource })

# Dnevnik
$ui.lstLog.ItemsSource = $LogEntries
$ui.btnClearLog.Add_Click({ $LogEntries.Clear() })
$ui.btnCopyLog.Add_Click({
        [System.Windows.Clipboard]::SetText((@($LogEntries | ForEach-Object Line) -join [Environment]::NewLine))
        Write-UiLog 'Dnevnik je kopiran u međuspremnik.' -Level Ok
    })

# Traka radnji
$ui.btnDiff.Add_Click({ Invoke-UiPolicyAction })
$ui.btnApply.Add_Click({ Invoke-UiPolicyAction -Apply })
$ui.btnBackup.Add_Click({ Invoke-UiBackup })
$ui.btnRestore.Add_Click({ Invoke-UiRestore })
$ui.btnReplication.Add_Click({ Invoke-UiReplicationCheck })

#endregion

#region Pokretanje

Initialize-AuxStars $ui.hdrStars
$ui.txtVersion.Text = "VERZIJA $GpsVersion"
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
$ui.chipAdmin.Content = if ($isAdmin) { 'ADMINISTRATOR' } else { 'STANDARDNI KORISNIK' }
$ui.chipAdmin.Foreground = Get-AuxBrush $(if ($isAdmin) { 'Cyan' } else { 'Amber' })

$ClockTimer = [System.Windows.Threading.DispatcherTimer]::new()
$ClockTimer.Interval = [TimeSpan]::FromSeconds(20)
$ClockTimer.Add_Tick({ $ui.stClock.Text = (Get-Date).ToString('dd.MM.yyyy. HH:mm') })
$ui.stClock.Text = (Get-Date).ToString('dd.MM.yyyy. HH:mm')
$ClockTimer.Start()

try { Initialize-SecurityUi }
catch {
    Write-UiLog "Katalog sigurnosnih postavki se ne može učitati: $_" -Level Error
    if ($NoShow) { throw }
    $null = Show-AuxDialog -Title 'GPO Studio' -Kind Danger -Message 'Katalog sigurnosnih postavki se ne može učitati.' -Details "$_"
}
Update-TargetUi
Show-Page 'Pregled'
Write-UiLog "GPO Studio $GpsVersion pokrenut ($(if ($isAdmin) { 'administrator' } else { 'standardni korisnik' }))."
if (-not $isAdmin) {
    Write-UiLog 'Primjena postavki traži pokretanje kao administrator (desni klik na PowerShell, Run as administrator).' -Level Warning
}

$window.Add_SourceInitialized({ Set-AuxDarkTitleBar $window })
$window.Add_Closing({
        if ($Gui.Job -and (Show-AuxDialog -Title 'Zatvaranje' -Kind Warning -Buttons @('ZATVORI', 'ODUSTANI') -Message 'Radnja je još u tijeku. Svejedno zatvoriti?') -ne 'ZATVORI') { $_.Cancel = $true }
    })

if ($NoShow) { return }
$null = $window.ShowDialog()

#endregion
