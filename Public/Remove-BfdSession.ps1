function Remove-BfdSession {
    <#
    .SYNOPSIS
        Stops and deletes a BFD session, including its event log.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Name)
    process {
        $reg = Get-BfdRegistry
        $S = $reg.Bfd[$Name]
        if (-not $S) { Write-Error "No such BFD session '$Name'."; return }
        if ($PSCmdlet.ShouldProcess($Name, 'Remove BFD session')) {
            Stop-BfdRunspace $S
            $reg.Bfd.Remove($Name)
        }
    }
}
