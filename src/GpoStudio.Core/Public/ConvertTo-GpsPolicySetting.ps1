function ConvertTo-GpsPolicySetting {
    <#
    .SYNOPSIS
        Pretvara ADMX politiku iz kataloga + odabir korisnika (Enabled/Disabled, vrijednosti elemenata)
        u postavke Policy Seta, po istim pravilima kao gpedit/GPMC.
    .DESCRIPTION
        Enabled : valueName dobiva enabledValue (zadano DWORD 1), upisuje se enabledList, a elementi
                  dobivaju unesene vrijednosti (boolean: trueValue/falseValue, enum: vrijednost + valueList).
        Disabled: valueName dobiva disabledValue, a ako ga nema, vrijednost se briše (**del.);
                  upisuje se disabledList (ako je nema, brišu se vrijednosti iz enabledList);
                  boolean s eksplicitnom falseValue/falseList dobiva tu vrijednost, ostali elementi se brišu.
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

    $typeOf = {
        param($kind)
        switch ($kind) {
            'decimal' { 'REG_DWORD' }
            'longDecimal' { 'REG_QWORD' }
            'string' { 'REG_SZ' }
            default { throw "Nepodržan tip vrijednosti '$kind' u politici '$($Policy.DisplayName)'." }
        }
    }
    # Jedna registry vrijednost iz ADMX-a (decimal / longDecimal / string / delete).
    $emit = {
        param([string]$Id, [string]$Key, [string]$ValueName, $Kind, $Value)
        if ($Kind -eq 'delete') {
            New-GpsPolicySetting @common -Id $Id -Key $Key -ValueName $ValueName -Action Delete
            return
        }
        $type = & $typeOf $Kind
        $data = switch ($Kind) {
            'decimal' { [uint32]$Value }
            'longDecimal' { [uint64]$Value }
            default { [string]$Value }
        }
        New-GpsPolicySetting @common -Id $Id -Key $Key -ValueName $ValueName -Type $type -Data $data
    }
    $emitList = {
        param($List, [string]$IdPrefix, [switch]$AsDelete)
        foreach ($i in @($List)) {
            if (-not $i) { continue }
            $kind = if ($AsDelete) { 'delete' } else { $i.Type }
            & $emit "$IdPrefix/$($i.ValueName)" $i.Key $i.ValueName $kind $i.Value
        }
    }

    $result = @(
        if ($Policy.ValueName) {
            if ($State -eq 'Enabled') {
                if ($Policy.EnabledType) { & $emit $idBase $Policy.Key $Policy.ValueName $Policy.EnabledType $Policy.EnabledValue }
                else { & $emit $idBase $Policy.Key $Policy.ValueName 'decimal' 1 }
            }
            elseif ($Policy.DisabledType) { & $emit $idBase $Policy.Key $Policy.ValueName $Policy.DisabledType $Policy.DisabledValue }
            else { & $emit $idBase $Policy.Key $Policy.ValueName 'delete' $null }
        }

        if ($State -eq 'Enabled') { & $emitList $Policy.EnabledList "$idBase/enabledList" }
        elseif (@($Policy.DisabledList).Count -gt 0) { & $emitList $Policy.DisabledList "$idBase/disabledList" }
        else { & $emitList $Policy.EnabledList "$idBase/enabledList" -AsDelete }

        foreach ($el in @($Policy.Elements)) {
            if (-not $el -or -not $el.ValueName) { continue } # npr. 'list' bez valueName (faza 2)
            $id = "$idBase/$($el.Id)"

            if ($State -eq 'Disabled') {
                if ($el.Kind -eq 'boolean' -and ($el.FalseType -or @($el.FalseList).Count -gt 0)) {
                    if ($el.FalseType) { & $emit $id $el.Key $el.ValueName $el.FalseType $el.FalseValue }
                    & $emitList $el.FalseList "$id/falseList"
                }
                else {
                    & $emit $id $el.Key $el.ValueName 'delete' $null
                }
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
                    if ($el.StoreAsText) { & $emit $id $el.Key $el.ValueName 'string' ([string]$n) }
                    else { & $emit $id $el.Key $el.ValueName 'decimal' $n }
                }
                'boolean' {
                    $on = [bool]$v
                    $kind = if ($on) { $el.TrueType } else { $el.FalseType }
                    $value = if ($on) { $el.TrueValue } else { $el.FalseValue }
                    if ($kind) { & $emit $id $el.Key $el.ValueName $kind $value }
                    else { & $emit $id $el.Key $el.ValueName 'decimal' ([uint32]$on) }
                    & $emitList $(if ($on) { $el.TrueList } else { $el.FalseList }) "$id/$(if ($on) { 'trueList' } else { 'falseList' })"
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
                    & $emit $id $el.Key $el.ValueName $item.Type $item.Value
                    & $emitList $item.ValueList "$id/valueList"
                }
                default { Write-Warning "Element tipa '$($el.Kind)' ($($el.Id)) još nije podržan." }
            }
        }
    )

    if ($result.Count -eq 0) {
        throw "Politika '$($Policy.DisplayName)' nema registry vrijednosti koje GPO Studio zasad podržava."
    }
    $result
}
