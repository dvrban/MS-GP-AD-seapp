#Requires -Version 5.1
<#
.SYNOPSIS
    Pokreće GPO Studio: WPF sučelje za slaganje lokalnih i domenskih grupnih politika.
.DESCRIPTION
    GUI je tanki sloj iznad modula GpoStudio.Core / .Local / .Domain. Svaka akcija poziva
    cmdlet iz tih modula u pozadinskom runspaceu (sučelje se ne zamrzava), a ekvivalentna
    PowerShell naredba ispisuje se u karticu Log.
.PARAMETER AdmxPath
    Mapa s ADMX predlošcima. Zadano: Central Store u SYSVOL-u, inače %windir%\PolicyDefinitions.
.EXAMPLE
    .\Start-GpoStudio.ps1
.EXAMPLE
    .\Start-GpoStudio.ps1 -AdmxPath \\firma.local\SYSVOL\firma.local\Policies\PolicyDefinitions
#>
[CmdletBinding()]
param([string]$AdmxPath)

# GUI radi u 64-bitnom Windows PowerShellu 5.1 sa STA dretvom: WPF traži STA, domenski dio
# traži 5.1 (RSAT GroupPolicy), a 32-bitni proces bi pisao u SysWOW64\GroupPolicy.
$is32on64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
if ($PSVersionTable.PSEdition -eq 'Core' -or $is32on64 -or
    [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
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

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic

$srcRoot = Split-Path -Parent $PSScriptRoot
$script:ModulePaths = @(
    (Join-Path $srcRoot 'GpoStudio.Core\GpoStudio.Core.psd1')
    (Join-Path $srcRoot 'GpoStudio.Local\GpoStudio.Local.psm1')
    (Join-Path $srcRoot 'GpoStudio.Domain\GpoStudio.Domain.psm1')
)
Import-Module $script:ModulePaths -Force

#region Učitavanje XAML-a

[xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*')) {
    $name = $node.GetAttribute('Name', $xamlNs)
    if ($name) { $ui[$name] = $window.FindName($name) }
}

#endregion

#region Stanje i pomoćne funkcije

$script:State = @{
    Catalog  = @()
    Settings = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    Extra    = @{ security = [ordered]@{}; audit = [ordered]@{} }
    # Opis i verzija učitanog seta; GUI ih ne uređuje, ali ih čuva pri spremanju.
    Meta     = @{ description = ''; version = '1.0.0' }
    Job      = $null
}
$ui.dgSettings.ItemsSource = $script:State.Settings
if ($AdmxPath) { $ui.txtAdmxPath.Text = $AdmxPath }

function Write-UiLog([string]$Message) {
    $ui.txtLog.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine))
    $ui.txtLog.ScrollToEnd()
}

function Show-UiMessage([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    $result = [System.Windows.MessageBox]::Show($window, $Text, 'GPO Studio', $Buttons, $Icon)
    # Rezultat vraćamo samo kad postoji izbor, da ne "curi" u izlaz funkcija koje vraćaju $true/$false.
    if ($Buttons -ne 'OK') { $result }
}

function Set-UiBusy([bool]$Busy, [string]$Status) {
    $ui.pbBusy.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    foreach ($b in 'btnDiff', 'btnApply', 'btnBackup', 'btnRestore', 'btnReplication', 'btnLoadCatalog') { $ui[$b].IsEnabled = -not $Busy }
    if (-not $Busy) { $ui.btnReplication.IsEnabled = [bool]$ui.rbDomain.IsChecked }
    if ($Status) { $ui.txtStatus.Text = $Status }
}

function Get-UiComputers {
    @($ui.txtComputers.Text -split '[,;\s]+' | Where-Object { $_ })
}

function Get-UiPolicySet {
    $set = New-GpsPolicySet -Name $ui.txtSetName.Text -Description $script:State.Meta.description `
        -Version $script:State.Meta.version -Setting @($script:State.Settings)
    foreach ($section in 'security', 'audit') {
        foreach ($k in $script:State.Extra[$section].Keys) { $set.$section[$k] = $script:State.Extra[$section][$k] }
    }
    $set
}

function Test-UiDomainInput {
    if (-not $ui.txtGpoName.Text.Trim()) { Show-UiMessage 'Upišite naziv GPO-a.' 'Warning'; return $false }
    $true
}

#endregion

#region Pozadinski poslovi (runspace + DispatcherTimer)

$script:JobTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:JobTimer.Add_Tick({
        $job = $script:State.Job
        if (-not $job -or -not $job.Handle.IsCompleted) { return }
        $script:JobTimer.Stop()
        $script:State.Job = $null
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            foreach ($w in $job.PowerShell.Streams.Warning) { Write-UiLog "UPOZORENJE: $w" }
            foreach ($e in $job.PowerShell.Streams.Error) { Write-UiLog "GREŠKA: $e" }
            if ($job.OnSuccess) { & $job.OnSuccess @($output) $job.Context }
            Set-UiBusy $false "$($job.Title): gotovo ($([int]((Get-Date) - $job.Started).TotalSeconds) s)."
        }
        catch {
            $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "$_" }
            Write-UiLog "GREŠKA ($($job.Title)): $message"
            Set-UiBusy $false "$($job.Title): greška, pogledajte Log."
        }
        finally {
            $job.PowerShell.Dispose()
            $job.Runspace.Dispose()
        }
    })

function Start-UiJob {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$Arguments = @(),
        [scriptblock]$OnSuccess,
        [string]$Command,
        # Proslijeđuje se OnSuccess bloku kao drugi argument (blokovi nisu closure).
        $Context
    )
    if ($script:State.Job) { Show-UiMessage 'Operacija je već u tijeku.' 'Warning'; return }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule([string[]]$script:ModulePaths)
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($ScriptBlock.ToString())
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }

    if ($Command) { Write-UiLog "> $Command" }
    $script:State.Job = @{
        PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke()
        Title = $Title; OnSuccess = $OnSuccess; Context = $Context; Started = Get-Date
    }
    Set-UiBusy $true "$Title…"
    $script:JobTimer.Start()
}

#endregion

#region Katalog

function Update-CatalogTree {
    $ui.tvCatalog.Items.Clear()
    $filter = $ui.txtSearch.Text.Trim()
    $items = $script:State.Catalog
    if ($filter) {
        $pattern = '*' + [WildcardPattern]::Escape($filter) + '*'
        $items = @($items | Where-Object { $_.DisplayName -like $pattern -or $_.Category -like $pattern -or $_.Key -like $pattern -or $_.ValueName -like $pattern })
    }

    foreach ($scope in 'Machine', 'User') {
        $scoped = @($items | Where-Object { $_.Class -eq $scope -or $_.Class -eq 'Both' })
        $rootName = if ($scope -eq 'Machine') { 'Konfiguracija računala' } else { 'Korisnička konfiguracija' }
        $root = [System.Windows.Controls.TreeViewItem]@{ Header = "$rootName ($($scoped.Count))"; IsExpanded = $true }

        foreach ($group in $scoped | Group-Object Category | Sort-Object Name) {
            $catName = if ($group.Name) { $group.Name } else { '(bez kategorije)' }
            $cat = [System.Windows.Controls.TreeViewItem]@{ Header = "$catName ($($group.Count))"; IsExpanded = ($filter -and $scoped.Count -le 100) }
            foreach ($p in $group.Group | Sort-Object DisplayName) {
                $node = [System.Windows.Controls.TreeViewItem]@{ Header = $p.DisplayName; ToolTip = "$($p.Key)\$($p.ValueName)" }
                $node.Tag = [pscustomobject]@{ Policy = $p; Scope = $scope }
                $null = $cat.Items.Add($node)
            }
            $null = $root.Items.Add($cat)
        }
        $null = $ui.tvCatalog.Items.Add($root)
    }
}

function Start-CatalogLoad {
    $path = $ui.txtAdmxPath.Text.Trim()
    $cmd = 'Get-GpsAdmxCatalog -Language ' + (Get-Culture).Name + $(if ($path) { " -Path '$path'" })
    Start-UiJob -Title 'Učitavanje kataloga' -Command $cmd -Arguments @($path, (Get-Culture).Name) -ScriptBlock {
        param($path, $language)
        $p = @{ Language = $language }
        if ($path) { $p.Path = $path }
        Get-GpsAdmxCatalog @p
    } -OnSuccess {
        param($result)
        $script:State.Catalog = @($result)
        Update-CatalogTree
        Write-UiLog "Katalog učitan: $($script:State.Catalog.Count) politika."
    }
}

function Show-PolicyDetails($Tag) {
    if (-not $Tag) { $ui.txtPolicyTitle.Text = ''; $ui.txtPolicyMeta.Text = ''; $ui.txtExplain.Text = ''; return }
    $p = $Tag.Policy
    $hive = if ($Tag.Scope -eq 'User') { 'HKCU' } else { 'HKLM' }
    $elements = @($p.Elements | ForEach-Object { "$($_.Kind):$($_.ValueName)" }) -join ', '
    $ui.txtPolicyTitle.Text = $p.DisplayName
    $ui.txtPolicyMeta.Text = "Registry: $hive\$($p.Key)" + $(if ($p.ValueName) { "\$($p.ValueName)" }) +
        "`nKategorija: $($p.Category)`nKlasa: $($p.Class)`nIzvor: $($p.Source)" + $(if ($elements) { "`nElementi: $elements" })
    $ui.txtExplain.Text = $p.Explain
}

#endregion

#region Uređivanje Policy Seta

function Show-ElementDialog($Policy) {
    $dlg = [System.Windows.Window]@{
        Title = $Policy.DisplayName; Width = 480; SizeToContent = 'Height'; ResizeMode = 'NoResize'
        WindowStartupLocation = 'CenterOwner'; Owner = $window
    }
    $panel = [System.Windows.Controls.StackPanel]@{ Margin = '14' }
    $controls = @{}

    foreach ($el in @($Policy.Elements | Where-Object ValueName)) {
        $label = "$($el.Id)" + $(if ($el.Required) { ' *' }) + $(if ($el.Kind -eq 'decimal' -and $el.MaxValue) { " ($($el.MinValue)–$($el.MaxValue))" })
        $null = $panel.Children.Add([System.Windows.Controls.TextBlock]@{ Text = $label; Margin = '0,8,0,2' })
        $control = switch ($el.Kind) {
            'enum' {
                $c = [System.Windows.Controls.ComboBox]::new()
                foreach ($i in $el.Items) { $null = $c.Items.Add($i.DisplayName) }
                $c.SelectedIndex = 0
                $c
            }
            'boolean' { [System.Windows.Controls.CheckBox]@{ Content = 'Uključeno' } }
            'multiText' { [System.Windows.Controls.TextBox]@{ AcceptsReturn = $true; Height = 90; VerticalScrollBarVisibility = 'Auto' } }
            default {
                $text = if ($el.Kind -eq 'decimal' -and $el.MinValue) { $el.MinValue } else { '' }
                [System.Windows.Controls.TextBox]@{ Text = $text }
            }
        }
        $null = $panel.Children.Add($control)
        $controls[$el.Id] = @{ Kind = $el.Kind; Control = $control }
    }

    $buttons = [System.Windows.Controls.StackPanel]@{ Orientation = 'Horizontal'; HorizontalAlignment = 'Right'; Margin = '0,14,0,0' }
    $ok = [System.Windows.Controls.Button]@{ Content = 'U redu'; IsDefault = $true; MinWidth = 80; Margin = '0,0,6,0' }
    $ok.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    $cancel = [System.Windows.Controls.Button]@{ Content = 'Odustani'; IsCancel = $true; MinWidth = 80 }
    $null = $buttons.Children.Add($ok)
    $null = $buttons.Children.Add($cancel)
    $null = $panel.Children.Add($buttons)
    $dlg.Content = $panel

    if (-not $dlg.ShowDialog()) { return $null }

    $values = @{}
    foreach ($id in $controls.Keys) {
        $c = $controls[$id].Control
        $values[$id] = switch ($controls[$id].Kind) {
            'enum' { $c.SelectedItem }
            'boolean' { [bool]$c.IsChecked }
            'multiText' { , @($c.Text -split "`r?`n" | Where-Object { $_ }) }
            default { $c.Text }
        }
    }
    return $values
}

function Add-SelectedPolicy([string]$State) {
    $selected = $ui.tvCatalog.SelectedItem
    if (-not $selected -or -not $selected.Tag) { Show-UiMessage 'Odaberite politiku u katalogu.'; return }
    $policy = $selected.Tag.Policy

    $values = @{}
    if ($State -eq 'Enabled' -and @($policy.Elements | Where-Object ValueName).Count -gt 0) {
        $values = Show-ElementDialog $policy
        if ($null -eq $values) { return }
    }

    try {
        $new = @(ConvertTo-GpsPolicySetting -Policy $policy -State $State -Scope $selected.Tag.Scope -ElementValues $values `
                -WarningVariable conversionWarnings -WarningAction SilentlyContinue)
    }
    catch { Show-UiMessage "$_" 'Warning'; return }
    foreach ($w in $conversionWarnings) { Write-UiLog "UPOZORENJE: $w" }

    # Prvo uklanjamo ranije postavke iste politike u istom scopeu (isti id ili id s istim prefiksom),
    # a zatim i postavke drugih politika koje pišu istu vrijednost.
    $idBase = "$($policy.Source)/$($policy.Name)"
    $idPattern = "$([WildcardPattern]::Escape($idBase))/*"
    $scope = $selected.Tag.Scope
    foreach ($s in $new) {
        $existing = @($script:State.Settings | Where-Object {
                ($_.scope -eq $scope -and ($_.id -eq $idBase -or $_.id -like $idPattern)) -or
                ($_.scope -eq $s.scope -and $_.key -eq $s.key -and $_.valueName -eq $s.valueName)
            })
        foreach ($e in $existing) { $null = $script:State.Settings.Remove($e) }
    }
    foreach ($s in $new) { $script:State.Settings.Add($s) }
    Write-UiLog "Dodano ($State): $($policy.DisplayName), $($new.Count) vrijednosti."
}

#endregion

#region Primjena, diff, backup

function Show-Results($Results, [switch]$Domain) {
    $rows = foreach ($r in @($Results)) {
        $target = if ($Domain) { $r.GpoName } else { $r.ComputerName }
        if (-not $Domain) { foreach ($m in @($r.Messages)) { Write-UiLog "${target}: $m" } }
        $line = "${target}: status $($r.Status)"
        if (-not $Domain -and $r.BackupPath) { $line += ", backup: $($r.BackupPath)" }
        Write-UiLog $line
        foreach ($d in @($r.Diff)) {
            [pscustomobject]@{ Target = $target; Status = $d.Status; Scope = $d.Scope; Key = $d.Key; ValueName = $d.ValueName; Current = $d.Current; Desired = $d.Desired }
        }
    }
    $ui.dgDiff.ItemsSource = @($rows)
    $ui.tabDiff.IsSelected = $true
}

function Invoke-UiPolicyAction([switch]$Apply) {
    if ($script:State.Settings.Count -eq 0 -and $script:State.Extra.security.Count -eq 0 -and $script:State.Extra.audit.Count -eq 0) {
        Show-UiMessage 'Policy Set je prazan.'; return
    }
    $set = Get-UiPolicySet

    if ($ui.rbLocal.IsChecked) {
        $computers = Get-UiComputers
        $targetText = if ($computers) { $computers -join ', ' } else { 'ovo računalo' }
        if ($Apply -and (Show-UiMessage "Primijeniti '$($set.name)' na lokalni GP: ${targetText}?`nPrije primjene radi se backup." 'Question' 'YesNo') -ne 'Yes') { return }

        $cmd = "Set-GpsLocalPolicy -PolicySet `$set" + $(if ($computers) { " -ComputerName $($computers -join ',')" }) + $(if ($Apply) { ' -Confirm:$false' } else { ' -WhatIf' })
        Start-UiJob -Title $(if ($Apply) { 'Primjena (lokalno)' } else { 'Usporedba (lokalno)' }) -Command $cmd `
            -Arguments @($set, $computers, [bool]$Apply) -ScriptBlock {
            param($set, $computers, $apply)
            $p = @{ PolicySet = $set }
            if ($computers) { $p.ComputerName = $computers }
            if ($apply) { Set-GpsLocalPolicy @p -Confirm:$false } else { Set-GpsLocalPolicy @p -WhatIf }
        } -OnSuccess { param($r) Show-Results $r }
    }
    else {
        if (-not (Test-UiDomainInput)) { return }
        $gpo = $ui.txtGpoName.Text.Trim()
        $domain = $ui.txtDomain.Text.Trim()
        $link = $ui.txtLinkTarget.Text.Trim()
        $group = $ui.txtApplyGroup.Text.Trim()
        $question = "Objaviti '$($set.name)' u domenski GPO '$gpo'?"
        if ($link) { $question += "`nPovezivanje na: $link" }
        $question += "`nPostojeći GPO se prije promjene backupira."
        if ($Apply -and (Show-UiMessage $question 'Question' 'YesNo') -ne 'Yes') { return }

        $cmd = "Publish-GpsDomainPolicy -PolicySet `$set -GpoName '$gpo'" + $(if ($domain) { " -Domain $domain" }) +
            $(if ($link) { " -LinkTarget '$link'" }) + $(if ($group) { " -ApplyToGroup '$group'" }) + $(if ($Apply) { ' -Confirm:$false' } else { ' -WhatIf' })
        Start-UiJob -Title $(if ($Apply) { 'Objava (domena)' } else { 'Usporedba (domena)' }) -Command $cmd `
            -Arguments @($set, $gpo, $domain, $link, $group, [bool]$Apply) -ScriptBlock {
            param($set, $gpo, $domain, $link, $group, $apply)
            $p = @{ PolicySet = $set; GpoName = $gpo }
            if ($domain) { $p.Domain = $domain }
            if ($link) { $p.LinkTarget = $link }
            if ($group) { $p.ApplyToGroup = $group }
            if ($apply) { Publish-GpsDomainPolicy @p -Confirm:$false } else { Publish-GpsDomainPolicy @p -WhatIf }
        } -OnSuccess { param($r) Show-Results $r -Domain }
    }
}

function Invoke-UiBackup {
    if ($ui.rbLocal.IsChecked) {
        $computers = Get-UiComputers
        Start-UiJob -Title 'Backup (lokalno)' -Command ('Backup-GpsLocalPolicy' + $(if ($computers) { " -ComputerName $($computers -join ',')" })) `
            -Arguments @(, $computers) -ScriptBlock {
            param($computers)
            if ($computers) { Backup-GpsLocalPolicy -ComputerName $computers } else { Backup-GpsLocalPolicy }
        } -OnSuccess { param($r) foreach ($b in @($r)) { Write-UiLog "Backup spremljen ($($b.ComputerName)): $($b.BackupPath)" } }
    }
    else {
        if (-not (Test-UiDomainInput)) { return }
        $gpo = $ui.txtGpoName.Text.Trim()
        $domain = $ui.txtDomain.Text.Trim()
        $path = Join-Path $env:ProgramData 'GpoStudio\GpoBackup'
        Start-UiJob -Title 'Backup (domena)' -Command "Backup-GPO -Name '$gpo' -Path '$path'" -Arguments @($gpo, $domain, $path) -ScriptBlock {
            param($gpo, $domain, $path)
            $ctx = Get-GpsDomainContext -Domain $domain
            $null = New-Item -ItemType Directory -Path $path -Force
            Backup-GPO -Name $gpo -Path $path -Domain $ctx.Domain -Server $ctx.Server
        } -OnSuccess { param($r) foreach ($b in @($r)) { Write-UiLog "Backup GPO-a '$($b.DisplayName)': $($b.Id) u $($b.BackupDirectory)" } }
    }
}

function Invoke-UiRestore {
    if ($ui.rbLocal.IsChecked) {
        $computers = Get-UiComputers
        if ($computers.Count -gt 1) { Show-UiMessage 'Vraćanje se radi za jedno računalo.' 'Warning'; return }
        $path = [Microsoft.VisualBasic.Interaction]::InputBox('Putanja backupa na ciljanom računalu (npr. C:\ProgramData\GpoStudio\Backup\20261010-101500):', 'Vrati lokalni GP')
        if (-not $path) { return }
        $computer = $computers | Select-Object -First 1
        Start-UiJob -Title 'Vraćanje (lokalno)' -Command "Restore-GpsLocalPolicy -BackupPath '$path'$(if ($computer) { " -ComputerName $computer" }) -Confirm:`$false" `
            -Arguments @($path, $computer) -ScriptBlock {
            param($path, $computer)
            $p = @{ BackupPath = $path }
            if ($computer) { $p.ComputerName = $computer }
            Restore-GpsLocalPolicy @p -Confirm:$false
        } -OnSuccess {
            param($r)
            foreach ($x in @($r)) {
                foreach ($m in @($x.Messages)) { Write-UiLog "$($x.ComputerName): $m" }
                Write-UiLog "$($x.ComputerName): vraćanje iz backupa, status $($x.Status)"
            }
        }
    }
    else {
        if (-not (Test-UiDomainInput)) { return }
        $gpo = $ui.txtGpoName.Text.Trim()
        $domain = $ui.txtDomain.Text.Trim()
        $path = [Microsoft.VisualBasic.Interaction]::InputBox('Mapa s backupom GPO-a (vraća se najnoviji backup):', 'Vrati GPO', (Join-Path $env:ProgramData 'GpoStudio\GpoBackup'))
        if (-not $path) { return }
        if ((Show-UiMessage "Vratiti GPO '$gpo' iz ${path}?" 'Question' 'YesNo') -ne 'Yes') { return }
        Start-UiJob -Title 'Vraćanje (domena)' -Command "Restore-GPO -Name '$gpo' -Path '$path'" -Arguments @($gpo, $domain, $path) -Context $gpo -ScriptBlock {
            param($gpo, $domain, $path)
            $ctx = Get-GpsDomainContext -Domain $domain
            Restore-GPO -Name $gpo -Path $path -Domain $ctx.Domain -Server $ctx.Server
            Write-GpsAuditLog -Action 'Restore-GPO' -Target "$($ctx.Domain)/$gpo" -Details @{ path = $path }
        } -OnSuccess { param($r, $gpoName) Write-UiLog "GPO '$gpoName' vraćen iz backupa." }
    }
}

#endregion

#region Događaji

$ui.rbLocal.Add_Checked({ $ui.pnlLocal.Visibility = 'Visible'; $ui.pnlDomain.Visibility = 'Collapsed'; $ui.btnReplication.IsEnabled = $false })
$ui.rbDomain.Add_Checked({ $ui.pnlLocal.Visibility = 'Collapsed'; $ui.pnlDomain.Visibility = 'Visible'; $ui.btnReplication.IsEnabled = $true })
$ui.btnReplication.IsEnabled = $false

$ui.btnLoadCatalog.Add_Click({ Start-CatalogLoad })

# Pretraga s odgodom da se stablo ne gradi nakon svakog znaka.
$script:SearchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:SearchTimer.Add_Tick({ $script:SearchTimer.Stop(); Update-CatalogTree })
$ui.txtSearch.Add_TextChanged({ $script:SearchTimer.Stop(); $script:SearchTimer.Start() })

$ui.tvCatalog.Add_SelectedItemChanged({ Show-PolicyDetails $ui.tvCatalog.SelectedItem.Tag })
$ui.tvCatalog.Add_MouseDoubleClick({ if ($ui.tvCatalog.SelectedItem.Tag) { Add-SelectedPolicy 'Enabled' } })

$ui.btnEnable.Add_Click({ Add-SelectedPolicy 'Enabled' })
$ui.btnDisable.Add_Click({ Add-SelectedPolicy 'Disabled' })
$ui.btnRemove.Add_Click({
        foreach ($s in @($ui.dgSettings.SelectedItems)) { $null = $script:State.Settings.Remove($s) }
    })

$ui.btnOpen.Add_Click({
        $dlg = [Microsoft.Win32.OpenFileDialog]@{ Filter = 'Policy Set (*.json)|*.json'; Title = 'Otvori Policy Set' }
        if (-not $dlg.ShowDialog($window)) { return }
        try {
            $set = Import-GpsPolicySet -Path $dlg.FileName
            $script:State.Settings.Clear()
            foreach ($s in $set.settings) { $script:State.Settings.Add($s) }
            $script:State.Extra = @{ security = $set.security; audit = $set.audit }
            $script:State.Meta = @{ description = $set.description; version = $set.version }
            $ui.txtSetName.Text = $set.name
            Write-UiLog "Učitan Policy Set '$($set.name)' ($($set.settings.Count) postavki, security: $($set.security.Count), audit: $($set.audit.Count))."
        }
        catch { Show-UiMessage "Ne mogu učitati datoteku: $_" 'Error' }
    })

$ui.btnSave.Add_Click({
        $dlg = [Microsoft.Win32.SaveFileDialog]@{ Filter = 'Policy Set (*.json)|*.json'; FileName = "$($ui.txtSetName.Text).json" }
        if (-not $dlg.ShowDialog($window)) { return }
        Export-GpsPolicySet -PolicySet (Get-UiPolicySet) -Path $dlg.FileName
        Write-UiLog "Spremljeno: $($dlg.FileName)"
    })

$ui.btnDiff.Add_Click({ Invoke-UiPolicyAction })
$ui.btnApply.Add_Click({ Invoke-UiPolicyAction -Apply })
$ui.btnBackup.Add_Click({ Invoke-UiBackup })
$ui.btnRestore.Add_Click({ Invoke-UiRestore })
$ui.btnReplication.Add_Click({
        if (-not (Test-UiDomainInput)) { return }
        $gpo = $ui.txtGpoName.Text.Trim()
        Start-UiJob -Title 'Provjera replikacije' -Command "Test-GpsDomainGpoReplication -GpoName '$gpo'" `
            -Arguments @($gpo, $ui.txtDomain.Text.Trim()) -ScriptBlock {
            param($gpo, $domain)
            $p = @{ GpoName = $gpo }
            if ($domain) { $p.Domain = $domain }
            Test-GpsDomainGpoReplication @p
        } -OnSuccess {
            param($r)
            Write-UiLog ($r | Format-Table DomainController, ComputerAD, ComputerSysvol, UserAD, UserSysvol, InSync -AutoSize | Out-String)
            $ui.tabLog.IsSelected = $true
        }
    })

$window.Add_ContentRendered({ Start-CatalogLoad })
$window.Add_Closing({
        if ($script:State.Job -and (Show-UiMessage 'Operacija je u tijeku. Svejedno zatvoriti?' 'Warning' 'YesNo') -ne 'Yes') { $_.Cancel = $true }
    })

#endregion

$null = $window.ShowDialog()
