function Stop-BfdSession {
    <#
    .SYNOPSIS
        Stops a BFD session after sending AdminDown. It stays configured (State 'Stopped') so Resume-BfdSession can
        restart it; use Remove-BfdSession to delete it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Name)
    process {
        foreach ($S in @((Get-BfdRegistry).Bfd.Values | Where-Object { $_.Name -like $Name })) {
            Stop-BfdRunspace $S
            $S.State = 'Stopped'
            $S.RemoteState = $null
            $S.UpSince = $null
        }
        if (-not $Name.Contains('*') -and -not (Get-BfdRegistry).Bfd[$Name]) { Write-Error "No such BFD session '$Name'." }
    }
}
