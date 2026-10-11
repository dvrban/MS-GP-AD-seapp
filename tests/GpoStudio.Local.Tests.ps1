BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\GpoStudio.Local\GpoStudio.Local.psm1') -Force
}

Describe 'gpt.ini' {
    It 'povećava verziju Machine dijela i dodaje CSE za Administrative Templates' {
        InModuleScope GpoStudio.Local {
            $root = Join-Path $TestDrive 'gp1'
            $null = New-Item -ItemType Directory -Path $root
            Set-Content -Path (Join-Path $root 'gpt.ini') -Value @('[General]', 'Version=65538') # User=1, Machine=2

            Update-GpsGptIni -Root $root -Scope Machine -ExtensionNames $script:GpsAdmCse

            $ini = Get-Content (Join-Path $root 'gpt.ini')
            $ini | Should -Contain 'Version=65539'
            ($ini | Where-Object { $_ -like 'gPCMachineExtensionNames=*' }) |
                Should -Be "gPCMachineExtensionNames=$($script:GpsAdmCse.Machine)"
        }
    }

    It 'povećava User dio verzije (gornjih 16 bitova)' {
        InModuleScope GpoStudio.Local {
            $root = Join-Path $TestDrive 'gp2'
            $null = New-Item -ItemType Directory -Path $root
            Update-GpsGptIni -Root $root -Scope User -ExtensionNames $script:GpsAdmCse
            Get-Content (Join-Path $root 'gpt.ini') | Should -Contain 'Version=65536'
        }
    }
}

Describe 'Payload za udaljena računala' {
    It 'se izvršava u čistom runspaceu bez učitanih modula' {
        $payload = InModuleScope GpoStudio.Local { Get-GpsRemotePayload }
        $pol = Join-Path $TestDrive 'remote.pol'

        $ps = [powershell]::Create()
        try {
            $null = $ps.AddScript({
                    param($payload, $pol)
                    . ([scriptblock]::Create($payload))
                    $settings = @([pscustomobject]@{ scope = 'Machine'; key = 'Software\X'; valueName = 'V'; type = 'REG_DWORD'; data = 7; action = 'Set' })
                    $merged = Merge-GpsPolicySet -Existing @() -Setting $settings
                    Write-GpsRegistryPol -Path $pol -Entry $merged
                    $read = @(Read-GpsRegistryPol -Path $pol)
                    [pscustomobject]@{
                        Data   = $read[0].Data
                        Diff   = (Compare-GpsPolicySet -Current $read -Setting $settings).Status
                        Audit  = $script:GpsAuditGuids['Logon']
                    }
                }).AddArgument($payload).AddArgument($pol)
            $result = $ps.Invoke()
            $ps.Streams.Error | Should -BeNullOrEmpty
        }
        finally { $ps.Dispose() }

        $result[0].Data | Should -Be 7
        $result[0].Diff | Should -Be 'Unchanged'
        $result[0].Audit | Should -Be '{0CCE9215-69AE-11D9-BED3-505054503030}'
    }
}

Describe 'Invoke-GpsLocalApplyCore' {
    BeforeAll {
        # Get-CimInstance ne postoji u PowerShellu na Linuxu; Pester treba postojeću naredbu za Mock.
        if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
            function global:Get-CimInstance { param($ClassName) }
            $script:cimStub = $true
        }
    }
    AfterAll { if ($script:cimStub) { Remove-Item function:global:Get-CimInstance } }

    It 'diff radi i kad Policy Set nema security ni audit (StrictMode)' {
        InModuleScope GpoStudio.Local {
            Mock Get-CimInstance { [pscustomobject]@{ PartOfDomain = $false } }
            Mock Get-GpsLocalGpRoot { Join-Path $TestDrive 'GroupPolicy' }
            $json = [pscustomobject]@{
                name     = 'Bez sigurnosti'
                settings = @([pscustomobject]@{ scope = 'Machine'; key = 'Software\X'; valueName = 'V'; type = 'REG_DWORD'; data = 1; action = 'Set' })
            } | ConvertTo-Json -Depth 5

            $r = Invoke-GpsLocalApplyCore -PolicySetJson $json -WhatIfMode $true
            $r.Status | Should -Be 'WhatIf'
            @($r.Diff).Status | Should -Be 'Added'
        }
    }
}

Describe 'Restore-GpsLocalPolicyCore' {
    It 'ne dira GroupPolicy mapu kad putanja nije backup' {
        InModuleScope GpoStudio.Local {
            $gpRoot = Join-Path $TestDrive 'GroupPolicy'
            $null = New-Item -ItemType Directory -Path (Join-Path $gpRoot 'Machine') -Force
            Set-Content -Path (Join-Path $gpRoot 'gpt.ini') -Value '[General]', 'Version=1'
            Mock Get-GpsLocalGpRoot { Join-Path $TestDrive 'GroupPolicy' }

            $missing = Restore-GpsLocalPolicyCore -BackupPath (Join-Path $TestDrive 'nema-ga')
            $missing.Status | Should -Be 'Error'

            $notBackup = Join-Path $TestDrive 'neka-mapa'
            $null = New-Item -ItemType Directory -Path $notBackup
            (Restore-GpsLocalPolicyCore -BackupPath $notBackup).Status | Should -Be 'Error'

            Test-Path (Join-Path $gpRoot 'gpt.ini') | Should -BeTrue
        }
    }
}

Describe 'Prepoznavanje lokalnog računala' {
    It 'vlastito DNS ime je lokalno, a tuđe nije' {
        InModuleScope GpoStudio.Local {
            Test-GpsIsLocalComputer ([System.Net.Dns]::GetHostName()) | Should -BeTrue
            Test-GpsIsLocalComputer 'LOCALHOST' | Should -BeTrue
            Test-GpsIsLocalComputer 'neko-drugo-racunalo.example.invalid' | Should -BeFalse
        }
    }
}
