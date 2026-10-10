BeforeAll {
    # Zamjenske funkcije za RSAT cmdlete, da se modul može testirati bez domene.
    foreach ($name in 'Get-ADDomain', 'Get-GPO', 'New-GPO', 'Backup-GPO', 'Get-GPRegistryValue', 'Set-GPRegistryValue',
        'Get-GPInheritance', 'New-GPLink', 'Set-GPPermission') {
        Set-Item -Path "function:global:$name" -Value {
            param($Identity, $Name, $Guid, $Domain, $Server, $Key, $ValueName, $Type, $Value, [switch]$Disable,
                $Target, $LinkEnabled, $Comment, $Path, $TargetName, $TargetType, $PermissionLevel, [switch]$Replace)
        }
    }
    Import-Module (Join-Path $PSScriptRoot '..\src\GpoStudio.Domain\GpoStudio.Domain.psm1') -Force

    $script:set = New-GpsPolicySet -Name 'Test' -Setting @(
        New-GpsPolicySetting -Scope Machine -Key 'Software\Policies\X' -ValueName 'Big' -Type REG_DWORD -Data 4294967295
        New-GpsPolicySetting -Scope User -Key 'Software\Policies\Y' -ValueName 'Txt' -Type REG_SZ -Data 'a'
        New-GpsPolicySetting -Scope Machine -Key 'Software\Policies\X' -ValueName 'Old' -Action Delete
    )
}

AfterAll {
    foreach ($name in 'Get-ADDomain', 'Get-GPO', 'New-GPO', 'Backup-GPO', 'Get-GPRegistryValue', 'Set-GPRegistryValue',
        'Get-GPInheritance', 'New-GPLink', 'Set-GPPermission') { Remove-Item "function:global:$name" -ErrorAction SilentlyContinue }
}

Describe 'Publish-GpsDomainPolicy' {
    BeforeEach {
        Mock -ModuleName GpoStudio.Domain Import-GpsRsatModules {}
        Mock -ModuleName GpoStudio.Domain Get-ADDomain { [pscustomobject]@{ DNSRoot = 'firma.local'; DistinguishedName = 'DC=firma,DC=local'; PDCEmulator = 'dc01.firma.local' } }
        Mock -ModuleName GpoStudio.Domain Get-GPO { $null }
        Mock -ModuleName GpoStudio.Domain New-GPO { [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555'; DisplayName = $Name } }
        Mock -ModuleName GpoStudio.Domain Set-GPRegistryValue {}
        Mock -ModuleName GpoStudio.Domain Get-GPInheritance { [pscustomobject]@{ GpoLinks = @() } }
        Mock -ModuleName GpoStudio.Domain New-GPLink {}
        Mock -ModuleName GpoStudio.Domain Write-GpsAuditLog {}
    }

    It 'WhatIf vraća diff bez kreiranja GPO-a' {
        $r = Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS' -WhatIf
        $r.Status | Should -Be 'WhatIf'
        @($r.Diff).Count | Should -Be 3
        Should -Invoke -ModuleName GpoStudio.Domain New-GPO -Times 0
    }

    It 'kreira GPO na PDC-u, upisuje vrijednosti i povezuje ga' {
        $r = Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS' -LinkTarget 'OU=PC,DC=firma,DC=local' -Confirm:$false
        $r.Status | Should -Be 'OK'

        Should -Invoke -ModuleName GpoStudio.Domain New-GPO -Times 1 -ParameterFilter { $Server -eq 'dc01.firma.local' }
        Should -Invoke -ModuleName GpoStudio.Domain Set-GPRegistryValue -Times 1 -ParameterFilter {
            $Key -eq 'HKLM\Software\Policies\X' -and $ValueName -eq 'Big' -and $Type -eq 'DWord' -and $Value -eq -1
        }
        Should -Invoke -ModuleName GpoStudio.Domain Set-GPRegistryValue -Times 1 -ParameterFilter {
            $Key -eq 'HKCU\Software\Policies\Y' -and $Type -eq 'String' -and $Value -eq 'a'
        }
        Should -Invoke -ModuleName GpoStudio.Domain Set-GPRegistryValue -Times 1 -ParameterFilter { $ValueName -eq 'Old' -and $Disable }
        Should -Invoke -ModuleName GpoStudio.Domain New-GPLink -Times 1 -ParameterFilter { $Target -eq 'OU=PC,DC=firma,DC=local' }
    }

    It 'odbija zadani domenski GPO bez -Force' {
        Mock -ModuleName GpoStudio.Domain Get-GPO { [pscustomobject]@{ Id = [guid]'31B2F340-016D-11D2-945F-00C04FB984F9' } }
        { Publish-GpsDomainPolicy -PolicySet $set -GpoName 'Default Domain Policy' -Confirm:$false } | Should -Throw '*-Force*'
    }
}
