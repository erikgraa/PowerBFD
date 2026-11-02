function ConvertFrom-BfdControl {
    <#
    .SYNOPSIS
        Parses a BFD control packet (RFC 5880). With -AuthKey, the authentication section is verified (Auth.Valid).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][byte[]]$Packet, [string]$AuthKey)
    process {
        if ($Packet.Length -lt 24) { throw 'BFD control packet must be at least 24 bytes.' }
        $stateCode = [int][Math]::Floor($Packet[1] / 64)
        $diag = [int]($Packet[0] % 32)
        $auth = $null
        if (($Packet[1] -band 0x04) -and $Packet.Length -ge 27) {
            $type = $script:BfdAuthCodes[[int]$Packet[24]]
            $keyed = $type -and $type -ne 'SimplePassword'
            $auth = [pscustomobject]@{
                Type     = if ($type) { $type } else { "Type $($Packet[24])" }
                KeyId    = [int]$Packet[26]
                Sequence = if ($keyed -and $Packet.Length -ge 32) { Get-BfdUInt32 $Packet 28 } else { $null }
                Valid    = if ($AuthKey -and $type) { Test-BfdAuth -Packet $Packet -Type $type -KeyId $Packet[26] -Key $AuthKey } else { $null }
            }
        }
        [pscustomobject]@{
            PSTypeName              = 'PowerBFD.BfdControl'
            Auth                    = $auth
            Version                 = [int][Math]::Floor($Packet[0] / 32)
            Diagnostic              = $diag
            DiagnosticName          = $script:BfdDiags[$diag]
            State                   = $script:BfdStates[$stateCode]
            Poll                    = [bool]($Packet[1] -band 0x20)
            Final                   = [bool]($Packet[1] -band 0x10)
            ControlPlaneIndependent = [bool]($Packet[1] -band 0x08)
            Demand                  = [bool]($Packet[1] -band 0x02)
            Multipoint              = [bool]($Packet[1] -band 0x01)
            DetectMult              = [int]$Packet[2]
            Length                  = [int]$Packet[3]
            MyDiscriminator         = Get-BfdUInt32 $Packet 4
            YourDiscriminator       = Get-BfdUInt32 $Packet 8
            DesiredMinTx            = Get-BfdUInt32 $Packet 12
            RequiredMinRx           = Get-BfdUInt32 $Packet 16
            RequiredMinEchoRx       = Get-BfdUInt32 $Packet 20
        }
    }
}
