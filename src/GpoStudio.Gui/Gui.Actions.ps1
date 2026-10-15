<#
    Radnje nad ciljem: pregled promjena (diff), primjena, sigurnosna kopija, vraćanje i provjera
    replikacije. Vrijede za otvorenu stranicu: sigurnosne postavke ili napredni Policy Set.
    Učitava ga Start-GpoStudio.ps1 (dot-source).
#>

function Get-UiTarget {
    $mode = if ($ui.rbTargetDomain.IsChecked) { 'Domain' } elseif ($ui.rbTargetRemote.IsChecked) { 'Remote' } else { 'Local' }
    $computers = @()
    if ($mode -eq 'Remote') {
        # Bez duplikata (velika i mala slova su ista): dvaput isto računalo pokrenulo bi dvije primjene.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $computers = @($ui.txtComputers.Text -split '[,;\s]+' | Where-Object { $_ -and $seen.Add($_) })
    }
    [pscustomobject]@{
        Mode      = $mode
        Computers = $computers
        Gpo       = $ui.txtGpoName.Text.Trim()
        Link      = $ui.txtLinkTarget.Text.Trim()
        Group     = $ui.txtApplyGroup.Text.Trim()
        Domain    = $ui.txtDomain.Text.Trim()
        Text      = switch ($mode) {
            'Local' { 'ovo računalo' }
            'Remote' { if ($computers) { $computers -join ', ' } else { '(upišite računala)' } }
            'Domain' { if ($ui.txtGpoName.Text.Trim()) { "GPO '$($ui.txtGpoName.Text.Trim())'" } else { '(upišite naziv GPO-a)' } }
        }
    }
}

function Update-TargetUi {
    $t = Get-UiTarget
    $ui.pnlRemote.Visibility = if ($t.Mode -eq 'Remote') { 'Visible' } else { 'Collapsed' }
    $ui.pnlDomain.Visibility = if ($t.Mode -eq 'Domain') { 'Visible' } else { 'Collapsed' }
    $ui.btnReplication.Visibility = if ($t.Mode -eq 'Domain') { 'Visible' } else { 'Collapsed' }
    $ui.chipTarget.Content = 'CILJ: ' + $(switch ($t.Mode) { 'Local' { 'OVO RAČUNALO' } 'Remote' { 'DRUGA RAČUNALA' } 'Domain' { 'DOMENSKI GPO' } })
    $ui.stTarget.Text = $t.Text.ToUpperInvariant()
}

function Test-UiTarget($Target) {
    if ($Target.Mode -eq 'Remote' -and -not $Target.Computers) {
        $null = Show-AuxDialog -Message 'Upišite barem jedno računalo u traku CILJ (npr. PC01, PC02).' -Kind Warning; return $false
    }
    if ($Target.Mode -eq 'Domain' -and -not $Target.Gpo) {
        $null = Show-AuxDialog -Message 'Upišite naziv GPO-a u traku CILJ.' -Kind Warning; return $false
    }
    $true
}

function Get-UiActivePolicySet([switch]$Domain) {
    # Napredna stranica radi sa svojim Policy Setom, ostale sa sigurnosnim postavkama; stranice Promjene i
    # Dnevnik zadržavaju izvor zadnje stranice (pregled naprednog seta mora primijeniti taj isti set).
    if ($Gui.ActionSource -eq 'Advanced') {
        if (-not $ui.txtSetName.Text.Trim()) { $null = Show-AuxDialog -Message 'Upišite naziv Policy Seta na stranici Napredno.' -Kind Warning; return $null }
        $set = Get-UiAdvancedPolicySet
        return [pscustomobject]@{ Set = $set; Source = "napredni Policy Set '$($set.name)'"; Lookup = @{}; Skipped = @() }
    }
    $title = Get-SelectionTitle
    # Domenski GPO zasad ne prima lozinke ni reviziju: takve kontrole se izostavljaju cijele, da se ne
    # objavi samo dio (npr. "prednost podkategorija revizije" bez samih podkategorija).
    $selection = $Sec.Selection
    $skipped = @()
    if ($Domain) {
        $selection = [ordered]@{}
        foreach ($c in @($Sec.Catalog.controls)) {
            $optionId = $Sec.Selection[$c.id]
            $o = if ($optionId) { Get-GpsControlOption $c $optionId } else { $null }
            if ($o -and ((Get-GpsOptionalProperty $o 'security') -or (Get-GpsOptionalProperty $o 'audit'))) { $skipped += $c.title; $optionId = $null }
            $selection[$c.id] = $optionId
        }
    }
    $set = ConvertTo-GpsControlPolicySet -Catalog $Sec.Catalog -Selection $selection -Name "GPO Studio: $title" `
        -Description "Sigurnosne postavke iz GPO Studija ($title)." -WarningVariable buildWarnings -WarningAction SilentlyContinue
    foreach ($w in $buildWarnings) { Write-UiLog "$w" -Level Warning }

    # Nazivi za prikaz promjena: registry vrijednost / security ključ / podkategorija -> "Kontrola: opcija".
    $lookup = @{}
    foreach ($s in $set.settings) { $lookup["reg|$($s.scope)\$($s.key)\$($s.valueName)".ToLowerInvariant()] = $s.displayName }
    foreach ($c in @($Sec.Catalog.controls)) {
        $optionId = $selection[$c.id]
        if (-not $optionId) { continue }
        $o = Get-GpsControlOption $c $optionId
        foreach ($k in (Get-GpsOptionalProperty $o 'security' | ForEach-Object { $_.PSObject.Properties.Name })) { $lookup["sec|$k"] = "$($c.title): $($o.title)" }
        foreach ($k in (Get-GpsOptionalProperty $o 'audit' | ForEach-Object { $_.PSObject.Properties.Name })) { $lookup["aud|$k"] = "$($c.title): $($o.title)" }
    }
    [pscustomobject]@{ Set = $set; Source = "sigurnosne postavke ($title)"; Lookup = $lookup; Skipped = $skipped }
}

function Test-UiPolicySetEmpty($Set) {
    if ($null -eq $Set) { return $true }
    @($Set.settings).Count -eq 0 -and $Set.security.Count -eq 0 -and $Set.audit.Count -eq 0
}

function Show-UiChanges {
    param($Results, $Active, [string]$Target, [switch]$Domain, [switch]$Applied, [string[]]$Expected)
    $previewTexts = @{ Added = 'DODAJE SE'; Changed = 'MIJENJA SE'; Removed = 'BRIŠE SE'; Unchanged = 'BEZ PROMJENE'; Planned = 'POSTAVLJA SE' }
    $appliedTexts = @{ Added = 'DODANO'; Changed = 'PROMIJENJENO'; Removed = 'OBRISANO'; Unchanged = 'BEZ PROMJENE'; Planned = 'POSTAVLJENO' }
    $chipTexts = if ($Applied) { $appliedTexts.Clone() } else { $previewTexts.Clone() }
    $chipTexts.Failed = 'NIJE PRIMIJENJENO'
    $rows = [System.Collections.Generic.List[object]]::new()
    $failed = 0
    # Računalo koje nije odgovorilo (WinRM) ne vraća rezultat; to je greška, a ne uspjeh.
    $answered = @($Results | Where-Object { $_ } | ForEach-Object { ([string]$_.ComputerName).Split('.')[0] })
    foreach ($e in @($Expected | Where-Object { $_ })) {
        if ($answered -notcontains $e.Split('.')[0]) { $failed++; Write-UiLog "${e}: nije odgovorilo (provjerite WinRM i mrežu)." -Level Error }
    }
    if (-not @($Results | Where-Object { $_ }).Count -and $Gui.LastJobErrors) { $failed = [math]::Max($failed, 1) }
    foreach ($r in @($Results | Where-Object { $_ })) {
        $name = if ($Domain) { $r.GpoName } else { $r.ComputerName }
        foreach ($m in @(Get-GpsOptionalProperty $r 'Messages')) { Write-UiLog "${name}: $m" -Level $(if ($m -like 'Greška*') { 'Error' } else { 'Info' }) }
        $targetFailed = $Applied -and $r.Status -eq 'Error'
        if ($r.Status -eq 'Error') { $failed++ }
        # Kad primjena na računalu nije uspjela, retci ne smiju pisati DODANO/POSTAVLJENO.
        $statusTexts = if (-not $Applied) { $previewTexts } elseif ($targetFailed) { @{} } else { $appliedTexts }
        $line = "${name}: status $($r.Status)"
        $backup = Get-GpsOptionalProperty $r 'BackupPath'
        if ($backup) { $line += ", sigurnosna kopija: $backup" }
        Write-UiLog $line -Level $(if ($r.Status -eq 'Error') { 'Error' } elseif ($Applied) { 'Ok' } else { 'Info' })
        foreach ($d in @($r.Diff)) {
            $key = "reg|$($d.Scope)\$($d.Key)\$($d.ValueName)".ToLowerInvariant()
            $rows.Add([pscustomobject]@{
                    Target = $name; Status = $(if ($targetFailed -and $d.Status -ne 'Unchanged') { 'Failed' } else { $d.Status })
                    StatusText = $(if ($targetFailed -and $d.Status -ne 'Unchanged') { 'NIJE PRIMIJENJENO' } elseif ($targetFailed) { 'BEZ PROMJENE' } else { $statusTexts[$d.Status] })
                    Setting = if ($Active.Lookup.ContainsKey($key)) { $Active.Lookup[$key] } else { "$($d.Key)\$($d.ValueName)" }
                    Current = if ($null -ne $d.Current) { $d.Current } else { '(nije postavljeno)' }
                    Desired = $d.Desired; Technical = "$(if ($d.Scope -eq 'User') { 'HKCU' } else { 'HKLM' })\$($d.Key)\$($d.ValueName)"
                })
        }
        if (-not $Domain) {
            $plannedStatus = if ($targetFailed) { 'Failed' } else { 'Planned' }
            $plannedText = if ($targetFailed) { 'NIJE PRIMIJENJENO' } else { $statusTexts.Planned }
            foreach ($k in $Active.Set.security.Keys) {
                $rows.Add([pscustomobject]@{ Target = $name; Status = $plannedStatus; StatusText = $plannedText; Setting = $(if ($Active.Lookup.ContainsKey("sec|$k")) { $Active.Lookup["sec|$k"] } else { $k })
                        Current = '(provjera na stranici Usporedba)'; Desired = [string]$Active.Set.security[$k]; Technical = "secedit [System Access] $k" })
            }
            foreach ($k in $Active.Set.audit.Keys) {
                $rows.Add([pscustomobject]@{ Target = $name; Status = $plannedStatus; StatusText = $plannedText; Setting = $(if ($Active.Lookup.ContainsKey("aud|$k")) { $Active.Lookup["aud|$k"] } else { $k })
                        Current = '(provjera na stranici Usporedba)'; Desired = [string]$Active.Set.audit[$k]; Technical = "auditpol /subcategory:`"$k`"" })
            }
        }
    }
    $ordered = @($rows | Sort-Object @{ Expression = { switch ($_.Status) { 'Failed' { 0 } 'Changed' { 1 } 'Added' { 2 } 'Removed' { 3 } 'Planned' { 4 } default { 5 } } } }, Setting)
    $ui.dgChanges.ItemsSource = $ordered

    $ui.pnlChangeChips.Children.Clear()
    foreach ($status in 'Failed', 'Added', 'Changed', 'Removed', 'Planned', 'Unchanged') {
        $count = @($rows | Where-Object Status -eq $status).Count
        if (-not $count) { continue }
        $chip = [System.Windows.Controls.ContentControl]::new()
        $chip.Style = Get-AuxBrush 'Cip'
        $chip.Content = "$($chipTexts[$status]): $count"
        $chip.Margin = '0,0,8,0'
        $chip.Foreground = Get-AuxBrush $(switch ($status) { 'Failed' { 'Red' } 'Added' { 'Green' } 'Changed' { 'Amber' } 'Unchanged' { 'Muted' } default { 'Cyan' } })
        $null = $ui.pnlChangeChips.Children.Add($chip)
    }
    $ui.txtChangesTitle.Text = if ($Applied -and $failed) { 'Primjena s greškama' } elseif ($Applied) { 'Primijenjene promjene' } else { 'Pregled promjena' }
    $skippedNote = if ($Domain -and @($Active.Skipped).Count) { " Ne objavljuje se (lozinke i revizija još nisu podržane u domeni): $(@($Active.Skipped) -join ', ')." } else { '' }
    $ui.txtChangesInfo.Text = if ($Applied) {
        "Cilj: $Target. Izvor: $($Active.Source)." + $(if ($failed) { " $failed cilj(eva) javlja grešku ili nije odgovorilo, pogledajte Dnevnik." } else { ' Prije primjene napravljena je sigurnosna kopija.' }) + $skippedNote
    }
    else { "Ništa još nije promijenjeno. Cilj: $Target. Izvor: $($Active.Source). Kliknite Primijeni za primjenu.$skippedNote" }
    Show-Page 'Promjene'
}

function Invoke-UiPolicyAction([switch]$Apply) {
    $target = Get-UiTarget
    if (-not (Test-UiTarget $target)) { return }
    $active = Get-UiActivePolicySet -Domain:($target.Mode -eq 'Domain')
    if (-not $active) { return }
    $set = $active.Set
    if ($target.Mode -eq 'Domain' -and $set -and @($set.settings).Count -eq 0) {
        $null = Show-AuxDialog -Message ('Za domenski GPO nema postavki: lozinke i revizija se u domenu još ne objavljuju.' +
            $(if (@($active.Skipped).Count) { " Izostavljeno: $(@($active.Skipped) -join ', ')." })) -Kind Warning
        return
    }
    if (Test-UiPolicySetEmpty $set) {
        $null = Show-AuxDialog -Message 'Nema postavki za primjenu. Odaberite razinu ili uključite postavke.' -Kind Warning
        return
    }

    if ($target.Mode -ne 'Domain') {
        if ($Apply) {
            $msg = "Primijeniti $($active.Source) na: $($target.Text)?`n`nPrije primjene radi se sigurnosna kopija, a promjene možete vratiti gumbom Vrati prethodno stanje."
            if ((Show-AuxDialog -Title 'Primjena' -Kind Warning -Buttons @('PRIMIJENI', 'ODUSTANI') -Message $msg) -ne 'PRIMIJENI') { return }
        }
        $computers = $target.Computers
        $cmd = "Set-GpsLocalPolicy -PolicySet `$set" + $(if ($computers) { " -ComputerName $($computers -join ',')" }) + $(if ($Apply) { ' -Confirm:$false' } else { ' -WhatIf' })
        Start-UiJob -Title $(if ($Apply) { 'Primjena' } else { 'Pregled promjena' }) -Command $cmd -Arguments @($set, $computers, [bool]$Apply) `
            -Context @{ Active = $active; Target = $target.Text; Applied = [bool]$Apply; Expected = $computers } -ScriptBlock {
            param($set, $computers, $apply)
            $p = @{ PolicySet = $set }
            if ($computers) { $p.ComputerName = $computers }
            if ($apply) { Set-GpsLocalPolicy @p -Confirm:$false } else { Set-GpsLocalPolicy @p -WhatIf }
        } -OnSuccess { param($r, $ctx) Show-UiChanges -Results $r -Active $ctx.Active -Target $ctx.Target -Applied:$ctx.Applied -Expected $ctx.Expected }
        return
    }

    $skipped = @($active.Skipped) + @(if ($set.security.Count -or $set.audit.Count) { 'lozinke i revizija iz naprednog Policy Seta' })
    $question = "Objaviti $($active.Source) u domenski GPO '$($target.Gpo)'?"
    if ($target.Link) { $question += "`nPovezivanje na: $($target.Link)" }
    if ($target.Group) { $question += "`nPrimjenjuje se samo na grupu: $($target.Group)" }
    $question += "`n`nPostojeći GPO se prije promjene sprema u sigurnosnu kopiju."
    if ($skipped.Count) { $question += "`n`nLozinke i revizija u domenskom GPO-u još nisu podržane; ne objavljuje se: $($skipped -join ', ')." }
    if ($Apply -and (Show-AuxDialog -Title 'Objava GPO-a' -Kind Warning -Buttons @('OBJAVI', 'ODUSTANI') -Message $question) -ne 'OBJAVI') { return }

    $cmd = "Publish-GpsDomainPolicy -PolicySet `$set -GpoName '$($target.Gpo)'" + $(if ($target.Domain) { " -Domain $($target.Domain)" }) +
        $(if ($target.Link) { " -LinkTarget '$($target.Link)'" }) + $(if ($target.Group) { " -ApplyToGroup '$($target.Group)'" }) + $(if ($Apply) { ' -Confirm:$false' } else { ' -WhatIf' })
    Start-UiJob -Title $(if ($Apply) { 'Objava GPO-a' } else { 'Pregled promjena (domena)' }) -Command $cmd `
        -Arguments @($set, $target.Gpo, $target.Domain, $target.Link, $target.Group, [bool]$Apply) `
        -Context @{ Active = $active; Target = $target.Text; Applied = [bool]$Apply } -ScriptBlock {
        param($set, $gpo, $domain, $link, $group, $apply)
        $p = @{ PolicySet = $set; GpoName = $gpo }
        if ($domain) { $p.Domain = $domain }
        if ($link) { $p.LinkTarget = $link }
        if ($group) { $p.ApplyToGroup = $group }
        if ($apply) { Publish-GpsDomainPolicy @p -Confirm:$false } else { Publish-GpsDomainPolicy @p -WhatIf }
    } -OnSuccess { param($r, $ctx) Show-UiChanges -Results $r -Active $ctx.Active -Target $ctx.Target -Domain -Applied:$ctx.Applied }
}

function Invoke-UiBackup {
    $target = Get-UiTarget
    if (-not (Test-UiTarget $target)) { return }
    if ($target.Mode -ne 'Domain') {
        $computers = $target.Computers
        Start-UiJob -Title 'Sigurnosna kopija' -Command ('Backup-GpsLocalPolicy' + $(if ($computers) { " -ComputerName $($computers -join ',')" })) `
            -Arguments @(, $computers) -ScriptBlock {
            param($computers)
            if ($computers) { Backup-GpsLocalPolicy -ComputerName $computers } else { Backup-GpsLocalPolicy }
        } -OnSuccess { param($r) foreach ($b in @($r)) { Write-UiLog "Sigurnosna kopija ($($b.ComputerName)): $($b.BackupPath)" -Level Ok } }
        return
    }
    $path = Join-Path $env:ProgramData 'GpoStudio\GpoBackup'
    Start-UiJob -Title 'Sigurnosna kopija GPO-a' -Command "Backup-GPO -Name '$($target.Gpo)' -Path '$path'" -Arguments @($target.Gpo, $target.Domain, $path) -ScriptBlock {
        param($gpo, $domain, $path)
        $ctx = Get-GpsDomainContext -Domain $domain
        $null = New-Item -ItemType Directory -Path $path -Force
        Backup-GPO -Name $gpo -Path $path -Domain $ctx.Domain -Server $ctx.Server
    } -OnSuccess { param($r) foreach ($b in @($r)) { Write-UiLog "Sigurnosna kopija GPO-a '$($b.DisplayName)': $($b.Id) u $($b.BackupDirectory)" -Level Ok } }
}

function Invoke-UiRestore {
    $target = Get-UiTarget
    if (-not (Test-UiTarget $target)) { return }
    if ($target.Mode -eq 'Domain') {
        $result = Show-AuxInput -Title 'Vrati GPO' -Message "Vraća se najnovija sigurnosna kopija GPO-a '$($target.Gpo)' iz mape:" `
            -Fields ([ordered]@{ 'Mapa sa sigurnosnim kopijama' = (Join-Path $env:ProgramData 'GpoStudio\GpoBackup') }) -OkText 'DALJE'
        if (-not $result) { return }
        $path = $result['Mapa sa sigurnosnim kopijama']
        if ((Show-AuxDialog -Title 'Vrati GPO' -Kind Danger -Buttons @('VRATI', 'ODUSTANI') -Message "Vratiti GPO '$($target.Gpo)' iz ${path}?") -ne 'VRATI') { return }
        Start-UiJob -Title 'Vraćanje GPO-a' -Command "Restore-GPO -Name '$($target.Gpo)' -Path '$path'" -Arguments @($target.Gpo, $target.Domain, $path) -Context $target.Gpo -ScriptBlock {
            param($gpo, $domain, $path)
            $ctx = Get-GpsDomainContext -Domain $domain
            Restore-GPO -Name $gpo -Path $path -Domain $ctx.Domain -Server $ctx.Server
            Write-GpsAuditLog -Action 'Restore-GPO' -Target "$($ctx.Domain)/$gpo" -Details @{ path = $path }
        } -OnSuccess { param($r, $gpoName) Write-UiLog "GPO '$gpoName' vraćen iz sigurnosne kopije." -Level Ok }
        return
    }

    if ($target.Computers.Count -gt 1) { $null = Show-AuxDialog -Message 'Vraćanje se radi za jedno računalo. U traci CILJ ostavite samo jedno računalo.' -Kind Warning; return }
    $computer = $target.Computers | Select-Object -First 1
    Start-UiJob -Title 'Popis sigurnosnih kopija' -Command ('Get-GpsLocalBackup' + $(if ($computer) { " -ComputerName $computer" })) -Arguments @($computer) -Context $computer -ScriptBlock {
        param($computer)
        if ($computer) { Get-GpsLocalBackup -ComputerName $computer } else { Get-GpsLocalBackup }
    } -OnSuccess {
        param($backups, $computer)
        $list = @($backups | Where-Object { $_ })
        if (-not $list) { $null = Show-AuxDialog -Message 'Na ciljanom računalu nema sigurnosnih kopija GPO Studija.' -Kind Warning; return }
        $choice = Show-AuxList -Title 'Vrati prethodno stanje' -Message 'Odaberite sigurnosnu kopiju. Vraća se stanje lokalnog GP-a, lozinki i revizije iz trenutka kopije.' `
            -Items $list -Display { '{0:dd.MM.yyyy. HH:mm}   ·   {1}   ·   {2}' -f $_.Created, $_.ComputerName, (Split-Path $_.BackupPath -Leaf) } -OkText 'VRATI'
        if (-not $choice) { return }
        if ((Show-AuxDialog -Title 'Vrati prethodno stanje' -Kind Danger -Buttons @('VRATI', 'ODUSTANI') `
                    -Message ("Vratiti računalo {0} na stanje od {1:dd.MM.yyyy. HH:mm}?" -f $choice.ComputerName, $choice.Created)) -ne 'VRATI') { return }
        Start-UiJob -Title 'Vraćanje' -Command "Restore-GpsLocalPolicy -BackupPath '$($choice.BackupPath)'$(if ($computer) { " -ComputerName $computer" }) -Confirm:`$false" `
            -Arguments @($choice.BackupPath, $computer) -ScriptBlock {
            param($path, $computer)
            $p = @{ BackupPath = $path }
            if ($computer) { $p.ComputerName = $computer }
            Restore-GpsLocalPolicy @p -Confirm:$false
        } -OnSuccess {
            param($r)
            foreach ($x in @($r)) {
                foreach ($m in @($x.Messages)) { Write-UiLog "$($x.ComputerName): $m" }
                Write-UiLog "$($x.ComputerName): vraćanje iz sigurnosne kopije, status $($x.Status)" -Level $(if ($x.Status -eq 'OK') { 'Ok' } else { 'Error' })
            }
        }
    }
}

function Invoke-UiReplicationCheck {
    $target = Get-UiTarget
    if (-not (Test-UiTarget $target)) { return }
    Start-UiJob -Title 'Provjera replikacije' -Command "Test-GpsDomainGpoReplication -GpoName '$($target.Gpo)'" -Arguments @($target.Gpo, $target.Domain) -ScriptBlock {
        param($gpo, $domain)
        $p = @{ GpoName = $gpo }
        if ($domain) { $p.Domain = $domain }
        Test-GpsDomainGpoReplication @p
    } -OnSuccess {
        param($r)
        Write-UiLog ($r | Format-Table DomainController, ComputerAD, ComputerSysvol, UserAD, UserSysvol, InSync -AutoSize | Out-String)
        # Redak s greškom (DC nedostupan, GPO ne postoji) nije "još nije repliciran".
        $errors = @($r | Where-Object { $_ -and $_.PSObject.Properties['Error'] -and $_.Error })
        if ($errors.Count) {
            $null = Show-AuxDialog -Title 'Replikacija' -Kind Danger -Message 'Provjera nije uspjela na svim domain controllerima.' `
                -Details (($errors | ForEach-Object { "$($_.DomainController): $($_.Error)" }) -join "`n")
            return
        }
        $bad = @($r | Where-Object { -not $_.InSync }).Count
        $null = Show-AuxDialog -Title 'Replikacija' -Kind $(if ($bad) { 'Warning' } else { 'Info' }) `
            -Message $(if ($bad) { "GPO još nije usklađen na $bad domain controller(a). Pričekajte nekoliko minuta i provjerite ponovno." } else { 'GPO je jednak na svim domain controllerima.' })
    }
}
