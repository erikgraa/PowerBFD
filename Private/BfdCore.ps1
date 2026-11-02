# Core constants and byte helpers for the BFD code. Self-contained: no dependency on the rest of the module.

$script:BfdRegistryKey = 'PowerBFD.Registry'

$script:BfdStates = @{ 0 = 'AdminDown'; 1 = 'Down'; 2 = 'Init'; 3 = 'Up' }
$script:BfdStateCodes = @{ AdminDown = 0; Down = 1; Init = 2; Up = 3 }

$script:BfdDiags = @{
    0 = 'No Diagnostic'; 1 = 'Control Detection Time Expired'; 2 = 'Echo Function Failed'
    3 = 'Neighbor Signaled Session Down'; 4 = 'Forwarding Plane Reset'; 5 = 'Path Down'
    6 = 'Concatenated Path Down'; 7 = 'Administratively Down'; 8 = 'Reverse Concatenated Path Down'
}

# RFC 5880 4.2-4.4 authentication sections. Length is the whole section; MaxKey the longest allowed key in bytes.
$script:BfdAuthTypes = @{
    SimplePassword      = @{ Code = 1; Hash = $null; Length = 0; MaxKey = 16; Meticulous = $false }
    KeyedMD5            = @{ Code = 2; Hash = 'MD5'; Length = 24; MaxKey = 16; Meticulous = $false }
    MeticulousKeyedMD5  = @{ Code = 3; Hash = 'MD5'; Length = 24; MaxKey = 16; Meticulous = $true }
    KeyedSHA1           = @{ Code = 4; Hash = 'SHA1'; Length = 28; MaxKey = 20; Meticulous = $false }
    MeticulousKeyedSHA1 = @{ Code = 5; Hash = 'SHA1'; Length = 28; MaxKey = 20; Meticulous = $true }
}
$script:BfdAuthCodes = @{}
foreach ($k in $script:BfdAuthTypes.Keys) { $script:BfdAuthCodes[[int]$script:BfdAuthTypes[$k].Code] = $k }

function Get-BfdUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    [uint32](([long]$Bytes[$Offset] * 16777216) + ([long]$Bytes[$Offset + 1] * 65536) + ([long]$Bytes[$Offset + 2] * 256) + [long]$Bytes[$Offset + 3])
}

function Set-BfdUInt32 {
    param([byte[]]$Bytes, [int]$Offset, [uint32]$Value)
    $v = [long]$Value
    $Bytes[$Offset] = [byte](($v -shr 24) -band 255)
    $Bytes[$Offset + 1] = [byte](($v -shr 16) -band 255)
    $Bytes[$Offset + 2] = [byte](($v -shr 8) -band 255)
    $Bytes[$Offset + 3] = [byte]($v -band 255)
}

function Get-BfdHash {
    param([string]$Algorithm, [byte[]]$Data)
    if ($Algorithm -eq 'MD5') { , [Security.Cryptography.MD5]::HashData($Data) } else { , [Security.Cryptography.SHA1]::HashData($Data) }
}
