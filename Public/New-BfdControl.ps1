function New-BfdControl {
    <#
    .SYNOPSIS
        Builds a BFD control packet (RFC 5880): 24 bytes plus an optional authentication section. Intervals are in microseconds.
    .DESCRIPTION
        Every header field can be set to an invalid value on purpose (version, length, discriminators, zero DetectMult,
        the Multipoint bit), which makes this the building block for fault injection against a peer.
    .PARAMETER Length
        Overrides the Length field (a lie about the packet size).
    .PARAMETER AuthType
        None, SimplePassword, KeyedMD5, MeticulousKeyedMD5, KeyedSHA1 or MeticulousKeyedSHA1.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('AdminDown', 'Down', 'Init', 'Up')][string]$State = 'Down',
        [ValidateRange(0, 31)][int]$Diagnostic = 0,
        [ValidateRange(0, 255)][int]$DetectMult = 3,
        [uint32]$MyDiscriminator = 1,
        [uint32]$YourDiscriminator = 0,
        [uint32]$DesiredMinTx = 1000000,
        [uint32]$RequiredMinRx = 1000000,
        [uint32]$RequiredMinEchoRx = 0,
        [switch]$Poll,
        [switch]$Final,
        [switch]$Demand,
        [switch]$ControlPlaneIndependent,
        [switch]$Multipoint,
        [ValidateRange(0, 7)][int]$Version = 1,
        [ValidateRange(0, 255)][int]$Length,
        [ValidateSet('None', 'SimplePassword', 'KeyedMD5', 'MeticulousKeyedMD5', 'KeyedSHA1', 'MeticulousKeyedSHA1')][string]$AuthType = 'None',
        [ValidateRange(0, 255)][int]$AuthKeyId = 0,
        [string]$AuthKey,
        [uint32]$AuthSequence = 0
    )
    $flags = 0
    if ($Poll) { $flags = $flags -bor 0x20 }
    if ($Final) { $flags = $flags -bor 0x10 }
    if ($ControlPlaneIndependent) { $flags = $flags -bor 0x08 }
    if ($Demand) { $flags = $flags -bor 0x02 }
    if ($Multipoint) { $flags = $flags -bor 0x01 }

    $info = $null
    $keyBytes = [byte[]]@()
    $authLen = 0
    if ($AuthType -ne 'None') {
        if (-not $AuthKey) { throw "-AuthKey is required with -AuthType $AuthType." }
        $info = $script:BfdAuthTypes[$AuthType]
        $keyBytes = [Text.Encoding]::UTF8.GetBytes($AuthKey)
        if ($keyBytes.Length -gt $info.MaxKey) { throw "-AuthKey can be at most $($info.MaxKey) bytes for $AuthType." }
        $authLen = if ($AuthType -eq 'SimplePassword') { 3 + $keyBytes.Length } else { $info.Length }
        $flags = $flags -bor 0x04
    }

    $buf = [byte[]]::new(24 + $authLen)
    $buf[0] = [byte](($Version -shl 5) -bor $Diagnostic)
    $buf[1] = [byte](($script:BfdStateCodes[$State] -shl 6) -bor $flags)
    $buf[2] = [byte]$DetectMult
    $buf[3] = if ($PSBoundParameters.ContainsKey('Length')) { [byte]$Length } else { [byte]$buf.Length }
    Set-BfdUInt32 $buf 4 $MyDiscriminator
    Set-BfdUInt32 $buf 8 $YourDiscriminator
    Set-BfdUInt32 $buf 12 $DesiredMinTx
    Set-BfdUInt32 $buf 16 $RequiredMinRx
    Set-BfdUInt32 $buf 20 $RequiredMinEchoRx

    if ($AuthType -eq 'SimplePassword') {
        $buf[24] = 1; $buf[25] = [byte]$authLen; $buf[26] = [byte]$AuthKeyId
        [Array]::Copy($keyBytes, 0, $buf, 27, $keyBytes.Length)
    }
    elseif ($info) {
        $buf[24] = [byte]$info.Code; $buf[25] = [byte]$authLen; $buf[26] = [byte]$AuthKeyId
        Set-BfdUInt32 $buf 28 $AuthSequence
        [Array]::Copy($keyBytes, 0, $buf, 32, $keyBytes.Length)
        $hash = Get-BfdHash -Algorithm $info.Hash -Data $buf
        [Array]::Copy($hash, 0, $buf, 32, $hash.Length)
    }
    , $buf
}
