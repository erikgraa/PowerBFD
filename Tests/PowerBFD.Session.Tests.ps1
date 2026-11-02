BeforeAll {
    Import-Module "$PSScriptRoot\..\PowerBFD.psd1" -Force

    function Wait-Until {
        param([scriptblock]$Condition, [int]$Seconds = 20)
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            if (& $Condition) { return $true }
            Start-Sleep -Milliseconds 100
        }
        [bool](& $Condition)
    }

    # Two sessions on loopback talking to each other: 127.0.<n>.1 <-> 127.0.<n>.2, UDP port 16000+<n>
    function New-BfdPair {
        param([string]$Tag, [int]$N, [hashtable]$A = @{}, [hashtable]$B = @{})
        $make = {
            param($self, $peer, $extra)
            $h = @{
                Name = "$Tag-$self"; RemoteAddress = "127.0.$N.$(if ($self -eq 'a') { 2 } else { 1 })"
                LocalAddress = [ipaddress]"127.0.$N.$(if ($self -eq 'a') { 1 } else { 2 })"
                ListenPort = 16000 + $N; Port = 16000 + $N; DesiredMinTxMs = 100; RequiredMinRxMs = 100
            }
            foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
            $h
        }
        $sa = & $make 'a' 'b' $A
        $sb = & $make 'b' 'a' $B
        $null = Start-BfdSession @sa
        $null = Start-BfdSession @sb
    }
}
AfterAll { Get-BfdSession | Remove-BfdSession -Confirm:$false }

Describe 'session defaults' {
    It 'uses port 3784 single-hop and 4784 multihop' {
        (Start-BfdSession -Name d-mh -RemoteAddress 127.0.50.9 -LocalAddress 127.0.50.1 -MultiHop -ListenPort 16050).Remote | Should -Be '127.0.50.9:4784'
        (Start-BfdSession -Name d-sh -RemoteAddress 127.0.50.10 -LocalAddress 127.0.50.2 -ListenPort 16051).Remote | Should -Be '127.0.50.10:3784'
        (Get-BfdSession d-mh).MultiHop | Should -BeTrue
        Get-BfdSession d-* | Remove-BfdSession -Confirm:$false
    }
    It 'rejects a duplicate name, a bad address and a missing key' {
        $null = Start-BfdSession -Name d-dup -RemoteAddress 127.0.51.9 -LocalAddress 127.0.51.1 -ListenPort 16052
        { Start-BfdSession -Name d-dup -RemoteAddress 127.0.51.9 -ListenPort 16053 } | Should -Throw '*already exists*'
        { Start-BfdSession -RemoteAddress notanip } | Should -Throw '*not an IP address*'
        { Start-BfdSession -RemoteAddress 127.0.51.9 -AuthType KeyedSHA1 } | Should -Throw '*AuthKey is required*'
        Get-BfdSession d-* | Remove-BfdSession -Confirm:$false
    }
    It 'fails with a clear error when the listen port is taken' {
        $blocker = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([ipaddress]'127.0.52.1', 16054))
        try {
            { Start-BfdSession -Name d-bind -RemoteAddress 127.0.52.2 -LocalAddress 127.0.52.1 -ListenPort 16054 } | Should -Throw '*failed to start*'
            Get-BfdSession d-bind | Should -BeNullOrEmpty
        }
        finally { $blocker.Dispose() }
    }
}

Describe 'asynchronous mode between two sessions' {
    BeforeAll {
        $script:q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $hook = { param($e, $ctx) $ctx.Enqueue($e) }
        New-BfdPair -Tag as -N 1 -A @{ OnStateChange = $hook; HookContext = $script:q }
    }
    AfterAll { Get-BfdSession as-* | Remove-BfdSession -Confirm:$false }

    It 'comes Up and negotiates the configured timers with a Poll sequence' {
        Wait-Until { (Get-BfdSession as-a).State -eq 'Up' -and (Get-BfdSession as-b).State -eq 'Up' } | Should -BeTrue
        $a = Get-BfdSession as-a
        $a.RemoteState | Should -Be 'Up'
        $a.LocalDiscriminator | Should -Not -Be 0
        $a.RemoteDiscriminator | Should -Be (Get-BfdSession as-b).LocalDiscriminator
        Wait-Until { -not (Get-BfdSession as-a).PollPending -and (Get-BfdSession as-a).TxIntervalMs -le 150 } | Should -BeTrue
        (Get-BfdSession as-a).DetectionTimeMs | Should -BeLessOrEqual 400
    }
    It 'calls the notification hook for every state change' {
        $states = @($script:q.ToArray() | ForEach-Object NewState)
        $states | Should -Contain 'Init'
        $states[-1] | Should -Be 'Up'
        $up = $script:q.ToArray() | Where-Object IsUp | Select-Object -First 1
        $up.Session | Should -Be 'as-a'
        $up.RemoteDiscriminator | Should -Be (Get-BfdSession as-b).LocalDiscriminator
    }
    It 'records state changes and parsed control packets in the event log' {
        Get-BfdEvent as-a -Type StateChange | ForEach-Object { $_.Data.NewState } | Should -Contain 'Up'
        $rx = Get-BfdEvent as-a -Type Control -Last 5 | Where-Object Direction -EQ 'Rx' | Select-Object -Last 1
        $rx.Message.State | Should -Be 'Up'
    }
    It 'goes Down with diagnostic 1 on the peer when sending is suppressed, and recovers' {
        Set-BfdSession as-a -Suppress $true
        Wait-Until { (Get-BfdSession as-b).State -eq 'Down' } | Should -BeTrue
        (Get-BfdSession as-b).Diagnostic | Should -Be 1
        (Get-BfdSession as-a).Suppressed | Should -BeTrue
        Set-BfdSession as-a -Suppress $false
        Wait-Until { (Get-BfdSession as-a).State -eq 'Up' -and (Get-BfdSession as-b).State -eq 'Up' } | Should -BeTrue
    }
    It 'changes timers live without going Down' {
        Set-BfdSession as-a -DesiredMinTxMs 300
        (Get-BfdSession as-a).TxMs | Should -Be 300
        Wait-Until { (Get-BfdSession as-a).TxIntervalMs -ge 300 } | Should -BeTrue
        (Get-BfdSession as-a).State | Should -Be 'Up'
        (Get-BfdSession as-b).State | Should -Be 'Up'
    }
    It 'signals AdminDown (diagnostic 3 on the peer) and recovers' {
        Set-BfdSession as-a -AdminDown $true
        Wait-Until { (Get-BfdSession as-b).State -eq 'Down' } | Should -BeTrue
        (Get-BfdSession as-b).Diagnostic | Should -Be 3
        (Get-BfdSession as-a).State | Should -Be 'AdminDown'
        Set-BfdSession as-a -AdminDown $false
        Wait-Until { (Get-BfdSession as-a).State -eq 'Up' -and (Get-BfdSession as-b).State -eq 'Up' } | Should -BeTrue
    }
    It 'stops with AdminDown, resumes and keeps its event log' {
        Stop-BfdSession as-a
        (Get-BfdSession as-a).State | Should -Be 'Stopped'
        Wait-Until { (Get-BfdSession as-b).State -eq 'Down' } | Should -BeTrue
        Resume-BfdSession as-a | Out-Null
        Wait-Until { (Get-BfdSession as-a).State -eq 'Up' -and (Get-BfdSession as-b).State -eq 'Up' } | Should -BeTrue
        @(Get-BfdEvent as-a -Type StateChange -Last 100).Count | Should -BeGreaterThan 4
    }
}

Describe 'fault injection' {
    BeforeAll { New-BfdPair -Tag fi -N 2; Wait-Until { (Get-BfdSession fi-a).State -eq 'Up' -and (Get-BfdSession fi-b).State -eq 'Up' } | Out-Null }
    AfterAll { Get-BfdSession fi-* | Remove-BfdSession -Confirm:$false }

    It 'makes the peer drop packets with a wrong Your Discriminator and then expire' {
        Set-BfdSession fi-a -FaultYourDiscriminator 12345
        (Get-BfdSession fi-a).Faults.YourDiscriminator | Should -Be 12345
        Wait-Until { (Get-BfdSession fi-b).State -eq 'Down' } | Should -BeTrue
        (Get-BfdSession fi-b).Diagnostic | Should -Be 1
        @(Get-BfdEvent fi-b -Type Drop | Where-Object Summary -Like '*YourDiscriminatorUnknown*').Count | Should -BeGreaterThan 0
        Set-BfdSession fi-a -ClearFaults
        (Get-BfdSession fi-a).Faults | Should -BeNullOrEmpty
        Wait-Until { (Get-BfdSession fi-a).State -eq 'Up' -and (Get-BfdSession fi-b).State -eq 'Up' } | Should -BeTrue
    }
    It 'makes the peer drop packets with a zero DetectMult' {
        Set-BfdSession fi-a -FaultDetectMult 0
        Wait-Until { (Get-BfdSession fi-b).State -eq 'Down' } | Should -BeTrue
        @(Get-BfdEvent fi-b -Type Drop | Where-Object Summary -Like '*DetectMultZero*').Count | Should -BeGreaterThan 0
        Set-BfdSession fi-a -ClearFaults
        Wait-Until { (Get-BfdSession fi-a).State -eq 'Up' -and (Get-BfdSession fi-b).State -eq 'Up' } | Should -BeTrue
    }
    It 'advertises a bad RequiredMinRx of 0 and the peer stops periodic packets without dropping the session' {
        Set-BfdSession fi-a -FaultRequiredMinRxMs 0
        Start-Sleep -Seconds 1
        $before = (Get-BfdSession fi-b).Sent
        Start-Sleep -Seconds 1
        ((Get-BfdSession fi-b).Sent - $before) | Should -BeLessOrEqual 2
        Set-BfdSession fi-a -ClearFaults
    }
}

Describe 'authentication on the wire' {
    AfterEach { Get-BfdSession au-* | Remove-BfdSession -Confirm:$false }

    It 'comes Up with <Type> and the same key' -ForEach @(
        @{ Type = 'SimplePassword' }, @{ Type = 'MeticulousKeyedMD5' }, @{ Type = 'KeyedSHA1' }
    ) {
        $x = @{ AuthType = $Type; AuthKey = 'secret'; AuthKeyId = 1 }
        New-BfdPair -Tag au -N 3 -A $x -B $x
        Wait-Until { (Get-BfdSession au-a).State -eq 'Up' -and (Get-BfdSession au-b).State -eq 'Up' } | Should -BeTrue
        (Get-BfdSession au-a).AuthType | Should -Be $Type
        (Get-BfdSession au-a).AuthFailures | Should -Be 0
    }
    It 'never comes Up with different keys and counts failures' {
        New-BfdPair -Tag au -N 4 -A @{ AuthType = 'KeyedSHA1'; AuthKey = 'one' } -B @{ AuthType = 'KeyedSHA1'; AuthKey = 'two' }
        Wait-Until { (Get-BfdSession au-a).AuthFailures -gt 1 } | Should -BeTrue
        (Get-BfdSession au-a).State | Should -Be 'Down'
        (Get-BfdSession au-b).State | Should -Be 'Down'
    }
    It 'loses the session when the peer starts signing with a wrong key' {
        $x = @{ AuthType = 'KeyedMD5'; AuthKey = 'secret' }
        New-BfdPair -Tag au -N 5 -A $x -B $x
        Wait-Until { (Get-BfdSession au-a).State -eq 'Up' -and (Get-BfdSession au-b).State -eq 'Up' } | Should -BeTrue
        Set-BfdSession au-a -FaultAuthKey 'bogus'
        Wait-Until { (Get-BfdSession au-b).State -eq 'Down' } | Should -BeTrue
        (Get-BfdSession au-b).AuthFailures | Should -BeGreaterThan 0
    }
}

Describe 'echo function' {
    It 'originates echo packets that the peer loops back' {
        New-BfdPair -Tag ec -N 6 `
            -A @{ EchoMode = 'Active'; EchoIntervalMs = 50; EchoListenPort = 16061; EchoPort = 16062 } `
            -B @{ EchoMode = 'Reflect'; EchoIntervalMs = 50; EchoListenPort = 16062; EchoPort = 16061 }
        Wait-Until { (Get-BfdSession ec-a).EchoActive } | Should -BeTrue
        Wait-Until { (Get-BfdSession ec-a).EchoReceived -gt 3 } | Should -BeTrue
        (Get-BfdSession ec-b).EchoReflected | Should -BeGreaterThan 3
        (Get-BfdSession ec-a).State | Should -Be 'Up'
        Get-BfdSession ec-* | Remove-BfdSession -Confirm:$false
    }
    It 'goes Down with diagnostic 2 when echo packets stop coming back' {
        New-BfdPair -Tag ef -N 7 `
            -A @{ EchoMode = 'Active'; EchoIntervalMs = 50; EchoListenPort = 16071; EchoPort = 16072 } `
            -B @{ EchoMode = 'Reflect'; EchoIntervalMs = 50; EchoListenPort = 16072; EchoPort = 16071 }
        Wait-Until { (Get-BfdSession ef-a).EchoReceived -gt 2 } | Should -BeTrue
        # B keeps advertising echo support but silently stops looping the packets back
        Set-BfdSession ef-b -DropEcho $true
        Wait-Until { (Get-BfdSession ef-a).State -eq 'Down' } | Should -BeTrue
        (Get-BfdSession ef-a).Diagnostic | Should -Be 2
        Get-BfdSession ef-* | Remove-BfdSession -Confirm:$false
    }
}

Describe 'demand mode' {
    It 'keeps the session Up with the peer silent, verified by Poll/Final' {
        New-BfdPair -Tag dm -N 8 -A @{ DemandMode = $true }
        Wait-Until { (Get-BfdSession dm-a).DemandActive } | Should -BeTrue
        Start-Sleep -Seconds 3
        (Get-BfdSession dm-a).State | Should -Be 'Up'
        (Get-BfdSession dm-b).State | Should -Be 'Up'
        (Get-BfdSession dm-a).Mode | Should -Be 'Demand'
        $tx = @(Get-BfdEvent dm-b -Type Control -Last 200 | Where-Object Direction -EQ 'Tx' | Select-Object -Last 4)
        $tx.Count | Should -Be 4
        $tx.Message.Final | Should -Not -Contain $false
        Get-BfdSession dm-* | Remove-BfdSession -Confirm:$false
    }
    It 'goes Down with diagnostic 1 when the Poll gets no answer' {
        New-BfdPair -Tag dn -N 9 -A @{ DemandMode = $true }
        Wait-Until { (Get-BfdSession dn-a).DemandActive } | Should -BeTrue
        Set-BfdSession dn-b -Suppress $true
        Wait-Until { (Get-BfdSession dn-a).State -eq 'Down' } | Should -BeTrue
        (Get-BfdSession dn-a).Diagnostic | Should -Be 1
        Get-BfdSession dn-* | Remove-BfdSession -Confirm:$false
    }
}

Describe 'hooks and Poll answered by a raw peer' {
    It 'answers a Poll with the Final bit' {
        $null = Start-BfdSession -Name raw -RemoteAddress 127.0.10.2 -LocalAddress 127.0.10.1 -ListenPort 16010 -Port 16011
        $peer = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([ipaddress]'127.0.10.2', 16011))
        try {
            $peer.Client.ReceiveTimeout = 500
            $poll = New-BfdControl -State Down -Poll -MyDiscriminator 77 -YourDiscriminator 0
            $final = $false
            $deadline = (Get-Date).AddSeconds(8)
            while (-not $final -and (Get-Date) -lt $deadline) {
                $null = $peer.Send($poll, $poll.Length, [Net.IPEndPoint]::new([ipaddress]'127.0.10.1', 16010))
                try {
                    $ep = [Net.IPEndPoint]::new([ipaddress]::Any, 0)
                    $final = (ConvertFrom-BfdControl ($peer.Receive([ref]$ep))).Final
                }
                catch [Net.Sockets.SocketException] { }
            }
            $final | Should -BeTrue
        }
        finally { $peer.Dispose(); Remove-BfdSession raw -Confirm:$false }
    }
    It 'survives a notification hook that throws and logs HookError' {
        New-BfdPair -Tag he -N 11 -A @{ OnStateChange = { param($e, $ctx) throw 'boom' } }
        Wait-Until { (Get-BfdSession he-a).State -eq 'Up' } | Should -BeTrue
        @(Get-BfdEvent he-a -Type HookError).Count | Should -BeGreaterThan 0
        Get-BfdSession he-* | Remove-BfdSession -Confirm:$false
    }
}

Describe 'config export and import' {
    It 'round-trips sessions and leaves keys out unless asked' {
        $null = Start-BfdSession -Name cfg -RemoteAddress 127.0.12.2 -LocalAddress 127.0.12.1 -ListenPort 16012 -Port 16013 -DesiredMinTxMs 200 -AuthType KeyedSHA1 -AuthKey topsecret -DemandMode
        $path = Join-Path ([IO.Path]::GetTempPath()) "bfd-$([guid]::NewGuid()).json"
        try {
            Export-BfdConfig -Path $path
            (Get-Content $path -Raw) | Should -Not -Match 'topsecret'
            Export-BfdConfig -Path $path -IncludeAuthKey
            (Get-Content $path -Raw) | Should -Match 'topsecret'
            Remove-BfdSession cfg -Confirm:$false
            Import-BfdConfig -Path $path | Out-Null
            $s = Get-BfdSession cfg
            $s.TxMs | Should -Be 200
            $s.Mode | Should -Be 'Demand'
            $s.AuthType | Should -Be 'KeyedSHA1'
        }
        finally { Remove-Item $path -ErrorAction SilentlyContinue; Remove-BfdSession cfg -Confirm:$false -ErrorAction SilentlyContinue }
    }
}
