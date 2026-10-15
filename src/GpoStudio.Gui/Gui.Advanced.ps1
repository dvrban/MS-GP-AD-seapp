<#
    Napredni uređivač: katalog ADMX politika s pretragom (kao gpedit.msc) i vlastiti Policy Set.
    Učitava ga Start-GpoStudio.ps1 (dot-source).
#>

$State = @{
    Catalog       = @()
    CatalogLoaded = $false
    Settings      = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    Extra         = @{ security = [ordered]@{}; audit = [ordered]@{} }
    # Opis i verzija učitanog seta; GUI ih ne uređuje, ali ih čuva pri spremanju.
    Meta          = @{ description = ''; version = '1.0.0' }
}

function Get-UiAdvancedPolicySet {
    $set = New-GpsPolicySet -Name $ui.txtSetName.Text -Description $State.Meta.description -Version $State.Meta.version -Setting @($State.Settings)
    foreach ($section in 'security', 'audit') {
        foreach ($k in $State.Extra[$section].Keys) { $set.$section[$k] = $State.Extra[$section][$k] }
    }
    $set
}

function Update-CatalogTree {
    $ui.tvCatalog.Items.Clear()
    $filter = $ui.txtSearch.Text.Trim()
    $items = $State.Catalog
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
        $State.Catalog = @($result)
        $State.CatalogLoaded = $true
        Update-CatalogTree
        Write-UiLog "Katalog učitan: $($State.Catalog.Count) politika."
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

function Show-ElementDialog($Policy) {
    $dlg = New-AuxDialogWindow -Title $Policy.DisplayName -Width 500
    $panel = [System.Windows.Controls.StackPanel]::new()
    $controls = @{}

    foreach ($el in @($Policy.Elements | Where-Object ValueName)) {
        $label = "$($el.Id)" + $(if ($el.Required) { ' *' }) + $(if ($el.Kind -eq 'decimal' -and $el.MaxValue) { " ($($el.MinValue)–$($el.MaxValue))" })
        $null = $panel.Children.Add((New-AuxText $label.ToUpperInvariant() 'EyebrowPrigusen' '0,10,0,4'))
        $control = switch ($el.Kind) {
            'enum' {
                $c = [System.Windows.Controls.ComboBox]::new()
                foreach ($i in $el.Items) { $null = $c.Items.Add($i.DisplayName) }
                $c.SelectedIndex = 0
                $c
            }
            'boolean' { $c = [System.Windows.Controls.CheckBox]::new(); $c.Content = 'Uključeno'; $c }
            'multiText' { $c = [System.Windows.Controls.TextBox]::new(); $c.AcceptsReturn = $true; $c.Height = 90; $c.VerticalScrollBarVisibility = 'Auto'; $c.VerticalContentAlignment = 'Top'; $c }
            default {
                $c = [System.Windows.Controls.TextBox]::new()
                $c.Text = if ($el.Kind -eq 'decimal' -and $el.MinValue) { $el.MinValue } else { '' }
                $c
            }
        }
        $null = $panel.Children.Add($control)
        $controls[$el.Id] = @{ Kind = $el.Kind; Control = $control }
    }

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $ok = [System.Windows.Controls.Button]::new(); $ok.Content = 'U REDU'; $ok.Style = Get-AuxBrush 'GumbPrimarni'; $ok.IsDefault = $true
    $ok.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); $w.Tag = 'OK'; $w.Close() })
    $cancel = [System.Windows.Controls.Button]::new(); $cancel.Content = 'ODUSTANI'; $cancel.IsCancel = $true; $cancel.Margin = '8,0,0,0'
    $null = $buttons.Children.Add($ok); $null = $buttons.Children.Add($cancel)
    $dlg.Content = New-AuxDialogFrame -Eyebrow 'VRIJEDNOSTI POLITIKE' -Body $panel -Buttons $buttons
    $null = $dlg.ShowDialog()
    if ($dlg.Tag -ne 'OK') { return $null }

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

function Add-SelectedPolicy([string]$PolicyState) {
    $selected = $ui.tvCatalog.SelectedItem
    if (-not $selected -or -not $selected.Tag) { $null = Show-AuxDialog -Message 'Odaberite politiku u katalogu.'; return }
    $policy = $selected.Tag.Policy

    $values = @{}
    if ($PolicyState -eq 'Enabled' -and @($policy.Elements | Where-Object ValueName).Count -gt 0) {
        $values = Show-ElementDialog $policy
        if ($null -eq $values) { return }
    }

    try {
        $new = @(ConvertTo-GpsPolicySetting -Policy $policy -State $PolicyState -Scope $selected.Tag.Scope -ElementValues $values `
                -WarningVariable conversionWarnings -WarningAction SilentlyContinue)
    }
    catch { $null = Show-AuxDialog -Message "$_" -Kind Warning; return }
    foreach ($w in $conversionWarnings) { Write-UiLog "$w" -Level Warning }

    # Prvo uklanjamo ranije postavke iste politike u istom scopeu (isti id ili id s istim prefiksom),
    # a zatim i postavke drugih politika koje pišu istu vrijednost.
    $idBase = "$($policy.Source)/$($policy.Name)"
    $idPattern = "$([WildcardPattern]::Escape($idBase))/*"
    $scope = $selected.Tag.Scope
    foreach ($s in $new) {
        $existing = @($State.Settings | Where-Object {
                ($_.scope -eq $scope -and ($_.id -eq $idBase -or $_.id -like $idPattern)) -or
                ($_.scope -eq $s.scope -and $_.key -eq $s.key -and $_.valueName -eq $s.valueName)
            })
        foreach ($e in $existing) { $null = $State.Settings.Remove($e) }
    }
    foreach ($s in $new) { $State.Settings.Add($s) }
    Write-UiLog "Dodano ($PolicyState): $($policy.DisplayName), $($new.Count) vrijednosti."
    Update-ActionSource
}

function Open-UiAdvancedPolicySet {
    $dlg = [Microsoft.Win32.OpenFileDialog]@{ Filter = 'Policy Set (*.json)|*.json'; Title = 'Otvori Policy Set' }
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        $set = Import-GpsPolicySet -Path $dlg.FileName
        $State.Settings.Clear()
        foreach ($s in $set.settings) { $State.Settings.Add($s) }
        $State.Extra = @{ security = $set.security; audit = $set.audit }
        $State.Meta = @{ description = $set.description; version = $set.version }
        $ui.txtSetName.Text = $set.name
        Write-UiLog "Učitan Policy Set '$($set.name)' ($($set.settings.Count) postavki, security: $($set.security.Count), audit: $($set.audit.Count))." -Level Ok
        Update-ActionSource
    }
    catch { $null = Show-AuxDialog -Title 'Otvori Policy Set' -Message 'Datoteka se ne može učitati.' -Details "$_" -Kind Danger }
}

function Save-UiAdvancedPolicySet {
    if (-not $ui.txtSetName.Text.Trim()) { $null = Show-AuxDialog -Message 'Upišite naziv Policy Seta.' -Kind Warning; return }
    $dlg = [Microsoft.Win32.SaveFileDialog]@{ Filter = 'Policy Set (*.json)|*.json'; FileName = "$($ui.txtSetName.Text.Trim()).json" }
    if (-not $dlg.ShowDialog($window)) { return }
    try {
        Export-GpsPolicySet -PolicySet (Get-UiAdvancedPolicySet) -Path $dlg.FileName -ErrorAction Stop
        Write-UiLog "Spremljeno: $($dlg.FileName)" -Level Ok
    }
    catch { $null = Show-AuxDialog -Title 'Spremi Policy Set' -Kind Danger -Message 'Policy Set se ne može spremiti.' -Details "$_" }
}
