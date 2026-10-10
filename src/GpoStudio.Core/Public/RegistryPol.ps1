<#
    Čitač i pisač Registry.pol datoteka (PReg format, verzija 1).

    Format:
      zaglavlje : 'PReg' (0x50 0x52 0x65 0x67) + UInt32 verzija (1)
      zapis     : [ključ\0;vrijednost\0;tip;veličina;podaci]
    Ključ, ime vrijednosti i graničnici [ ; ] su UTF-16LE; tip i veličina su UInt32 LE.

    Funkcije u ovoj datoteci nemaju ovisnosti o Windowsima, pa ih adapter za lokalni GP
    šalje i na udaljena računala (Invoke-Command), a testovi ih pokreću i na Linuxu.
#>

$script:GpsRegTypes = [ordered]@{
    REG_NONE             = 0
    REG_SZ               = 1
    REG_EXPAND_SZ        = 2
    REG_BINARY           = 3
    REG_DWORD            = 4
    REG_DWORD_BIG_ENDIAN = 5
    REG_MULTI_SZ         = 7
    REG_QWORD            = 11
}

function ConvertTo-GpsRegTypeName {
    param([uint32]$Value)
    foreach ($name in $script:GpsRegTypes.Keys) {
        if ($script:GpsRegTypes[$name] -eq $Value) { return $name }
    }
    return "REG_UNKNOWN_$Value"
}

function ConvertFrom-GpsRegistryPolBytes {
    <#
    .SYNOPSIS
        Pretvara sadržaj Registry.pol datoteke (byte[]) u listu zapisa.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $entries = [System.Collections.Generic.List[object]]::new()
    if ($Bytes.Length -eq 0) { return , $entries }
    if ($Bytes.Length -lt 8 -or
        [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'PReg' -or
        [BitConverter]::ToUInt32($Bytes, 4) -ne 1) {
        throw 'Neispravno zaglavlje Registry.pol datoteke (očekivano PReg v1).'
    }

    $unicode = [System.Text.Encoding]::Unicode
    $pos = 8

    function Read-Delimiter([ref]$Pos, [char]$Char) {
        if ($Pos.Value + 2 -gt $Bytes.Length -or [char][BitConverter]::ToUInt16($Bytes, $Pos.Value) -ne $Char) {
            throw "Neispravan Registry.pol: očekivan znak '$Char' na poziciji $($Pos.Value)."
        }
        $Pos.Value += 2
    }

    function Read-PolString([ref]$Pos) {
        $start = $Pos.Value
        $i = $start
        while ($i + 1 -lt $Bytes.Length -and ($Bytes[$i] -ne 0 -or $Bytes[$i + 1] -ne 0)) { $i += 2 }
        if ($i + 1 -ge $Bytes.Length) { throw 'Neispravan Registry.pol: string nije terminiran.' }
        $Pos.Value = $i + 2
        $unicode.GetString($Bytes, $start, $i - $start)
    }

    function Read-UInt32([ref]$Pos) {
        if ($Pos.Value + 4 -gt $Bytes.Length) { throw 'Neispravan Registry.pol: neočekivan kraj datoteke.' }
        $value = [BitConverter]::ToUInt32($Bytes, $Pos.Value)
        $Pos.Value += 4
        $value
    }

    while ($pos -lt $Bytes.Length) {
        Read-Delimiter ([ref]$pos) '['
        $key = Read-PolString ([ref]$pos)
        Read-Delimiter ([ref]$pos) ';'
        $valueName = Read-PolString ([ref]$pos)
        Read-Delimiter ([ref]$pos) ';'
        $type = Read-UInt32 ([ref]$pos)
        Read-Delimiter ([ref]$pos) ';'
        $size = Read-UInt32 ([ref]$pos)
        Read-Delimiter ([ref]$pos) ';'
        if ($pos + $size -gt $Bytes.Length) { throw "Neispravan Registry.pol: podaci izlaze izvan datoteke ($key\$valueName)." }
        $raw = [byte[]]::new($size)
        [Array]::Copy($Bytes, $pos, $raw, 0, $size)
        $pos += $size
        Read-Delimiter ([ref]$pos) ']'

        $typeName = ConvertTo-GpsRegTypeName $type
        $data = switch ($typeName) {
            { $_ -in 'REG_SZ', 'REG_EXPAND_SZ' } { $unicode.GetString($raw).TrimEnd([char]0) }
            'REG_MULTI_SZ' { , [string[]]@($unicode.GetString($raw).Split([char]0) | Where-Object { $_ -ne '' }) }
            'REG_DWORD' { if ($size -ge 4) { [BitConverter]::ToUInt32($raw, 0) } else { [uint32]0 } }
            'REG_QWORD' { if ($size -ge 8) { [BitConverter]::ToUInt64($raw, 0) } else { [uint64]0 } }
            default { , $raw }
        }

        $entries.Add([pscustomobject]@{
                Key       = $key
                ValueName = $valueName
                Type      = $typeName
                Data      = $data
            })
    }
    return , $entries
}

function ConvertTo-GpsRegistryPolBytes {
    <#
    .SYNOPSIS
        Pretvara listu zapisa (Key, ValueName, Type, Data) u sadržaj Registry.pol datoteke.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry)

    $unicode = [System.Text.Encoding]::Unicode
    $ms = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($ms)
    try {
        $w.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))
        $w.Write([uint32]1)
        $delim = { param([char]$c) $w.Write([uint16]$c) }

        foreach ($e in $Entry) {
            if (-not $script:GpsRegTypes.Contains([string]$e.Type)) { throw "Nepodržan tip '$($e.Type)' za $($e.Key)\$($e.ValueName)." }
            $typeValue = [uint32]$script:GpsRegTypes[[string]$e.Type]
            [byte[]]$raw = switch ([string]$e.Type) {
                { $_ -in 'REG_SZ', 'REG_EXPAND_SZ' } { $unicode.GetBytes([string]$e.Data + [char]0) }
                'REG_MULTI_SZ' { $unicode.GetBytes((@($e.Data) -join [char]0) + [char]0 + [char]0) }
                'REG_DWORD' { [BitConverter]::GetBytes([uint32]$e.Data) }
                'REG_QWORD' { [BitConverter]::GetBytes([uint64]$e.Data) }
                default { if ($null -eq $e.Data) { , [byte[]]@() } else { , [byte[]]$e.Data } }
            }
            if ($null -eq $raw) { $raw = [byte[]]@() }

            & $delim '['
            $w.Write($unicode.GetBytes([string]$e.Key + [char]0))
            & $delim ';'
            $w.Write($unicode.GetBytes([string]$e.ValueName + [char]0))
            & $delim ';'
            $w.Write($typeValue)
            & $delim ';'
            $w.Write([uint32]$raw.Length)
            & $delim ';'
            $w.Write($raw)
            & $delim ']'
        }
        $w.Flush()
        return , $ms.ToArray()
    }
    finally {
        $w.Dispose()
        $ms.Dispose()
    }
}

function Read-GpsRegistryPol {
    <#
    .SYNOPSIS
        Čita Registry.pol datoteku i vraća zapise (Key, ValueName, Type, Data).
    .EXAMPLE
        Read-GpsRegistryPol -Path C:\Windows\System32\GroupPolicy\Machine\Registry.pol
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $entries = ConvertFrom-GpsRegistryPolBytes -Bytes ([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath))
    $entries
}

function Write-GpsRegistryPol {
    <#
    .SYNOPSIS
        Atomarno zapisuje zapise u Registry.pol (privremena datoteka, provjera, zamjena).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry
    )

    $bytes = ConvertTo-GpsRegistryPolBytes -Entry $Entry
    # Provjera: ono što zapisujemo mora se moći ponovno pročitati.
    $null = ConvertFrom-GpsRegistryPolBytes -Bytes $bytes

    if ($PSCmdlet.ShouldProcess($Path, "Zapis $($Entry.Count) stavki u Registry.pol")) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $tmp = "$Path.gps-tmp"
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}
