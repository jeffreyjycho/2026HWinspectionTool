param([Parameter(Mandatory=$true)][string]$PendingFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BootTrace.ps1')
$traceApp=Split-Path -Parent $PSScriptRoot
Write-BootTrace $traceApp 'DEEP_SCRIPT_ENTERED'
function KstNow { [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9)) }
function SafeName([string]$s){return ([regex]::Replace($s,'[^A-Za-z0-9._-]','_'))}
function Find-TaggedRoot([string]$tag){foreach($d in Get-PSDrive -PSProvider FileSystem){$p=Join-Path $d.Root $tag;if(Test-Path -LiteralPath $p){return $d.Root}};return $null}
if(!(Test-Path -LiteralPath $PendingFile)){throw 'Deep pending file not found.'}
$p=Get-Content -LiteralPath $PendingFile -Raw|ConvertFrom-Json

$dataRoot=Find-TaggedRoot 'COUEYE_DATA.TAG'
$bootRoot=Find-TaggedRoot 'COUEYE_BOOT.TAG'
if(!$dataRoot){throw 'COUEYE_DATA.TAG volume not found during Headless Deep phase.'}
if(!$bootRoot){throw 'COUEYE_BOOT.TAG volume not found during Headless Deep phase.'}
$app=Join-Path $dataRoot 'COU-EYE'
if(!(Test-Path -LiteralPath (Join-Path $app 'Collect.ps1'))){throw 'COU-EYE app root not available.'}

$working=Join-Path $app 'DeepPE\Working'
$cache=Join-Path $app 'DeepPE\Cache'
$results=Join-Path $app 'Results'
$logs=Join-Path $app 'Logs'
New-Item -ItemType Directory -Force -Path $working,$cache,$results,$logs|Out-Null
$stateFile=Join-Path $working 'DEEP_STATE.json'
$resumeFile=Join-Path $working 'DEEP_RESUME.json'
$safeAsset=SafeName ([string]$p.AssetID)
$stamp=(KstNow).ToString('yyyyMMdd_HHmmss')
$log=Join-Path $logs ('DEEP_'+$safeAsset+'_'+$stamp+'.log')
$bootMarker=Join-Path $logs 'DEEP_BOOT_STARTED.log'
$coreStatus=if($p.CoreEvidenceStatusName){Join-Path $results ([string]$p.CoreEvidenceStatusName)}elseif($p.CoreEvidenceStatus -and (Test-Path -LiteralPath $p.CoreEvidenceStatus)){[string]$p.CoreEvidenceStatus}else{''}
$coreResult=if($p.CoreResultCsvName){Join-Path $results ([string]$p.CoreResultCsvName)}else{''}
. (Join-Path $app 'DeepPE\CoreReturn.ps1')
$returnGuard=Join-Path $cache ('CORE_RETURN_'+(Get-FileHash -LiteralPath $PendingFile -Algorithm SHA256).Hash+'.guard')
if(Test-Path -LiteralPath $returnGuard){throw 'This Deep run already requested Core return. Repeated collection/reboot blocked.'}
$coreRestored=$false
$deepStatus='';$merged='';$mergedSummary='';$deepResultCsv='';$deepError=''
function Write-DeepState([string]$state,[hashtable]$extra=@{}){
    $o=[ordered]@{Schema='COU-EYE_DEEP_STATE_V1';Version='1.3.11';RunId=$p.RunId;State=$state;AssetID=$p.AssetID;PlatformIdentitySHA256=$p.PlatformIdentitySHA256;UpdatedAt=(KstNow).ToString('o')}
    foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
    [pscustomobject]$o|ConvertTo-Json -Depth 6|Out-File -LiteralPath $stateFile -Encoding UTF8
}

try{
    ('['+(KstNow).ToString('o')+'] HEADLESS_STARTED AssetID='+$p.AssetID)|Out-File -LiteralPath $bootMarker -Append -Encoding UTF8
    Write-BootTrace $app 'HEADLESS_STARTED'
    Write-DeepState 'HEADLESS_STARTED' @{Log=$log;BootMarker=$bootMarker}
    ('COU-EYE V1.3.11 Headless Deep phase started '+(KstNow).ToString('o'))|Out-File -LiteralPath $log -Encoding UTF8
    ('PendingFile='+$PendingFile)|Out-File -LiteralPath $log -Append -Encoding UTF8
    ('DataRoot='+$dataRoot+' BootRoot='+$bootRoot)|Out-File -LiteralPath $log -Append -Encoding UTF8

    $start=Get-Date
    Write-DeepState 'DEEP_COLLECT_RUNNING' @{Log=$log}
    & (Join-Path $app 'Collect.ps1') -WaybillNumber $p.AssetID -Coucode $p.Coucode -GpuScanMode DeepHeadless *>> $log
    if(-not $?){throw 'Deep collector returned a failure status. See Deep log.'}
    Write-DeepState 'DEEP_COLLECT_FINISHED' @{Log=$log}

    $new=@(Get-ChildItem -LiteralPath $results -Filter '*_EVIDENCE_STATUS.csv' -File | Where-Object {$_.LastWriteTime -ge $start.AddSeconds(-3)} | Sort-Object LastWriteTime -Descending)
    foreach($f in $new){try{$first=@(Import-Csv -LiteralPath $f.FullName|Select-Object -First 1);if($first.Count -and $first[0].AssetID -eq $p.AssetID){$deepStatus=$f.FullName;break}}catch{}}
    if(!$deepStatus){throw 'Deep phase did not produce an EVIDENCE_STATUS file for this AssetID.'}
    if(!$coreStatus -or !(Test-Path -LiteralPath $coreStatus)){throw 'Core EVIDENCE_STATUS could not be resolved on the current data partition.'}

    $merged=Join-Path $results ($safeAsset+'_MERGED_EVIDENCE_STATUS.csv')
    $mergedSummary=[IO.Path]::ChangeExtension($merged,'.summary.json')
    Write-DeepState 'DEEP_MERGE_RUNNING' @{Log=$log;DeepEvidenceStatus=$deepStatus}
    & (Join-Path $app 'DeepPE\Merge_Evidence.ps1') -CoreEvidenceStatus $coreStatus -DeepEvidenceStatus $deepStatus -OutputCsv $merged -OutputSummary $mergedSummary *>> $log
    if(-not $?){throw 'Evidence merge failed.'}
    $deepResultCsv=$deepStatus -replace '_EVIDENCE_STATUS\.csv$','.csv'

    [pscustomobject]@{
        Schema='COU-EYE_DEEP_RESUME_V1';Version='1.3.11';RunId=$p.RunId;State='DEEP_COMPLETE';AssetID=$p.AssetID;Coucode=$p.Coucode;
        PlatformIdentitySHA256=$p.PlatformIdentitySHA256;ResultCsvName=$(if(Test-Path -LiteralPath $deepResultCsv){[IO.Path]::GetFileName($deepResultCsv)}else{''});
        CoreResultCsvName=$(if($coreResult){[IO.Path]::GetFileName($coreResult)}else{''});MergedEvidenceStatusName=[IO.Path]::GetFileName($merged);
        MergedSummaryName=[IO.Path]::GetFileName($mergedSummary);DeepLogName=[IO.Path]::GetFileName($log);CreatedAt=(KstNow).ToString('o')
    }|ConvertTo-Json -Depth 6|Out-File $resumeFile -Encoding UTF8
    Write-DeepState 'DEEP_SCAN_FINISHED' @{DeepEvidenceStatus=$deepStatus;MergedEvidenceStatus=$merged;Log=$log;ResumeFile=$resumeFile}
}catch{
    $deepError=$_.Exception.Message
    $deepError|Out-File -LiteralPath $log -Append -Encoding UTF8
    Write-DeepState 'DEEP_ERROR' @{Error=$deepError;Log=$log}
    [pscustomobject]@{
        Schema='COU-EYE_DEEP_RESUME_V1';Version='1.3.11';RunId=$p.RunId;State='DEEP_ERROR';AssetID=$p.AssetID;Coucode=$p.Coucode;
        PlatformIdentitySHA256=$p.PlatformIdentitySHA256;CoreResultCsvName=$(if($coreResult){[IO.Path]::GetFileName($coreResult)}else{''});
        Error=$deepError;DeepLogName=[IO.Path]::GetFileName($log);CreatedAt=(KstNow).ToString('o')
    }|ConvertTo-Json -Depth 5|Out-File $resumeFile -Encoding UTF8
}finally{
    if($p.AutoRestoreCore -eq $true){
        try{
            Write-DeepState 'CORE_RESTORE_RUNNING' @{Log=$log;DeepEvidenceStatus=$deepStatus;Error=$deepError}
            & (Join-Path $app 'DeepPE\Restore_CorePE.ps1') -PendingFile $PendingFile -Execute *>> $log
            if(-not $?){throw 'Core restore returned a failure status.'}
            $coreRestored=$true
        }catch{('Core restore failed: '+$_.Exception.Message)|Out-File -LiteralPath $log -Append -Encoding UTF8}
    }
}

$finalState=if($deepStatus -and !$deepError){if($coreRestored){'DEEP_COMPLETE'}else{'DEEP_COMPLETE_CORE_RESTORE_FAILED'}}else{if($coreRestored){'DEEP_ERROR'}else{'DEEP_ERROR_CORE_RESTORE_FAILED'}}
Write-DeepState $finalState @{DeepEvidenceStatus=$deepStatus;MergedEvidenceStatus=$merged;Error=$deepError;Log=$log;CoreRestored=$coreRestored;ResumeFile=$resumeFile}

if($coreRestored){
    try{
        $archive=Join-Path $cache ('DEEP_PENDING_DONE_'+$safeAsset+'_'+(KstNow).ToString('yyyyMMdd_HHmmss')+'.json')
        Copy-Item -LiteralPath $PendingFile -Destination $archive -Force
        Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
    }catch{}
}
# The running Headless PE is already RAM-booted from COUEYE_BOOT. The staging copy on DATA can now be reclaimed.
if($p.DeepWim){
    try{
        $dw=[string]$p.DeepWim
        if(Test-Path -LiteralPath $dw){Remove-Item -LiteralPath $dw -Force -ErrorAction Stop;('Removed DeepPE staging WIM: '+$dw)|Out-File -LiteralPath $log -Append -Encoding UTF8}
    }catch{('Staging WIM cleanup deferred: '+$_.Exception.Message)|Out-File -LiteralPath $log -Append -Encoding UTF8}
}
if($deepStatus){
    Write-Host 'COU-EYE Deep phase complete.'
    Write-Host ('Merged evidence: '+$merged)
}else{
    Write-Host ('COU-EYE Deep phase ended with error: '+$deepError)
}
Write-Host ('Core boot.wim restored: '+$coreRestored)

try{
 if(!(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')){throw 'Automatic Core return is permitted only inside WinPE.'}
 Write-DeepState 'CORE_RETURN_PENDING' @{CoreRestored=$coreRestored;ResumeFile=$resumeFile;Log=$log}
 Request-CoreReturn $resumeFile $returnGuard $coreRestored {
  Write-DeepState 'CORE_RETURN_REQUESTED' @{CoreRestored=$true;ResumeFile=$resumeFile;Log=$log}
  Write-BootTrace $app 'CORE_RETURN_REBOOT_COMMAND_REQUESTED'
  & (Join-Path $env:SystemRoot 'System32\wpeutil.exe') reboot
  if($LASTEXITCODE -ne 0){throw ('Core return reboot failed: '+$LASTEXITCODE)}
 }
}catch{
 ('Core return blocked/failed: '+$_.Exception.Message)|Add-Content -LiteralPath $log -Encoding UTF8
 Write-DeepState 'CORE_RETURN_BLOCKED' @{CoreRestored=$coreRestored;Error=$_.Exception.Message;ResumeFile=$resumeFile;Log=$log}
}
# Never retry reboot or open the final GUI in the GPU-loaded Deep session.
while($true){cmd.exe;Start-Sleep -Seconds 1}