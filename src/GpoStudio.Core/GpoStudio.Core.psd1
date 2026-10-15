@{
    RootModule        = 'GpoStudio.Core.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '6f0e8d1c-3b52-4f0a-9a57-2c1f7d3e9b10'
    Author            = 'GPO Studio'
    Description       = 'Jezgra GPO Studija: Registry.pol, ADMX katalog, Policy Set model, diff i sigurnosne kontrole.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Read-GpsRegistryPol', 'Write-GpsRegistryPol',
        'New-GpsPolicySet', 'New-GpsPolicySetting', 'ConvertTo-GpsPolicySet', 'Import-GpsPolicySet', 'Export-GpsPolicySet',
        'Merge-GpsPolicySet', 'Compare-GpsPolicySet',
        'Get-GpsAdmxCatalog', 'ConvertTo-GpsPolicySetting', 'Write-GpsAuditLog',
        'Get-GpsControlCatalog', 'Test-GpsControlCatalog', 'Get-GpsControlOption', 'Get-GpsControlLevelOption', 'Get-GpsOptionalProperty', 'Get-GpsControlSelection', 'Get-GpsControlOptionSettings',
        'ConvertTo-GpsControlPolicySet', 'Get-GpsControlCompliance',
        'Get-GpsControlPreset', 'Get-GpsControlPresetFolder', 'Import-GpsControlPreset', 'Export-GpsControlPreset',
        'New-GpsControlPreset', 'Resolve-GpsControlPreset',
        'Get-GpsControlStateQuery', 'Resolve-GpsControlState', 'ConvertTo-GpsComplianceHtml'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
}
