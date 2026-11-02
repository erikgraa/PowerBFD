# Session registry, runspace plumbing and event log. The registry lives in AppDomain data so every runspace shares it.

function Get-BfdRegistry {
    $r = [AppDomain]::CurrentDomain.GetData($script:BfdRegistryKey)
    if (-not $r) {
        $r = [hashtable]::Synchronized(@{ Bfd = [hashtable]::Synchronized(@{}) })
        [AppDomain]::CurrentDomain.SetData($script:BfdRegistryKey, $r)
    }
    $r
}

function Start-BfdRunspace {
    # Runs Invoke-BfdSessionLoop in its own runspace. The runspace imports the module this code lives in, so the
    # same code works unchanged when embedded in another module.
    param([Parameter(Mandatory)]$State)
    $mod = $ExecutionContext.SessionState.Module
    $manifest = Join-Path $mod.ModuleBase ($mod.Name + '.psd1')
    if (-not (Test-Path $manifest)) { $manifest = $mod.Path }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
            param($manifest, $state)
            $mod = Import-Module $manifest -PassThru
            & $mod { param($s) Invoke-BfdSessionLoop $s } $state
        }).AddArgument($manifest).AddArgument($State)
    $State.PowerShell = $ps
    $State.Handle = $ps.BeginInvoke()
}

function Stop-BfdRunspace {
    param($State, [int]$TimeoutSeconds = 5)
    $State.Stop = $true
    if ($State.Handle) { $null = $State.Handle.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000) }
    if ($State.PowerShell) {
        try { $State.PowerShell.Runspace.Dispose(); $State.PowerShell.Dispose() } catch { }
    }
    $State.PowerShell = $null; $State.Handle = $null
}

function Assert-BfdAuth {
    param([string]$AuthType, [string]$AuthKey)
    if (-not $AuthType -or $AuthType -eq 'None') { return }
    if (-not $AuthKey) { throw "-AuthKey is required with -AuthType $AuthType." }
    $max = $script:BfdAuthTypes[$AuthType].MaxKey
    if ([Text.Encoding]::UTF8.GetByteCount($AuthKey) -gt $max) { throw "-AuthKey can be at most $max bytes for $AuthType." }
}

function Wait-BfdReady {
    param($State, [int]$TimeoutSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $State.Ready -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
}

function Add-BfdEvent {
    param($State, [string]$Type, [string]$Summary, [string]$Direction, [byte[]]$Bytes, $Data)
    $State.Events.Enqueue([pscustomobject]@{
            PSTypeName = 'PowerBFD.BfdEvent'
            Time       = Get-Date
            Session    = $State.Name
            Type       = $Type
            Direction  = $Direction
            Summary    = $Summary
            Data       = $Data
            Bytes      = $Bytes
        })
    $dummy = $null
    while ($State.Events.Count -gt 500) { $null = $State.Events.TryDequeue([ref]$dummy) }
}

function Publish-BfdChange {
    # Drains state changes from the engine context: updates the session, logs events and calls the notification hook.
    param($S, $Ctx, $Hook)
    foreach ($ch in @($Ctx.Changes)) {
        $S.State = $ch.NewState
        $S.Diagnostic = $ch.Diagnostic
        $S.LastStateChange = $ch.Time
        $S.UpSince = if ($ch.NewState -eq 'Up') { $ch.Time } else { $null }
        $S.History.Enqueue(('{0:HH:mm:ss.fff} {1} -> {2}' -f $ch.Time, $ch.OldState, $ch.NewState))
        $dummy = $null
        while ($S.History.Count -gt 100) { $null = $S.History.TryDequeue([ref]$dummy) }

        $evt = [pscustomobject]@{
            PSTypeName          = 'PowerBFD.StateChange'
            Time                = $ch.Time
            Session             = $S.Name
            Remote              = $S.Config.RemoteAddress
            OldState            = $ch.OldState
            NewState            = $ch.NewState
            Diagnostic          = [int]$ch.Diagnostic
            DiagnosticName      = $script:BfdDiags[[int]$ch.Diagnostic]
            LocalDiscriminator  = $Ctx.MyDisc
            RemoteDiscriminator = $Ctx.YourDisc
            IsUp                = $ch.NewState -eq 'Up'
        }
        $note = '{0} -> {1} ({2})' -f $ch.OldState, $ch.NewState, $evt.DiagnosticName
        Add-BfdEvent -State $S -Type 'StateChange' -Summary $note -Data $evt
        if ($Hook) {
            try { & $Hook $evt $S.Config.HookContext }
            catch { Add-BfdEvent -State $S -Type 'HookError' -Summary $_.Exception.Message }
        }
    }
    $Ctx.Changes.Clear()
}
