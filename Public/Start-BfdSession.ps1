function Start-BfdSession {
    <#
    .SYNOPSIS
        Starts a BFD session (RFC 5880) over UDP, TTL 255, source port 49152-65535. Single-hop (RFC 5881, port 3784) by default.
    .PARAMETER MultiHop
        Multihop BFD (RFC 5883): defaults -Port and -ListenPort to 4784 instead of 3784.
    .PARAMETER LocalAddress
        Bind to this local address, so packets leave from the address the peer expects. Two sessions can share a
        listen port when they bind different local addresses.
    .PARAMETER Passive
        Do not send control packets until the peer's discriminator is known.
    .PARAMETER DemandMode
        Request Demand mode (RFC 5880 6.6) once the session is Up: the peer stops its periodic packets and this side
        verifies connectivity with Poll sequences.
    .PARAMETER EchoMode
        Disabled, Reflect (advertise a required echo interval and loop the peer's echo packets back, UDP 3785) or
        Active (Reflect, plus originate echo packets and fail the session with diagnostic 2 when they stop coming back).
    .PARAMETER OnStateChange
        Notification hook, called with ($Event, $Context) on every state change, e.g. { param($e, $ctx) ... }.
        $Event has Session, Remote, OldState, NewState, Diagnostic, DiagnosticName, LocalDiscriminator,
        RemoteDiscriminator and IsUp. The hook runs in the session's runspace, so it cannot capture local variables:
        pass shared state with -HookContext. Keep it short: packets are not processed while it runs.
    .PARAMETER HookContext
        Object (typically a synchronized hashtable or a ConcurrentQueue) handed to -OnStateChange as its second argument.
    .PARAMETER AuthType
        None, SimplePassword, KeyedMD5, MeticulousKeyedMD5, KeyedSHA1 or MeticulousKeyedSHA1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteAddress,
        [string]$Name,
        [ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(1, 65535)][int]$ListenPort,
        [switch]$MultiHop,
        [ipaddress]$LocalAddress,
        [ValidateRange(1, 4294967)][uint32]$DesiredMinTxMs = 500,
        [ValidateRange(0, 4294967)][uint32]$RequiredMinRxMs = 500,
        [ValidateRange(1, 255)][int]$DetectMult = 3,
        [switch]$Passive,
        [switch]$DemandMode,
        [ValidateSet('Disabled', 'Reflect', 'Active')][string]$EchoMode = 'Disabled',
        [ValidateRange(1, 4294967)][uint32]$EchoIntervalMs = 100,
        [ValidateRange(1, 65535)][int]$EchoPort = 3785,
        [ValidateRange(1, 65535)][int]$EchoListenPort = 3785,
        [ValidateSet('None', 'SimplePassword', 'KeyedMD5', 'MeticulousKeyedMD5', 'KeyedSHA1', 'MeticulousKeyedSHA1')][string]$AuthType = 'None',
        [ValidateRange(0, 255)][int]$AuthKeyId = 1,
        [string]$AuthKey,
        [scriptblock]$OnStateChange,
        $HookContext,
        [bool]$RecordPackets = $true
    )
    $addr = $null
    if (-not [ipaddress]::TryParse($RemoteAddress, [ref]$addr)) { throw "-RemoteAddress '$RemoteAddress' is not an IP address." }
    Assert-BfdAuth -AuthType $AuthType -AuthKey $AuthKey

    $default = if ($MultiHop) { 4784 } else { 3784 }
    if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = $default }
    if (-not $PSBoundParameters.ContainsKey('ListenPort')) { $ListenPort = $default }
    if (-not $Name) { $Name = $RemoteAddress }
    $reg = Get-BfdRegistry
    $existing = $reg.Bfd[$Name]
    if ($existing -and $existing.State -ne 'Stopped') { throw "BFD session '$Name' already exists." }
    if ($existing) { $null = $reg.Bfd.Remove($Name) }

    $S = [hashtable]::Synchronized(@{
            Name                = $Name
            Config              = [pscustomobject]@{
                RemoteAddress = $addr.ToString(); RemotePort = $Port; ListenPort = $ListenPort
                LocalAddress  = if ($LocalAddress) { $LocalAddress.ToString() } else { $null }
                MultiHop      = [bool]$MultiHop
                DesiredMinTx  = [uint32]($DesiredMinTxMs * 1000); RequiredMinRx = [uint32]($RequiredMinRxMs * 1000); DetectMult = $DetectMult
                Passive       = [bool]$Passive; DemandMode = [bool]$DemandMode
                EchoMode      = $EchoMode; EchoInterval = [uint32]($EchoIntervalMs * 1000); EchoPort = $EchoPort; EchoListenPort = $EchoListenPort
                AuthType      = $AuthType; AuthKeyId = $AuthKeyId; AuthKey = $AuthKey
                OnStateChange = $OnStateChange; HookContext = $HookContext; RecordPackets = $RecordPackets
            }
            State               = 'Down'
            RemoteState         = $null
            Diagnostic          = 0
            Stop                = $false
            Ready               = $false
            Suppress            = $false
            AdminDown           = $false
            DropEcho            = $false
            Fault               = [hashtable]::Synchronized(@{})
            Sent                = 0
            Received            = 0
            Dropped             = 0
            AuthFailures        = 0
            EchoSent            = 0
            EchoReceived        = 0
            EchoReflected       = 0
            LocalDiscriminator  = 0
            RemoteDiscriminator = 0
            DetectionTimeMs     = $null
            TxIntervalMs        = $null
            PollPending         = $false
            DemandActive        = $false
            EchoActive          = $false
            UpSince             = $null
            LastStateChange     = $null
            LastError           = $null
            History             = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            Events              = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            PowerShell          = $null
            Handle              = $null
        })
    $reg.Bfd[$Name] = $S
    Start-BfdRunspace -State $S
    Wait-BfdReady $S
    if ($S.LastError) {
        $err = $S.LastError
        Stop-BfdRunspace $S
        $null = $reg.Bfd.Remove($Name)
        throw "BFD session '$Name' failed to start: $err"
    }
    Get-BfdSession -Name $Name
}
