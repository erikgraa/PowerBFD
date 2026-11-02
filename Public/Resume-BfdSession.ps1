function Resume-BfdSession {
    <#
    .SYNOPSIS
        Restarts a stopped BFD session with its stored settings (fresh discriminator, event log kept).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Name)
    process {
        $S = (Get-BfdRegistry).Bfd[$Name]
        if (-not $S) { Write-Error "No such BFD session '$Name'."; return }
        if ($S.State -ne 'Stopped') { Write-Error "BFD session '$Name' is already running."; return }
        $S.Stop = $false; $S.Ready = $false; $S.LastError = $null
        $S.State = 'Down'
        Start-BfdRunspace -State $S
        Wait-BfdReady $S
        if ($S.LastError) { Write-Error "BFD session '$Name' failed to start: $($S.LastError)"; return }
        Get-BfdSession -Name $Name
    }
}
