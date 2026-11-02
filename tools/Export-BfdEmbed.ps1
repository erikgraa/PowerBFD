<#
.SYNOPSIS
    Copies the self-contained BFD code into another module (PowerBGP, PowerOSPF, ...).
.DESCRIPTION
    Copies Private\Bfd*.ps1 and Public\*-Bfd*.ps1 into <Destination>\Private and <Destination>\Public. The host module
    only has to dot-source every file in its Private and Public folders (as PowerBFD.psm1 does) and export the Bfd
    functions it wants to expose. Nothing else from PowerBFD is needed.
.PARAMETER RegistryKey
    Rewrites the AppDomain key of the session registry so the host's sessions are not shared with a PowerBFD module
    loaded in the same process (default: keep 'PowerBFD.Registry').
#>
param(
    [Parameter(Mandatory)][string]$Destination,
    [string]$RegistryKey,
    [string]$Source = (Join-Path $PSScriptRoot '..')
)

$files = @(Get-ChildItem (Join-Path $Source 'Private') -Filter 'Bfd*.ps1') + @(Get-ChildItem (Join-Path $Source 'Public') -Filter '*-Bfd*.ps1')
foreach ($sub in 'Private', 'Public') { New-Item (Join-Path $Destination $sub) -ItemType Directory -Force | Out-Null }

foreach ($f in $files) {
    $sub = Split-Path (Split-Path $f.FullName -Parent) -Leaf
    $target = Join-Path (Join-Path $Destination $sub) $f.Name
    $text = Get-Content $f.FullName -Raw
    if ($RegistryKey -and $f.Name -eq 'BfdCore.ps1') {
        $text = $text -replace "(\`$script:BfdRegistryKey\s*=\s*)'[^']*'", "`$1'$RegistryKey'"
    }
    Set-Content -Path $target -Value $text -NoNewline -Encoding utf8NoBOM
    $target
}
