Set-StrictMode -Version Latest

foreach ($folder in 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter *.ps1 -ErrorAction SilentlyContinue |
        ForEach-Object { . $_.FullName }
}
