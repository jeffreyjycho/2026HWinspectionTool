param([Parameter(Mandatory=$true)][string]$PendingFile)
$ErrorActionPreference='Stop'
$app=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'BootTrace.ps1')
Write-BootTrace $app 'BOOT_POWERSHELL_ENTERED' $PendingFile
try {
 $record=Get-Content -LiteralPath $PendingFile -Raw|ConvertFrom-Json
 if(!$record.RunId){throw 'Pending RunId missing'}
 Write-BootTrace $app 'PENDING_PARSED' ('AssetID='+$record.AssetID)
 Write-BootTrace $app 'DEEP_WORKER_INVOKING'
 & (Join-Path $PSScriptRoot 'Run_Deep_Phase.ps1') -PendingFile $PendingFile
 Write-BootTrace $app 'DEEP_WORKER_RETURNED'
}catch{
 Write-BootTrace $app 'DEEP_WORKER_EXCEPTION' ($_|Out-String)
 Write-Error $_ -ErrorAction Continue
 exit 1
}
