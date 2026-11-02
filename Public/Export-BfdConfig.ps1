function Export-BfdConfig {
    <#
    .SYNOPSIS
        Saves the current BFD sessions to a JSON file. Authentication keys are left out unless -IncludeAuthKey is given
        (they are then stored in clear text). Notification hooks are not saved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$IncludeAuthKey)
    $sessions = foreach ($S in @((Get-BfdRegistry).Bfd.Values)) {
        $c = $S.Config
        [ordered]@{
            Name = $S.Name; RemoteAddress = $c.RemoteAddress; Port = $c.RemotePort; ListenPort = $c.ListenPort
            LocalAddress = $c.LocalAddress; MultiHop = [bool]$c.MultiHop
            DesiredMinTxMs = $c.DesiredMinTx / 1000; RequiredMinRxMs = $c.RequiredMinRx / 1000; DetectMult = $c.DetectMult
            Passive = [bool]$c.Passive; DemandMode = [bool]$c.DemandMode
            EchoMode = $c.EchoMode; EchoIntervalMs = $c.EchoInterval / 1000; EchoPort = $c.EchoPort; EchoListenPort = $c.EchoListenPort
            AuthType = $c.AuthType; AuthKeyId = $c.AuthKeyId; AuthKey = if ($IncludeAuthKey) { $c.AuthKey } else { $null }
        }
    }
    [ordered]@{ Version = 1; Sessions = @($sessions) } | ConvertTo-Json -Depth 5 | Set-Content -Path $Path
}
