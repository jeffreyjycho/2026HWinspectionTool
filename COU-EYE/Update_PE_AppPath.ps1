$ErrorActionPreference='Stop'
try{
 $drive=[IO.Path]::GetPathRoot($PSScriptRoot)
 $config=Join-Path $drive 'SSTR\COUEYE\AppPath.txt'
 if(-not(Test-Path -LiteralPath $config)){throw 'PE autostart config not found on this drive. Copy this entire program folder onto the PE USB first.'}
 $relative=$PSScriptRoot.Substring($drive.Length)
 if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'COU_EYE_UI.ps1'))){throw 'UI missing'}
 $backup=$config+'.'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.bak'
 Copy-Item -LiteralPath $config -Destination $backup
 [IO.File]::WriteAllText($config,$relative,[Text.Encoding]::UTF8)
 Write-Host ('Updated PE autostart app: '+$relative)
 Write-Host ('Backup: '+$backup)
}catch{Write-Host $_.Exception.Message;exit 1}
