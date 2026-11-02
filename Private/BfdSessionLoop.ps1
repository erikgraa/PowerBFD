function Invoke-BfdSessionLoop {
    # Socket I/O around the protocol engine. Runs inside a dedicated runspace until $S.Stop is set.
    param($S)
    $c = $S.Config
    $rx = $null; $tx = $null; $echoRx = $null; $echoFailed = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $rand = [Random]::new()
    $ctx = $null

    $quiet = {
        param($sock)
        # Windows reports ICMP port unreachable as a receive error on UDP sockets; switch that off
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { try { $null = $sock.Client.IOControl(-1744830452, [byte[]]@(0, 0, 0, 0), $null) } catch { } }
    }

    try {
        $remoteIp = [ipaddress]$c.RemoteAddress
        $any = if ($remoteIp.AddressFamily -eq 'InterNetworkV6') { [ipaddress]::IPv6Any } else { [ipaddress]::Any }
        $bindIp = if ($c.LocalAddress) { [ipaddress]$c.LocalAddress } else { $any }
        $rx = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new($bindIp, $c.ListenPort))
        & $quiet $rx
        # RFC 5881 4: source port in 49152-65535, TTL/hop limit 255
        for ($i = 0; $i -lt 20 -and -not $tx; $i++) {
            try { $tx = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new($bindIp, $rand.Next(49152, 65535))) } catch { }
        }
        if (-not $tx) { throw 'Could not bind a source port in 49152-65535.' }
        & $quiet $tx
        $tx.Client.Ttl = 255
        $remote = [Net.IPEndPoint]::new($remoteIp, $c.RemotePort)

        $hook = $null
        if ($c.OnStateChange) {
            $copy = [scriptblock]::Create($c.OnStateChange.ToString())
            $mod = $ExecutionContext.SessionState.Module
            $hook = if ($mod) { $mod.NewBoundScriptBlock($copy) } else { $copy }
        }

        $ctx = New-BfdContext -Config $c -MyDiscriminator ([uint32]$rand.Next(1, [int]::MaxValue)) -Now $clock.Elapsed.TotalMilliseconds -TxSequence ([uint32]$rand.Next(1, 1000000))
        $S.AuthFailures = 0
        $S.State = 'Down'
        $S.LocalDiscriminator = $ctx.MyDisc
        $S.Ready = $true
        $nextTx = 0.0; $lastTx = 0.0; $echoNextTx = 0.0

        while (-not $S.Stop) {
            $now = $clock.Elapsed.TotalMilliseconds

            if ($S.AdminDown -and $ctx.State -ne 'AdminDown') { Set-BfdContextState $ctx $c 'AdminDown' 7 $now }
            elseif (-not $S.AdminDown -and $ctx.State -eq 'AdminDown') { Set-BfdContextState $ctx $c 'Down' 0 $now; $ctx.YourDisc = 0 }

            try {
                while ($rx.Available -gt 0) {
                    $ep = [Net.IPEndPoint]::new($any, 0)
                    $data = $rx.Receive([ref]$ep)
                    if (-not $ep.Address.Equals($remote.Address)) { continue }
                    $r = Invoke-BfdReceive $ctx $c $data $now
                    if ($r.Accepted) {
                        $S.Received = $ctx.Received
                        if ($c.RecordPackets) { Add-BfdEvent -State $S -Type 'Control' -Direction 'Rx' -Bytes $data -Summary ('rx from {0}' -f $ep.Address) }
                    }
                    else {
                        $S.Dropped = $ctx.Dropped; $S.AuthFailures = $ctx.AuthFailures
                        Add-BfdEvent -State $S -Type 'Drop' -Direction 'Rx' -Bytes $data -Summary "dropped: $($r.Reason)"
                    }
                    Publish-BfdChange $S $ctx $hook
                }
            }
            catch [Net.Sockets.SocketException] { }

            # echo function (RFC 5880 6.4): loop back the peer's echo packets, and originate our own when Active
            if ($c.EchoMode -and $c.EchoMode -ne 'Disabled' -and -not $echoRx -and -not $echoFailed) {
                try { $echoRx = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new($bindIp, $c.EchoListenPort)); & $quiet $echoRx }
                catch { $echoFailed = $true; $S.LastError = "Echo socket: $($_.Exception.Message)" }
            }
            if ($echoRx) {
                try {
                    while ($echoRx.Available -gt 0) {
                        $ep = [Net.IPEndPoint]::new($any, 0)
                        $data = $echoRx.Receive([ref]$ep)
                        if ($data.Length -lt 20 -or $data[0] -ne 0x42 -or $data[1] -ne 0x46 -or $data[2] -ne 0x44 -or $data[3] -ne 0x45) { continue }
                        if ((Get-BfdUInt32 $data 4) -eq $ctx.MyDisc) { $ctx.EchoLastRx = $now; $S.EchoReceived++ }
                        elseif ($c.EchoMode -ne 'Disabled' -and -not $S.DropEcho -and $ep.Address.Equals($remote.Address)) {
                            $null = $tx.Send($data, $data.Length, [Net.IPEndPoint]::new($ep.Address, $c.EchoPort))
                            $S.EchoReflected++
                        }
                    }
                }
                catch [Net.Sockets.SocketException] { }
            }
            $wantEcho = $c.EchoMode -eq 'Active' -and $echoRx -and $ctx.State -eq 'Up' -and $ctx.RemoteState -eq 'Up' -and $ctx.RemoteRequiredEchoRx -gt 0
            if ($wantEcho -and -not $ctx.EchoActive) {
                $ctx.EchoActive = $true; $ctx.EchoLastRx = $now; $echoNextTx = 0.0
                Add-BfdEvent -State $S -Type 'Echo' -Summary 'echo function started'
            }
            elseif (-not $wantEcho -and $ctx.EchoActive) {
                $ctx.EchoActive = $false
                Add-BfdEvent -State $S -Type 'Echo' -Summary 'echo function stopped'
            }
            if ($ctx.EchoActive) {
                $echoMs = [Math]::Max([double]$c.EchoInterval, $ctx.RemoteRequiredEchoRx) / 1000.0
                if ($now -ge $echoNextTx) {
                    $e = [byte[]]::new(20)
                    $e[0] = 0x42; $e[1] = 0x46; $e[2] = 0x44; $e[3] = 0x45
                    Set-BfdUInt32 $e 4 $ctx.MyDisc
                    $ctx.EchoSeq = [uint32](([uint64]$ctx.EchoSeq + 1) % 4294967296)
                    Set-BfdUInt32 $e 8 $ctx.EchoSeq
                    [BitConverter]::GetBytes([int64][Diagnostics.Stopwatch]::GetTimestamp()).CopyTo($e, 12)
                    $null = $tx.Send($e, $e.Length, [Net.IPEndPoint]::new($remoteIp, $c.EchoPort))
                    $S.EchoSent++
                    $echoNextTx = $now + $echoMs
                }
                if (($now - $ctx.EchoLastRx) -gt ($c.DetectMult * $echoMs)) {
                    Add-BfdEvent -State $S -Type 'Echo' -Summary 'echo function failed'
                    Set-BfdContextState $ctx $c 'Down' 2 $now
                }
            }

            Update-BfdTimers $ctx $c $now
            Publish-BfdChange $S $ctx $hook

            if ($S.Suppress) { $ctx.ReplyFinal = $false; $ctx.SendNow = $false }
            else {
                $intervalMs = Get-BfdTxIntervalMs $ctx
                # a shorter interval (state change, Poll sequence, peer lowering RequiredMinRx) must not wait for a slow schedule
                if ($nextTx -gt $lastTx + $intervalMs) { $nextTx = $lastTx + $intervalMs }
                $due = $now -ge $nextTx -and (Test-BfdPeriodicTx $ctx $c)
                if ($ctx.ReplyFinal -or $ctx.SendNow -or $due) {
                    $pkt = New-BfdSessionPacket $ctx $c $S.Fault $S.Fault.AuthKey
                    $null = $tx.Send($pkt, $pkt.Length, $remote)
                    $S.Sent++
                    $lastTx = $now
                    if ($c.RecordPackets) { Add-BfdEvent -State $S -Type 'Control' -Direction 'Tx' -Bytes $pkt -Summary ('tx to {0}' -f $remote.Address) }
                    if ($due -or $nextTx -gt $now + $intervalMs) {
                        $jitter = if ($c.DetectMult -eq 1) { 0.90 - 0.15 * $rand.NextDouble() } else { 1.0 - 0.25 * $rand.NextDouble() }
                        $nextTx = $now + $intervalMs * $jitter
                    }
                }
            }

            $S.RemoteState = $ctx.RemoteState
            $S.RemoteDiscriminator = $ctx.YourDisc
            $S.DetectionTimeMs = if ($ctx.RemoteMult) { Get-BfdDetectionTimeMs $ctx } else { $null }
            $S.TxIntervalMs = Get-BfdTxIntervalMs $ctx
            $S.PollPending = [bool]($ctx.PollPending -or $null -ne $ctx.DemandPollAt)
            $S.DemandActive = Test-BfdDemandActive $ctx $c
            $S.EchoActive = $ctx.EchoActive
            try { $null = $rx.Client.Poll(2000, [Net.Sockets.SelectMode]::SelectRead) } catch { Start-Sleep -Milliseconds 2 }
        }

        if (-not $S.Suppress -and $ctx) {
            $ctx.State = 'AdminDown'; $ctx.Diag = 7
            $pkt = New-BfdSessionPacket $ctx $c $null
            $null = $tx.Send($pkt, $pkt.Length, $remote)
        }
    }
    catch { $S.LastError = $_.Exception.Message }
    finally {
        if ($rx) { $rx.Dispose() }
        if ($tx) { $tx.Dispose() }
        if ($echoRx) { $echoRx.Dispose() }
        $S.State = 'Stopped'
        $S.Ready = $true
    }
}
