# PowerBFD

[![Tests](https://github.com/erikgraa/PowerBFD/actions/workflows/tests.yml/badge.svg)](https://github.com/erikgraa/PowerBFD/actions/workflows/tests.yml)

Stand up **BFD** (Bidirectional Forwarding Detection) test peers straight from PowerShell, inject faults and craft or decode BFD packets byte by byte. Built for PowerShell 7.4+ on Windows and Linux, no external modules and no web UI.

> [!WARNING]
> **Lab use only.** PowerBFD makes real routers believe a neighbour is up, down or flapping. Never point it at production equipment, and never use it against a network you do not own or have permission to test. Authentication keys are plain strings in memory (and in exported config if you ask for it).

## What it speaks

| Area | Support |
| --- | --- |
| Protocol | BFD version 1, RFC 5880 |
| Transport | Single-hop over UDP 3784 (RFC 5881) and multihop over UDP 4784 (RFC 5883), TTL/hop limit 255, source port 49152-65535, IPv4 and IPv6 |
| State machine | AdminDown, Down, Init, Up, all diagnostic codes (0-8) |
| Timers | Detection time, jittered transmit, 1 s while not Up, live changes by Poll/Final |
| Modes | Asynchronous, Demand (RFC 5880 6.6), echo function on UDP 3785 (reflect or active) |
| Authentication | Simple password, keyed MD5, meticulous keyed MD5, keyed SHA1, meticulous keyed SHA1 |
| Faults | Stop sending, wrong discriminators, bad timers, zero DetectMult, wrong state or diagnostic, wrong auth key, no echo loopback, AdminDown |

Not implemented: multipoint BFD (RFC 8562), receive-side TTL checks (GTSM) and micro-BFD over LAG.

## Quick start

```powershell
Import-Module ./PowerBFD.psd1

# Peer with a router at 192.0.2.1, 300 ms timers, multiplier 3
Start-BfdSession -RemoteAddress 192.0.2.1 -LocalAddress 192.0.2.10 -DesiredMinTxMs 300 -RequiredMinRxMs 300 -DetectMult 3

Get-BfdSession          # State, RemoteState, diagnostic, timers, counters, history
Get-BfdEvent -Last 20   # control packets (parsed), state changes, dropped packets and why
```

The router must have a BFD session configured towards the address you bind to. A listen port can only be used by one session unless the sessions bind different `-LocalAddress` values.

Other common forms:

```powershell
Start-BfdSession -RemoteAddress 198.51.100.7 -MultiHop                          # RFC 5883, port 4784
Start-BfdSession -RemoteAddress 192.0.2.1 -AuthType MeticulousKeyedSHA1 -AuthKey 'secret' -AuthKeyId 1
Start-BfdSession -RemoteAddress 192.0.2.1 -DemandMode                           # ask the peer to go silent
Start-BfdSession -RemoteAddress 192.0.2.1 -EchoMode Active -EchoIntervalMs 50   # originate echo packets (peer must advertise echo support)
Start-BfdSession -RemoteAddress 192.0.2.1 -Passive                              # wait for the peer to speak first
```

### Fault injection

```powershell
Set-BfdSession -Name 192.0.2.1 -Suppress $true                # stop sending, the peer's detection time expires (diagnostic 1)
Set-BfdSession -Name 192.0.2.1 -AdminDown $true               # signal AdminDown (diagnostic 7 on the wire, 3 at the peer)
Set-BfdSession -Name 192.0.2.1 -FaultYourDiscriminator 1234   # packets the peer will drop
Set-BfdSession -Name 192.0.2.1 -FaultRequiredMinRxMs 0        # bad timers
Set-BfdSession -Name 192.0.2.1 -FaultAuthKey 'wrong'          # signed with the wrong key
Set-BfdSession -Name 192.0.2.1 -DropEcho $true                # stop looping echo packets back
Set-BfdSession -Name 192.0.2.1 -ClearFaults
```

Timers, `-DetectMult`, `-DemandMode`, `-EchoMode`, `-Passive` and authentication can be changed on a running session; the timers are renegotiated with a Poll sequence and the session stays Up.

### Cmdlets

| Cmdlet | Purpose |
| --- | --- |
| `Start-BfdSession` | Start a session in its own runspace |
| `Get-BfdSession` | State, negotiated timers, counters, faults, history |
| `Set-BfdSession` | Change a session live, inject faults |
| `Stop-BfdSession` / `Resume-BfdSession` | Send AdminDown and stop, restart with the stored settings |
| `Remove-BfdSession` | Stop and delete |
| `Get-BfdEvent` | Event log (500 per session): `Control`, `StateChange`, `Drop`, `Echo`, `Fault`, `HookError` |
| `Export-BfdConfig` / `Import-BfdConfig` | Save and restore sessions as JSON (keys only with `-IncludeAuthKey`) |
| `New-BfdControl` / `ConvertFrom-BfdControl` | Build and parse a control packet, including invalid ones |
| `New-Packet`, `New-PacketField`, `Format-Packet` | Generic packet builder and hex dump |

```powershell
$p = New-BfdControl -State Up -MyDiscriminator 1 -YourDiscriminator 2 -AuthType KeyedSHA1 -AuthKey secret -AuthKeyId 1
ConvertFrom-BfdControl $p -AuthKey secret     # Auth.Valid is $true
Format-Packet $p
```

## Embedding in PowerBGP, PowerOSPF and other modules

The BFD code is deliberately self-contained so another module can copy it instead of depending on PowerBFD as a module:

* No external modules, no Pode, no references to the generic packet helpers. `New-BfdControl` builds bytes itself.
* The embeddable files are `Private\Bfd*.ps1` and `Public\*-Bfd*.ps1`. `New-Packet`, `New-PacketField`, `Format-Packet` and `ConvertTo-FieldBytes` are separate and not needed.
* The session loop runs in its own runspace which imports **the module the code lives in** (`$ExecutionContext.SessionState.Module`), so it works under any module name. The host module just dot-sources its `Private` and `Public` folders like `PowerBFD.psm1` does.

| File | Role |
| --- | --- |
| `Private\BfdCore.ps1` | Constants, diagnostic and auth tables, byte helpers, `$script:BfdRegistryKey` |
| `Private\BfdAuth.ps1` | Authentication and sequence verification |
| `Private\BfdEngine.ps1` | State machine, timers, Poll/Final, Demand: pure functions, no sockets |
| `Private\BfdSessionLoop.ps1` | UDP I/O around the engine (runs in the session runspace) |
| `Private\BfdRuntime.ps1` | Registry, runspace plumbing, event log, hook dispatch |
| `Public\*-Bfd*.ps1` | The cmdlets above |

Copy the files in with the helper (it only touches the destination folder):

```powershell
./tools/Export-BfdEmbed.ps1 -Destination ../PowerBGP -RegistryKey 'PowerBGP.BfdRegistry'
```

Then export the Bfd functions you want from the host manifest. `-RegistryKey` gives the host its own session registry, so a standalone PowerBFD loaded in the same process does not see (or collide with) the host's sessions. Replace the host's own copies of `BfdAuth.ps1`, `Invoke-BfdSessionLoop.ps1` and friends instead of keeping both.

### Notification hook

The boundary between BFD and the host is one callback: `-OnStateChange` on `Start-BfdSession`. It is called for every state change with `($Event, $Context)`:

```powershell
$q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()   # or a synchronized hashtable, any runspace-safe object

Start-BfdSession -RemoteAddress 192.0.2.1 -Name bgp-peer-1 -HookContext $q -OnStateChange {
    param($e, $ctx)
    # $e: Session, Remote, OldState, NewState, Diagnostic, DiagnosticName,
    #     LocalDiscriminator, RemoteDiscriminator, IsUp, Time
    if (-not $e.IsUp) { $ctx.Enqueue(@{ Peer = $e.Remote; Action = 'TearDown'; Reason = $e.DiagnosticName }) }
}
```

Rules for the hook:

* It runs in the session's runspace, so it **cannot capture local variables**. Hand shared state in with `-HookContext`. In an embedded module the hook is bound to the host module's scope, so it can call the host's private functions.
* Keep it short. Packets are not processed while it runs. A common pattern is to enqueue work for the host (as above), or to flip a flag the host's own loop polls.
* An exception in the hook is caught and logged as a `HookError` event; the session carries on.
* For hosts that prefer polling, `Get-BfdSession` (`State`, `Diagnostic`, `UpSince`) and `Get-BfdEvent -Type StateChange` expose the same information.

Typical uses: PowerBGP drops its BGP session (Cease, or just closes the TCP connection) when BFD for that neighbour goes Down; PowerOSPF kills the adjacency on BFD Down and lets it form again on Up.

## Tests

```powershell
Invoke-Pester ./Tests -Output Detailed
```

The tests need no network: packet, authentication and state machine tests are pure, the session tests talk over loopback (`127.0.x.y`) and the embed test builds a throwaway host module with `tools/Export-BfdEmbed.ps1`. A full run takes about a minute because sessions need real seconds to come Up.

## Building the Gallery package

```powershell
./tools/Build-Nupkg.ps1 -Source . -OutDir ./out
```

The `Publish` workflow does this on a `v*` tag (or manually as a dry run) and pushes to the PowerShell Gallery when `PSGALLERY_API_KEY` is set.

## Licence

MIT, see [LICENSE](LICENSE).
