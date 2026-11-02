function Get-BfdEvent {
    <#
    .SYNOPSIS
        Returns recent events (ring buffer of 500 per session), oldest first: Control packets sent/received (parsed into
        Message), StateChange, Drop (with the reason a packet was rejected), Echo, Fault and HookError.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = '*',
        [ValidateSet('Control', 'StateChange', 'Drop', 'Echo', 'Fault', 'HookError')][string[]]$Type,
        [int]$Last = 50
    )
    $events = foreach ($S in @((Get-BfdRegistry).Bfd.Values)) {
        if ($S.Name -like $Name) { $S.Events.ToArray() }
    }
    if ($Type) { $events = $events | Where-Object { $_.Type -in $Type } }
    foreach ($e in @($events | Sort-Object Time | Select-Object -Last $Last)) {
        $msg = $null
        if ($e.Bytes -and $e.Bytes.Length -ge 24) { try { $msg = ConvertFrom-BfdControl $e.Bytes } catch { } }
        $e | Add-Member -NotePropertyName Message -NotePropertyValue $msg -PassThru -Force
    }
}
