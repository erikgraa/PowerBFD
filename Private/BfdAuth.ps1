function Test-BfdAuth {
    # Verifies the RFC 5880 6.7 authentication section of a received control packet (not the sequence number).
    param([byte[]]$Packet, [string]$Type, [int]$KeyId, [string]$Key)
    $info = $script:BfdAuthTypes[$Type]
    if (-not $info -or $Packet.Length -lt 27) { return $false }
    $len = [int]$Packet[3]
    if (($Packet[1] -band 0x04) -eq 0 -or $Packet.Length -lt $len -or $len -lt 27) { return $false }
    if ($Packet[24] -ne $info.Code -or $Packet[26] -ne $KeyId) { return $false }
    $keyBytes = [Text.Encoding]::UTF8.GetBytes($Key)

    if ($Type -eq 'SimplePassword') {
        if ($Packet[25] -ne ($len - 24)) { return $false }
        $pw = [byte[]]$Packet[27..($len - 1)]
        return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($pw, $keyBytes)
    }

    $digestLen = $info.Length - 8
    if ($Packet[25] -ne $info.Length -or $len -ne (24 + $info.Length) -or $keyBytes.Length -gt $info.MaxKey -or $keyBytes.Length -eq 0) { return $false }
    $tmp = [byte[]]$Packet[0..($len - 1)]
    [Array]::Clear($tmp, 32, $digestLen)
    [Array]::Copy($keyBytes, 0, $tmp, 32, $keyBytes.Length)
    $calc = Get-BfdHash -Algorithm $info.Hash -Data $tmp
    [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($calc, [byte[]]$Packet[32..($len - 1)])
}

function Test-BfdAuthSequence {
    # RFC 5880 6.7.3/6.7.4: keyed sequence in [last, last + 3 x DetectMult], meticulous strictly greater than last.
    param([uint32]$Sequence, [uint32]$Last, [bool]$Known, [bool]$Meticulous, [int]$DetectMult)
    if (-not $Known) { return $true }
    $diff = (([long]$Sequence + 4294967296 - [long]$Last) % 4294967296)
    $max = 3 * [Math]::Max(1, $DetectMult)
    if ($Meticulous) { return ($diff -ge 1 -and $diff -le $max) }
    $diff -le $max
}
