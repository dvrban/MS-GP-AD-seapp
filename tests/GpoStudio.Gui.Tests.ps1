# GUI test: gradi prozor bez prikaza (WPF traži Windows PowerShell 5.1 i STA dretvu), prolazi kroz
# razine, presete, kontrole i stranice te sprema snimke stranica (GPS_SCREENSHOT_DIR) za pregled izgleda.
$canRun = $PSVersionTable.PSEdition -eq 'Desktop' -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

Describe 'GUI (WPF)' -Skip:(-not $canRun) {
    BeforeAll {
        $guiScript = Join-Path $PSScriptRoot '..\src\GpoStudio.Gui\Start-GpoStudio.ps1'
        . $guiScript -NoShow
        $shots = if ($env:GPS_SCREENSHOT_DIR) { $env:GPS_SCREENSHOT_DIR } else { Join-Path $TestDrive 'shots' }
        $null = New-Item -ItemType Directory -Path $shots -Force

        function Save-PageShot([string]$Page, [string]$File) {
            Show-Page $Page
            $root = $window.Content
            $size = [System.Windows.Size]::new(1320, 860)
            $root.Measure($size)
            $root.Arrange([System.Windows.Rect]::new($size))
            $root.UpdateLayout()
            $bmp = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(1320, 860, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($root)
            $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $path = Join-Path $shots $File
            $stream = [IO.File]::Create($path)
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
            $path
        }
    }

    It 'učitava prozor i sve imenovane elemente' {
        $window | Should -Not -BeNullOrEmpty
        @($ui.Keys | Where-Object { $null -eq $ui[$_] }) | Should -BeNullOrEmpty
        $ui.Count | Should -BeGreaterThan 60
    }

    It 'počinje s razinom Preporučeno i gradi redak za svaku kontrolu' {
        $Sec.Level | Should -Be 2
        $Sec.Rows.Count | Should -Be @($Sec.Catalog.controls).Count
        $ui.pnlControls.Children.Count | Should -Be @($Sec.Catalog.controls).Count
        $ui.txtLevel2Count.Text | Should -Match 'UKLJUČUJE \d+ OD \d+'
        $ui.lbCategories.Items.Count | Should -Be @($Sec.Catalog.categories).Count
    }

    It 'klik na opciju mijenja odabir i označava ručnu promjenu' {
        $Sec.Rows['usb.storage'].Options['blocked'].IsChecked = $true
        $Sec.Selection['usb.storage'] | Should -Be 'blocked'
        $Sec.Rows['usb.storage'].Manual.Visibility | Should -Be 'Visible'
        Test-HasManualChanges | Should -BeTrue

        $check = @($Sec.Rows.Values | Where-Object { $_.Check } | Select-Object -First 1)[0]
        $id = $check.Check.Tag.ControlId
        $check.Check.IsChecked = -not $check.Check.IsChecked
        [bool]$Sec.Selection[$id] | Should -Be ([bool]$check.Check.IsChecked)
    }

    It 'promjena razine bez potvrde (Force) vraća zadane opcije' {
        Set-SecurityLevel 3 -Force
        $Sec.Level | Should -Be 3
        $Sec.Selection['usb.storage'] | Should -Be (Get-GpsControlLevelOption $Sec.Index['usb.storage'] 3)
        Test-HasManualChanges | Should -BeFalse
        $ui.rbLevel3.IsChecked | Should -BeTrue
        $null = Save-PageShot 'Sigurnost' '02-sigurnosne-postavke-strogo.png'
        Set-SecurityLevel 2 -Force
    }

    It 'preset postavlja razinu i promjene' {
        $kiosk = $Sec.Presets | Where-Object { $_.Changes.Count -gt 0 } | Select-Object -First 1
        Use-ControlPreset $kiosk
        $Sec.Level | Should -Be $kiosk.Level
        foreach ($k in $kiosk.Changes.Keys) { $Sec.Selection[$k] | Should -Be $kiosk.Changes[$k] }
        Get-SelectionTitle | Should -Match ([regex]::Escape($kiosk.Name))
        Get-SelectionTitle | Should -Not -Match 'prilagođeno'
        Test-HasManualChanges | Should -BeFalse
        $first = @($kiosk.Changes.Keys)[0]
        $Sec.Rows[$first].Manual.Visibility | Should -Be 'Visible'
        Update-Summary
        $null = Save-PageShot 'Pregled' '01-pregled-preset.png'
    }

    It 'aktivni Policy Set dolazi iz sigurnosnih postavki' {
        $active = Get-UiActivePolicySet
        @($active.Set.settings).Count | Should -BeGreaterThan 10
        $active.Set.security.Count | Should -BeGreaterThan 0
        $active.Source | Should -Match 'sigurnosne postavke'
    }

    It 'izvor primjene ostaje isti na stranicama Promjene i Dnevnik' {
        $Gui.ActionSource = 'Advanced'
        Show-Page 'Promjene'
        $Gui.ActionSource | Should -Be 'Advanced'
        (Get-UiActivePolicySet).Source | Should -Match 'napredni'
        Show-Page 'Dnevnik'
        $Gui.ActionSource | Should -Be 'Advanced'
        Show-Page 'Pregled'
        $Gui.ActionSource | Should -Be 'Security'
    }

    It 'neuspjela primjena i računalo koje nije odgovorilo nisu prikazani kao uspjeh' {
        $active = Get-UiActivePolicySet
        $first = @($active.Set.settings)[0]
        $failedResult = [pscustomobject]@{
            ComputerName = 'PC01'; Status = 'Error'; BackupPath = $null; Messages = @('Greška: pristup odbijen')
            Diff = @([pscustomobject]@{ Status = 'Added'; Scope = $first.scope; Key = $first.key; ValueName = $first.valueName; Current = $null; Desired = "$($first.data)"; Action = 'Set' })
        }
        Show-UiChanges -Results @($failedResult) -Active $active -Target 'PC01, PC02' -Applied -Expected @('PC01', 'PC02')
        $ui.txtChangesTitle.Text | Should -Be 'Primjena s greškama'
        $ui.txtChangesInfo.Text | Should -Match '2 cilj'
        @($ui.dgChanges.ItemsSource | Where-Object StatusText -in 'DODANO', 'POSTAVLJENO').Count | Should -Be 0
        @($ui.dgChanges.ItemsSource)[0].StatusText | Should -Be 'NIJE PRIMIJENJENO'
        Show-Page 'Pregled'
    }

    It 'prikazuje promjene i usporedbu' {
        $active = Get-UiActivePolicySet
        $first = @($active.Set.settings)[0]
        $fake = [pscustomobject]@{
            ComputerName = 'PC01'; Status = 'WhatIf'; BackupPath = $null; Messages = @('Računalo je u domeni.')
            Diff = @(
                [pscustomobject]@{ Status = 'Added'; Scope = $first.scope; Key = $first.key; ValueName = $first.valueName; Current = $null; Desired = "$($first.data)"; Action = 'Set' }
                [pscustomobject]@{ Status = 'Unchanged'; Scope = 'Machine'; Key = 'Software\X'; ValueName = 'Y'; Current = '1'; Desired = '1'; Action = 'Set' }
            )
        }
        Show-UiChanges -Results @($fake) -Active $active -Target 'ovo računalo'
        $ui.pgPromjene.Visibility | Should -Be 'Visible'
        @($ui.dgChanges.ItemsSource).Count | Should -BeGreaterThan 2
        @($ui.dgChanges.ItemsSource)[0].Setting | Should -Be $first.displayName
        $null = Save-PageShot 'Promjene' '05-promjene.png'

        Show-Page 'Usporedba'
        @($ui.dgCompliance.ItemsSource).Count | Should -BeGreaterThan 5
        $null = Save-PageShot 'Usporedba' '04-usporedba.png'
    }

    It 'sprema snimke ostalih stranica' {
        $ui.rbTargetDomain.IsChecked = $true
        $ui.pnlDomain.Visibility | Should -Be 'Visible'
        $ui.btnReplication.Visibility | Should -Be 'Visible'
        $ui.rbTargetLocal.IsChecked = $true
        $ui.lbCategories.SelectedIndex = [array]::IndexOf(@($Sec.Catalog.categories.id), 'defender')
        $Sec.Category | Should -Be 'defender'
        $null = Save-PageShot 'Sigurnost' '06-sigurnosne-zastita.png'
        foreach ($p in @(@('Preseti', '03-preseti.png'), @('Dnevnik', '07-dnevnik.png'))) {
            $path = Save-PageShot $p[0] $p[1]
            (Get-Item $path).Length | Should -BeGreaterThan 10000
        }
        $ui.pgPregled.Visibility | Should -Be 'Collapsed'
    }
}
