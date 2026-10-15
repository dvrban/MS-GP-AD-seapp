<#
    Sigurnosne postavke za korisnike koji ne poznaju Group Policy: razine, kontrolna ploča s
    kvačicama i izborima po područjima, preseti i usporedba sa standardima (CIS, Microsoft baseline).
    Učitava ga Start-GpoStudio.ps1 (dot-source) nakon što je prozor učitan ($window, $ui).
#>

$LevelNames = @{ 0 = 'Bez razine'; 1 = 'Osnovno'; 2 = 'Preporučeno'; 3 = 'Strogo' }
$LevelBrushNames = @{ 1 = 'Cyan'; 2 = 'Green'; 3 = 'Amber' }
$LevelTagKinds = @{ 1 = 'Osnovno'; 2 = 'Preporuceno'; 3 = 'Strogo' }
$StatusTexts = @{ OK = 'U REDU'; Deviates = 'ODSTUPA'; NotSet = 'NIJE POSTAVLJENO' }

$Sec = @{
    Catalog        = $null
    Index          = @{}
    Categories     = @{}
    Level          = 2
    Selection      = [ordered]@{}
    Preset         = $null       # naziv učitanog preseta ili izvora odabira (npr. stanje računala)
    Baseline       = [ordered]@{} # odabir kakav je bio nakon zadnje razine, preseta ili preuzetog stanja
    Rows           = @{}         # id kontrole -> elementi retka
    CategoryItems  = @{}         # id kategorije -> stavka popisa
    Updating       = $false
    Category       = $null
    Presets        = @()
    Detected       = $null       # zadnja provjera računala
    Standard       = 'CIS-L1'
    TilesOverview  = @{}
    TilesCompare   = @{}
    CompareNote    = ''
}

#region Pomoćne funkcije

function Get-ControlFirstLevel($Control) {
    # Najniža razina koja uključuje kontrolu (1-3), ili 0 ako je ne uključuje nijedna.
    foreach ($level in 1..3) { if (Get-GpsControlLevelOption $Control $level) { return $level } }
    0
}

function Get-ControlLevelOptionTitle($Control, [int]$Level) {
    $id = Get-GpsControlLevelOption $Control $Level
    if (-not $id) { return 'ne mijenja se' }
    (Get-GpsControlOption $Control $id).title
}

function Test-ControlUsesLocalOnly($Control) {
    # [System Access] i revizija se zasad primjenjuju samo na lokalni GP (ne u domenski GPO).
    foreach ($o in @($Control.options)) {
        if ((Get-GpsOptionalProperty $o 'security') -or (Get-GpsOptionalProperty $o 'audit')) { return $true }
    }
    $false
}

function Get-SelectionStats {
    $enabled = 0; $changed = 0
    foreach ($c in @($Sec.Catalog.controls)) {
        $value = $Sec.Selection[$c.id]
        if ($value) { $enabled++ }
        if ([string]$value -ne [string](Get-GpsControlLevelOption $c $Sec.Level)) { $changed++ }
    }
    $edited = 0
    foreach ($c in @($Sec.Catalog.controls)) { if ([string]$Sec.Selection[$c.id] -ne [string]$Sec.Baseline[$c.id]) { $edited++ } }
    # Changed: razlika prema razini (oznake u retcima), Edited: ručne izmjene nakon razine/preseta.
    [pscustomobject]@{ Enabled = $enabled; Changed = $changed; Edited = $edited; Total = @($Sec.Catalog.controls).Count }
}

function Get-SelectionTitle {
    $stats = Get-SelectionStats
    if ($Sec.Preset) {
        if ($stats.Edited -gt 0) { return "$($Sec.Preset) (prilagođeno)" }
        return $Sec.Preset
    }
    if ($stats.Edited -gt 0) { return "Prilagođeno (temelj: $($LevelNames[$Sec.Level]))" }
    $LevelNames[$Sec.Level]
}

#endregion

#region Inicijalizacija

function Initialize-SecurityUi {
    $Sec.Catalog = Get-GpsControlCatalog
    foreach ($c in @($Sec.Catalog.controls)) { $Sec.Index[$c.id] = $c }
    foreach ($cat in @($Sec.Catalog.categories)) { $Sec.Categories[$cat.id] = $cat }
    $Sec.Selection = Get-GpsControlSelection -Catalog $Sec.Catalog -Level $Sec.Level
    Set-SelectionBaseline

    foreach ($level in 1..3) {
        $count = @((Get-GpsControlSelection -Catalog $Sec.Catalog -Level $level).Values | Where-Object { $_ }).Count
        $ui["txtLevel${level}Count"].Text = "UKLJUČUJE $count OD $(@($Sec.Catalog.controls).Count) POSTAVKI"
    }

    # Popis područja
    foreach ($cat in @($Sec.Catalog.categories)) {
        $item = [System.Windows.Controls.ListBoxItem]::new()
        $item.Height = 42
        $item.Padding = '16,0,12,0'
        $item.Tag = $cat.id
        $grid = [System.Windows.Controls.DockPanel]::new()
        $count = [System.Windows.Controls.TextBlock]::new()
        $count.FontFamily = Get-AuxBrush 'FontMono'
        $count.FontSize = 11
        $count.FontWeight = 'Bold'
        $count.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($count, 'Right')
        $null = $grid.Children.Add($count)
        $glyph = [System.Windows.Controls.Border]::new()
        $glyph.Width = 30; $glyph.Height = 20
        $glyph.BorderBrush = Get-AuxBrush 'Line'
        $glyph.BorderThickness = 1
        $glyph.Margin = '0,0,10,0'
        $glyphText = [System.Windows.Controls.TextBlock]::new()
        $glyphText.Text = [string](Get-GpsOptionalProperty $cat 'glyph')
        $glyphText.FontFamily = Get-AuxBrush 'FontMono'
        $glyphText.FontWeight = 'Bold'
        $glyphText.FontSize = 10
        $glyphText.HorizontalAlignment = 'Center'
        $glyphText.VerticalAlignment = 'Center'
        $glyph.Child = $glyphText
        $null = $grid.Children.Add($glyph)
        $title = [System.Windows.Controls.TextBlock]::new()
        $title.Text = $cat.title
        $title.VerticalAlignment = 'Center'
        $title.TextTrimming = 'CharacterEllipsis'
        $null = $grid.Children.Add($title)
        $item.Content = $grid
        $null = $ui.lbCategories.Items.Add($item)
        $Sec.CategoryItems[$cat.id] = @{ Item = $item; Count = $count }
    }

    foreach ($c in @($Sec.Catalog.controls)) {
        $row = New-ControlRow $c
        $null = $ui.pnlControls.Children.Add($row.Root)
        $Sec.Rows[$c.id] = $row
    }

    # Pločice ocjene na pregledu i na usporedbi
    foreach ($std in @($Sec.Catalog.standards)) {
        $short = Get-StandardShortName $std
        # Podnaslov pločice: kratka verzija standarda (npr. v5.0.1), cijeli naziv u opisu alata.
        $subtitle = [string](Get-GpsOptionalProperty $std 'version')
        if (-not $subtitle) { $subtitle = [string](Get-GpsOptionalProperty $std 'source') }
        $t1 = New-AuxScoreTile -Title $short -Subtitle $subtitle
        $null = $ui.pnlScoresOverview.Children.Add($t1.Root)
        $Sec.TilesOverview[$std.id] = $t1
        $t2 = New-AuxScoreTile -Title $short -Subtitle $subtitle
        foreach ($t in $t1, $t2) { $t.Root.ToolTip = [string](Get-GpsOptionalProperty $std 'source') }
        $null = $ui.pnlScoresCompare.Children.Add($t2.Root)
        $Sec.TilesCompare[$std.id] = $t2

        $rb = [System.Windows.Controls.RadioButton]::new()
        $rb.Style = Get-AuxBrush 'Segment'
        $rb.GroupName = 'standard'
        $rb.Content = $short
        $rb.Tag = [string]$std.id
        $rb.ToolTip = [string](Get-GpsOptionalProperty $std 'source')
        if ($std.id -eq $Sec.Standard) { $rb.IsChecked = $true }
        $rb.Add_Checked({ $Sec.Standard = $this.Tag; Update-ComparePage })
        $null = $ui.pnlStandardFilter.Children.Add($rb)
    }
    $Sec.CompareNote = "Katalog $([string](Get-GpsOptionalProperty $Sec.Catalog 'catalogVersion')). " +
        'Standardi sadrže stotine preporuka; ovdje se uspoređuju samo one koje GPO Studio može postaviti. Rezultat nije potvrda sukladnosti.'

    $ui.lbCategories.SelectedIndex = 0
    Update-PresetList
    Update-AllControlRows
    Update-Summary
}

function Get-StandardShortName($Standard) {
    switch ([string]$Standard.id) { 'CIS-L1' { 'CIS RAZINA 1' } 'CIS-L2' { 'CIS RAZINA 2' } 'MSB' { 'MICROSOFT BASELINE' } default { ([string]$Standard.title).ToUpperInvariant() } }
}

#endregion

#region Redak kontrole

function New-ControlRow($Control) {
    $first = Get-ControlFirstLevel $Control
    $root = [System.Windows.Controls.ContentControl]::new()
    $root.Style = Get-AuxBrush 'RedakKontrole'
    $root.Tag = if ($first) { Get-AuxBrush $LevelBrushNames[$first] } else { Get-AuxBrush 'Line' }

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $left = [System.Windows.Controls.StackPanel]::new()
    $left.Margin = '0,0,18,0'
    $title = New-AuxText $Control.title 'Tekst'
    $title.FontWeight = 'SemiBold'
    $title.FontSize = 14
    $null = $left.Children.Add($title)
    $null = $left.Children.Add((New-AuxText $Control.description 'TekstPrigusen' '0,3,0,0'))
    $impact = [string](Get-GpsOptionalProperty $Control 'impact')
    if ($impact) { $null = $left.Children.Add((New-AuxText "Utjecaj: $impact" 'Sitno' '0,4,0,0')) }
    $requirement = [string](Get-GpsOptionalProperty $Control 'requirement')
    if ($requirement) { $null = $left.Children.Add((New-AuxText "Uvjet: $requirement" 'Sitno' '0,2,0,0')) }

    $tags = [System.Windows.Controls.WrapPanel]::new()
    if ($first) {
        $null = $tags.Children.Add((New-AuxTag ($LevelNames[$first].ToUpperInvariant()) $LevelTagKinds[$first] "Uključeno od razine $($LevelNames[$first])"))
    }
    else { $null = $tags.Children.Add((New-AuxTag 'DODATNO' 'Neutral' 'Nije uključeno ni u jednu razinu; uključite ga ručno ako vam treba.')) }
    $seen = @{}
    foreach ($b in @(Get-GpsOptionalProperty $Control 'benchmarks')) {
        if (-not $b -or $seen.ContainsKey([string]$b.standard)) { continue }
        $seen[[string]$b.standard] = $true
        $text = switch ([string]$b.standard) { 'CIS-L1' { 'CIS L1' } 'CIS-L2' { 'CIS L2' } 'MSB' { 'MS BASELINE' } default { [string]$b.standard } }
        $null = $tags.Children.Add((New-AuxTag $text 'Neutral' "$($text): $($b.recommendation)"))
    }
    if ($requirement) { $null = $tags.Children.Add((New-AuxTag 'UVJET' 'Info' $requirement)) }
    if (Get-GpsOptionalProperty $Control 'requiresRestart') { $null = $tags.Children.Add((New-AuxTag 'RESTART' 'Restart' 'Promjena djeluje nakon ponovnog pokretanja računala.')) }
    if (Test-ControlUsesLocalOnly $Control) { $null = $tags.Children.Add((New-AuxTag 'SAMO LOKALNO' 'Neutral' 'Lozinke i revizija primjenjuju se na lokalni GP; u domenskom GPO-u još nisu podržane.')) }
    $manual = New-AuxTag 'IZVAN RAZINE' 'Info'
    $manual.Visibility = 'Collapsed'
    $null = $tags.Children.Add($manual)
    $null = $left.Children.Add($tags)

    $hint = New-AuxText '' 'Sitno' '0,6,0,0'
    $hint.Foreground = Get-AuxBrush 'Amber'
    $hint.Visibility = 'Collapsed'
    $null = $left.Children.Add($hint)
    $null = $grid.Children.Add($left)

    $right = [System.Windows.Controls.WrapPanel]::new()
    $right.VerticalAlignment = 'Center'
    $right.HorizontalAlignment = 'Right'
    $right.MaxWidth = 470
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    $optionControls = @{}
    $check = $null
    $options = @($Control.options)
    if ($options.Count -eq 1) {
        $check = [System.Windows.Controls.CheckBox]::new()
        $check.Style = Get-AuxBrush 'KvacicaVelika'
        $check.Content = ([string]$options[0].title).ToUpperInvariant()
        $check.Tag = @{ ControlId = $Control.id; OptionId = $options[0].id }
        $check.Add_Checked({ if (-not $Sec.Updating) { Set-ControlOption $this.Tag.ControlId $this.Tag.OptionId } })
        $check.Add_Unchecked({ if (-not $Sec.Updating) { Set-ControlOption $this.Tag.ControlId $null } })
        $null = $right.Children.Add($check)
    }
    else {
        foreach ($o in @(@{ id = $null; title = 'Ne mijenjaj' }) + $options) {
            $rb = [System.Windows.Controls.RadioButton]::new()
            $rb.Style = Get-AuxBrush 'Segment'
            $rb.GroupName = "kontrola-$($Control.id)"
            $rb.Content = ([string]$o.title).ToUpperInvariant()
            $rb.Margin = '0,3,6,3'
            $rb.Tag = @{ ControlId = $Control.id; OptionId = $o.id }
            if (-not $o.id) { $rb.ToolTip = 'Postavka se ne dira: računalo zadržava trenutno stanje.' }
            $rb.Add_Checked({ if (-not $Sec.Updating) { Set-ControlOption $this.Tag.ControlId $this.Tag.OptionId } })
            $null = $right.Children.Add($rb)
            $optionControls[[string]$o.id] = $rb
        }
    }
    $null = $grid.Children.Add($right)
    $root.Content = $grid

    $search = (@($Control.title, $Control.description, $impact) + @($options | ForEach-Object { $_.title })) -join ' '
    @{ Root = $root; Check = $check; Options = $optionControls; Hint = $hint; Manual = $manual; Search = $search.ToLowerInvariant(); Category = $Control.category }
}

function Update-ControlRow([string]$ControlId) {
    $row = $Sec.Rows[$ControlId]
    $control = $Sec.Index[$ControlId]
    $value = $Sec.Selection[$ControlId]
    $Sec.Updating = $true
    try {
        if ($row.Check) { $row.Check.IsChecked = [bool]$value }
        else { $row.Options[[string]$value].IsChecked = $true }
    }
    finally { $Sec.Updating = $false }

    $levelValue = Get-GpsControlLevelOption $control $Sec.Level
    if ([string]$value -ne [string]$levelValue) {
        $row.Hint.Text = "Razina $($LevelNames[$Sec.Level]) predlaže: $(Get-ControlLevelOptionTitle $control $Sec.Level)."
        $row.Hint.Visibility = 'Visible'
        $row.Manual.Visibility = 'Visible'
        $row.Manual.ToolTip = "Odabir se razlikuje od razine $($LevelNames[$Sec.Level]) (vaša promjena ili preset)."
    }
    else {
        $row.Hint.Visibility = 'Collapsed'
        $row.Manual.Visibility = 'Collapsed'
    }
}

function Update-AllControlRows {
    foreach ($id in @($Sec.Rows.Keys)) { Update-ControlRow $id }
    Update-ControlFilter
}

function Update-ControlFilter {
    $search = $ui.txtControlSearch.Text.Trim().ToLowerInvariant()
    $onlySelected = [bool]$ui.rbFilterSelected.IsChecked
    $onlyChanged = [bool]$ui.rbFilterChanged.IsChecked
    $visible = 0
    foreach ($c in @($Sec.Catalog.controls)) {
        $row = $Sec.Rows[$c.id]
        $show = if ($search) { $row.Search.Contains($search) } elseif ($onlySelected -or $onlyChanged) { $true } else { $row.Category -eq $Sec.Category }
        if ($show -and $onlySelected) { $show = [bool]$Sec.Selection[$c.id] }
        if ($show -and $onlyChanged) { $show = [string]$Sec.Selection[$c.id] -ne [string](Get-GpsControlLevelOption $c $Sec.Level) }
        $row.Root.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
        if ($show) { $visible++ }
    }
    if ($search) {
        $ui.txtCategoryTitle.Text = 'Rezultati pretrage'
        $ui.txtCategoryDesc.Text = "Postavki koje sadrže '$($ui.txtControlSearch.Text.Trim())': $visible."
    }
    elseif ($onlySelected -or $onlyChanged) {
        $ui.txtCategoryTitle.Text = if ($onlySelected) { 'Uključene postavke' } else { 'Postavke izvan odabrane razine' }
        $ui.txtCategoryDesc.Text = "Iz svih područja: $visible."
    }
    elseif ($Sec.Category) {
        $cat = $Sec.Categories[$Sec.Category]
        $ui.txtCategoryTitle.Text = $cat.title
        $ui.txtCategoryDesc.Text = [string](Get-GpsOptionalProperty $cat 'description')
    }
    $ui.svControls.ScrollToTop()
}

#endregion

#region Promjene odabira

function Set-ControlOption([string]$ControlId, $OptionId) {
    $Sec.Selection[$ControlId] = if ($OptionId) { [string]$OptionId } else { $null }
    Update-ControlRow $ControlId
    Request-SummaryUpdate
}

$SummaryTimer = [System.Windows.Threading.DispatcherTimer]::new()
$SummaryTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$SummaryTimer.Add_Tick({ $SummaryTimer.Stop(); Update-Summary })
function Request-SummaryUpdate { $SummaryTimer.Stop(); $SummaryTimer.Start() }

function Test-HasManualChanges { (Get-SelectionStats).Edited -gt 0 }

function Set-SelectionBaseline {
    $Sec.Baseline = [ordered]@{}
    foreach ($k in @($Sec.Selection.Keys)) { $Sec.Baseline[$k] = $Sec.Selection[$k] }
}

function Set-SecurityLevel([int]$Level, [switch]$Force) {
    if (-not $Force -and (Test-HasManualChanges)) {
        $answer = Show-AuxDialog -Title 'Promjena razine' -Kind Warning -Buttons @('PROMIJENI RAZINU', 'ODUSTANI') `
            -Message "Imate ručne promjene u trenutnom odabiru. Odabir razine $($LevelNames[$Level]) ih poništava. Nastaviti?"
        if ($answer -ne 'PROMIJENI RAZINU') { Sync-LevelRadio; return }
    }
    $Sec.Level = $Level
    $Sec.Preset = $null
    $Sec.Selection = Get-GpsControlSelection -Catalog $Sec.Catalog -Level $Level
    Set-SelectionBaseline
    Sync-LevelRadio
    Update-AllControlRows
    Update-Summary
    Write-UiLog "Odabrana razina: $($LevelNames[$Level])."
}

function Sync-LevelRadio {
    $Sec.Updating = $true
    try { foreach ($l in 1..3) { $ui["rbLevel$l"].IsChecked = ($l -eq $Sec.Level) } }
    finally { $Sec.Updating = $false }
}

function Use-ControlPreset($Preset) {
    if ((Test-HasManualChanges) -and (Show-AuxDialog -Title 'Učitavanje preseta' -Kind Warning -Buttons @('UČITAJ', 'ODUSTANI') `
                -Message "Učitavanje preseta '$($Preset.Name)' zamjenjuje trenutni odabir. Nastaviti?") -ne 'UČITAJ') { return }
    $Sec.Level = $Preset.Level
    $Sec.Selection = Resolve-GpsControlPreset -Catalog $Sec.Catalog -Preset $Preset -WarningVariable presetWarnings -WarningAction SilentlyContinue
    foreach ($w in $presetWarnings) { Write-UiLog "Preset '$($Preset.Name)': $w" -Level Warning }
    $Sec.Preset = "Preset: $($Preset.Name)"
    Set-SelectionBaseline
    Sync-LevelRadio
    Update-AllControlRows
    Update-Summary
    Write-UiLog "Učitan preset '$($Preset.Name)' (razina $($LevelNames[$Preset.Level]), promjena: $($Preset.Changes.Count))." -Level Ok
}

#endregion

#region Sažetak, pločice, usporedba

function Update-Summary {
    $stats = Get-SelectionStats
    $title = Get-SelectionTitle
    $ui.txtSelectionTitle.Text = $title
    $areas = @($Sec.Catalog.categories | Where-Object { $cid = $_.id; @($Sec.Catalog.controls | Where-Object { $_.category -eq $cid -and $Sec.Selection[$_.id] }).Count -gt 0 }).Count
    $ui.txtSelectionInfo.Text = "$($stats.Enabled) od $($stats.Total) postavki u $areas područja" + $(if ($stats.Edited) { "  ·  ručnih promjena: $($stats.Edited)" })
    $ui.txtSummaryNote.Text = "$($stats.Enabled) POSTAVKI"

    $ui.pnlSummary.Children.Clear()
    foreach ($cat in @($Sec.Catalog.categories)) {
        $controls = @($Sec.Catalog.controls | Where-Object category -eq $cat.id)
        $on = @($controls | Where-Object { $Sec.Selection[$_.id] }).Count
        $Sec.CategoryItems[$cat.id].Count.Text = "$on/$($controls.Count)"
        $Sec.CategoryItems[$cat.id].Count.Foreground = Get-AuxBrush $(if ($on) { 'Amber' } else { 'Muted2' })

        $row = [System.Windows.Controls.Grid]::new()
        $row.Margin = '0,0,0,7'
        foreach ($w in '180', '*', '58') {
            $cd = [System.Windows.Controls.ColumnDefinition]::new()
            $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::new([double]$w) }
            $row.ColumnDefinitions.Add($cd)
        }
        $name = New-AuxText $cat.title 'Sitno'
        $name.TextWrapping = 'NoWrap'; $name.TextTrimming = 'CharacterEllipsis'
        $null = $row.Children.Add($name)
        $track = [System.Windows.Controls.Grid]::new()
        $track.Height = 6; $track.Margin = '8,0'; $track.VerticalAlignment = 'Center'
        $track.Background = Get-AuxBrush 'Line'
        $fill = [System.Windows.Shapes.Rectangle]::new()
        $fill.HorizontalAlignment = 'Left'
        $fill.Fill = Get-AuxBrush 'Amber'
        $ratio = if ($controls.Count) { $on / $controls.Count } else { 0 }
        $pct = [System.Windows.Controls.ColumnDefinition]::new(); $pct.Width = [System.Windows.GridLength]::new([math]::Max($ratio, 0.0001), [System.Windows.GridUnitType]::Star)
        $rest = [System.Windows.Controls.ColumnDefinition]::new(); $rest.Width = [System.Windows.GridLength]::new([math]::Max(1 - $ratio, 0.0001), [System.Windows.GridUnitType]::Star)
        $track.ColumnDefinitions.Add($pct); $track.ColumnDefinitions.Add($rest)
        if ($on) { $null = $track.Children.Add($fill); $fill.HorizontalAlignment = 'Stretch' }
        [System.Windows.Controls.Grid]::SetColumn($track, 1)
        $null = $row.Children.Add($track)
        $count = New-AuxText "$on od $($controls.Count)" 'Sitno'
        $count.TextAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetColumn($count, 2)
        $null = $row.Children.Add($count)
        $null = $ui.pnlSummary.Children.Add($row)
    }

    foreach ($r in @(Get-GpsControlCompliance -Catalog $Sec.Catalog -Selection $Sec.Selection)) {
        if ($Sec.TilesOverview.ContainsKey($r.Id)) { Update-AuxScoreTile $Sec.TilesOverview[$r.Id] $r.Score $r.Satisfied $r.Total }
    }

    $ui.chipLevel.Content = 'RAZINA: ' + $LevelNames[$Sec.Level].ToUpperInvariant() + $(if ($stats.Changed) { ' + IZMJENE' })
    $ui.stSelection.Text = "$($stats.Enabled) POSTAVKI  ·  $($title.ToUpperInvariant())"
    Update-ActionSource
    if ($ui.pgUsporedba.Visibility -eq 'Visible') { Update-ComparePage }
}

function Update-ComparePage {
    $useState = [bool]$ui.rbCmpState.IsChecked -and $Sec.Detected
    $selection = if ($useState) { $Sec.Detected.Selection } else { $Sec.Selection }
    $results = @(Get-GpsControlCompliance -Catalog $Sec.Catalog -Selection $selection)
    foreach ($r in $results) {
        if ($Sec.TilesCompare.ContainsKey($r.Id)) { Update-AuxScoreTile $Sec.TilesCompare[$r.Id] $r.Score $r.Satisfied $r.Total }
    }
    $current = $results | Where-Object Id -eq $Sec.Standard | Select-Object -First 1
    $notSetText = if ($useState) { 'Nije postavljeno' } else { 'Ne mijenja se' }
    $rows = foreach ($row in @($current.Rows)) {
        [pscustomobject]@{
            Category       = $row.Category
            Control        = $row.Control
            Source         = switch ($row.Source) { 'CIS-L1' { 'CIS L1' } 'CIS-L2' { 'CIS L2' } 'MSB' { 'MS BASELINE' } default { $row.Source } }
            Reference      = $row.Reference
            Recommendation = $row.Recommendation
            SelectedText   = if ($row.Selected) { $row.Selected } else { $notSetText }
            Status         = $row.Status
            StatusText     = $StatusTexts[$row.Status]
        }
    }
    $ui.txtCompareNote.Text = $Sec.CompareNote + $(if ($current.Note) { ' ' + $current.Note })
    $ui.dgCompliance.ItemsSource = @($rows | Sort-Object @{ Expression = { switch ($_.Status) { 'Deviates' { 0 } 'NotSet' { 1 } default { 2 } } } }, Category)
}

function Update-ActionSource {
    if (-not $ui.txtActionSource) { return }
    if ($ui.pgNapredno.Visibility -eq 'Visible') {
        $ui.txtActionSource.Text = "Napredni Policy Set '$($ui.txtSetName.Text)': $($State.Settings.Count) postavki"
    }
    else {
        $stats = Get-SelectionStats
        $ui.txtActionSource.Text = "Sigurnosne postavke: $(Get-SelectionTitle), $($stats.Enabled) postavki"
    }
}

#endregion

#region Preseti

function Update-PresetList {
    $Sec.Presets = @(Get-GpsControlPreset -WarningVariable presetWarnings -WarningAction SilentlyContinue)
    foreach ($w in $presetWarnings) { Write-UiLog "$w" -Level Warning }
    $ui.txtPresetFolder.Text = "Vlastiti preseti spremaju se u $(Get-GpsControlPresetFolder) i dijele ih svi administratori ovog računala."

    $ui.pnlQuickPresets.Children.Clear()
    foreach ($p in @($Sec.Presets | Where-Object { $_.BuiltIn -and $_.Changes.Count -gt 0 })) {
        $b = [System.Windows.Controls.Button]::new()
        $b.Style = Get-AuxBrush 'GumbTraka'
        $b.Content = $p.Name.ToUpperInvariant()
        $b.Margin = '0,0,8,6'
        $b.ToolTip = $p.Description
        $b.Tag = $p
        $b.Add_Click({ Use-ControlPreset $this.Tag })
        $null = $ui.pnlQuickPresets.Children.Add($b)
    }

    $ui.pnlPresets.Children.Clear()
    foreach ($p in $Sec.Presets) {
        $card = [System.Windows.Controls.HeaderedContentControl]::new()
        $card.Style = Get-AuxBrush 'Kartica'
        $card.Header = if ($p.BuiltIn) { 'UGRAĐENI PRESET' } else { 'VLASTITI PRESET' }
        $card.Margin = '0,0,10,10'
        $stack = [System.Windows.Controls.StackPanel]::new()
        $name = New-AuxText $p.Name 'Naslov'
        $name.FontSize = 16
        $null = $stack.Children.Add($name)
        $desc = New-AuxText $p.Description 'TekstPrigusen' '0,4,0,0'
        $desc.Height = 54
        $desc.TextTrimming = 'WordEllipsis'
        $desc.ToolTip = $p.Description
        $null = $stack.Children.Add($desc)
        $tags = [System.Windows.Controls.WrapPanel]::new()
        if ($p.Level) { $null = $tags.Children.Add((New-AuxTag ("TEMELJ: " + $LevelNames[$p.Level].ToUpperInvariant()) $LevelTagKinds[$p.Level])) }
        $null = $tags.Children.Add((New-AuxTag ("PROMJENA: $($p.Changes.Count)") 'Neutral'))
        $selection = Resolve-GpsControlPreset -Catalog $Sec.Catalog -Preset $p -WarningAction SilentlyContinue
        $null = $tags.Children.Add((New-AuxTag ("POSTAVKI: " + @($selection.Values | Where-Object { $_ }).Count) 'Neutral'))
        $null = $stack.Children.Add($tags)
        $buttons = [System.Windows.Controls.WrapPanel]::new()
        $buttons.Margin = '0,12,0,0'
        $load = [System.Windows.Controls.Button]::new(); $load.Style = Get-AuxBrush 'GumbPrimarni'; $load.Content = 'UČITAJ'; $load.Tag = $p; $load.Margin = '0,0,8,0'
        $load.Add_Click({ Use-ControlPreset $this.Tag; Show-Page 'Pregled' })
        $export = [System.Windows.Controls.Button]::new(); $export.Content = 'IZVEZI…'; $export.Tag = $p; $export.Margin = '0,0,8,0'
        $export.Add_Click({ Export-UiPreset $this.Tag })
        $null = $buttons.Children.Add($load); $null = $buttons.Children.Add($export)
        if (-not $p.BuiltIn) {
            $delete = [System.Windows.Controls.Button]::new(); $delete.Style = Get-AuxBrush 'GumbOpasni'; $delete.Content = 'OBRIŠI'; $delete.Tag = $p
            $delete.Add_Click({ Remove-UiPreset $this.Tag })
            $null = $buttons.Children.Add($delete)
        }
        $null = $stack.Children.Add($buttons)
        $card.Content = $stack
        $null = $ui.pnlPresets.Children.Add($card)
    }
}

function Save-UiPreset {
    $result = Show-AuxInput -Title 'Spremi preset' -Message "Sprema se razina $($LevelNames[$Sec.Level]) i vaše promjene u odnosu na nju." `
        -Fields ([ordered]@{ 'Naziv' = ''; 'Opis' = '' })
    if (-not $result) { return }
    if (-not $result['Naziv']) { $null = Show-AuxDialog -Message 'Upišite naziv preseta.' -Kind Warning; return }
    $preset = New-GpsControlPreset -Catalog $Sec.Catalog -Name $result['Naziv'] -Description $result['Opis'] -Level $Sec.Level -Selection $Sec.Selection
    try { $path = Export-GpsControlPreset -Preset $preset }
    catch {
        if ((Show-AuxDialog -Title 'Spremi preset' -Kind Warning -Buttons @('ZAMIJENI', 'ODUSTANI') -Message "Preset s nazivom '$($preset.Name)' već postoji. Zamijeniti ga?") -ne 'ZAMIJENI') { return }
        $path = Export-GpsControlPreset -Preset $preset -Force
    }
    $Sec.Preset = "Preset: $($preset.Name)"
    Set-SelectionBaseline
    Write-UiLog "Preset spremljen: $path" -Level Ok
    Update-PresetList
    Update-Summary
}

function Import-UiPreset {
    $dlg = [Microsoft.Win32.OpenFileDialog]@{ Filter = 'GPO Studio preset (*.json)|*.json'; Title = 'Uvezi preset' }
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        $preset = Import-GpsControlPreset -Path $dlg.FileName
        $null = Resolve-GpsControlPreset -Catalog $Sec.Catalog -Preset $preset -WarningVariable w -WarningAction SilentlyContinue
        foreach ($m in $w) { Write-UiLog "Preset '$($preset.Name)': $m" -Level Warning }
        $target = Join-Path (Get-GpsControlPresetFolder) ([IO.Path]::GetFileName($dlg.FileName))
        if ((Test-Path -LiteralPath $target) -and
            (Show-AuxDialog -Title 'Uvezi preset' -Kind Warning -Buttons @('ZAMIJENI', 'ODUSTANI') -Message "Preset '$([IO.Path]::GetFileName($target))' već postoji. Zamijeniti ga?") -ne 'ZAMIJENI') { return }
        $null = Export-GpsControlPreset -Preset $preset -Path $target -Force:$true -ErrorAction Stop
        Write-UiLog "Uvezen preset '$($preset.Name)'." -Level Ok
        Update-PresetList
    }
    catch { $null = Show-AuxDialog -Title 'Uvezi preset' -Message 'Datoteka nije ispravan preset.' -Details "$_" -Kind Danger }
}

function Export-UiPreset($Preset) {
    $dlg = [Microsoft.Win32.SaveFileDialog]@{ Filter = 'GPO Studio preset (*.json)|*.json'; FileName = (($Preset.Name -replace '[\\/:*?"<>|]', '-') + '.json') }
    if (-not $dlg.ShowDialog($window)) { return }
    $null = Export-GpsControlPreset -Preset $Preset -Path $dlg.FileName -Force
    Write-UiLog "Preset '$($Preset.Name)' izvezen: $($dlg.FileName)" -Level Ok
}

function Remove-UiPreset($Preset) {
    if ((Show-AuxDialog -Title 'Obriši preset' -Kind Danger -Buttons @('OBRIŠI', 'ODUSTANI') -Message "Obrisati preset '$($Preset.Name)'?") -ne 'OBRIŠI') { return }
    Remove-Item -LiteralPath $Preset.Path -Force
    Write-UiLog "Preset '$($Preset.Name)' obrisan."
    Update-PresetList
}

#endregion

#region Provjera stanja računala

function Start-ComputerCheck {
    $target = Get-UiTarget
    $computer = $null
    $note = ''
    switch ($target.Mode) {
        'Remote' {
            if (-not $target.Computers) { $null = Show-AuxDialog -Message 'Upišite naziv računala u traku CILJ.' -Kind Warning; return }
            $computer = $target.Computers[0]
            if ($target.Computers.Count -gt 1) { $note = " Provjerava se samo prvo računalo ($computer)." }
        }
        'Domain' { $note = ' Za domenski GPO provjerava se ovo računalo (stvarno stanje uključuje i domenske GPO-ove).' }
    }
    $cmd = 'Get-GpsControlState -Catalog (Get-GpsControlCatalog)' + $(if ($computer) { " -ComputerName $computer" })
    Start-UiJob -Title 'Provjera računala' -Command $cmd -Arguments @($Sec.Catalog, $computer) -Context $note -ScriptBlock {
        param($catalog, $computer)
        $p = @{ Catalog = $catalog }
        if ($computer) { $p.ComputerName = $computer }
        Get-GpsControlState @p
    } -OnSuccess {
        param($result, $note)
        $state = @($result) | Select-Object -First 1
        if (-not $state) { Write-UiLog 'Provjera nije vratila rezultat.' -Level Warning; return }
        $Sec.Detected = $state
        foreach ($m in @($state.Messages)) { Write-UiLog "$($state.ComputerName): $m" -Level Warning }
        $unknown = @($state.Details | Where-Object Status -eq 'Unknown').Count
        $detected = @($state.Details | Where-Object Status -eq 'Detected').Count
        $reasons = @()
        if (-not $state.UserIncluded) { $reasons += 'korisnički dio se na udaljenom računalu ne provjerava' }
        if (@($state.Messages) -match 'secedit') { $reasons += 'lozinke nisu pročitane' }
        if (@($state.Messages) -match 'auditpol') { $reasons += 'revizija nije pročitana' }
        $ui.txtStateInfo.Text = "Računalo $($state.ComputerName), provjereno $((Get-Date).ToString('dd.MM.yyyy. HH:mm')): prepoznato $detected postavki" +
            $(if ($unknown) { ", $unknown se ne može provjeriti" + $(if ($reasons) { ' (' + ($reasons -join '; ') + ')' }) }) + '.' +
            $(if ($state.UserName) { " Korisnički dio provjeren za račun $($state.UserName)." }) + $note
        $ui.rbCmpState.IsEnabled = $true
        $ui.rbCmpState.IsChecked = $true
        $ui.btnUseState.IsEnabled = $true
        Update-ComparePage
    }
}

function Use-DetectedState {
    if (-not $Sec.Detected) { return }
    $unknown = @($Sec.Detected.Details | Where-Object Status -eq 'Unknown').Count
    if ((Show-AuxDialog -Title 'Preuzmi stanje' -Kind Warning -Buttons @('PREUZMI', 'ODUSTANI') `
                -Message ("Odabir će se postaviti na stanje računala $($Sec.Detected.ComputerName). Postavke koje na računalu nisu postavljene bit će 'Ne mijenjaj'." +
                $(if ($unknown) { " Postavke koje se nisu mogle provjeriti ($unknown) ostaju kako su sada odabrane." }) + ' Nastaviti?')) -ne 'PREUZMI') { return }
    # Nepoznato stanje (npr. korisnički dio udaljenog računala) ne mijenja trenutni odabir.
    foreach ($d in @($Sec.Detected.Details)) { if ($d.Status -ne 'Unknown') { $Sec.Selection[$d.ControlId] = $d.OptionId } }
    $Sec.Preset = "Stanje računala $($Sec.Detected.ComputerName)"
    Set-SelectionBaseline
    Update-AllControlRows
    Update-Summary
    Write-UiLog "Odabir preuzet sa stanja računala $($Sec.Detected.ComputerName)." -Level Ok
}

#endregion

#region Izvještaj

function Export-UiComplianceReport {
    $useState = [bool]$ui.rbCmpState.IsChecked -and $Sec.Detected
    $selection = if ($useState) { $Sec.Detected.Selection } else { $Sec.Selection }
    $subject = if ($useState) { "Računalo $($Sec.Detected.ComputerName)" } else { "Odabir: $(Get-SelectionTitle)" }
    $name = if ($useState) { "GPO Studio - $($Sec.Detected.ComputerName)" } else { 'GPO Studio - odabir' }
    $dlg = [Microsoft.Win32.SaveFileDialog]@{ Filter = 'HTML izvještaj (*.html)|*.html'; FileName = ("{0} {1:yyyy-MM-dd}.html" -f $name, (Get-Date)) }
    if (-not $dlg.ShowDialog($window)) { return }
    $html = ConvertTo-GpsComplianceHtml -Catalog $Sec.Catalog -Selection $selection -Subject $subject -NotSetText $(if ($useState) { 'Nije postavljeno' } else { 'Ne mijenja se' })
    [IO.File]::WriteAllText($dlg.FileName, $html, [Text.UTF8Encoding]::new($true))
    Write-UiLog "Izvještaj spremljen: $($dlg.FileName)" -Level Ok
    try { Start-Process -FilePath $dlg.FileName } catch { }
}

#endregion
