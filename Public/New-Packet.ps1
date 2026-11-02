function New-Packet {
    <#
    .SYNOPSIS
        Builds a byte[] from an ordered list of fields.
    .DESCRIPTION
        If -LengthField names one of the fields, it is overwritten with the total
        packet length (header included), big-endian, using that field's -Bytes width.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Field,
        [string]$LengthField
    )

    $parts = [System.Collections.Generic.List[byte[]]]::new()
    $index = @{}
    foreach ($f in $Field) {
        $index[$f.Name] = $parts.Count
        $parts.Add([byte[]](ConvertTo-FieldBytes $f))
    }

    if ($LengthField) {
        if (-not $index.ContainsKey($LengthField)) { throw "LengthField '$LengthField' is not in -Field." }
        $total = 0
        foreach ($p in $parts) { $total += $p.Length }
        $lf = $Field | Where-Object Name -EQ $LengthField
        $parts[$index[$LengthField]] = [byte[]](ConvertTo-FieldBytes (New-PacketField $LengthField $total -Bytes $lf.Bytes))
    }

    $out = [System.Collections.Generic.List[byte]]::new()
    foreach ($p in $parts) { $out.AddRange($p) }
    , $out.ToArray()
}
