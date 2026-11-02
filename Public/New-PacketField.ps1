function New-PacketField {
    <#
    .SYNOPSIS
        Describes one named field of a packet.
    .DESCRIPTION
        Value may be an integer (requires -Bytes, encoded big-endian), a byte[],
        an [ipaddress], or a hex string such as 'DE:AD:BE:EF'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)]$Value,
        [int]$Bytes
    )
    [pscustomobject]@{ PSTypeName = 'PowerBFD.PacketField'; Name = $Name; Value = $Value; Bytes = $Bytes }
}
