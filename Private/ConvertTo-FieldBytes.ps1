function ConvertTo-FieldBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Field)

    $value = $Field.Value

    if ($value -is [byte[]]) { return , $value }
    if ($value -is [ipaddress]) { return , $value.GetAddressBytes() }
    if ($value -is [string]) {
        $hex = $value -replace '[\s:-]', ''
        if ($hex.Length % 2) { throw "Field '$($Field.Name)': hex string has odd length." }
        $b = [byte[]]::new($hex.Length / 2)
        for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        return , $b
    }

    if (-not $Field.Bytes) { throw "Field '$($Field.Name)' is numeric and needs -Bytes." }
    $v = [uint64]$value
    $b = [byte[]]::new($Field.Bytes)
    for ($i = $Field.Bytes - 1; $i -ge 0; $i--) {
        $b[$i] = [byte]($v -band 0xFF)
        $v = $v -shr 8
    }
    if ($v -ne 0) { throw "Field '$($Field.Name)': value $value does not fit in $($Field.Bytes) byte(s)." }
    , $b
}
