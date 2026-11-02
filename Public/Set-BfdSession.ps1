function Set-BfdSession {
    <#
    .SYNOPSIS
        Changes a BFD session in place, or injects faults.
    .DESCRIPTION
        Timers, DetectMult, Demand and echo mode, Passive and authentication apply live: a running session negotiates
        new timers with a Poll sequence (RFC 5880 6.8.3) and does not go Down. -Port, -ListenPort, -LocalAddress,
        -EchoPort and -EchoListenPort restart a running session.

        Fault injection (all revert with -ClearFaults):
          -Suppress $true         stop sending control packets while the session stays alive (the peer's detection time expires)
          -AdminDown $true        send AdminDown (diagnostic 7) without stopping the session
          -DropEcho $true         keep advertising echo support but stop looping the peer's echo packets back
          -FaultMyDiscriminator   advertise another My Discriminator than the real one (0 is invalid on the wire)
          -FaultYourDiscriminator advertise a wrong Your Discriminator, so the peer drops the packets
          -FaultDesiredMinTxMs / -FaultRequiredMinRxMs   advertise bad timers (0 is allowed, e.g. RequiredMinRx 0 tells the peer to stop sending)
          -FaultDetectMult        advertise another DetectMult (0 is invalid)
          -FaultDiagnostic / -FaultState   advertise another diagnostic code or state
          -FaultAuthKey           sign packets with the wrong key
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Name,
        [ValidateRange(1, 4294967)][uint32]$DesiredMinTxMs,
        [ValidateRange(0, 4294967)][uint32]$RequiredMinRxMs,
        [ValidateRange(1, 255)][int]$DetectMult,
        [bool]$Passive,
        [bool]$DemandMode,
        [ValidateSet('Disabled', 'Reflect', 'Active')][string]$EchoMode,
        [ValidateRange(1, 4294967)][uint32]$EchoIntervalMs,
        [ValidateSet('None', 'SimplePassword', 'KeyedMD5', 'MeticulousKeyedMD5', 'KeyedSHA1', 'MeticulousKeyedSHA1')][string]$AuthType,
        [ValidateRange(0, 255)][int]$AuthKeyId,
        [string]$AuthKey,
        [bool]$RecordPackets,
        [ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(1, 65535)][int]$ListenPort,
        [ipaddress]$LocalAddress,
        [ValidateRange(1, 65535)][int]$EchoPort,
        [ValidateRange(1, 65535)][int]$EchoListenPort,
        [bool]$Suppress,
        [bool]$AdminDown,
        [bool]$DropEcho,
        [uint32]$FaultMyDiscriminator,
        [uint32]$FaultYourDiscriminator,
        [uint32]$FaultDesiredMinTxMs,
        [uint32]$FaultRequiredMinRxMs,
        [ValidateRange(0, 255)][int]$FaultDetectMult,
        [ValidateRange(0, 31)][int]$FaultDiagnostic,
        [ValidateSet('AdminDown', 'Down', 'Init', 'Up')][string]$FaultState,
        [string]$FaultAuthKey,
        [switch]$ClearFaults
    )
    process {
        $S = (Get-BfdRegistry).Bfd[$Name]
        if (-not $S) { throw "No such BFD session '$Name'." }
        $c = $S.Config
        $p = $PSBoundParameters

        $authType = if ($p.ContainsKey('AuthType')) { $AuthType } else { $c.AuthType }
        $authKey = if ($p.ContainsKey('AuthKey')) { $AuthKey } else { $c.AuthKey }
        Assert-BfdAuth -AuthType $authType -AuthKey $authKey

        $restart = foreach ($k in 'Port', 'ListenPort', 'LocalAddress', 'EchoPort', 'EchoListenPort') { if ($p.ContainsKey($k)) { $k } }
        $wasRunning = $S.State -ne 'Stopped'
        if ($restart -and $wasRunning) { Stop-BfdSession -Name $Name }

        if ($p.ContainsKey('DesiredMinTxMs')) { $c.DesiredMinTx = [uint32]($DesiredMinTxMs * 1000) }
        if ($p.ContainsKey('RequiredMinRxMs')) { $c.RequiredMinRx = [uint32]($RequiredMinRxMs * 1000) }
        if ($p.ContainsKey('EchoIntervalMs')) { $c.EchoInterval = [uint32]($EchoIntervalMs * 1000) }
        foreach ($k in 'DetectMult', 'Passive', 'DemandMode', 'EchoMode', 'AuthKeyId', 'RecordPackets', 'Port', 'ListenPort', 'EchoPort', 'EchoListenPort') {
            if ($p.ContainsKey($k)) {
                $prop = if ($k -eq 'Port') { 'RemotePort' } else { $k }
                $c.$prop = $p[$k]
            }
        }
        if ($p.ContainsKey('LocalAddress')) { $c.LocalAddress = $LocalAddress.ToString() }
        $c.AuthType = $authType; $c.AuthKey = $authKey

        if ($p.ContainsKey('Suppress')) { $S.Suppress = $Suppress }
        if ($p.ContainsKey('AdminDown')) { $S.AdminDown = $AdminDown }
        if ($p.ContainsKey('DropEcho')) { $S.DropEcho = $DropEcho }
        if ($ClearFaults) { $S.Fault.Clear(); $S.Suppress = $false; $S.AdminDown = $false; $S.DropEcho = $false }
        $faults = @{
            FaultMyDiscriminator = 'MyDiscriminator'; FaultYourDiscriminator = 'YourDiscriminator'
            FaultDetectMult = 'DetectMult'; FaultDiagnostic = 'Diagnostic'; FaultState = 'State'; FaultAuthKey = 'AuthKey'
        }
        foreach ($k in $faults.Keys) {
            if ($p.ContainsKey($k)) { $S.Fault[$faults[$k]] = $p[$k]; Add-BfdEvent -State $S -Type 'Fault' -Summary "fault injected: $($faults[$k]) = $($p[$k])" }
        }
        if ($p.ContainsKey('FaultDesiredMinTxMs')) { $S.Fault.DesiredMinTx = [uint32]($FaultDesiredMinTxMs * 1000) }
        if ($p.ContainsKey('FaultRequiredMinRxMs')) { $S.Fault.RequiredMinRx = [uint32]($FaultRequiredMinRxMs * 1000) }

        if ($restart -and $wasRunning) { $null = Resume-BfdSession -Name $Name }
    }
}
