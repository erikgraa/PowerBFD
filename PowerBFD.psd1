@{
    RootModule           = 'PowerBFD.psm1'
    ModuleVersion        = '0.1.1'
    GUID                 = 'b2f4c6a8-3d1e-4f70-9a5b-7c8d9e0f1a23'
    Author               = 'erikgraa'
    Description          = 'Lab-use-only standalone BFD (RFC 5880/5881/5883) test peer for PowerShell: single-hop and multihop sessions, async and demand mode, echo, authentication (simple password, keyed MD5/SHA1 and meticulous variants), fault injection and a packet builder. The BFD code is self-contained so it can be embedded in PowerBGP, PowerOSPF and similar modules.'
    CompanyName          = 'erikgraa'
    Copyright            = '(c) erikgraa. All rights reserved.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'New-PacketField', 'New-Packet', 'Format-Packet',
        'New-BfdControl', 'ConvertFrom-BfdControl',
        'Start-BfdSession', 'Get-BfdSession', 'Set-BfdSession', 'Stop-BfdSession', 'Resume-BfdSession', 'Remove-BfdSession',
        'Get-BfdEvent', 'Export-BfdConfig', 'Import-BfdConfig'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{ PSData = @{
            Tags         = @('BFD', 'Networking', 'Packet', 'Testing', 'Router', 'RFC5880', 'Linux', 'Windows')
            ProjectUri   = 'https://github.com/erikgraa/PowerBFD'
            LicenseUri   = 'https://github.com/erikgraa/PowerBFD/blob/main/LICENSE'
            IconUri      = 'https://raw.githubusercontent.com/erikgraa/PowerBFD/main/icon.png'
            ReleaseNotes = '0.1.1: Icon, container image on GHCR (no module changes). 0.1.0: Initial release. BFD single-hop (RFC 5881) and multihop (RFC 5883), async and demand mode, echo, timer negotiation with Poll/Final, authentication (simple password, keyed MD5/SHA1, meticulous variants), state-change notification hook for embedding, event log, fault injection, config export/import and a generic packet builder.'
        } }
}
