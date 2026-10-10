function Get-GpsAdmxCatalog {
    <#
    .SYNOPSIS
        Parsira ADMX/ADML predloške u katalog politika za GUI.
    .DESCRIPTION
        Za svaku politiku vraća: ime, prikazni naziv i opis (iz ADML-a), klasu (Machine/User/Both),
        registry ključ, valueName, enabled/disabled vrijednosti i elemente (boolean, decimal, text,
        enum, list, multiText) iz kojih GUI automatski gradi formu.
    .PARAMETER Path
        Mapa s *.admx datotekama. Zadano: Central Store u SYSVOL-u ako postoji, inače
        %windir%\PolicyDefinitions.
    .PARAMETER Language
        Jezik ADML-a (npr. hr-HR); ako ne postoji, koristi se en-US.
    .EXAMPLE
        Get-GpsAdmxCatalog -Language hr-HR | Where-Object DisplayName -like '*Update*'
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Language = (Get-Culture).Name,
        [string[]]$Filter = '*.admx'
    )

    # XML adapter vraća $null za nepostojeće atribute, što je u ADMX-u uobičajeno.
    Set-StrictMode -Off

    if (-not $Path) {
        $domain = $env:USERDNSDOMAIN
        $central = if ($domain) { "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions" }
        $Path = if ($central -and (Test-Path $central)) { $central } else { Join-Path $env:windir 'PolicyDefinitions' }
    }

    $valueOf = {
        param($node)
        if (-not $node) { return $null }
        $v = $node.FirstChild
        switch ($v.LocalName) {
            'string' { $v.InnerText }
            'decimal' { $v.GetAttribute('value') }
            default { $null } # <delete/> ili nepodržano
        }
    }

    foreach ($admxFile in Get-ChildItem -Path (Join-Path $Path '*') -Include $Filter -File) {
        try { [xml]$admx = Get-Content -LiteralPath $admxFile.FullName -Raw -Encoding UTF8 }
        catch { Write-Warning "Ne mogu pročitati $($admxFile.Name): $_"; continue }

        $strings = @{}
        $baseName = [IO.Path]::GetFileNameWithoutExtension($admxFile.Name)
        foreach ($lang in @($Language, 'en-US') | Select-Object -Unique) {
            $admlPath = Join-Path (Join-Path $Path $lang) "$baseName.adml"
            if (Test-Path -LiteralPath $admlPath) {
                [xml]$adml = Get-Content -LiteralPath $admlPath -Raw -Encoding UTF8
                foreach ($s in $adml.policyDefinitionResources.resources.stringTable.string) { $strings[$s.id] = $s.'#text' }
                break
            }
        }
        $resolve = {
            param([string]$ref)
            if ($ref -match '^\$\(string\.(.+)\)$') { if ($strings.ContainsKey($Matches[1])) { return $strings[$Matches[1]] } return $Matches[1] }
            $ref
        }

        $root = $admx.policyDefinitions
        $categories = @{}
        if ($root.categories) {
            foreach ($c in $root.categories.category) {
                $categories[$c.name] = [pscustomobject]@{
                    Name        = $c.name
                    DisplayName = & $resolve $c.displayName
                    Parent      = if ($c.parentCategory) { $c.parentCategory.ref } else { $null }
                }
            }
        }
        if (-not $root.policies) { continue }

        foreach ($p in $root.policies.policy) {
            $elements = @()
            if ($p.elements) {
                foreach ($el in $p.elements.ChildNodes) {
                    if ($el.NodeType -ne 'Element') { continue }
                    $elements += [pscustomobject]@{
                        Kind      = $el.LocalName
                        Id        = $el.id
                        Key       = if ($el.key) { $el.key } else { $p.key }
                        ValueName = $el.valueName
                        Required  = $el.required -eq 'true'
                        Expandable = $el.expandable -eq 'true'
                        StoreAsText = $el.storeAsText -eq 'true'
                        MinValue  = $el.minValue
                        MaxValue  = $el.maxValue
                        Items     = if ($el.LocalName -eq 'enum') {
                            @(foreach ($i in $el.item) {
                                    [pscustomobject]@{
                                        DisplayName = & $resolve $i.displayName
                                        Type        = $i.value.FirstChild.LocalName
                                        Value       = & $valueOf $i.value
                                    }
                                })
                        } else { @() }
                    }
                }
            }

            $categoryRef = if ($p.parentCategory) { $p.parentCategory.ref } else { $null }
            $categoryName = if ($categoryRef -and $categories.ContainsKey($categoryRef)) { $categories[$categoryRef].DisplayName } else { $categoryRef }

            [pscustomobject]@{
                PSTypeName    = 'GpoStudio.AdmxPolicy'
                Name          = $p.name
                DisplayName   = & $resolve $p.displayName
                Explain       = & $resolve $p.explainText
                Class         = $p.class
                Category      = $categoryName
                CategoryRef   = $categoryRef
                Key           = $p.key
                ValueName     = $p.valueName
                EnabledValue  = & $valueOf $p['enabledValue']
                DisabledValue = & $valueOf $p['disabledValue']
                EnabledType   = if ($p['enabledValue']) { $p['enabledValue'].FirstChild.LocalName } else { $null }
                DisabledType  = if ($p['disabledValue']) { $p['disabledValue'].FirstChild.LocalName } else { $null }
                Elements      = $elements
                Source        = $admxFile.Name
            }
        }
    }
}
