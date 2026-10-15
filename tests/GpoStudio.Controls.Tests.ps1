BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\GpoStudio.Core') -Force
    $fixture = Join-Path $PSScriptRoot 'fixtures\controls\test-controls.json'
    $catalog = Get-GpsControlCatalog -Path $fixture
    $usbKey = 'Software\Policies\Microsoft\Windows\RemovableStorageDevices'
    $usbClassKey = "$usbKey\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}"
    $lockKey = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
}

Describe 'Katalog sigurnosnih kontrola' {
    It 'testni katalog je ispravan' {
        @(Test-GpsControlCatalog -Catalog $catalog).Count | Should -Be 0
    }

    It 'prijavljuje neispravne reference, ključeve i vrijednosti' {
        $bad = Get-Content -LiteralPath $fixture -Raw -Encoding UTF8 | ConvertFrom-Json
        $bad.controls[0].levels.'2' = 'nema'
        $bad.controls[0].options[0].security = [pscustomobject]@{ NepoznatKljuc = 1 }
        $bad.controls[1].benchmarks[0].satisfiedBy = @('x')
        $bad.controls[3].options[0].audit = [pscustomobject]@{ Logon = 'Uvijek' }
        $errors = @(Test-GpsControlCatalog -Catalog $bad)
        ($errors -join "`n") | Should -Match 'nepostojeću opciju ''nema'''
        ($errors -join "`n") | Should -Match 'NepoznatKljuc'
        ($errors -join "`n") | Should -Match 'satisfiedBy'
        ($errors -join "`n") | Should -Match 'Uvijek'
    }

    It 'ne dopušta da dvije kontrole pišu istu registry vrijednost' {
        $bad = Get-Content -LiteralPath $fixture -Raw -Encoding UTF8 | ConvertFrom-Json
        $bad.controls[1].options[0].settings[0].key = $usbKey
        $bad.controls[1].options[0].settings[0].valueName = 'Deny_All'
        (@(Test-GpsControlCatalog -Catalog $bad) -join "`n") | Should -Match 'već koristi kontrola'
    }

    It 'pravi katalog i ugrađeni preseti su ispravni' {
        $real = Get-GpsControlCatalog
        @($real.controls).Count | Should -BeGreaterThan 20
        $presets = @(Get-GpsControlPreset -UserFolder (Join-Path $TestDrive 'nema') -WarningVariable presetWarnings -WarningAction SilentlyContinue)
        $presetWarnings | Should -BeNullOrEmpty
        $presets.Count | Should -BeGreaterOrEqual 3
        foreach ($p in $presets) {
            $null = Resolve-GpsControlPreset -Catalog $real -Preset $p -WarningVariable w -WarningAction SilentlyContinue
            $w | Should -BeNullOrEmpty -Because "preset '$($p.Name)' upućuje samo na postojeće kontrole i opcije"
        }
        foreach ($level in 1..3) {
            $set = ConvertTo-GpsControlPolicySet -Catalog $real -Selection (Get-GpsControlSelection -Catalog $real -Level $level) -WarningVariable w -WarningAction SilentlyContinue
            $w | Should -BeNullOrEmpty -Because "razina $level nema sukobljenih postavki"
            @($set.settings).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Odabir i razine' {
    It 'razina bira zadane opcije, null znači ne mijenja se' {
        $s1 = Get-GpsControlSelection -Catalog $catalog -Level 1
        $s1['accounts.password-length'] | Should -Be '8'
        $s1['accounts.audit-logon'] | Should -BeNullOrEmpty
        (Get-GpsControlSelection -Catalog $catalog -Level 3)['usb.storage'] | Should -Be 'readonly'
        @((Get-GpsControlSelection -Catalog $catalog -Level 0).Values | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'promjene nadjačavaju razinu, a nepoznate kontrole i opcije se preskaču uz upozorenje' {
        $s = Get-GpsControlSelection -Catalog $catalog -Level 2 -Override @{ 'usb.storage' = 'blocked'; 'nema.kontrole' = 'x'; 'accounts.password-length' = 'nema' } -WarningVariable w -WarningAction SilentlyContinue
        $s['usb.storage'] | Should -Be 'blocked'
        $s['accounts.password-length'] | Should -Be '14'
        @($w).Count | Should -Be 2
    }
}

Describe 'ConvertTo-GpsControlPolicySet' {
    It 'gradi registry, security i audit dio' {
        $set = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 2) -Name 'Test'
        $set.name | Should -Be 'Test'
        $set.security['MinimumPasswordLength'] | Should -Be 14
        $set.audit['Logon'] | Should -Be 'Success,Failure'
        ($set.settings | Where-Object valueName -eq 'InactivityTimeoutSecs').data | Should -Be 900
        ($set.settings | Where-Object valueName -eq 'UserFlag').scope | Should -Be 'User'
    }

    It 'odabrana opcija briše vrijednosti ostalih opcija iste kontrole' {
        $sel = Get-GpsControlSelection -Catalog $catalog -Level 2 -Override @{ 'usb.storage' = 'readonly' }
        $set = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection $sel
        $write = $set.settings | Where-Object { $_.key -eq $usbClassKey -and $_.valueName -eq 'Deny_Write' }
        $write.action | Should -Be 'Set'
        ($set.settings | Where-Object { $_.key -eq $usbKey -and $_.valueName -eq 'Deny_All' }).action | Should -Be 'Delete'

        $allowed = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 1 -Override @{ 'usb.storage' = 'allowed' })
        @($allowed.settings | Where-Object { $_.key -like "$usbKey*" }).action | Sort-Object -Unique | Should -Be 'Delete'
    }

    It 'kontrola koja se ne mijenja ne dodaje ništa' {
        $set = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 0)
        @($set.settings).Count | Should -Be 0
        $set.security.Count | Should -Be 0
        $set.audit.Count | Should -Be 0
    }

    It 'rezultat je valjan Policy Set (prolazi ConvertTo-GpsPolicySet i JSON)' {
        $set = ConvertTo-GpsControlPolicySet -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 3)
        $again = $set | ConvertTo-Json -Depth 10 | ConvertFrom-Json | ConvertTo-GpsPolicySet
        @($again.settings).Count | Should -Be @($set.settings).Count
    }
}

Describe 'Usporedba sa standardima' {
    It 'računa pokrivenost po standardu, CIS L2 uključuje L1 preporuke' {
        $c = @(Get-GpsControlCompliance -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 2))
        $l1 = $c | Where-Object Id -eq 'CIS-L1'
        $l1.Total | Should -Be 3
        $l1.Satisfied | Should -Be 3
        $l1.Score | Should -Be 100
        $l2 = $c | Where-Object Id -eq 'CIS-L2'
        $l2.Total | Should -Be 4
        ($l2.Rows | Where-Object ControlId -eq 'usb.storage').Status | Should -Be 'Deviates'
        $l2.Score | Should -Be 75
        ($c | Where-Object Id -eq 'MSB').Total | Should -Be 1
    }

    It 'kontrola koja se ne mijenja ima status NotSet' {
        $c = Get-GpsControlCompliance -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 1) | Where-Object Id -eq 'CIS-L1'
        ($c.Rows | Where-Object ControlId -eq 'accounts.audit-logon').Status | Should -Be 'NotSet'
        ($c.Rows | Where-Object ControlId -eq 'accounts.password-length').Status | Should -Be 'Deviates'
    }
}

Describe 'Preseti' {
    It 'sprema samo razlike u odnosu na razinu i vraća isti odabir' {
        $sel = Get-GpsControlSelection -Catalog $catalog -Level 2 -Override @{ 'usb.storage' = 'blocked'; 'accounts.audit-logon' = $null }
        $preset = New-GpsControlPreset -Catalog $catalog -Name 'Kiosk / test' -Description 'opis' -Level 2 -Selection $sel
        @($preset.Changes.Keys) | Should -Be @('usb.storage', 'accounts.audit-logon')

        $path = Export-GpsControlPreset -Preset $preset -Path (Join-Path $TestDrive 'kiosk.json')
        $loaded = Import-GpsControlPreset -Path $path
        $loaded.Name | Should -Be 'Kiosk / test'
        $loaded.Level | Should -Be 2
        $resolved = Resolve-GpsControlPreset -Catalog $catalog -Preset $loaded
        foreach ($k in $sel.Keys) { $resolved[$k] | Should -Be $sel[$k] }
    }

    It 'ne prepisuje postojeću datoteku bez -Force' {
        $preset = New-GpsControlPreset -Catalog $catalog -Name 'X' -Level 1 -Selection (Get-GpsControlSelection -Catalog $catalog -Level 1)
        $path = Join-Path $TestDrive 'x.json'
        $null = Export-GpsControlPreset -Preset $preset -Path $path
        { Export-GpsControlPreset -Preset $preset -Path $path } | Should -Throw '*već postoji*'
        { Export-GpsControlPreset -Preset $preset -Path $path -Force } | Should -Not -Throw
    }

    It 'neispravan preset u mapi daje upozorenje, ne grešku' {
        $folder = Join-Path $TestDrive 'user'
        $null = New-Item -ItemType Directory -Path $folder
        Set-Content -LiteralPath (Join-Path $folder 'los.json') -Value '{ "name": "Bez razine" }' -Encoding UTF8
        $presets = @(Get-GpsControlPreset -UserFolder $folder -BuiltInFolder (Join-Path $TestDrive 'nema') -WarningVariable w -WarningAction SilentlyContinue)
        $presets.Count | Should -Be 0
        @($w).Count | Should -Be 1
    }
}

Describe 'Stanje računala' {
    BeforeAll {
        function New-State([hashtable]$Registry, [hashtable]$Security = @{}, [hashtable]$Audit = @{}) {
            $reg = @{}
            foreach ($k in $Registry.Keys) { $reg[$k.ToLowerInvariant()] = $Registry[$k] }
            [pscustomobject]@{ ComputerName = 'PC01'; Registry = $reg; Security = $Security; Audit = $Audit }
        }
        $absent = [pscustomobject]@{ Exists = $false; Type = $null; Data = $null }
        function Value($d) { [pscustomobject]@{ Exists = $true; Type = 'REG_DWORD'; Data = $d } }
    }

    It 'upit sadrži sve vrijednosti, security ključeve i podkategorije revizije' {
        $q = Get-GpsControlStateQuery -Catalog $catalog
        @($q.registry).Count | Should -Be 4
        $q.security | Should -Be @('MinimumPasswordLength')
        $q.audit | Should -Be @('Logon')
    }

    It 'prepoznaje opcije, uključujući atLeast i atMost' {
        $state = New-State @{
            "Machine\$lockKey\InactivityTimeoutSecs" = (Value 600)
            "Machine\$usbKey\Deny_All"               = (Value 1)
            "Machine\$usbClassKey\Deny_Write"        = $absent
            'User\Software\Policies\Test\UserFlag'   = (Value 1)
        } @{ MinimumPasswordLength = '16' } @{ Logon = 'Success,Failure' }
        $r = Resolve-GpsControlState -Catalog $catalog -State $state
        $r.Selection['accounts.password-length'] | Should -Be '14'
        $r.Selection['accounts.screen-lock'] | Should -Be '15'
        $r.Selection['usb.storage'] | Should -Be 'blocked'
        $r.Selection['accounts.audit-logon'] | Should -Be 'on'
    }

    It 'nula za atMost nije usklađena, a nepoznata vrijednost daje status Unknown' {
        $state = New-State @{
            "Machine\$lockKey\InactivityTimeoutSecs" = (Value 0)
            "Machine\$usbKey\Deny_All"               = $absent
            "Machine\$usbClassKey\Deny_Write"        = $absent
        } @{ MinimumPasswordLength = '6' } @{ Logon = 'Success' }
        $r = Resolve-GpsControlState -Catalog $catalog -State $state
        $r.Selection['accounts.screen-lock'] | Should -BeNullOrEmpty
        $r.Selection['accounts.password-length'] | Should -BeNullOrEmpty
        $r.Selection['usb.storage'] | Should -Be 'allowed'
        ($r.Details | Where-Object ControlId -eq 'accounts.audit-logon').Status | Should -Be 'Unknown'
        ($r.Details | Where-Object ControlId -eq 'accounts.screen-lock').Status | Should -Be 'Other'
    }

    It 'otkriveni odabir se može izravno usporediti sa standardima' {
        $state = New-State @{
            "Machine\$lockKey\InactivityTimeoutSecs" = (Value 300)
            "Machine\$usbKey\Deny_All"               = $absent
            "Machine\$usbClassKey\Deny_Write"        = (Value 1)
            'User\Software\Policies\Test\UserFlag'   = (Value 1)
        } @{ MinimumPasswordLength = '14' } @{ Logon = 'Success,Failure' }
        $r = Resolve-GpsControlState -Catalog $catalog -State $state
        $r.Selection['usb.storage'] | Should -Be 'readonly'
        (Get-GpsControlCompliance -Catalog $catalog -Selection $r.Selection | Where-Object Id -eq 'CIS-L2').Score | Should -Be 100
    }
}

Describe 'Izvještaj usporedbe' {
    It 'sadrži sve standarde, retke i escapea tekst' {
        $html = ConvertTo-GpsComplianceHtml -Catalog $catalog -Selection (Get-GpsControlSelection -Catalog $catalog -Level 2) -Subject 'Računalo <PC01>' -Date ([datetime]'2026-10-15 08:30')
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'Računalo &lt;PC01&gt;'
        $html | Should -Match '15\.10\.2026\. 08:30'
        foreach ($std in $catalog.standards) { $html | Should -Match ([regex]::Escape($std.title)) }
        ([regex]::Matches($html, '<tr><td>')).Count | Should -Be 8
        $html | Should -Match 'U REDU'
        $html | Should -Match 'ODSTUPA'
    }
}
