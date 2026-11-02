BeforeDiscovery { Import-Module "$PSScriptRoot\..\PowerBFD.psd1" -Force }

InModuleScope PowerBFD {
    Describe 'BFD engine' {
        BeforeAll {
            function New-TestConfig {
                param([hashtable]$With = @{})
                $c = [pscustomobject]@{
                    DesiredMinTx = [uint32]100000; RequiredMinRx = [uint32]100000; DetectMult = 3
                    Passive = $false; DemandMode = $false; EchoMode = 'Disabled'; EchoInterval = [uint32]100000
                    AuthType = 'None'; AuthKeyId = 1; AuthKey = $null
                }
                foreach ($k in $With.Keys) { $c.$k = $With[$k] }
                $c
            }
            function New-PeerPacket {
                param($Ctx, [string]$State = 'Down', [hashtable]$With = @{})
                $a = @{ State = $State; MyDiscriminator = 100; YourDiscriminator = $(if ($State -eq 'Down') { 0 } else { $Ctx.MyDisc })
                    DesiredMinTx = 100000; RequiredMinRx = 100000; DetectMult = 3
                }
                foreach ($k in $With.Keys) { $a[$k] = $With[$k] }
                New-BfdControl @a
            }
            function New-UpContext {
                param($Config, [double]$Now = 0)
                $ctx = New-BfdContext -Config $Config -MyDiscriminator 7 -Now $Now
                $null = Invoke-BfdReceive $ctx $Config (New-PeerPacket $ctx 'Down') $Now
                $null = Invoke-BfdReceive $ctx $Config (New-PeerPacket $ctx 'Init') $Now
                $null = Invoke-BfdReceive $ctx $Config (New-PeerPacket $ctx 'Up') $Now
                $ctx.Changes.Clear()
                $ctx
            }
        }

        Context 'state machine (RFC 5880 6.8.6)' {
            It 'goes Down -> Init -> Up with a notification per change' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                (Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down') 0).Accepted | Should -BeTrue
                $ctx.State | Should -Be 'Init'
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up') 1
                $ctx.State | Should -Be 'Up'
                $ctx.Changes.Count | Should -Be 2
                $ctx.Changes[1].OldState | Should -Be 'Init'
                $ctx.Changes[1].NewState | Should -Be 'Up'
                $ctx.YourDisc | Should -Be 100
            }
            It 'goes Down -> Up when the peer already is Init' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Init') 0
                $ctx.State | Should -Be 'Up'
            }
            It 'ignores an AdminDown peer while Down' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'AdminDown' @{ YourDiscriminator = 0 }) 0
                $ctx.State | Should -Be 'Down'
            }
            It 'goes Down with diagnostic 3 when an Up session sees the peer Down' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                $ctx.State | Should -Be 'Up'
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down' @{ YourDiscriminator = $ctx.MyDisc }) 5
                $ctx.State | Should -Be 'Down'
                $ctx.Diag | Should -Be 3
            }
            It 'goes Down with diagnostic 3 when an Init session sees the peer AdminDown' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down') 0
                $ctx.State | Should -Be 'Init'
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'AdminDown') 1
                $ctx.State | Should -Be 'Down'
                $ctx.Diag | Should -Be 3
            }
            It 'ignores all packets while administratively down' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                Set-BfdContextState $ctx $c 'AdminDown' 7 0
                (Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up') 1).Reason | Should -Be 'SessionAdminDown'
            }
        }

        Context 'packet validation' {
            It 'drops <Reason>' -ForEach @(
                @{ Reason = 'Version'; With = @{ Version = 2 } }
                @{ Reason = 'DetectMultZero'; With = @{ DetectMult = 0 } }
                @{ Reason = 'MyDiscriminatorZero'; With = @{ MyDiscriminator = 0 } }
                @{ Reason = 'PollAndFinal'; With = @{ Poll = $true; Final = $true } }
                @{ Reason = 'Multipoint'; With = @{ Multipoint = $true } }
                @{ Reason = 'Length'; With = @{ Length = 60 } }
                @{ Reason = 'YourDiscriminatorUnknown'; With = @{ YourDiscriminator = 12345 } }
            ) {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $r = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down' $With) 0
                $r.Accepted | Should -BeFalse
                $r.Reason | Should -Be $Reason
                $ctx.State | Should -Be 'Down'
                $ctx.Dropped | Should -Be 1
            }
            It 'drops a truncated datagram' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                (Invoke-BfdReceive $ctx $c ([byte[]]::new(10)) 0).Reason | Should -Be 'TooShort'
            }
            It 'drops a zero Your Discriminator when the peer claims Init or Up' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                (Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ YourDiscriminator = 0 }) 0).Reason | Should -Be 'YourDiscriminatorZero'
            }
        }

        Context 'timers' {
            It 'computes the detection time from the peer multiplier and the larger of RequiredMinRx and the peer DesiredMinTx' {
                $c = New-TestConfig @{ RequiredMinRx = [uint32]50000 }
                $ctx = New-UpContext $c
                $ctx.RemoteMult = 4; $ctx.RemoteDesiredTx = 200000; $ctx.UsedRx = 50000
                Get-BfdDetectionTimeMs $ctx | Should -Be 800
                $ctx.UsedRx = 300000
                Get-BfdDetectionTimeMs $ctx | Should -Be 1200
            }
            It 'transmits at the larger of its own DesiredMinTx and the peer RequiredMinRx' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                $ctx.UsedTx = 100000; $ctx.RemoteRequiredRx = 400000
                Get-BfdTxIntervalMs $ctx | Should -Be 400
                $ctx.RemoteRequiredRx = 20000
                Get-BfdTxIntervalMs $ctx | Should -Be 100
            }
            It 'goes Down with diagnostic 1 when the detection time expires' {
                $c = New-TestConfig
                $ctx = New-UpContext $c 0
                $ctx.UsedRx = 100000; $ctx.RemoteDesiredTx = 100000
                Update-BfdTimers $ctx $c 299
                $ctx.State | Should -Be 'Up'
                Update-BfdTimers $ctx $c 301
                $ctx.State | Should -Be 'Down'
                $ctx.Diag | Should -Be 1
                $ctx.YourDisc | Should -Be 0
            }
            It 'sticks to 1 s or slower while not Up' {
                $c = New-TestConfig
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $ctx.AdvTx | Should -Be 1000000
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down') 0
                $ctx.State | Should -Be 'Init'
                $ctx.UsedTx | Should -Be 1000000
            }
            It 'moves to the configured interval with a Poll sequence once Up' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                $ctx.AdvTx | Should -Be 1000000
                Update-BfdTimers $ctx $c 10
                $ctx.PollPending | Should -BeTrue
                $ctx.AdvTx | Should -Be 100000
                $ctx.UsedTx | Should -Be 100000
                $pkt = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $null)
                $pkt.Poll | Should -BeTrue
                $pkt.DesiredMinTx | Should -Be 100000
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Final = $true }) 20
                $ctx.PollPending | Should -BeFalse
            }
            It 'keeps the old transmit interval when DesiredMinTx is raised until the peer answers Final' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                Update-BfdTimers $ctx $c 10
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Final = $true }) 20
                $c.DesiredMinTx = [uint32]400000
                Update-BfdTimers $ctx $c 30
                $ctx.PollPending | Should -BeTrue
                $ctx.AdvTx | Should -Be 400000
                $ctx.UsedTx | Should -Be 100000
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Final = $true }) 40
                $ctx.UsedTx | Should -Be 400000
            }
            It 'keeps the old detection interval when RequiredMinRx is lowered until the peer answers Final' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                Update-BfdTimers $ctx $c 10
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Final = $true }) 20
                $c.RequiredMinRx = [uint32]20000
                Update-BfdTimers $ctx $c 30
                $ctx.AdvRx | Should -Be 20000
                $ctx.UsedRx | Should -Be 100000
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Final = $true }) 40
                $ctx.UsedRx | Should -Be 20000
            }
            It 'answers a Poll with Final and no Poll' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Poll = $true }) 5
                $ctx.ReplyFinal | Should -BeTrue
                $pkt = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $null)
                $pkt.Final | Should -BeTrue
                $pkt.Poll | Should -BeFalse
                $ctx.ReplyFinal | Should -BeFalse
            }
            It 'stops periodic transmission when the peer requires no packets (RequiredMinRx 0)' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ RequiredMinRx = 0 }) 5
                Test-BfdPeriodicTx $ctx $c | Should -BeFalse
            }
            It 'does not transmit while Passive and the peer is unknown' {
                $c = New-TestConfig @{ Passive = $true }
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                Test-BfdPeriodicTx $ctx $c | Should -BeFalse
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down') 0
                Test-BfdPeriodicTx $ctx $c | Should -BeTrue
            }
        }

        Context 'demand mode (RFC 5880 6.6)' {
            It 'sets the D bit once both ends are Up and verifies the path with a Poll after silence' {
                $c = New-TestConfig @{ DemandMode = $true }
                $ctx = New-UpContext $c 0
                $ctx.State | Should -Be 'Up'
                (ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $null)).Demand | Should -BeTrue
                $ctx.UsedRx = 100000; $ctx.RemoteDesiredTx = 100000
                Update-BfdTimers $ctx $c 100
                $ctx.DemandPollAt | Should -BeNullOrEmpty
                Update-BfdTimers $ctx $c 200
                $ctx.DemandPollAt | Should -Not -BeNullOrEmpty
                (ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $null)).Poll | Should -BeTrue
                $ctx.State | Should -Be 'Up'
            }
            It 'clears the verification Poll on Final' {
                $c = New-TestConfig @{ DemandMode = $true }
                $ctx = New-UpContext $c 0
                $ctx.UsedRx = 100000; $ctx.RemoteDesiredTx = 100000
                Update-BfdTimers $ctx $c 200
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Final = $true }) 210
                $ctx.DemandPollAt | Should -BeNullOrEmpty
                Update-BfdTimers $ctx $c 250
                $ctx.State | Should -Be 'Up'
            }
            It 'goes Down with diagnostic 1 when the verification Poll gets no answer' {
                $c = New-TestConfig @{ DemandMode = $true }
                $ctx = New-UpContext $c 0
                $ctx.UsedRx = 100000; $ctx.RemoteDesiredTx = 100000
                Update-BfdTimers $ctx $c 200
                Update-BfdTimers $ctx $c 600
                $ctx.State | Should -Be 'Down'
                $ctx.Diag | Should -Be 1
            }
            It 'stops periodic packets and the detection timer when the peer is in Demand mode' {
                $c = New-TestConfig
                $ctx = New-UpContext $c 0
                $null = Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Up' @{ Demand = $true }) 5
                Test-BfdPeriodicTx $ctx $c | Should -BeFalse
                Update-BfdTimers $ctx $c 60000
                $ctx.State | Should -Be 'Up'
            }
        }

        Context 'authentication in the receive path' {
            It 'accepts a valid <Type> packet and drops a wrong key' -ForEach @(
                @{ Type = 'SimplePassword' }, @{ Type = 'KeyedMD5' }, @{ Type = 'MeticulousKeyedMD5' }
                @{ Type = 'KeyedSHA1' }, @{ Type = 'MeticulousKeyedSHA1' }
            ) {
                $c = New-TestConfig @{ AuthType = $Type; AuthKey = 'secret' }
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $good = New-PeerPacket $ctx 'Down' @{ AuthType = $Type; AuthKey = 'secret'; AuthKeyId = 1; AuthSequence = 10 }
                (Invoke-BfdReceive $ctx $c $good 0).Accepted | Should -BeTrue
                $bad = New-PeerPacket $ctx 'Down' @{ AuthType = $Type; AuthKey = 'wrong'; AuthKeyId = 1; AuthSequence = 11 }
                (Invoke-BfdReceive $ctx $c $bad 1).Reason | Should -Be 'AuthFailed'
                $ctx.AuthFailures | Should -Be 1
            }
            It 'drops an unauthenticated packet when authentication is configured, and the reverse' {
                $c = New-TestConfig @{ AuthType = 'KeyedSHA1'; AuthKey = 'secret' }
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                (Invoke-BfdReceive $ctx $c (New-PeerPacket $ctx 'Down') 0).Reason | Should -Be 'AuthFailed'
                $c2 = New-TestConfig
                $ctx2 = New-BfdContext -Config $c2 -MyDiscriminator 7
                $signed = New-PeerPacket $ctx2 'Down' @{ AuthType = 'KeyedSHA1'; AuthKey = 'secret'; AuthKeyId = 1 }
                (Invoke-BfdReceive $ctx2 $c2 $signed 0).Reason | Should -Be 'AuthUnexpected'
            }
            It 'drops a wrong key id' {
                $c = New-TestConfig @{ AuthType = 'KeyedMD5'; AuthKey = 'secret' }
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $p = New-PeerPacket $ctx 'Down' @{ AuthType = 'KeyedMD5'; AuthKey = 'secret'; AuthKeyId = 9 }
                (Invoke-BfdReceive $ctx $c $p 0).Reason | Should -Be 'AuthFailed'
            }
            It 'rejects a replayed meticulous sequence but accepts a repeated keyed one' {
                foreach ($case in @(@{ T = 'MeticulousKeyedSHA1'; Ok = $false }, @{ T = 'KeyedSHA1'; Ok = $true })) {
                    $c = New-TestConfig @{ AuthType = $case.T; AuthKey = 'secret' }
                    $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                    $p = New-PeerPacket $ctx 'Down' @{ AuthType = $case.T; AuthKey = 'secret'; AuthKeyId = 1; AuthSequence = 50 }
                    (Invoke-BfdReceive $ctx $c $p 0).Accepted | Should -BeTrue
                    $ctx.State = 'Down'
                    (Invoke-BfdReceive $ctx $c $p 1).Accepted | Should -Be $case.Ok
                }
            }
            It 'increments the transmit sequence per packet for meticulous types only' {
                $c = New-TestConfig @{ AuthType = 'MeticulousKeyedMD5'; AuthKey = 'secret' }
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7 -TxSequence 100
                $a = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $null)
                $b = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $null)
                ($b.Auth.Sequence - $a.Auth.Sequence) | Should -Be 1
                $c2 = New-TestConfig @{ AuthType = 'KeyedMD5'; AuthKey = 'secret' }
                $ctx2 = New-BfdContext -Config $c2 -MyDiscriminator 7 -TxSequence 100
                $a = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx2 $c2 $null)
                $b = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx2 $c2 $null)
                $b.Auth.Sequence | Should -Be $a.Auth.Sequence
            }
        }

        Context 'fault injection in transmitted packets' {
            It 'overrides discriminators, timers, multiplier, state and diagnostic' {
                $c = New-TestConfig
                $ctx = New-UpContext $c
                $fault = @{ MyDiscriminator = 0; YourDiscriminator = 999; DesiredMinTx = 0; RequiredMinRx = 0; DetectMult = 0; State = 'Init'; Diagnostic = 5 }
                $p = ConvertFrom-BfdControl (New-BfdSessionPacket $ctx $c $fault)
                $p.MyDiscriminator | Should -Be 0
                $p.YourDiscriminator | Should -Be 999
                $p.DesiredMinTx | Should -Be 0
                $p.RequiredMinRx | Should -Be 0
                $p.DetectMult | Should -Be 0
                $p.State | Should -Be 'Init'
                $p.Diagnostic | Should -Be 5
            }
            It 'signs with a wrong key' {
                $c = New-TestConfig @{ AuthType = 'KeyedSHA1'; AuthKey = 'secret' }
                $ctx = New-BfdContext -Config $c -MyDiscriminator 7
                $raw = New-BfdSessionPacket $ctx $c $null 'bogus'
                (ConvertFrom-BfdControl $raw -AuthKey 'secret').Auth.Valid | Should -BeFalse
                (ConvertFrom-BfdControl $raw -AuthKey 'bogus').Auth.Valid | Should -BeTrue
            }
        }
    }
}
