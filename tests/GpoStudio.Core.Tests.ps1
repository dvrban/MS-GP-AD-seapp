BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\GpoStudio.Core') -Force
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Registry.pol' {
    It 'zapisuje i čita sve podržane tipove bez gubitka' {
        $entries = @(
            [pscustomobject]@{ Key = 'Software\Policies\A'; ValueName = 'Dw'; Type = 'REG_DWORD'; Data = 4294967295 }
            [pscustomobject]@{ Key = 'Software\Policies\A'; ValueName = 'Sz'; Type = 'REG_SZ'; Data = 'čćžšđ' }
            [pscustomobject]@{ Key = 'Software\Policies\A'; ValueName = 'Ex'; Type = 'REG_EXPAND_SZ'; Data = '%SystemRoot%\x' }
            [pscustomobject]@{ Key = 'Software\Policies\A'; ValueName = 'Ms'; Type = 'REG_MULTI_SZ'; Data = @('a', 'b c') }
            [pscustomobject]@{ Key = 'Software\Policies\A'; ValueName = 'Qw'; Type = 'REG_QWORD'; Data = 5000000000 }
            [pscustomobject]@{ Key = 'Software\Policies\A'; ValueName = 'Bin'; Type = 'REG_BINARY'; Data = [byte[]](1, 2, 255) }
            [pscustomobject]@{ Key = 'Software\Policies\B'; ValueName = ''; Type = 'REG_SZ'; Data = '' }
        )
        $path = Join-Path $TestDrive 'Registry.pol'
        Write-GpsRegistryPol -Path $path -Entry $entries
        $read = @(Read-GpsRegistryPol -Path $path)

        $read.Count | Should -Be 7
        $read[0].Data | Should -Be ([uint32]::MaxValue)
        $read[1].Data | Should -Be 'čćžšđ'
        $read[2].Type | Should -Be 'REG_EXPAND_SZ'
        $read[3].Data | Should -Be @('a', 'b c')
        $read[4].Data | Should -Be 5000000000
        $read[5].Data | Should -Be ([byte[]](1, 2, 255))
        $read[6].ValueName | Should -Be ''
    }

    It 'zapisuje ispravno zaglavlje PReg v1' {
        $path = Join-Path $TestDrive 'empty.pol'
        Write-GpsRegistryPol -Path $path -Entry @()
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes | Should -Be ([byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0))
        @(Read-GpsRegistryPol -Path $path).Count | Should -Be 0
    }

    It 'odbija oštećenu datoteku' {
        $path = Join-Path $TestDrive 'bad.pol'
        [IO.File]::WriteAllBytes($path, [byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0, 0x5B, 0))
        { Read-GpsRegistryPol -Path $path } | Should -Throw
    }

    It 'zamjenjuje postojeću datoteku i radi s relativnom putanjom' {
        Push-Location $TestDrive
        try {
            Write-GpsRegistryPol -Path 'rel.pol' -Entry @([pscustomobject]@{ Key = 'K'; ValueName = 'V'; Type = 'REG_DWORD'; Data = 1 })
            Write-GpsRegistryPol -Path 'rel.pol' -Entry @([pscustomobject]@{ Key = 'K'; ValueName = 'V'; Type = 'REG_DWORD'; Data = 2 })
            (Read-GpsRegistryPol -Path 'rel.pol').Data | Should -Be 2
            @(Get-ChildItem -Path $TestDrive -Filter '*.gps-tmp').Count | Should -Be 0
        }
        finally { Pop-Location }
    }

    It 'WhatIf ne mijenja datoteku' {
        $path = Join-Path $TestDrive 'whatif.pol'
        Write-GpsRegistryPol -Path $path -Entry @() -WhatIf
        Test-Path $path | Should -BeFalse
    }
}

Describe 'Policy Set' {
    It 'iz HKLM prefiksa određuje scope Machine' {
        $s = New-GpsPolicySetting -Key 'HKLM\Software\Policies\X' -ValueName V -Data 1
        $s.scope | Should -Be 'Machine'
        $s.key | Should -Be 'Software\Policies\X'
    }

    It 'odbija neispravnu DWORD vrijednost' {
        { New-GpsPolicySetting -Key 'Software\X' -ValueName V -Type REG_DWORD -Data -1 } | Should -Throw
    }

    It 'merge zamjenjuje vrijednost, a Delete dodaje **del. zapis' {
        $existing = @(
            [pscustomobject]@{ Key = 'Software\X'; ValueName = 'A'; Type = 'REG_DWORD'; Data = 0 }
            [pscustomobject]@{ Key = 'Software\X'; ValueName = 'B'; Type = 'REG_DWORD'; Data = 1 }
            [pscustomobject]@{ Key = 'Software\X'; ValueName = 'Keep'; Type = 'REG_SZ'; Data = 'x' }
        )
        $settings = @(
            New-GpsPolicySetting -Key 'Software\x' -ValueName 'a' -Data 1
            New-GpsPolicySetting -Key 'Software\X' -ValueName 'B' -Action Delete
        )
        $merged = Merge-GpsPolicySet -Existing $existing -Setting $settings

        $merged.Count | Should -Be 3
        ($merged | Where-Object ValueName -eq 'a').Data | Should -Be 1
        ($merged | Where-Object ValueName -eq '**del.B').Type | Should -Be 'REG_SZ'
        ($merged | Where-Object ValueName -eq 'Keep') | Should -Not -BeNullOrEmpty
    }

    It 'diff prepoznaje Added, Changed, Unchanged i Removed' {
        $current = @(
            [pscustomobject]@{ Key = 'Software\X'; ValueName = 'Same'; Type = 'REG_DWORD'; Data = 1 }
            [pscustomobject]@{ Key = 'Software\X'; ValueName = 'Diff'; Type = 'REG_DWORD'; Data = 1 }
            [pscustomobject]@{ Key = 'Software\X'; ValueName = 'Gone'; Type = 'REG_DWORD'; Data = 1 }
        )
        $settings = @(
            New-GpsPolicySetting -Key 'Software\X' -ValueName 'Same' -Data 1
            New-GpsPolicySetting -Key 'Software\X' -ValueName 'Diff' -Data 2
            New-GpsPolicySetting -Key 'Software\X' -ValueName 'New' -Data 1
            New-GpsPolicySetting -Key 'Software\X' -ValueName 'Gone' -Action Delete
        )
        $diff = Compare-GpsPolicySet -Current $current -Setting $settings
        ($diff | ForEach-Object { "$($_.ValueName)=$($_.Status)" }) |
            Should -Be @('Same=Unchanged', 'Diff=Changed', 'New=Added', 'Gone=Removed')
    }

    It 'REG_BINARY nakon JSON-a nije Changed' {
        $current = @([pscustomobject]@{ Key = 'Software\X'; ValueName = 'B'; Type = 'REG_BINARY'; Data = [byte[]](1, 2, 255) })
        $setting = New-GpsPolicySetting -Key 'Software\X' -ValueName 'B' -Type REG_BINARY -Data ([byte[]](1, 2, 255))
        $roundTrip = $setting | ConvertTo-Json | ConvertFrom-Json
        (Compare-GpsPolicySet -Current $current -Setting @($roundTrip)).Status | Should -Be 'Unchanged'
    }

    It 'uvozi minimalan JSON bez description i version' {
        $path = Join-Path $TestDrive 'min.json'
        Set-Content -Path $path -Encoding UTF8 -Value '{ "name": "Min", "settings": [ { "key": "Software\\X", "valueName": "V", "type": "REG_DWORD", "data": 1 } ] }'
        $set = Import-GpsPolicySet -Path $path
        $set.version | Should -Be '1.0.0'
        $set.description | Should -Be ''
        $set.settings.Count | Should -Be 1
    }

    It 'ConvertTo-GpsPolicySet normalizira hashtable i objekt bez opcionalnih polja' {
        $fromHash = ConvertTo-GpsPolicySet @{ name = 'H'; settings = @(@{ key = 'Software\X'; valueName = 'V'; data = 1 }); audit = @{ Logon = 'Success' } }
        $fromHash.version | Should -Be '1.0.0'
        $fromHash.settings[0].type | Should -Be 'REG_DWORD'
        $fromHash.audit['Logon'] | Should -Be 'Success'

        $fromObject = ConvertTo-GpsPolicySet ([pscustomobject]@{ name = 'O'; settings = @() })
        $fromObject.description | Should -Be ''
        $fromObject.security.Count | Should -Be 0
        { ConvertTo-GpsPolicySet @{ settings = @() } } | Should -Throw '*name*'
    }

    It 'JSON export i import čuvaju postavke' {
        $example = Join-Path $PSScriptRoot '..\examples\radna-stanica-baseline.json'
        $set = Import-GpsPolicySet -Path $example
        $out = Join-Path $TestDrive 'set.json'
        Export-GpsPolicySet -PolicySet $set -Path $out
        $again = Import-GpsPolicySet -Path $out

        $again.name | Should -Be $set.name
        $again.settings.Count | Should -Be $set.settings.Count
        $again.security['MinimumPasswordLength'] | Should -Be 14
    }
}

Describe 'ADMX katalog' {
    It 'čita politike i prijevode iz ADML-a' {
        $catalog = @(Get-GpsAdmxCatalog -Path (Join-Path $fixtures 'PolicyDefinitions') -Language 'hr-HR' -Filter 'GpsSample.admx')
        $catalog.Count | Should -Be 2

        $store = $catalog | Where-Object Name -eq 'RemoveStore'
        $store.DisplayName | Should -Be 'Isključi aplikaciju Trgovina'
        $store.Category | Should -Be 'Trgovina'
        $store.EnabledValue | Should -Be '1'
        $store.Class | Should -Be 'Machine'
    }

    It 'koristi en-US kad traženi jezik ne postoji' {
        $catalog = @(Get-GpsAdmxCatalog -Path (Join-Path $fixtures 'PolicyDefinitions') -Language 'de-DE')
        ($catalog | Where-Object Name -eq 'RemoveStore').DisplayName | Should -Be 'Turn off the Store application'
    }

    It 'čita elemente politike (enum, decimal, text)' {
        $policy = Get-GpsAdmxCatalog -Path (Join-Path $fixtures 'PolicyDefinitions') -Language 'en-US' |
            Where-Object Name -eq 'UpdateMode'
        $policy.Elements.Kind | Should -Be @('enum', 'decimal', 'text')
        $policy.Elements[0].Items.Value | Should -Be @('4', '2')
        $policy.Elements[1].MaxValue | Should -Be '30'
    }
}

Describe 'ConvertTo-GpsPolicySetting' {
    BeforeAll {
        $catalog = @(Get-GpsAdmxCatalog -Path (Join-Path $fixtures 'PolicyDefinitions') -Language 'en-US')
        $removeStore = $catalog | Where-Object Name -eq 'RemoveStore'
        $updateMode = $catalog | Where-Object Name -eq 'UpdateMode'
    }

    It 'Enabled koristi enabledValue, Disabled disabledValue' {
        $on = ConvertTo-GpsPolicySetting -Policy $removeStore -State Enabled
        $on.data | Should -Be 1
        $on.type | Should -Be 'REG_DWORD'
        $on.scope | Should -Be 'Machine'
        (ConvertTo-GpsPolicySetting -Policy $removeStore -State Disabled).data | Should -Be 0
    }

    It 'elementi dobivaju unesene vrijednosti' {
        $s = @(ConvertTo-GpsPolicySetting -Policy $updateMode -ElementValues @{ Mode = 'Never'; Delay = 7; Note = 'x' })
        $s.Count | Should -Be 3
        ($s | Where-Object valueName -eq 'AutoDownload').data | Should -Be 2
        ($s | Where-Object valueName -eq 'DelayDays').data | Should -Be 7
        ($s | Where-Object valueName -eq 'Note').type | Should -Be 'REG_SZ'
    }

    It 'provjerava raspon i obavezne elemente' {
        { ConvertTo-GpsPolicySetting -Policy $updateMode -ElementValues @{ Mode = 'Never'; Delay = 31 } } | Should -Throw '*rasponu*'
        { ConvertTo-GpsPolicySetting -Policy $updateMode -ElementValues @{ Delay = 1 } } | Should -Throw '*obavezan*'
    }

    It 'Disabled briše vrijednosti elemenata' {
        $s = @(ConvertTo-GpsPolicySetting -Policy $updateMode -State Disabled)
        $s.action | Sort-Object -Unique | Should -Be 'Delete'
        $s.Count | Should -Be 3
    }
}

Describe 'ConvertTo-GpsPolicySetting: liste i posebni tipovi' {
    BeforeAll {
        $catalog = @(Get-GpsAdmxCatalog -Path (Join-Path $fixtures 'PolicyDefinitions') -Language 'en-US' -Filter 'GpsAdvanced.admx')
        $printers = $catalog | Where-Object Name -eq 'PrinterRestrictions'
        $listOnly = $catalog | Where-Object Name -eq 'EnabledListOnly'
        $quota = $catalog | Where-Object Name -eq 'BigQuota'
    }

    It 'Enabled upisuje enabledList (s defaultKey i vlastitim ključem)' {
        $s = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Level = 'Low' })
        ($s | Where-Object valueName -eq 'Restricted').data | Should -Be 1
        $mode = $s | Where-Object valueName -eq 'Mode'
        $mode.key | Should -Be 'Software\Policies\Gps\Printers\Mode'
        $mode.type | Should -Be 'REG_SZ'
        $mode.data | Should -Be 'strict'
    }

    It 'Disabled upisuje disabledList, a bez nje briše enabledList' {
        $s = @(ConvertTo-GpsPolicySetting -Policy $printers -State Disabled)
        ($s | Where-Object valueName -eq 'Restricted').data | Should -Be 0

        $d = @(ConvertTo-GpsPolicySetting -Policy $listOnly -State Disabled)
        $d.Count | Should -Be 1
        $d[0].action | Should -Be 'Delete'
    }

    It 'boolean koristi trueValue/falseValue, a bez njih DWORD 1/0' {
        $on = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Inverted = $true; Plain = $true; Level = 'Low' })
        ($on | Where-Object valueName -eq 'ShowWarning').data | Should -Be 0
        ($on | Where-Object valueName -eq 'Plain').data | Should -Be 1

        $off = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Inverted = $false; Plain = $false; Level = 'Low' })
        ($off | Where-Object valueName -eq 'ShowWarning').data | Should -Be 1
        ($off | Where-Object valueName -eq 'Plain').data | Should -Be 0
    }

    It 'Disabled: boolean s falseValue dobiva tu vrijednost, ostali elementi se brišu' {
        $s = @(ConvertTo-GpsPolicySetting -Policy $printers -State Disabled)
        $warning = $s | Where-Object valueName -eq 'ShowWarning'
        $warning.action | Should -Be 'Set'
        $warning.data | Should -Be 1
        ($s | Where-Object valueName -eq 'Plain').action | Should -Be 'Delete'
    }

    It 'enum: valueList odabrane stavke i stavka koja briše vrijednost' {
        $low = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Level = 'Low' })
        ($low | Where-Object valueName -eq 'Level').data | Should -Be 1
        ($low | Where-Object valueName -eq 'LowExtra').data | Should -Be 'yes'

        $none = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Level = 'None' })
        ($none | Where-Object valueName -eq 'Level').action | Should -Be 'Delete'
    }

    It 'promjena opcije ili stanja briše vrijednosti iz ranijeg izbora (kao gpedit)' {
        $low = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Level = 'Low' })
        $none = @(ConvertTo-GpsPolicySetting -Policy $printers -ElementValues @{ Level = 'None' })
        ($none | Where-Object valueName -eq 'LowExtra').action | Should -Be 'Delete'

        $pol = Merge-GpsPolicySet -Existing @() -Setting $low
        $pol = Merge-GpsPolicySet -Existing $pol -Setting @(ConvertTo-GpsPolicySetting -Policy $printers -State Disabled)
        @($pol | Where-Object { $_.ValueName -in 'Mode', 'LowExtra' }).Count | Should -Be 0
        ($pol | Where-Object ValueName -eq 'Restricted').Data | Should -Be 0
    }

    It 'element tipa list se izostavlja uz upozorenje' {
        $policy = $catalog | Where-Object Name -eq 'DeviceIdList'
        $s = @(ConvertTo-GpsPolicySetting -Policy $policy -WarningVariable w -WarningAction SilentlyContinue)
        $s.Count | Should -Be 1
        $s[0].valueName | Should -Be 'AllowDeviceIDs'
        "$w" | Should -BeLike "*list*DeviceIds*"
    }

    It 'longDecimal postaje REG_QWORD, a klasa User određuje scope' {
        $s = ConvertTo-GpsPolicySetting -Policy $quota
        $s.type | Should -Be 'REG_QWORD'
        $s.data | Should -Be 5000000000
        $s.scope | Should -Be 'User'
    }
}

Describe 'Write-GpsAuditLog' {
    It 'upisuje zapis u JSON lines' {
        $path = Join-Path $TestDrive 'audit.jsonl'
        Write-GpsAuditLog -Action 'Test' -Target 'PC' -Details @{ a = 1 } -Path $path
        $e = Get-Content $path | ConvertFrom-Json
        $e.action | Should -Be 'Test'
        $e.details.a | Should -Be 1
    }

    It 'ne ruši operaciju kad zapis ne uspije, nego upozorava' {
        $file = Join-Path $TestDrive 'nije-mapa.txt'
        Set-Content -Path $file -Value 'x'
        { Write-GpsAuditLog -Action 'Test' -Target 'PC' -Path (Join-Path $file 'audit.jsonl') -WarningVariable w -WarningAction SilentlyContinue } |
            Should -Not -Throw
        Write-GpsAuditLog -Action 'Test' -Target 'PC' -Path (Join-Path $file 'audit.jsonl') -WarningVariable w2 -WarningAction SilentlyContinue
        "$w2" | Should -BeLike '*nije upisan*'
    }
}

Describe 'Kodiranje datoteka' {
    It 'sve PowerShell datoteke imaju UTF-8 BOM (Windows PowerShell 5.1 inače čita ANSI)' {
        $root = Join-Path $PSScriptRoot '..'
        $files = Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
        $missing = foreach ($f in $files) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $f.Name }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'sve PowerShell datoteke (i lab skripte) parsiraju se bez sintaksnih grešaka' {
        $root = Join-Path $PSScriptRoot '..'
        $errors = foreach ($f in Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1') {
            $tokens = $null; $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
            foreach ($e in $parseErrors) { "$($f.Name):$($e.Extent.StartLineNumber) $($e.Message)" }
        }
        $errors | Should -BeNullOrEmpty
    }
}
