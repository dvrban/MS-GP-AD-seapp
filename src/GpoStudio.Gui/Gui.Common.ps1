<#
    Zajednički dio GUI-ja: Auxilium tema, dnevnik, dijalozi u stilu aplikacije, pozadinski poslovi,
    pločice ocjene i zvjezdice u zaglavlju. Učitava ga Start-GpoStudio.ps1 (dot-source).
#>

#region Tema

function Initialize-AuxTheme {
    <# Učitava Theme\Auxilium.xaml u resurse aplikacije, da vrijedi i za dijaloge. #>
    param([Parameter(Mandatory)][string]$GuiRoot)
    $app = [System.Windows.Application]::Current
    if (-not $app) {
        $app = [System.Windows.Application]::new()
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $existing = @($app.Resources.MergedDictionaries | Where-Object { $_.Contains('GumbPrimarni') })
    if ($existing.Count -gt 0) { return }

    $reader = [System.Xml.XmlReader]::Create((Join-Path $GuiRoot 'Theme\Auxilium.xaml'))
    try { $theme = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }

    # Fontovi marke (Orbitron, Sora, IBM Plex Mono; licenca OFL) koriste se ako su u mapi Fonts uz GUI.
    $fontDir = Join-Path $GuiRoot 'Fonts'
    if (Test-Path -LiteralPath $fontDir) {
        $baseUri = [Uri]((Resolve-Path -LiteralPath $fontDir).ProviderPath.TrimEnd('\') + '\')
        $brand = @{
            FontNaslov = @('Orbitron', 'Bahnschrift, Segoe UI Semibold, Segoe UI')
            FontTekst  = @('Sora', 'Segoe UI')
            FontMono   = @('IBM Plex Mono', 'Consolas, Courier New')
            FontGumb   = @('IBM Plex Mono', 'Segoe UI')
        }
        $files = @(Get-ChildItem -LiteralPath $fontDir -Include *.ttf, *.otf -File -Recurse)
        foreach ($key in $brand.Keys) {
            $family = $brand[$key][0]
            if (@($files | Where-Object { $_.BaseName -replace '[-_ ]', '' -like ($family -replace ' ', '') + '*' }).Count -gt 0) {
                $theme[$key] = [System.Windows.Media.FontFamily]::new($baseUri, "./#$family, $($brand[$key][1])")
            }
        }
    }
    $app.Resources.MergedDictionaries.Add($theme)
}

function Get-AuxBrush([string]$Name) {
    [System.Windows.Application]::Current.Resources[$Name]
}

function Set-AuxDarkTitleBar($Window) {
    <# Tamna naslovna traka prozora (Windows 10 2004+ / 11); bez greške na starijim sustavima. #>
    try {
        if (-not ('GpoStudio.NativeDwm' -as [type])) {
            Add-Type -Namespace GpoStudio -Name NativeDwm -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attribute, ref int value, int size);
'@
        }
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
        $handle = $helper.EnsureHandle()
        $on = 1
        $null = [GpoStudio.NativeDwm]::DwmSetWindowAttribute($handle, 20, [ref]$on, 4)
    }
    catch { }
}

function New-AuxTag {
    <# Oznaka (18 px). Kind: Neutral, Osnovno, Preporuceno, Strogo, Restart, Info. #>
    param([string]$Text, [string]$Kind = 'Neutral', [string]$ToolTip)
    $tag = [System.Windows.Controls.ContentControl]::new()
    $tag.Content = $Text
    $brush = switch ($Kind) {
        'Osnovno' { 'Cyan' } 'Preporuceno' { 'Green' } 'Strogo' { 'Amber' } 'Restart' { 'Amber' } 'Info' { 'Cyan' } 'Greska' { 'Red' } default { $null }
    }
    if ($brush) {
        $tag.Style = Get-AuxBrush 'OznakaTocka'
        $tag.Foreground = Get-AuxBrush $brush
    }
    else { $tag.Style = Get-AuxBrush 'Oznaka' }
    $tag.Margin = '0,6,6,0'
    if ($ToolTip) { $tag.ToolTip = $ToolTip }
    $tag
}

function New-AuxText {
    param([string]$Text, [string]$Style = 'Tekst', $Margin)
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Style = Get-AuxBrush $Style
    $t.Text = $Text
    if ($null -ne $Margin) { $t.Margin = $Margin }
    $t
}

#endregion

#region Zvjezdice u zaglavlju (isti raspored kao Auxilium aplikacija i www.auxilium.hr)

$AuxStars = '47.29,4.49,2,0.251;17.24,17.18,2,0.369;33.84,33,1,0.231;19.46,19.23,2,0.322;48.63,81.53,1,0.412;27.85,54.68,2,0.376;77.8,60.13,1,0.231;58.52,94.01,1,0.184;72.05,26.43,1,0.259;14.22,87.75,1,0.18;94.98,77.2,1,0.239;70.67,48.18,1,0.133;22.15,67.52,1,0.325;61.42,72.9,2,0.231;19.4,58.15,1,0.149;78.03,33.13,1,0.227;8.19,4.51,2,0.212;70.87,44.22,1,0.345;58.84,77.17,1,0.302;13.42,33.27,1,0.161;52.17,76.19,2,0.196;25.2,57.16,2,0.337;86.69,55.75,1,0.122;74.95,65.58,1,0.239;39.65,1.42,1,0.243;14.72,14.93,1,0.396;91.73,7.92,2,0.137;10.49,89.1,2,0.357;41.27,83.18,1,0.122;4.95,46.56,1,0.153;30.85,34.31,1,0.129;39.65,19.71,2,0.376;34.87,0.56,1,0.141;89.63,50.72,1,0.153;84.1,50.26,1,0.42;48.36,89.41,2,0.384;76.55,18.44,2,0.153;60.65,40.45,2,0.286;86.79,92.61,2,0.22;8.59,76.97,1,0.227;21.99,15.54,1,0.263;78.1,67.2,2,0.412;68.28,67.7,1,0.165;47.29,97.35,1,0.118;45.64,8.75,1,0.227;4.9,94.17,2,0.212;43.67,17.9,2,0.188;15.41,34.49,1,0.196;11.97,27.24,1,0.408;40.04,78.74,1,0.169;21.95,24.25,2,0.18;22.71,2.2,2,0.251;89.95,93.87,2,0.216;38.41,17.08,1,0.318;82.93,54.96,1,0.318;41.99,99.47,1,0.345'

function Initialize-AuxStars([System.Windows.Controls.Canvas]$Canvas) {
    $Canvas.Children.Clear()
    foreach ($star in $AuxStars -split ';') {
        $p = $star -split ','
        $r = [System.Windows.Shapes.Rectangle]::new()
        $r.Width = [double]$p[2]; $r.Height = [double]$p[2]
        $r.Fill = Get-AuxBrush 'Star'
        $r.Opacity = [double]::Parse($p[3], [Globalization.CultureInfo]::InvariantCulture)
        $r.Tag = @([double]::Parse($p[0], [Globalization.CultureInfo]::InvariantCulture), [double]::Parse($p[1], [Globalization.CultureInfo]::InvariantCulture))
        $null = $Canvas.Children.Add($r)
    }
    $Canvas.Add_SizeChanged({
            # Pravokutnik zvjezdica: (0, 2, širina, visina - 6), kao u aplikaciji.
            foreach ($r in $this.Children) {
                [System.Windows.Controls.Canvas]::SetLeft($r, $r.Tag[0] / 100 * ($this.ActualWidth - $r.Width))
                [System.Windows.Controls.Canvas]::SetTop($r, 2 + $r.Tag[1] / 100 * ($this.ActualHeight - 6 - $r.Height))
            }
        })
}

#endregion

#region Dnevnik

$LogEntries = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

function Write-UiLog {
    param([string]$Message, [ValidateSet('Info', 'Command', 'Ok', 'Warning', 'Error')][string]$Level = 'Info')
    $prefix = switch ($Level) { 'Command' { '> ' } 'Warning' { 'UPOZORENJE: ' } 'Error' { 'GREŠKA: ' } default { '' } }
    foreach ($line in ($Message -split "`r?`n")) {
        if ($line -eq '' -and $Level -ne 'Info') { continue }
        $LogEntries.Add([pscustomobject]@{ Line = ('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $prefix, $line); Level = $Level })
        $prefix = ''
    }
    if ($ui -and $ui.svLog) { $ui.svLog.ScrollToEnd() }
    if ($ui -and $ui.stMessage -and $Level -in 'Ok', 'Warning', 'Error') {
        $ui.stMessage.Text = ($Message -split "`r?`n")[0]
        $ui.stMessage.Foreground = Get-AuxBrush $(switch ($Level) { 'Ok' { 'Green' } 'Warning' { 'Amber' } default { 'Red' } })
    }
}

#endregion

#region Dijalozi u stilu aplikacije

function New-AuxDialogWindow {
    param([string]$Title, [double]$Width = 540)
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $Title
    $dlg.Width = $Width
    $dlg.SizeToContent = 'Height'
    $dlg.ResizeMode = 'NoResize'
    $dlg.ShowInTaskbar = $false
    $dlg.Background = Get-AuxBrush 'Void'
    $dlg.Foreground = Get-AuxBrush 'Text'
    $dlg.FontFamily = Get-AuxBrush 'FontTekst'
    $dlg.FontSize = 13
    $dlg.UseLayoutRounding = $true
    if ($window -and $window.IsLoaded) { $dlg.Owner = $window; $dlg.WindowStartupLocation = 'CenterOwner' }
    else { $dlg.WindowStartupLocation = 'CenterScreen' }
    $dlg.Add_SourceInitialized({ Set-AuxDarkTitleBar $this })
    $dlg
}

function New-AuxDialogFrame {
    # Okvir dijaloga: jantarna crta gore, eyebrow naslov, sadržaj, gumbi desno.
    param([string]$Eyebrow, [System.Windows.UIElement]$Body, [System.Windows.Controls.Panel]$Buttons, [string]$Accent = 'Amber')
    $outer = [System.Windows.Controls.DockPanel]::new()
    $line = [System.Windows.Shapes.Rectangle]::new()
    $line.Height = 2
    $line.Fill = Get-AuxBrush $Accent
    [System.Windows.Controls.DockPanel]::SetDock($line, 'Top')
    $null = $outer.Children.Add($line)
    $Buttons.HorizontalAlignment = 'Right'
    $Buttons.Margin = '22,0,22,18'
    [System.Windows.Controls.DockPanel]::SetDock($Buttons, 'Bottom')
    $null = $outer.Children.Add($Buttons)
    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.Margin = '22,16,22,18'
    $eb = New-AuxText $Eyebrow 'Eyebrow'
    $eb.Foreground = Get-AuxBrush $Accent
    $null = $stack.Children.Add($eb)
    $Body.SetValue([System.Windows.FrameworkElement]::MarginProperty, [System.Windows.Thickness]::new(0, 8, 0, 0))
    $null = $stack.Children.Add($Body)
    $null = $outer.Children.Add($stack)
    $outer
}

function Show-AuxDialog {
    <#
    .SYNOPSIS
        Poruka u stilu aplikacije. Vraća natpis kliknutog gumba ili $null ako je prozor zatvoren.
    .PARAMETER Kind
        Info, Warning ili Danger (boja crte i naslova).
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'GPO Studio',
        [string[]]$Buttons = @('U REDU'),
        [string]$Primary,
        [ValidateSet('Info', 'Warning', 'Danger')][string]$Kind = 'Info',
        [string]$Details
    )
    $dlg = New-AuxDialogWindow -Title $Title
    $accent = switch ($Kind) { 'Warning' { 'Amber' } 'Danger' { 'Red' } default { 'Cyan' } }
    $body = [System.Windows.Controls.StackPanel]::new()
    $null = $body.Children.Add((New-AuxText $Message 'Tekst'))
    if ($Details) {
        $box = [System.Windows.Controls.TextBox]::new()
        $box.Text = $Details
        $box.IsReadOnly = $true
        $box.TextWrapping = 'Wrap'
        $box.MaxHeight = 220
        $box.VerticalScrollBarVisibility = 'Auto'
        $box.FontFamily = Get-AuxBrush 'FontMono'
        $box.FontSize = 12
        $box.Margin = '0,10,0,0'
        $box.Padding = '6,4'
        $box.VerticalContentAlignment = 'Top'
        $null = $body.Children.Add($box)
    }
    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    if (-not $Primary) { $Primary = $Buttons[0] }
    foreach ($label in $Buttons) {
        $b = [System.Windows.Controls.Button]::new()
        $b.Content = $label
        $b.Margin = '8,0,0,0'
        if ($label -eq $Primary) {
            $b.Style = Get-AuxBrush $(if ($Kind -eq 'Danger') { 'GumbOpasni' } else { 'GumbPrimarni' })
            $b.IsDefault = $true
        }
        if ($label -eq $Buttons[-1] -and $Buttons.Count -gt 1) { $b.IsCancel = $true }
        $b.Tag = $label
        $b.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); $w.Tag = $this.Tag; $w.Close() })
        $null = $panel.Children.Add($b)
    }
    $dlg.Content = New-AuxDialogFrame -Eyebrow $Title.ToUpperInvariant() -Body $body -Buttons $panel -Accent $accent
    $null = $dlg.ShowDialog()
    $dlg.Tag
}

function Show-AuxInput {
    <#
    .SYNOPSIS
        Dijalog s jednim ili više polja. Fields: uređeni rječnik  natpis -> zadana vrijednost.
        Vraća rječnik natpis -> uneseni tekst ili $null (odustajanje).
    #>
    param([Parameter(Mandatory)][string]$Title, [string]$Message, [Parameter(Mandatory)][System.Collections.IDictionary]$Fields, [string]$OkText = 'SPREMI')
    $dlg = New-AuxDialogWindow -Title $Title
    $body = [System.Windows.Controls.StackPanel]::new()
    if ($Message) { $null = $body.Children.Add((New-AuxText $Message 'TekstPrigusen' '0,0,0,6')) }
    $boxes = [ordered]@{}
    foreach ($label in $Fields.Keys) {
        $null = $body.Children.Add((New-AuxText $label.ToUpperInvariant() 'EyebrowPrigusen' '0,10,0,4'))
        $box = [System.Windows.Controls.TextBox]::new()
        $box.Text = [string]$Fields[$label]
        $null = $body.Children.Add($box)
        $boxes[$label] = $box
    }
    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $ok = [System.Windows.Controls.Button]::new(); $ok.Content = $OkText; $ok.Style = Get-AuxBrush 'GumbPrimarni'; $ok.IsDefault = $true
    $ok.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); $w.Tag = 'OK'; $w.Close() })
    $cancel = [System.Windows.Controls.Button]::new(); $cancel.Content = 'ODUSTANI'; $cancel.IsCancel = $true; $cancel.Margin = '8,0,0,0'
    $null = $panel.Children.Add($ok); $null = $panel.Children.Add($cancel)
    $dlg.Content = New-AuxDialogFrame -Eyebrow $Title.ToUpperInvariant() -Body $body -Buttons $panel
    $first = @($boxes.Values)[0]
    $dlg.Add_ContentRendered({ $first.Focus(); $first.SelectAll() }.GetNewClosure())
    $null = $dlg.ShowDialog()
    if ($dlg.Tag -ne 'OK') { return $null }
    $result = [ordered]@{}
    foreach ($label in $boxes.Keys) { $result[$label] = $boxes[$label].Text.Trim() }
    $result
}

function Show-AuxList {
    <#
    .SYNOPSIS
        Izbor jedne stavke s popisa. Items su objekti; Display je scriptblock koji vraća tekst stavke.
    #>
    param([Parameter(Mandatory)][string]$Title, [string]$Message, [Parameter(Mandatory)][object[]]$Items, [scriptblock]$Display = { "$_" }, [string]$OkText = 'ODABERI')
    $dlg = New-AuxDialogWindow -Title $Title -Width 620
    $body = [System.Windows.Controls.StackPanel]::new()
    if ($Message) { $null = $body.Children.Add((New-AuxText $Message 'TekstPrigusen' '0,0,0,10')) }
    $list = [System.Windows.Controls.ListBox]::new()
    $list.MaxHeight = 320
    $list.BorderBrush = Get-AuxBrush 'Line'
    $list.BorderThickness = 1
    $list.Background = Get-AuxBrush 'Panel'
    foreach ($item in $Items) {
        $li = [System.Windows.Controls.ListBoxItem]::new()
        $li.Height = 34
        $li.Content = (@($item) | ForEach-Object $Display) -join ''
        $li.Tag = $item
        $null = $list.Items.Add($li)
    }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $null = $body.Children.Add($list)
    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $ok = [System.Windows.Controls.Button]::new(); $ok.Content = $OkText; $ok.Style = Get-AuxBrush 'GumbPrimarni'; $ok.IsDefault = $true
    $ok.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); $w.Tag = 'OK'; $w.Close() })
    $cancel = [System.Windows.Controls.Button]::new(); $cancel.Content = 'ODUSTANI'; $cancel.IsCancel = $true; $cancel.Margin = '8,0,0,0'
    $null = $panel.Children.Add($ok); $null = $panel.Children.Add($cancel)
    $list.Add_MouseDoubleClick({ $w = [System.Windows.Window]::GetWindow($this); $w.Tag = 'OK'; $w.Close() })
    $dlg.Content = New-AuxDialogFrame -Eyebrow $Title.ToUpperInvariant() -Body $body -Buttons $panel
    $null = $dlg.ShowDialog()
    if ($dlg.Tag -ne 'OK' -or -not $list.SelectedItem) { return $null }
    $list.SelectedItem.Tag
}

#endregion

#region Pločica ocjene (kartica ocjene sa 20 segmenata)

function New-AuxScoreTile {
    param([string]$Title, [string]$Subtitle)
    $tile = [System.Windows.Controls.ContentControl]::new()
    $tile.Style = Get-AuxBrush 'RedakKontrole'
    $tile.Tag = Get-AuxBrush 'Line'
    $tile.Padding = '16,10,14,10'
    $tile.Margin = '0,0,8,0'
    $stack = [System.Windows.Controls.StackPanel]::new()
    # Ne $title: PowerShell ne razlikuje velika i mala slova, pa bi to bio parametar [string]$Title.
    $titleText = New-AuxText $Title 'Eyebrow'
    $number = [System.Windows.Controls.TextBlock]::new()
    $number.FontFamily = Get-AuxBrush 'FontNaslov'
    $number.FontWeight = 'Bold'
    $number.FontSize = 28
    $number.Margin = '0,2,0,4'
    $number.Text = '–'
    $bar = [System.Windows.Controls.Primitives.UniformGrid]::new()
    $bar.Columns = 20
    $bar.Height = 8
    foreach ($i in 1..20) {
        $seg = [System.Windows.Shapes.Rectangle]::new()
        $seg.Margin = '0,0,2,0'
        $seg.Fill = Get-AuxBrush 'Line'
        $null = $bar.Children.Add($seg)
    }
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.FontWeight = 'Bold'
    $label.FontSize = 11
    $label.Margin = '0,6,0,0'
    $sub = New-AuxText $Subtitle 'Nagovjestaj' '0,2,0,0'
    $sub.TextWrapping = 'NoWrap'
    $sub.TextTrimming = 'CharacterEllipsis'
    foreach ($e in $titleText, $number, $bar, $label, $sub) { $null = $stack.Children.Add($e) }
    $tile.Content = $stack
    [pscustomobject]@{ Root = $tile; Number = $number; Bar = $bar; Label = $label; Subtitle = $sub }
}

function Update-AuxScoreTile($Tile, [int]$Score, [int]$Satisfied, [int]$Total) {
    $level = if ($Total -eq 0) { 'Muted' } elseif ($Score -ge 80) { 'Green' } elseif ($Score -ge 50) { 'Amber' } else { 'Red' }
    $brush = Get-AuxBrush $level
    $Tile.Number.Text = if ($Total) { "$Score %" } else { '–' }
    $Tile.Number.Foreground = $brush
    $Tile.Label.Foreground = $brush
    $Tile.Label.Text = if ($Total -eq 0) { 'NEMA PREPORUKA' } elseif ($Score -ge 80) { "DOBRO  ·  $Satisfied OD $Total" } elseif ($Score -ge 50) { "DJELOMIČNO  ·  $Satisfied OD $Total" } else { "SLABO  ·  $Satisfied OD $Total" }
    $on = [int][math]::Round($Score / 5)
    for ($i = 0; $i -lt 20; $i++) { $Tile.Bar.Children[$i].Fill = if ($i -lt $on) { $brush } else { Get-AuxBrush 'Line' } }
}

#endregion

#region Pozadinski poslovi (runspace + DispatcherTimer)

$Gui = @{ Job = $null }
$Gui.JobTimer = [System.Windows.Threading.DispatcherTimer]::new()
$Gui.JobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$Gui.JobTimer.Add_Tick({
        $job = $Gui.Job
        if (-not $job -or -not $job.Handle.IsCompleted) { return }
        $Gui.JobTimer.Stop()
        $Gui.Job = $null
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            foreach ($w in $job.PowerShell.Streams.Warning) { Write-UiLog "$w" -Level Warning }
            foreach ($e in $job.PowerShell.Streams.Error) { Write-UiLog "$e" -Level Error }
            Set-UiBusy $false
            if ($job.OnSuccess) { & $job.OnSuccess @($output) $job.Context }
            Write-UiLog "$($job.Title): gotovo ($([int]((Get-Date) - $job.Started).TotalSeconds) s)." -Level Ok
        }
        catch {
            Set-UiBusy $false
            $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "$_" }
            Write-UiLog "$($job.Title): $message" -Level Error
            $null = Show-AuxDialog -Title $job.Title -Message 'Radnja nije uspjela.' -Details $message -Kind Danger
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
    if ($Gui.Job) { $null = Show-AuxDialog -Message 'Druga radnja je još u tijeku. Pričekajte da završi.' -Kind Warning; return }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule([string[]]$ModulePaths)
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($ScriptBlock.ToString())
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }

    if ($Command) { Write-UiLog $Command -Level Command }
    $Gui.Job = @{
        PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke()
        Title = $Title; OnSuccess = $OnSuccess; Context = $Context; Started = Get-Date
    }
    Set-UiBusy $true $Title
    $Gui.JobTimer.Start()
}

function Set-UiBusy([bool]$Busy, [string]$Title) {
    $ui.pbBusy.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    $ui.pbBusy.IsIndeterminate = $Busy
    foreach ($b in 'btnDiff', 'btnApply', 'btnBackup', 'btnRestore', 'btnReplication', 'btnLoadCatalog', 'btnCheckComputer') {
        if ($ui[$b]) { $ui[$b].IsEnabled = -not $Busy }
    }
    $ui.stState.Text = if ($Busy) { ($Title.ToUpperInvariant() + '…') } else { 'SPREMNO' }
    $ui.stState.Foreground = Get-AuxBrush $(if ($Busy) { 'Amber' } else { 'Cyan' })
}

#endregion
