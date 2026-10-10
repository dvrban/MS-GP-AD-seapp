function ConvertTo-GpsPolicySetting {
    <#
    .SYNOPSIS
        Pretvara ADMX politiku iz kataloga + odabir korisnika (Enabled/Disabled, vrijednosti elemenata)
        u postavke Policy Seta, po istim pravilima kao gpedit/GPMC.
    .DESCRIPTION
        Enabled : valueName dobiva enabledValue (zadano DWORD 1); elementi dobivaju unesene vrijednosti.
        Disabled: valueName dobiva disabledValue, a ako ga nema, vrijednost se briše (**del.);
                  vrijednosti elemenata se brišu.
    .EXAMPLE
        $p = Get-GpsAdmxCatalog | Where-Object Name -eq 'RemoveWindowsStore_2'
        ConvertTo-GpsPolicySetting -Policy $p -State Enabled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [ValidateSet('Enabled', 'Disabled')][string]$State = 'Enabled',
        [ValidateSet('Machine', 'User')][string]$Scope,
        [hashtable]$ElementValues = @{}
    )

    if (-not $Scope) {
        $Scope = if ($Policy.Class -eq 'User') { 'User' } else { 'Machine' }
    }
    $common = @{ Scope = $Scope; DisplayName = $Policy.DisplayName }
    $idBase = "$($Policy.Source)/$($Policy.Name)"

    $typeOf = { param($kind) if ($kind -eq 'string') { 'REG_SZ' } else { 'REG_DWORD' } }

    if ($Policy.ValueName) {
        $value = if ($State -eq 'Enabled') { $Policy.EnabledValue } else { $Policy.DisabledValue }
        $kind = if ($State -eq 'Enabled') { $Policy.EnabledType } else { $Policy.DisabledType }
        if ($State -eq 'Enabled' -and -not $kind) { $value = 1; $kind = 'decimal' }

        if ($kind -in 'decimal', 'string') {
            $data = if ($kind -eq 'decimal') { [uint32]$value } else { [string]$value }
            New-GpsPolicySetting @common -Id $idBase -Key $Policy.Key -ValueName $Policy.ValueName -Type (& $typeOf $kind) -Data $data
        }
        else {
            New-GpsPolicySetting @common -Id $idBase -Key $Policy.Key -ValueName $Policy.ValueName -Action Delete
        }
    }

    foreach ($el in @($Policy.Elements)) {
        if (-not $el -or -not $el.ValueName) { continue } # npr. 'list' bez valueName (faza 2)
        $id = "$idBase/$($el.Id)"

        if ($State -eq 'Disabled') {
            New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Action Delete
            continue
        }

        $hasValue = $ElementValues.ContainsKey($el.Id) -and $null -ne $ElementValues[$el.Id] -and "$($ElementValues[$el.Id])" -ne ''
        if (-not $hasValue) {
            if ($el.Required) { throw "Element '$($el.Id)' politike '$($Policy.DisplayName)' je obavezan." }
            continue
        }
        $v = $ElementValues[$el.Id]

        switch ($el.Kind) {
            'decimal' {
                $n = [decimal]$v
                if (($el.MinValue -and $n -lt [decimal]$el.MinValue) -or ($el.MaxValue -and $n -gt [decimal]$el.MaxValue)) {
                    throw "Vrijednost $n za '$($el.Id)' nije u rasponu $($el.MinValue)-$($el.MaxValue)."
                }
                if ($el.StoreAsText) { New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Type REG_SZ -Data ([string]$n) }
                else { New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Type REG_DWORD -Data ([uint32]$n) }
            }
            'boolean' {
                New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Type REG_DWORD -Data ([uint32][bool]$v)
            }
            'text' {
                $type = if ($el.Expandable) { 'REG_EXPAND_SZ' } else { 'REG_SZ' }
                New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Type $type -Data ([string]$v)
            }
            'multiText' {
                New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Type REG_MULTI_SZ -Data @($v)
            }
            'enum' {
                $item = @($el.Items) | Where-Object { $_.DisplayName -eq $v -or "$($_.Value)" -eq "$v" } | Select-Object -First 1
                if (-not $item) { throw "Vrijednost '$v' nije dopuštena za '$($el.Id)'." }
                $data = if ($item.Type -eq 'string') { [string]$item.Value } else { [uint32]$item.Value }
                New-GpsPolicySetting @common -Id $id -Key $el.Key -ValueName $el.ValueName -Type (& $typeOf $item.Type) -Data $data
            }
            default { Write-Warning "Element tipa '$($el.Kind)' ($($el.Id)) još nije podržan." }
        }
    }
}
