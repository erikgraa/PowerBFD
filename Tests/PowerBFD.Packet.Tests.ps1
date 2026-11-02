BeforeAll { Import-Module "$PSScriptRoot\..\PowerBFD.psd1" -Force }

Describe 'New-BfdControl / ConvertFrom-BfdControl' {
    It 'builds the RFC 5880 24-byte header' {
        $p = New-BfdControl -State Up -DetectMult 3 -MyDiscriminator 0x11223344 -YourDiscriminator 0x55667788 -DesiredMinTx 300000 -RequiredMinRx 400000 -RequiredMinEchoRx 50000
        $p.Length | Should -Be 24
        ($p | ForEach-Object { '{0:X2}' -f $_ }) -join '' | Should -Be '20C0031811223344556677880004 93E000061A800000C350'.Replace(' ', '')
    }
    It 'round-trips every field' {
        $p = New-BfdControl -State Init -Diagnostic 7 -DetectMult 5 -MyDiscriminator 5 -YourDiscriminator 6 -DesiredMinTx 7 -RequiredMinRx 8 -RequiredMinEchoRx 9 -Poll -Demand -ControlPlaneIndependent
        $c = ConvertFrom-BfdControl $p
        $c.Version | Should -Be 1
        $c.State | Should -Be 'Init'
        $c.Diagnostic | Should -Be 7
        $c.DiagnosticName | Should -Be 'Administratively Down'
        $c.DetectMult | Should -Be 5
        $c.Length | Should -Be 24
        $c.MyDiscriminator | Should -Be 5
        $c.YourDiscriminator | Should -Be 6
        $c.DesiredMinTx | Should -Be 7
        $c.RequiredMinRx | Should -Be 8
        $c.RequiredMinEchoRx | Should -Be 9
        $c.Poll | Should -BeTrue
        $c.Final | Should -BeFalse
        $c.Demand | Should -BeTrue
        $c.ControlPlaneIndependent | Should -BeTrue
        $c.Multipoint | Should -BeFalse
        $c.Auth | Should -BeNullOrEmpty
    }
    It 'handles discriminators above 2^31' {
        $c = ConvertFrom-BfdControl (New-BfdControl -MyDiscriminator 4294967295 -YourDiscriminator 2147483648)
        $c.MyDiscriminator | Should -Be 4294967295
        $c.YourDiscriminator | Should -Be 2147483648
    }
    It 'knows all diagnostic codes' {
        0..8 | ForEach-Object { (ConvertFrom-BfdControl (New-BfdControl -Diagnostic $_)).DiagnosticName | Should -Not -BeNullOrEmpty }
    }
    It 'supports invalid packets for fault injection' {
        (ConvertFrom-BfdControl (New-BfdControl -Version 2)).Version | Should -Be 2
        (ConvertFrom-BfdControl (New-BfdControl -DetectMult 0)).DetectMult | Should -Be 0
        (ConvertFrom-BfdControl (New-BfdControl -Length 99)).Length | Should -Be 99
        (ConvertFrom-BfdControl (New-BfdControl -Multipoint)).Multipoint | Should -BeTrue
    }
    It 'rejects a datagram shorter than 24 bytes' {
        { ConvertFrom-BfdControl ([byte[]]::new(10)) } | Should -Throw '*at least 24*'
    }
    It 'accepts pipeline input' {
        (New-BfdControl -State Up | ConvertFrom-BfdControl).State | Should -Be 'Up'
    }
}

Describe 'generic packet helpers' {
    It 'builds a packet from fields and fills the length field' {
        $p = New-Packet -LengthField Len -Field @(
            New-PacketField Type 1 -Bytes 1
            New-PacketField Len 0 -Bytes 2
            New-PacketField Body 'DE:AD:BE:EF'
        )
        ($p | ForEach-Object { '{0:X2}' -f $_ }) -join '' | Should -Be '010007DEADBEEF'
    }
    It 'rejects a value that does not fit' {
        { New-Packet -Field @(New-PacketField X 300 -Bytes 1) } | Should -Throw '*does not fit*'
    }
    It 'encodes an IP address and a hex dump' {
        $p = New-Packet -Field @(New-PacketField Addr ([ipaddress]'10.1.2.3'))
        $p | Should -Be @(10, 1, 2, 3)
        (Format-Packet $p) | Should -Match '^0000  0A 01 02 03'
    }
}
