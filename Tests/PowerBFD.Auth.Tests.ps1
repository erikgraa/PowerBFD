BeforeAll { Import-Module "$PSScriptRoot\..\PowerBFD.psd1" -Force }

Describe 'BFD authentication sections (RFC 5880 4.2-4.4)' {
    It '<Type> has the right wire layout' -ForEach @(
        @{ Type = 'SimplePassword'; Code = 1; Len = 24 + 3 + 6 }
        @{ Type = 'KeyedMD5'; Code = 2; Len = 24 + 24 }
        @{ Type = 'MeticulousKeyedMD5'; Code = 3; Len = 24 + 24 }
        @{ Type = 'KeyedSHA1'; Code = 4; Len = 24 + 28 }
        @{ Type = 'MeticulousKeyedSHA1'; Code = 5; Len = 24 + 28 }
    ) {
        $p = New-BfdControl -AuthType $Type -AuthKey 'secret' -AuthKeyId 7 -AuthSequence 0x01020304
        $p.Length | Should -Be $Len
        $p[3] | Should -Be $Len
        ($p[1] -band 0x04) | Should -Be 4
        $p[24] | Should -Be $Code
        $p[26] | Should -Be 7
        if ($Type -ne 'SimplePassword') {
            $p[25] | Should -Be ($Len - 24)
            $p[28..31] | Should -Be @(1, 2, 3, 4)
            ([Text.Encoding]::UTF8.GetString($p, 32, 6)) | Should -Not -Be 'secret'
        }
        else { [Text.Encoding]::UTF8.GetString($p, 27, 6) | Should -Be 'secret' }
    }
    It 'verifies <Type> with the right key only' -ForEach @(
        @{ Type = 'SimplePassword' }, @{ Type = 'KeyedMD5' }, @{ Type = 'MeticulousKeyedMD5' }
        @{ Type = 'KeyedSHA1' }, @{ Type = 'MeticulousKeyedSHA1' }
    ) {
        $p = New-BfdControl -State Up -AuthType $Type -AuthKey 'secret' -AuthKeyId 3 -AuthSequence 99
        $c = ConvertFrom-BfdControl $p -AuthKey 'secret'
        $c.Auth.Type | Should -Be $Type
        $c.Auth.KeyId | Should -Be 3
        $c.Auth.Valid | Should -BeTrue
        (ConvertFrom-BfdControl $p -AuthKey 'other').Auth.Valid | Should -BeFalse
        (ConvertFrom-BfdControl $p).Auth.Valid | Should -BeNullOrEmpty
        if ($Type -ne 'SimplePassword') { $c.Auth.Sequence | Should -Be 99 }
    }
    It 'detects a tampered packet' {
        $p = New-BfdControl -State Up -AuthType KeyedSHA1 -AuthKey secret
        $p[4] = 0xFF
        (ConvertFrom-BfdControl $p -AuthKey secret).Auth.Valid | Should -BeFalse
    }
    It 'rejects keys that are too long or missing' {
        { New-BfdControl -AuthType SimplePassword -AuthKey ('x' * 17) } | Should -Throw '*at most 16*'
        { New-BfdControl -AuthType KeyedMD5 -AuthKey ('x' * 17) } | Should -Throw '*at most 16*'
        { New-BfdControl -AuthType KeyedSHA1 -AuthKey ('x' * 21) } | Should -Throw '*at most 20*'
        { New-BfdControl -AuthType KeyedSHA1 } | Should -Throw '*AuthKey is required*'
    }
    It 'matches a known MD5 digest' {
        # key padded with zeros to 16 bytes sits in the digest field while hashing (RFC 5880 6.7.3)
        $p = New-BfdControl -State Up -AuthType KeyedMD5 -AuthKey 'pw' -AuthKeyId 1 -AuthSequence 1
        $tmp = $p.Clone(); [Array]::Clear($tmp, 32, 16); [Array]::Copy([Text.Encoding]::UTF8.GetBytes('pw'), 0, $tmp, 32, 2)
        $expected = [Security.Cryptography.MD5]::HashData($tmp)
        $p[32..47] | Should -Be $expected
    }
}

Describe 'BFD authentication sequence check' {
    It 'follows RFC 5880 6.7.3 and 6.7.4' {
        InModuleScope PowerBFD {
            Test-BfdAuthSequence -Sequence 5 -Last 0 -Known $false -Meticulous $true -DetectMult 3 | Should -BeTrue
            Test-BfdAuthSequence -Sequence 10 -Last 10 -Known $true -Meticulous $false -DetectMult 3 | Should -BeTrue
            Test-BfdAuthSequence -Sequence 10 -Last 10 -Known $true -Meticulous $true -DetectMult 3 | Should -BeFalse
            Test-BfdAuthSequence -Sequence 19 -Last 10 -Known $true -Meticulous $true -DetectMult 3 | Should -BeTrue
            Test-BfdAuthSequence -Sequence 20 -Last 10 -Known $true -Meticulous $true -DetectMult 3 | Should -BeFalse
            Test-BfdAuthSequence -Sequence 9 -Last 10 -Known $true -Meticulous $false -DetectMult 3 | Should -BeFalse
            Test-BfdAuthSequence -Sequence 2 -Last 4294967294 -Known $true -Meticulous $true -DetectMult 3 | Should -BeTrue
        }
    }
}
