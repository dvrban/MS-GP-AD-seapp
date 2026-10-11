function Write-GpsAuditLog {
    <#
    .SYNOPSIS
        Upisuje revizijski zapis (JSON lines): tko, kada, što, na kojem cilju i s kojim rezultatom.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [string]$Result = 'OK',
        $Details,
        [string]$Path = $(
            $root = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
            Join-Path $root 'GpoStudio\audit.jsonl'
        )
    )

    $user = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { [Environment]::UserName }
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        user      = $user
        host      = [Environment]::MachineName
        action    = $Action
        target    = $Target
        result    = $Result
        details   = $Details
    }

    # Zapis se radi nakon što je promjena već napravljena, pa greška ovdje (npr. korisnik bez prava
    # pisanja u C:\ProgramData\GpoStudio) ne smije srušiti operaciju; javlja se upozorenjem.
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        Add-Content -LiteralPath $Path -Value ($record | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Revizijski zapis nije upisan u '$Path': $($_.Exception.Message)"
    }
}
