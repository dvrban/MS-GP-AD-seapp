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
