# BFD protocol engine (RFC 5880): session state machine, timer negotiation, Poll/Final, Demand mode, echo bookkeeping.
# Pure logic with no sockets, so it is unit-testable and shared by the I/O loop. Times are milliseconds on a monotonic
# clock supplied by the caller; intervals on the wire and in the config are microseconds.

function New-BfdContext {
    param($Config, [uint32]$MyDiscriminator, [double]$Now = 0, [uint32]$TxSequence = 1)
    $slowTx = [Math]::Max([double]$Config.DesiredMinTx, 1000000)
    @{
        State = 'Down'; Diag = 0
        MyDisc = $MyDiscriminator; YourDisc = [uint32]0
        RemoteState = $null; RemoteMult = 0; RemoteDesiredTx = 1000000; RemoteRequiredRx = 1000000
        RemoteRequiredEchoRx = 0; RemoteDemand = $false
        LastRx = $Now; UpSince = $null
        AdvTx = $slowTx; UsedTx = $slowTx; AdvRx = [double]$Config.RequiredMinRx; UsedRx = [double]$Config.RequiredMinRx
        PollPending = $false; DemandPollAt = $null; ReplyFinal = $false; SendNow = $false
        TxSeq = $TxSequence; RcvSeq = [uint32]0; RcvSeqKnown = $false
        EchoActive = $false; EchoLastRx = $Now; EchoSeq = [uint32]0
        Received = 0; Dropped = 0; AuthFailures = 0
        Changes = [System.Collections.Generic.List[object]]::new()
    }
}

function Set-BfdContextState {
    param($Ctx, $Config, [string]$New, [int]$Diag = 0, [double]$Now = 0)
    $Ctx.Diag = $Diag
    if ($New -eq $Ctx.State) { return }
    $Ctx.Changes.Add([pscustomobject]@{ Time = Get-Date; OldState = $Ctx.State; NewState = $New; Diagnostic = $Diag })
    $Ctx.State = $New
    $Ctx.TxSeq = [uint32](([uint64]$Ctx.TxSeq + 1) % 4294967296)
    $Ctx.PollPending = $false; $Ctx.DemandPollAt = $null; $Ctx.EchoActive = $false
    $Ctx.UpSince = if ($New -eq 'Up') { $Now } else { $null }
    if ($New -eq 'Down' -or $New -eq 'AdminDown') { $Ctx.RcvSeqKnown = $false }
    # Not Up: RFC 5880 6.8.3 keeps DesiredMinTx at 1 s or more; Up: Update-BfdTimers moves to the configured value by Poll sequence.
    $slow = [Math]::Max([double]$Config.DesiredMinTx, 1000000)
    $Ctx.AdvTx = $slow; $Ctx.UsedTx = $slow
    $Ctx.AdvRx = [double]$Config.RequiredMinRx; $Ctx.UsedRx = $Ctx.AdvRx
}

function Get-BfdDetectionTimeMs {
    param($Ctx)
    $Ctx.RemoteMult * [Math]::Max($Ctx.UsedRx, $Ctx.RemoteDesiredTx) / 1000.0
}

function Get-BfdTxIntervalMs {
    param($Ctx)
    [Math]::Max($Ctx.UsedTx, $Ctx.RemoteRequiredRx) / 1000.0
}

function Test-BfdDemandActive {
    # Local Demand mode is in effect: both ends Up and we asked the peer to stop its periodic packets.
    param($Ctx, $Config)
    [bool]($Config.DemandMode -and $Ctx.State -eq 'Up' -and $Ctx.RemoteState -eq 'Up')
}

function Test-BfdPeriodicTx {
    param($Ctx, $Config)
    if ($Ctx.State -eq 'AdminDown') { return $true }
    if ($Ctx.PollPending -or $null -ne $Ctx.DemandPollAt) { return $true }
    if ($Config.Passive -and $Ctx.YourDisc -eq 0) { return $false }
    if ($Ctx.RemoteRequiredRx -eq 0) { return $false }
    if ($Ctx.State -eq 'Up' -and $Ctx.RemoteState -eq 'Up' -and $Ctx.RemoteDemand) { return $false }
    $true
}

function Invoke-BfdReceive {
    # Processes one received datagram (RFC 5880 6.8.6). Returns @{ Accepted; Reason }.
    param($Ctx, $Config, [byte[]]$Data, [double]$Now)
    $reject = { param($why) $Ctx.Dropped++; @{ Accepted = $false; Reason = $why } }

    if ($Ctx.State -eq 'AdminDown') { return & $reject 'SessionAdminDown' }
    if ($Data.Length -lt 24) { return & $reject 'TooShort' }
    if (([int]$Data[0] -shr 5) -ne 1) { return & $reject 'Version' }
    $len = [int]$Data[3]
    $authBit = ($Data[1] -band 0x04) -ne 0
    if ($len -lt $(if ($authBit) { 26 } else { 24 }) -or $len -gt $Data.Length) { return & $reject 'Length' }
    if ($Data[2] -eq 0) { return & $reject 'DetectMultZero' }
    if ($Data[1] -band 0x01) { return & $reject 'Multipoint' }
    $myDisc = Get-BfdUInt32 $Data 4
    $yourDisc = Get-BfdUInt32 $Data 8
    if ($myDisc -eq 0) { return & $reject 'MyDiscriminatorZero' }
    $poll = ($Data[1] -band 0x20) -ne 0
    $final = ($Data[1] -band 0x10) -ne 0
    if ($poll -and $final) { return & $reject 'PollAndFinal' }
    $remoteState = $script:BfdStates[[int]($Data[1] -shr 6)]
    if ($yourDisc -ne 0 -and $yourDisc -ne $Ctx.MyDisc) { return & $reject 'YourDiscriminatorUnknown' }
    if ($yourDisc -eq 0 -and $remoteState -notin 'Down', 'AdminDown') { return & $reject 'YourDiscriminatorZero' }

    $type = if ($Config.AuthType) { $Config.AuthType } else { 'None' }
    if ($type -ne 'None') {
        if (-not $authBit -or -not (Test-BfdAuth -Packet $Data -Type $type -KeyId $Config.AuthKeyId -Key $Config.AuthKey)) {
            $Ctx.AuthFailures++
            return & $reject 'AuthFailed'
        }
        $info = $script:BfdAuthTypes[$type]
        if ($type -ne 'SimplePassword') {
            $seq = Get-BfdUInt32 $Data 28
            if (-not (Test-BfdAuthSequence -Sequence $seq -Last $Ctx.RcvSeq -Known $Ctx.RcvSeqKnown -Meticulous $info.Meticulous -DetectMult $Ctx.RemoteMult)) {
                $Ctx.AuthFailures++
                return & $reject 'AuthSequence'
            }
            $Ctx.RcvSeq = $seq; $Ctx.RcvSeqKnown = $true
        }
    }
    elseif ($authBit) {
        $Ctx.AuthFailures++
        return & $reject 'AuthUnexpected'
    }

    $Ctx.Received++
    $Ctx.LastRx = $Now
    $Ctx.YourDisc = $myDisc
    $Ctx.RemoteState = $remoteState
    $Ctx.RemoteMult = [int]$Data[2]
    $Ctx.RemoteDemand = ($Data[1] -band 0x02) -ne 0
    $Ctx.RemoteDesiredTx = [double](Get-BfdUInt32 $Data 12)
    $Ctx.RemoteRequiredRx = [double](Get-BfdUInt32 $Data 16)
    $Ctx.RemoteRequiredEchoRx = [double](Get-BfdUInt32 $Data 20)

    if ($final -and ($Ctx.PollPending -or $null -ne $Ctx.DemandPollAt)) {
        # Poll sequence terminated: new timer values take full effect
        $Ctx.PollPending = $false; $Ctx.DemandPollAt = $null
        $Ctx.UsedTx = $Ctx.AdvTx; $Ctx.UsedRx = $Ctx.AdvRx
    }

    switch ($Ctx.State) {
        'Down' {
            if ($remoteState -eq 'Down') { Set-BfdContextState $Ctx $Config 'Init' 0 $Now }
            elseif ($remoteState -eq 'Init') { Set-BfdContextState $Ctx $Config 'Up' 0 $Now }
        }
        'Init' {
            if ($remoteState -eq 'AdminDown') { Set-BfdContextState $Ctx $Config 'Down' 3 $Now }
            elseif ($remoteState -in 'Init', 'Up') { Set-BfdContextState $Ctx $Config 'Up' 0 $Now }
        }
        'Up' {
            if ($remoteState -in 'Down', 'AdminDown') { Set-BfdContextState $Ctx $Config 'Down' 3 $Now }
        }
    }
    if ($poll) { $Ctx.ReplyFinal = $true; $Ctx.SendNow = $true }
    @{ Accepted = $true; Reason = $null }
}

function Update-BfdTimers {
    # Periodic step: timer changes via Poll sequence (RFC 5880 6.8.3), Demand-mode verification, detection time expiry.
    param($Ctx, $Config, [double]$Now)
    $cfgTx = [double]$Config.DesiredMinTx
    $cfgRx = [double]$Config.RequiredMinRx

    if ($Ctx.State -eq 'Up') {
        $wantTx = if ($Ctx.EchoActive) { [Math]::Max($cfgTx, 1000000) } else { $cfgTx }
        if ($wantTx -ne $Ctx.AdvTx -or $cfgRx -ne $Ctx.AdvRx) {
            # raising DesiredMinTx / lowering RequiredMinRx only takes effect once the peer answers with Final
            $Ctx.UsedTx = [Math]::Min($Ctx.UsedTx, $wantTx)
            $Ctx.UsedRx = [Math]::Max($Ctx.UsedRx, $cfgRx)
            $Ctx.AdvTx = $wantTx; $Ctx.AdvRx = $cfgRx
            $Ctx.PollPending = $true; $Ctx.SendNow = $true
        }
    }
    elseif ($Ctx.State -ne 'AdminDown') {
        $slow = [Math]::Max($cfgTx, 1000000)
        $Ctx.AdvTx = $slow; $Ctx.UsedTx = $slow
        $Ctx.AdvRx = $cfgRx; $Ctx.UsedRx = $cfgRx
    }

    if ($Ctx.State -notin 'Init', 'Up' -or $Ctx.RemoteMult -le 0) { return }
    $detect = Get-BfdDetectionTimeMs $Ctx

    if (Test-BfdDemandActive $Ctx $Config) {
        if ($null -eq $Ctx.DemandPollAt) {
            if (($Now - $Ctx.LastRx) -gt ($detect / 2)) { $Ctx.DemandPollAt = $Now; $Ctx.SendNow = $true }
        }
        elseif (($Now - $Ctx.DemandPollAt) -gt $detect) {
            Set-BfdContextState $Ctx $Config 'Down' 1 $Now
            $Ctx.YourDisc = 0
        }
        return
    }
    $Ctx.DemandPollAt = $null

    # a peer in Demand mode is silent by design, so only enforce the detection time otherwise
    $remoteQuiet = $Ctx.State -eq 'Up' -and $Ctx.RemoteState -eq 'Up' -and $Ctx.RemoteDemand
    if (-not $remoteQuiet -and ($Now - $Ctx.LastRx) -gt $detect) {
        Set-BfdContextState $Ctx $Config 'Down' 1 $Now
        $Ctx.YourDisc = 0
    }
}

function New-BfdSessionPacket {
    # Builds the next periodic/Poll/Final control packet for the session. $Fault overrides advertised fields.
    param($Ctx, $Config, $Fault, [string]$AuthKeyOverride)
    $f = if ($Fault) { $Fault } else { @{} }
    $state = if ($null -ne $f.State) { $f.State } else { $Ctx.State }
    $a = @{
        State             = $state
        Diagnostic        = $(if ($null -ne $f.Diagnostic) { [int]$f.Diagnostic } else { [int]$Ctx.Diag })
        DetectMult        = $(if ($null -ne $f.DetectMult) { [int]$f.DetectMult } else { [int]$Config.DetectMult })
        MyDiscriminator   = $(if ($null -ne $f.MyDiscriminator) { [uint32]$f.MyDiscriminator } else { $Ctx.MyDisc })
        YourDiscriminator = $(if ($null -ne $f.YourDiscriminator) { [uint32]$f.YourDiscriminator } else { $Ctx.YourDisc })
        DesiredMinTx      = $(if ($null -ne $f.DesiredMinTx) { [uint32]$f.DesiredMinTx } else { [uint32]$Ctx.AdvTx })
        RequiredMinRx     = $(if ($null -ne $f.RequiredMinRx) { [uint32]$f.RequiredMinRx } else { [uint32]$Ctx.AdvRx })
        RequiredMinEchoRx = $(if ($Config.EchoMode -and $Config.EchoMode -ne 'Disabled') { [uint32]$Config.EchoInterval } else { [uint32]0 })
        Final             = [bool]$Ctx.ReplyFinal
        Poll              = [bool](-not $Ctx.ReplyFinal -and ($Ctx.PollPending -or $null -ne $Ctx.DemandPollAt))
        Demand            = [bool](Test-BfdDemandActive $Ctx $Config)
    }
    $type = if ($Config.AuthType) { $Config.AuthType } else { 'None' }
    if ($type -ne 'None') {
        $info = $script:BfdAuthTypes[$type]
        $a.AuthType = $type
        $a.AuthKeyId = [int]$Config.AuthKeyId
        $a.AuthKey = if ($AuthKeyOverride) { $AuthKeyOverride } else { $Config.AuthKey }
        $a.AuthSequence = $Ctx.TxSeq
        if ($info.Meticulous) { $Ctx.TxSeq = [uint32](([uint64]$Ctx.TxSeq + 1) % 4294967296) }
    }
    $Ctx.ReplyFinal = $false; $Ctx.SendNow = $false
    New-BfdControl @a
}
