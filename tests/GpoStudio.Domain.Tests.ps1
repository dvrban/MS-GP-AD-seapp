BeforeAll {
    # Zamjenske funkcije za RSAT cmdlete, da se modul može testirati bez domene.
    $script:rsatStubs = 'Get-ADDomain', 'Get-GPO', 'New-GPO', 'Backup-GPO', 'Get-GPRegistryValue', 'Set-GPRegistryValue',
        'Get-GPInheritance', 'New-GPLink', 'Set-GPPermission', 'Get-ADGroup'
    foreach ($name in $script:rsatStubs) {
        Set-Item -Path "function:global:$name" -Value {
            [CmdletBinding()]
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
    # Remove-Item 'function:global:Ime' javi uspjeh, a funkciju ne ukloni; ispravna putanja je 'Function:\Ime'.
    # Zaostale zamjenske funkcije skrivale bi prave RSAT cmdlete u sesiji u kojoj su testovi pokrenuti.
    foreach ($name in $script:rsatStubs) { if (Test-Path "Function:\$name") { Remove-Item "Function:\$name" } }
    $left = @($script:rsatStubs | Where-Object { Test-Path "Function:\$_" })
    if ($left) { throw "Zamjenske funkcije su ostale u sesiji: $($left -join ', ')" }
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

    It 'uspoređuje HKLM i HKCU odvojeno kad dijele ključ i vrijednost' {
        Mock -ModuleName GpoStudio.Domain Get-GPO { [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555' } }
        Mock -ModuleName GpoStudio.Domain Backup-GPO { [pscustomobject]@{ Id = [guid]::NewGuid() } }
        Mock -ModuleName GpoStudio.Domain Get-GPRegistryValue {
            $v = if ($Key -like 'HKLM*') { 1 } else { 2 }
            [pscustomobject]@{ PolicyState = 'Set'; Type = 'DWord'; Value = $v }
        }
        $both = New-GpsPolicySet -Name 'Both' -Setting @(
            New-GpsPolicySetting -Scope Machine -Key 'Software\Policies\Z' -ValueName 'V' -Type REG_DWORD -Data 5
            New-GpsPolicySetting -Scope User -Key 'Software\Policies\Z' -ValueName 'V' -Type REG_DWORD -Data 2
        )
        $r = Publish-GpsDomainPolicy -PolicySet $both -GpoName 'WS' -Confirm:$false
        ($r.Diff | Where-Object Scope -eq 'Machine').Status | Should -Be 'Changed'
        ($r.Diff | Where-Object Scope -eq 'User').Status | Should -Be 'Unchanged'
        Should -Invoke -ModuleName GpoStudio.Domain Set-GPRegistryValue -Times 1 -Exactly
        Should -Invoke -ModuleName GpoStudio.Domain Set-GPRegistryValue -Times 1 -ParameterFilter { $Key -eq 'HKLM\Software\Policies\Z' }
    }

    It 'DWORD koji GP API vraća kao Int32 -1 nije Changed' {
        Mock -ModuleName GpoStudio.Domain Get-GPO { [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555' } }
        Mock -ModuleName GpoStudio.Domain Get-GPRegistryValue { [pscustomobject]@{ PolicyState = 'Set'; Type = 'DWord'; Value = [int32]-1 } }
        $big = New-GpsPolicySet -Name 'Big' -Setting @(New-GpsPolicySetting -Key 'Software\Policies\X' -ValueName 'Big' -Type REG_DWORD -Data 4294967295)
        (Publish-GpsDomainPolicy -PolicySet $big -GpoName 'WS' -WhatIf).Diff.Status | Should -Be 'Unchanged'
    }

    It 'ne mijenja postojeći GPO kad backup ne uspije' {
        Mock -ModuleName GpoStudio.Domain Get-GPO { [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555' } }
        Mock -ModuleName GpoStudio.Domain Backup-GPO { throw 'Pristup odbijen' }
        { Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS' -Confirm:$false } | Should -Throw '*Backup*'
        Should -Invoke -ModuleName GpoStudio.Domain Set-GPRegistryValue -Times 0
    }

    It 'ne radi ništa kad grupa za filtriranje ne postoji' {
        Mock -ModuleName GpoStudio.Domain Get-ADGroup { throw 'Cannot find an object with identity' }
        { Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS' -ApplyToGroup 'GPS-Pilt' -LinkTarget 'OU=PC,DC=firma,DC=local' -Confirm:$false } |
            Should -Throw '*GPS-Pilt*'
        Should -Invoke -ModuleName GpoStudio.Domain New-GPO -Times 0
        Should -Invoke -ModuleName GpoStudio.Domain New-GPLink -Times 0
    }

    It 'ne povezuje GPO kad sigurnosno filtriranje ne uspije' {
        Mock -ModuleName GpoStudio.Domain Get-ADGroup { [pscustomobject]@{ Name = 'GPS-Pilot' } }
        Mock -ModuleName GpoStudio.Domain Set-GPPermission { throw 'trustee not found' }
        { Publish-GpsDomainPolicy -PolicySet $set -GpoName 'WS' -ApplyToGroup 'GPS-Pilot' -LinkTarget 'OU=PC,DC=firma,DC=local' -Confirm:$false } |
            Should -Throw
        Should -Invoke -ModuleName GpoStudio.Domain New-GPLink -Times 0
        Should -Invoke -ModuleName GpoStudio.Domain Write-GpsAuditLog -Times 1 -ParameterFilter { $Result -eq 'Error' -and -not $Details.linked }
    }

    It 'odbija zadani domenski GPO bez -Force' {
        Mock -ModuleName GpoStudio.Domain Get-GPO { [pscustomobject]@{ Id = [guid]'31B2F340-016D-11D2-945F-00C04FB984F9' } }
        { Publish-GpsDomainPolicy -PolicySet $set -GpoName 'Default Domain Policy' -Confirm:$false } | Should -Throw '*-Force*'
    }
}

Describe 'Get-GpsDomainContext' {
    It 'javlja jasnu grešku kad Get-ADDomain ne vrati domenu' {
        Mock -ModuleName GpoStudio.Domain Import-GpsRsatModules {}
        Mock -ModuleName GpoStudio.Domain Get-ADDomain { }
        { Get-GpsDomainContext } | Should -Throw '*Get-ADDomain*'
    }
}

Describe 'Import-GpsRsatModules' {
    It 'u PowerShellu 7 javlja da domenski dio traži Windows PowerShell 5.1' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        InModuleScope GpoStudio.Domain { { Import-GpsRsatModules } | Should -Throw '*5.1*' }
    }
}
