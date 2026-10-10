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

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

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
    Add-Content -LiteralPath $Path -Value ($record | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
}
