param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'COU-EYE\Tools'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw '.NET Framework x64 C# compiler was not found.' }
& $csc /nologo /target:library /platform:x64 /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "/out:$tools\DarkControls.dll" "$tools\DarkControls.cs"
if ($LASTEXITCODE -ne 0) { throw 'DarkControls build failed.' }
& $csc /nologo /target:library /platform:x64 "/out:$tools\SpdEngine.dll" "$tools\SpdEngine.cs"
if ($LASTEXITCODE -ne 0) { throw 'SpdEngine build failed.' }
& $csc /nologo /target:exe /platform:x64 "/out:$tools\NvmlProbe.exe" "$tools\NvmlProbe.cs"
if ($LASTEXITCODE -ne 0) { throw 'NvmlProbe build failed.' }
Write-Output 'Built DarkControls.dll, SpdEngine.dll and NvmlProbe.exe. No hardware probes were executed.'
