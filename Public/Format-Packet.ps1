function Format-Packet {
    <#
    .SYNOPSIS
        Hex dump of a byte[] (offset, 16 bytes per row, ASCII), handy next to Wireshark.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][byte[]]$Packet)
    begin { $all = [System.Collections.Generic.List[byte]]::new() }
    process { $all.AddRange($Packet) }
    end {
        $Packet = $all.ToArray()
        for ($o = 0; $o -lt $Packet.Length; $o += 16) {
            $n = [Math]::Min(16, $Packet.Length - $o)
            $slice = $Packet[$o..($o + $n - 1)]
            $hex = ($slice | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $asc = -join ($slice | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
            '{0:X4}  {1,-47}  {2}' -f $o, $hex, $asc
        }
    }
}
