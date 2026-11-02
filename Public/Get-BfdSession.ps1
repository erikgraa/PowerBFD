function Get-BfdSession {
    <#
    .SYNOPSIS
        Lists BFD sessions with their live state and counters.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipelineByPropertyName)][string]$Name = '*')
    process {
        foreach ($S in @((Get-BfdRegistry).Bfd.Values)) {
            if ($S.Name -notlike $Name) { continue }
            $c = $S.Config
            [pscustomobject]@{
                PSTypeName          = 'PowerBFD.BfdSession'
                Name                = $S.Name
                State               = $S.State
                RemoteState         = $S.RemoteState
                Diagnostic          = [int]$S.Diagnostic
                DiagnosticName      = $script:BfdDiags[[int]$S.Diagnostic]
                Remote              = '{0}:{1}' -f $c.RemoteAddress, $c.RemotePort
                LocalAddress        = $c.LocalAddress
                MultiHop            = [bool]$c.MultiHop
                Mode                = if ($c.DemandMode) { 'Demand' } else { 'Asynchronous' }
                EchoMode            = $c.EchoMode
                EchoActive          = [bool]$S.EchoActive
                DemandActive        = [bool]$S.DemandActive
                Passive             = [bool]$c.Passive
                TxMs                = $c.DesiredMinTx / 1000
                RxMs                = $c.RequiredMinRx / 1000
                DetectMult          = $c.DetectMult
                DetectionTimeMs     = $S.DetectionTimeMs
                TxIntervalMs        = $S.TxIntervalMs
                PollPending         = [bool]$S.PollPending
                AuthType            = if ($c.AuthType) { $c.AuthType } else { 'None' }
                AuthFailures        = [int]$S.AuthFailures
                Sent                = $S.Sent
                Received            = $S.Received
                Dropped             = [int]$S.Dropped
                EchoSent            = $S.EchoSent
                EchoReceived        = $S.EchoReceived
                EchoReflected       = $S.EchoReflected
                LocalDiscriminator  = $S.LocalDiscriminator
                RemoteDiscriminator = $S.RemoteDiscriminator
                Suppressed          = [bool]$S.Suppress
                AdminDown           = [bool]$S.AdminDown
                Faults              = if ($S.Fault.Count) { $S.Fault.Clone() } else { $null }
                UpSince             = $S.UpSince
                LastStateChange     = $S.LastStateChange
                LastError           = $S.LastError
                History             = $S.History.ToArray()
            }
        }
    }
}
