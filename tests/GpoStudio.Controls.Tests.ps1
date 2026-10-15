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

Describe 'Stanje računala: načini usporedbe' {
    BeforeAll {
        $modes = @'
{
  "schemaVersion": 1, "standards": [], "categories": [ { "id": "x", "title": "X" } ],
  "controls": [
    { "id": "t.audit", "category": "x", "title": "Revizija", "description": "d", "levels": {},
      "options": [
        { "id": "basic", "title": "Osnovno", "audit": { "Logon": "Success" } },
        { "id": "extended", "title": "Prošireno", "audit": { "Logon": "Success,Failure", "Process Creation": "Success" } } ] },
    { "id": "t.lockout", "category": "x", "title": "Zaključavanje", "description": "d", "levels": {},
      "options": [
        { "id": "cis", "title": "CIS", "matchMode": "exact", "matchModes": { "LockoutBadCount": "atMost", "LockoutDuration": "atLeast" },
          "security": { "LockoutBadCount": 5, "LockoutDuration": 15 } } ] },
    { "id": "t.deadline", "category": "x", "title": "Rok", "description": "d", "levels": {},
      "options": [
        { "id": "d2", "title": "2 dana", "matchMode": "atMost", "matchModes": { "Grace": "atMostOrZero" },
          "settings": [
            { "scope": "Machine", "key": "Software\\Policies\\T", "valueName": "Days", "type": "REG_DWORD", "data": 2 },
            { "scope": "Machine", "key": "Software\\Policies\\T", "valueName": "Grace", "type": "REG_DWORD", "data": 1 } ] } ] }
  ]
}
'@ | ConvertFrom-Json
        function Value($d) { [pscustomobject]@{ Exists = $true; Type = 'REG_DWORD'; Data = $d } }
        $registry = @{ 'machine\software\policies\t\days' = (Value 1); 'machine\software\policies\t\grace' = (Value 0) }
    }

    It 'katalog s matchModes je ispravan, a ključ s košnicom nije' {
        @(Test-GpsControlCatalog -Catalog $modes).Count | Should -Be 0
        $bad = $modes | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $bad.controls[2].options[0].settings[0].key = 'HKLM\Software\Policies\T'
        $bad.controls[1].options[0].matchModes.LockoutBadCount = 'vise'
        $errors = @(Test-GpsControlCatalog -Catalog $bad)
        $errors -match 'košnic' | Should -Not -BeNullOrEmpty
        $errors -match "nepoznat matchMode 'vise'" | Should -Not -BeNullOrEmpty
    }

    It 'revizija sa više zastavica zadovoljava preporuku, a matchModes vrijede po vrijednosti' {
        $state = [pscustomobject]@{
            Registry = $registry
            Security = @{ LockoutBadCount = '3'; LockoutDuration = '30' }
            Audit    = @{ Logon = 'Success,Failure'; 'Process Creation' = 'None' }
        }
        $r = Resolve-GpsControlState -Catalog $modes -State $state
        $r.Selection['t.audit'] | Should -Be 'basic'
        $r.Selection['t.lockout'] | Should -Be 'cis'
        $r.Selection['t.deadline'] | Should -Be 'd2'
    }

    It 'nepročitan secedit ili auditpol daje Unknown, ne Other' {
        $state = [pscustomobject]@{ Registry = $registry; Security = $null; Audit = $null }
        $r = Resolve-GpsControlState -Catalog $modes -State $state
        foreach ($id in 't.audit', 't.lockout') { ($r.Details | Where-Object ControlId -eq $id).Status | Should -Be 'Unknown' }
    }

    It 'blaža opcija ne isključuje podkategorije revizije (Windows ih može bilježiti po zadanom)' {
        $basic = ConvertTo-GpsControlPolicySet -Catalog $modes -Selection ([ordered]@{ 't.audit' = 'basic' })
        $basic.audit['Logon'] | Should -Be 'Success'
        $basic.audit.Contains('Process Creation') | Should -BeFalse
        $extended = ConvertTo-GpsControlPolicySet -Catalog $modes -Selection ([ordered]@{ 't.audit' = 'extended' })
        $extended.audit['Process Creation'] | Should -Be 'Success'
    }

    It 'brojevi se uspoređuju neovisno o jeziku sustava' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('hr-HR')
            & (Get-Module GpoStudio.Core) { Test-GpsControlValue '2' '1.5' 'atLeast' } | Should -BeTrue
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
    }

    It 'vrijednost 0 koju je postavio GPO ne isključuje opciju' {
        $state = [pscustomobject]@{
            Registry = @{
                "machine\$($usbKey.ToLowerInvariant())\deny_all"        = (Value 0)
                "machine\$($usbClassKey.ToLowerInvariant())\deny_write" = (Value 1)
                "machine\$($lockKey.ToLowerInvariant())\inactivitytimeoutsecs" = (Value 900)
            }
            Security = @{ MinimumPasswordLength = '14' }; Audit = @{}
        }
        (Resolve-GpsControlState -Catalog $catalog -State $state).Selection['usb.storage'] | Should -Be 'readonly'
    }
}

Describe 'Usporedba: više preporuka i otkriveno stanje' {
    It 'svaka preporuka istog standarda je zaseban redak' {
        $c2 = Get-Content -LiteralPath $fixture -Raw -Encoding UTF8 | ConvertFrom-Json
        # Druga, stroža CIS L1 preporuka za USB: zadovoljava je samo 'blocked'.
        $c2.controls[2].benchmarks += [pscustomobject]@{ standard = 'CIS-L1'; recommendation = 'Zabranjeno'; satisfiedBy = @('blocked'); reference = '9.9' }
        $sel = [ordered]@{ 'usb.storage' = 'readonly' }
        $l1 = Get-GpsControlCompliance -Catalog $c2 -Selection $sel | Where-Object Id -eq 'CIS-L1'
        $usb = @($l1.Rows | Where-Object ControlId -eq 'usb.storage')
        $usb.Count | Should -Be 1
        $usb[0].Status | Should -Be 'Deviates'
        $l2 = Get-GpsControlCompliance -Catalog $c2 -Selection $sel | Where-Object Id -eq 'CIS-L2'
        @($l2.Rows | Where-Object ControlId -eq 'usb.storage').Status | Should -Be @('OK', 'Deviates')
    }

    It 'otkriveno slabije stanje (Other) je odstupanje, a nepoznato nije provjereno' {
        $details = @(
            [pscustomobject]@{ ControlId = 'accounts.password-length'; Status = 'Other' }
            [pscustomobject]@{ ControlId = 'accounts.audit-logon'; Status = 'Unknown' }
        )
        $r = Get-GpsControlCompliance -Catalog $catalog -Selection ([ordered]@{}) -Details $details | Where-Object Id -eq 'CIS-L1'
        ($r.Rows | Where-Object ControlId -eq 'accounts.password-length').Status | Should -Be 'Deviates'
        ($r.Rows | Where-Object ControlId -eq 'accounts.password-length').Selected | Should -Be 'Drukčije postavljeno'
        ($r.Rows | Where-Object ControlId -eq 'accounts.audit-logon').Status | Should -Be 'Unknown'
        ($r.Rows | Where-Object ControlId -eq 'accounts.screen-lock').Status | Should -Be 'NotSet'
    }

    It 'katalog bez naslova kategorije ili teksta preporuke nije ispravan' {
        $bad = Get-Content -LiteralPath $fixture -Raw -Encoding UTF8 | ConvertFrom-Json
        $bad.categories[0].PSObject.Properties.Remove('title')
        $bad.controls[0].benchmarks[0].PSObject.Properties.Remove('recommendation')
        $errors = @(Test-GpsControlCatalog -Catalog $bad)
        $errors -match "Kategorija 'accounts' nema" | Should -Not -BeNullOrEmpty
        $errors -match "nema 'recommendation'" | Should -Not -BeNullOrEmpty
    }

    It 'izvoz preseta stvara mapu koja ne postoji' {
        $preset = New-GpsControlPreset -Catalog $catalog -Name 'Mapa' -Level 2 -Selection (Get-GpsControlSelection -Catalog $catalog -Level 2)
        $path = Join-Path $TestDrive 'nova\mapa\preset.json'
        Export-GpsControlPreset -Preset $preset -Path $path | Should -Be $path
        Test-Path -LiteralPath $path | Should -BeTrue
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
