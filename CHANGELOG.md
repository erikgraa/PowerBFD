# Changelog

## 0.1.1

- Icon and PowerShell Gallery badge.
- Container image on GHCR (`ghcr.io/erikgraa/powerbfd`, amd64 and arm64), built by the `Container` workflow on each release. No module changes.

## 0.1.0

Initial release, extracted from the BFD code in [PowerBGP](https://github.com/erikgraa/PowerBGP) and generalised into a standalone module.

- BFD per RFC 5880 over single-hop UDP 3784 (RFC 5881) and multihop UDP 4784 (RFC 5883), IPv4 and IPv6.
- Session state machine (AdminDown, Down, Init, Up) with all diagnostic codes, including AdminDown handling in Init.
- Timer negotiation: detection time, transmit jitter, 1 s rule while not Up and timer changes by Poll/Final sequence.
- Demand mode (local verification Poll, silent peer) and the echo function (UDP 3785, reflect and active with diagnostic 2).
- Authentication: simple password, keyed MD5, meticulous keyed MD5, keyed SHA1, meticulous keyed SHA1, with sequence number checks.
- Passive sessions, administrative down, live reconfiguration with `Set-BfdSession`.
- Fault injection: stop sending, wrong discriminators, bad timers, zero DetectMult, wrong state/diagnostic, wrong auth key, no echo loopback.
- `-OnStateChange` / `-HookContext` notification hook for embedding in other modules.
- Event log with parsed packets and drop reasons (`Get-BfdEvent`), `Export-BfdConfig` / `Import-BfdConfig`.
- Packet helpers: `New-BfdControl`, `ConvertFrom-BfdControl`, `New-Packet`, `New-PacketField`, `Format-Packet`.
- `tools/Export-BfdEmbed.ps1` copies the self-contained BFD code into PowerBGP, PowerOSPF or any other module.
- Pester tests that need no network (loopback only), GitHub Actions for tests and Gallery publishing.

Behaviour changes compared with the BFD code in PowerBGP 0.8.x:

- A session stays at a 1 s transmit interval until Up, then moves to the configured interval with a Poll sequence (RFC 5880 6.8.3) instead of switching instantly.
- Authentication sequence numbers are checked as in RFC 5880 6.7.3/6.7.4; keyed (non-meticulous) types increment the sequence on state changes only.
- An Init session that receives AdminDown goes Down with diagnostic 3.
- `Update-BfdSession` is folded into `Set-BfdSession`; `-Suppress` is still there, now alongside the other fault injection switches.
