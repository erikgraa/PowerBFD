param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$OutDir)

Add-Type -AssemblyName System.IO.Compression
$m = Import-PowerShellDataFile (Join-Path $Source 'PowerBFD.psd1')
$ps = $m.PrivateData.PSData
$esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
$tags = @('PSModule', 'PSEdition_Core', 'PSIncludes_Function') + $ps.Tags + ($m.FunctionsToExport | ForEach-Object { "PSFunction_$_" })

$nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2011/10/nuspec.xsd">
  <metadata>
    <id>PowerBFD</id>
    <version>$($m.ModuleVersion)</version>
    <authors>$(& $esc $m.Author)</authors>
    <owners>$(& $esc $m.Author)</owners>
    <description>$(& $esc $m.Description)</description>
    <releaseNotes>$(& $esc $ps.ReleaseNotes)</releaseNotes>
    <copyright>$(& $esc $m.Copyright)</copyright>
    <tags>$(& $esc ($tags -join ' '))</tags>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <projectUrl>$(& $esc $ps.ProjectUri)</projectUrl>
    <licenseUrl>$(& $esc $ps.LicenseUri)</licenseUrl>
  </metadata>
</package>
"@

New-Item $OutDir -ItemType Directory -Force | Out-Null
$out = Join-Path $OutDir "PowerBFD.$($m.ModuleVersion).nupkg"
Remove-Item $out -ErrorAction SilentlyContinue
$fs = [IO.File]::Create($out)
$zip = [IO.Compression.ZipArchive]::new($fs, 'Create')
$addText = { param($name, $text)
    $e = $zip.CreateEntry($name)
    $w = [IO.StreamWriter]::new($e.Open(), [Text.UTF8Encoding]::new($false)); $w.Write($text); $w.Dispose()
}
& $addText 'PowerBFD.nuspec' $nuspec
& $addText '[Content_Types].xml' '<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" /><Default Extension="psmdcp" ContentType="application/vnd.openxmlformats-package.core-properties+xml" /><Default Extension="nuspec" ContentType="application/octet" /><Default Extension="psd1" ContentType="application/octet" /><Default Extension="psm1" ContentType="application/octet" /><Default Extension="ps1" ContentType="application/octet" /><Default Extension="md" ContentType="application/octet" /><Default Extension="" ContentType="application/octet" /></Types>'
$id = [guid]::NewGuid().ToString('N')
& $addText '_rels/.rels' "<?xml version=`"1.0`" encoding=`"utf-8`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Type=`"http://schemas.microsoft.com/packaging/2010/07/manifest`" Target=`"/PowerBFD.nuspec`" Id=`"R1`" /><Relationship Type=`"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties`" Target=`"/package/services/metadata/core-properties/$id.psmdcp`" Id=`"R2`" /></Relationships>"
& $addText "package/services/metadata/core-properties/$id.psmdcp" "<?xml version=`"1.0`" encoding=`"utf-8`"?><coreProperties xmlns=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`"><dc:creator xmlns:dc=`"http://purl.org/dc/elements/1.1/`">$(& $esc $m.Author)</dc:creator><dc:description xmlns:dc=`"http://purl.org/dc/elements/1.1/`">$(& $esc $m.Description)</dc:description><dc:identifier xmlns:dc=`"http://purl.org/dc/elements/1.1/`">PowerBFD</dc:identifier><version xmlns=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`">$($m.ModuleVersion)</version></coreProperties>"

$root = (Resolve-Path $Source).Path.TrimEnd('\', '/')
$outRoot = (Resolve-Path $OutDir).Path
foreach ($f in Get-ChildItem $root -Recurse -File | Where-Object { -not $_.FullName.StartsWith($outRoot) }) {
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    $e = $zip.CreateEntry($rel)
    $s = $e.Open(); $b = [IO.File]::ReadAllBytes($f.FullName); $s.Write($b, 0, $b.Length); $s.Dispose()
}
$zip.Dispose(); $fs.Dispose()
$out
