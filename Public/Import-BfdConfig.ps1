function Import-BfdConfig {
    <#
    .SYNOPSIS
        Starts the sessions saved by Export-BfdConfig. Sessions saved without their key need -AuthKey (applied to all of them).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$AuthKey)
    $cfg = Get-Content -Path $Path -Raw | ConvertFrom-Json
    foreach ($s in $cfg.Sessions) {
        $a = @{
            Name = $s.Name; RemoteAddress = $s.RemoteAddress; Port = [int]$s.Port; ListenPort = [int]$s.ListenPort
            DesiredMinTxMs = [uint32]$s.DesiredMinTxMs; RequiredMinRxMs = [uint32]$s.RequiredMinRxMs; DetectMult = [int]$s.DetectMult
            EchoMode = $s.EchoMode; EchoIntervalMs = [uint32]$s.EchoIntervalMs; EchoPort = [int]$s.EchoPort; EchoListenPort = [int]$s.EchoListenPort
        }
        if ($s.LocalAddress) { $a.LocalAddress = [ipaddress]$s.LocalAddress }
        if ($s.MultiHop) { $a.MultiHop = $true }
        if ($s.Passive) { $a.Passive = $true }
        if ($s.DemandMode) { $a.DemandMode = $true }
        if ($s.AuthType -and $s.AuthType -ne 'None') {
            $a.AuthType = $s.AuthType; $a.AuthKeyId = [int]$s.AuthKeyId
            $a.AuthKey = if ($s.AuthKey) { $s.AuthKey } else { $AuthKey }
        }
        Start-BfdSession @a
    }
}
