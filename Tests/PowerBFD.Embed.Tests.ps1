BeforeDiscovery {
    $script:root = Resolve-Path "$PSScriptRoot\.."
    $script:bfdFiles = @(Get-ChildItem "$script:root\Private\Bfd*.ps1") + @(Get-ChildItem "$script:root\Public\*-Bfd*.ps1")
}

Describe 'embeddable BFD code' {
    It 'does not reference anything outside the BFD files (<Name>)' -ForEach ($script:bfdFiles | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }) {
        $text = Get-Content $Path -Raw
        $text | Should -Not -Match '\b(New-Packet|New-PacketField|Format-Packet|ConvertTo-FieldBytes)\b'
        $text | Should -Not -Match '(?i)\b(Pode|PowerBGP|PowerOSPF|Import-Module\s+PowerBFD)\b'
    }
    It 'has no non-BFD file in the embed set' {
        $script:bfdFiles.Name | Should -Not -Contain 'New-Packet.ps1'
        $script:bfdFiles.Name | Should -Not -Contain 'ConvertTo-FieldBytes.ps1'
    }

    Context 'embedded into a host module' {
        BeforeAll {
            $script:hostDir = Join-Path ([IO.Path]::GetTempPath()) "EmbedHost-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item $script:hostDir -ItemType Directory
            $null = & "$PSScriptRoot\..\tools\Export-BfdEmbed.ps1" -Destination $script:hostDir -RegistryKey 'EmbedHost.Registry'
            Copy-Item "$PSScriptRoot\..\PowerBFD.psm1" "$script:hostDir\EmbedHost.psm1"
            Set-Content "$script:hostDir\EmbedHost.psd1" "@{ RootModule = 'EmbedHost.psm1'; ModuleVersion = '1.0.0'; GUID = '0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f'; PowerShellVersion = '7.4'; FunctionsToExport = @('*') }"
            Import-Module "$script:hostDir\EmbedHost.psd1" -Force
            $script:q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        }
        AfterAll {
            & (Get-Module EmbedHost) { Get-BfdSession | Remove-BfdSession -Confirm:$false }
            Remove-Module EmbedHost -ErrorAction SilentlyContinue
            Remove-Item $script:hostDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'runs sessions and calls the hook from its own copy of the code' {
            $mod = Get-Module EmbedHost
            $mod.ExportedFunctions.Keys | Should -Contain 'Start-BfdSession'
            $hook = { param($e, $ctx) $ctx.Enqueue($e) }
            $a = @{ RemoteAddress = '127.0.70.2'; LocalAddress = [ipaddress]'127.0.70.1'; ListenPort = 16070; Port = 16070; DesiredMinTxMs = 100; RequiredMinRxMs = 100; OnStateChange = $hook; HookContext = $script:q }
            $b = @{ RemoteAddress = '127.0.70.1'; LocalAddress = [ipaddress]'127.0.70.2'; ListenPort = 16070; Port = 16070; DesiredMinTxMs = 100; RequiredMinRxMs = 100 }
            $null = Start-BfdSession -Name embed-a @a
            $null = Start-BfdSession -Name embed-b @b
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline -and (Get-BfdSession embed-a).State -ne 'Up') { Start-Sleep -Milliseconds 100 }
            (Get-BfdSession embed-a).State | Should -Be 'Up'
            $script:q.ToArray().NewState | Should -Contain 'Up'
        }
        It 'keeps its sessions separate from a PowerBFD module in the same process' {
            Import-Module "$PSScriptRoot\..\PowerBFD.psd1" -Force
            (& (Get-Module PowerBFD) { $script:BfdRegistryKey }) | Should -Be 'PowerBFD.Registry'
            (& (Get-Module EmbedHost) { $script:BfdRegistryKey }) | Should -Be 'EmbedHost.Registry'
            @(& (Get-Module PowerBFD) { Get-BfdSession }) | Should -HaveCount 0
        }
    }
}
