BeforeAll { $script:root = (Resolve-Path "$PSScriptRoot\..").Path }

Describe 'module manifest' {
    It 'is valid and exports exactly the public functions' {
        $m = Test-ModuleManifest "$script:root\PowerBFD.psd1"
        $m.Version.ToString() | Should -Match '^\d+\.\d+\.\d+$'
        $exports = (Import-PowerShellDataFile "$script:root\PowerBFD.psd1").FunctionsToExport
        $public = (Get-ChildItem "$script:root\Public\*.ps1").BaseName
        $exports | Sort-Object | Should -Be ($public | Sort-Object)
    }
    It 'exports the documented cmdlets after import' {
        Import-Module "$script:root\PowerBFD.psd1" -Force
        $names = 'Start-BfdSession', 'Get-BfdSession', 'Set-BfdSession', 'Stop-BfdSession', 'Resume-BfdSession', 'Remove-BfdSession',
        'New-BfdControl', 'ConvertFrom-BfdControl', 'Get-BfdEvent', 'Export-BfdConfig', 'New-Packet', 'New-PacketField', 'Format-Packet'
        foreach ($n in $names) { Get-Command $n -Module PowerBFD | Should -Not -BeNullOrEmpty }
        (Get-Module PowerBFD).ExportedFunctions.Keys | Should -Not -Contain 'Invoke-BfdSessionLoop'
    }
    It 'has a CHANGELOG entry for the manifest version' {
        $v = (Import-PowerShellDataFile "$script:root\PowerBFD.psd1").ModuleVersion
        Get-Content "$script:root\CHANGELOG.md" -Raw | Should -Match "(?m)^## \[?$([regex]::Escape($v))\]?"
    }
}
