param([Parameter(Mandatory=$true)][string]$PendingFile,[switch]$Execute)
$ErrorActionPreference='Stop'
function Find-TaggedRoot([string]$tag){foreach($d in Get-PSDrive -PSProvider FileSystem){$p=Join-Path $d.Root $tag;if(Test-Path -LiteralPath $p){return $d.Root}};return $null}
if(!(Test-Path -LiteralPath $PendingFile)){throw 'PendingFile not found.'}
$p=Get-Content -LiteralPath $PendingFile -Raw|ConvertFrom-Json
$dataRoot=Find-TaggedRoot 'COUEYE_DATA.TAG'
$bootRoot=Find-TaggedRoot 'COUEYE_BOOT.TAG'
if(!$dataRoot){throw 'COUEYE_DATA.TAG volume not found during Core restore.'}
if(!$bootRoot){throw 'COUEYE_BOOT.TAG volume not found during Core restore.'}
$app=Join-Path $dataRoot 'COU-EYE'
$source=Join-Path $app 'DeepPE\Golden\core.boot.wim'
$target=Join-Path $bootRoot 'sources\boot.wim'
if(!(Test-Path -LiteralPath $source) -and $p.CoreBootBackup -and (Test-Path -LiteralPath $p.CoreBootBackup)){$source=[string]$p.CoreBootBackup}
if(!(Test-Path -LiteralPath $source)){throw 'Core boot.wim backup not found.'}
Write-Host ('Restore source: '+$source)
Write-Host ('Restore target: '+$target)
if(!$Execute){Write-Host 'DRY RUN ONLY. Re-run with -Execute.';exit 0}
Copy-Item -LiteralPath $source -Destination $target -Force
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash){throw 'Restored Core boot image hash mismatch.'}
Write-Host 'Core PE boot.wim restored.'
