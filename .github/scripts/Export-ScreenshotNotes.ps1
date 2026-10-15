<#
    Pomoćna skripta za CI: snimke sučelja pretvara u kratke bilješke (annotations) radnog toka,
    kako bi se mogle pregledati i kada preuzimanje artefakata nije dostupno.
    Pokreće se samo ručno (workflow_dispatch s uključenim unosom "snimke_u_biljeske").

    -Prepare: spaja odabrane snimke (PNG, base64) u jednu datoteku; -Filter bira snimke (npr. '01*').
    -Part N:  ispisuje N-tu skupinu od 10 dijelova kao ::notice (runner dopušta 10 po koraku).
#>
param(
    [Parameter(Mandatory)][string]$Folder,
    [switch]$Prepare,
    [string]$Filter = '*',
    [int]$Part = -1,
    [int]$ChunkSize = 4000,
    [int]$MaxChunks = 45
)
$ErrorActionPreference = 'Stop'
$payloadPath = Join-Path $Folder 'biljeske.txt'

if ($Prepare) {
    $parts = [System.Collections.Generic.List[string]]::new()
    $used = 0
    foreach ($file in Get-ChildItem $Folder -Filter "$Filter.png" | Sort-Object Name) {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $record = '{0}:{1};' -f $file.BaseName, [Convert]::ToBase64String($bytes)
        $chunks = [math]::Ceiling($record.Length / $ChunkSize)
        if ($used + $chunks -gt $MaxChunks) { Write-Host "Preskačem $($file.Name): nema mjesta ($chunks dijelova)."; continue }
        $used += $chunks
        $parts.Add($record)
        Write-Host ("{0}: {1:N0} B, {2} dijelova" -f $file.Name, $bytes.Length, $chunks)
    }
    [System.IO.File]::WriteAllText($payloadPath, ($parts -join ''))
    return
}

$payload = [System.IO.File]::ReadAllText($payloadPath)
$total = [math]::Ceiling($payload.Length / $ChunkSize)
for ($i = $Part * 10; $i -lt [math]::Min($total, ($Part + 1) * 10); $i++) {
    $chunk = $payload.Substring($i * $ChunkSize, [math]::Min($ChunkSize, $payload.Length - $i * $ChunkSize))
    Write-Host "::notice title=snimka $i/$total::$chunk"
}
