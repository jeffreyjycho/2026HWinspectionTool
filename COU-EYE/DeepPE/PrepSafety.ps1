# Shared, side-effect-free helpers; compatible with Windows PowerShell 5.1.
function Test-DeepStateOwner($state,[string]$runId){
    return ($state -and (!$runId -or ($state.RunId -eq $runId -and $state.Phase -eq 'DeepPrep')))
}
function Test-DeepWorkerAlive($worker){
    if(!$worker){return $false}
    try{return -not $worker.HasExited}catch{return $true}
}
function Test-DeepPreparationBusy([string]$root){
    $path=Join-Path $root 'DeepPE\Working\DEEP_PREP.lock'
    if(!(Test-Path -LiteralPath $path)){return $false}
    try{$handle=[IO.File]::Open($path,'Open','ReadWrite','None');$handle.Dispose();return $false}catch{return $true}
}
function Write-DeepProgressFile([string]$path,$value){
    $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{$value|Export-Clixml -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $path -Force}
    finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function Test-DeepChildPath([string]$path,[string]$parent){
    if(!$path -or !$parent){return $false}
    $p=[IO.Path]::GetFullPath($path).TrimEnd('\')
    $r=[IO.Path]::GetFullPath($parent).TrimEnd('\')+'\'
    return $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)
}
function ConvertFrom-DeepMountInfo([string]$raw){
    $entries=@();$current=$null
    foreach($line in ($raw -split "`r?`n")){
        if($line -match '^\s*Mount Dir\s*:\s*(.+?)\s*$'){
            if($current){$entries += [pscustomobject]$current}
            $current=@{MountDir=$matches[1].Trim();ImageFile='';Status=''}
        }elseif($line -match '^\s*(?:Mounted Image File|Image File)\s*:\s*(.+?)\s*$'){
            if(!$current){throw 'Unexpected DISM image record order.'};$current.ImageFile=$matches[1].Trim()
        }elseif($line -match '^\s*(?:Mount Status|Status)\s*:\s*(.+?)\s*$'){
            if(!$current){throw 'Unexpected DISM status record order.'};$current.Status=$matches[1].Trim()
        }
    }
    if($current){$entries += [pscustomobject]$current}
    if(!$entries.Count -and $raw -notmatch '(?im)^\s*No mounted images found\.?\s*$'){throw 'Cannot establish DISM mount inventory; raw output retained. No cleanup performed.'}
    foreach($entry in $entries){if(!$entry.ImageFile -or !$entry.Status){throw 'Incomplete DISM mount inventory; no cleanup performed.'}}
    return $entries
}
function Publish-DeepStage([string]$stage){
    if(Get-Command Update-DeepProgress -ErrorAction SilentlyContinue){Update-DeepProgress $stage}
}
function Invoke-DeepNative([string]$exe,[string[]]$arguments,[string]$stage,[int]$WarningSeconds=900){
    [void][IO.Directory]::CreateDirectory($script:DeepLogDirectory)
    $id=[guid]::NewGuid().ToString('N');$base=Join-Path $script:DeepLogDirectory $id
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$exe;$info.Arguments=($arguments|ForEach-Object{'"'+$_.Replace('"','')+'"'}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$info
    $started=[DateTime]::UtcNow
    [pscustomobject]@{Command=$exe;Arguments=$arguments;StartedUtc=$started.ToString('o');Stage=$stage}|ConvertTo-Json -Depth 4|Set-Content ($base+'.command.json') -Encoding UTF8
    try{
        if(!$p.Start()){throw 'Could not start native process.'}
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        while(!$p.WaitForExit(1000)){
            $elapsed=[int]([DateTime]::UtcNow-$started).TotalSeconds
            $label=$stage+' · '+$elapsed+'초'
            if($elapsed -ge $WarningSeconds){$label+=' · 예상 시간을 초과했습니다. 작업 감시 중 (재부팅 금지)'}
            # A progress-file failure must never abandon a live servicing process.
            try{Publish-DeepStage $label}catch{Write-Warning ('Progress update failed: '+$_.Exception.Message)}
        }
        $p.WaitForExit();$out=$stdout.Result;$err=$stderr.Result;$code=$p.ExitCode
        $out|Set-Content ($base+'.stdout.txt') -Encoding UTF8
        $err|Set-Content ($base+'.stderr.txt') -Encoding UTF8
        [pscustomobject]@{PID=$p.Id;ExitCode=$code;FinishedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content ($base+'.result.json') -Encoding UTF8
        if($code -ne 0){throw ($stage+' failed (exit='+$code+'). Logs: '+$base+"`n"+$out+"`n"+$err)}
        return $out
    }finally{$p.Dispose()}
}
function Invoke-DeepDism([string[]]$arguments,[string]$stage){
    $log=Join-Path $script:DeepLogDirectory ('dism_'+[guid]::NewGuid().ToString('N')+'.log')
    Invoke-DeepNative 'dism.exe' (@('/English',('/LogPath:'+$log))+$arguments) $stage
}
function Get-DeepMountInventory {
    $raw=Invoke-DeepDism @('/Get-MountedImageInfo') '마운트 상태 확인'
    return @(ConvertFrom-DeepMountInfo $raw)
}
function Get-DeepWorkspaceVolume([string]$path){
    $image=Get-DiskImage -ImagePath $path -ErrorAction Stop
    if(!$image.Attached){return $null}
    $volumes=@($image|Get-Disk -ErrorAction Stop|Get-Partition -ErrorAction Stop|Where-Object{$_.Type -ne 'Reserved'}|Get-Volume -ErrorAction Stop|Where-Object{$_.FileSystemLabel -eq 'COUEYE_WORK' -and $_.FileSystem -eq 'NTFS'})
    if($volumes.Count -ne 1){throw 'Workspace VHDX volume identity is ambiguous or not NTFS.'}
    return $volumes[0]
}
function Reset-DeepMountWorkspace([string]$volumeRoot,[string]$working,[string]$scratch){
    if(@(Get-Process -Name dism -ErrorAction SilentlyContinue).Count){throw 'Another DISM process is active. Recovery deferred.'}
    $registered=@(Get-DeepMountInventory)
    foreach($entry in $registered){
        if(Test-DeepChildPath $entry.MountDir $volumeRoot){
            if(!(Test-DeepChildPath $entry.ImageFile $working)){throw 'Workspace contains a mount not owned by this application. No cleanup performed.'}
            Invoke-DeepDism @('/Unmount-Image',('/MountDir:'+$entry.MountDir),'/Discard',('/ScratchDir:'+$scratch)) '기존 마운트 해제'|Out-Null
        }
    }
    $remaining=@(Get-DeepMountInventory|Where-Object{Test-DeepChildPath $_.MountDir $volumeRoot})
    if($remaining.Count){throw 'RecoveryRequired: workspace still has registered mounts.'}
    # Unregistered directories are preserved, never recursively deleted.
}
function Install-DeepBootImage([string]$source,[string]$boot,[string]$runId){
    $staged=$boot+'.'+$runId+'.new';$backup=$boot+'.'+$runId+'.previous'
    Publish-DeepStage '부트 이미지 배포 및 검증'
    Copy-Item -LiteralPath $source -Destination $staged -ErrorAction Stop
    $expected=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $expected){throw 'Boot staging hash mismatch; existing boot image retained.'}
    $hadBoot=Test-Path -LiteralPath $boot
    if($hadBoot){Move-Item -LiteralPath $boot -Destination $backup -ErrorAction Stop}
    try{
        Move-Item -LiteralPath $staged -Destination $boot -ErrorAction Stop
        if((Get-FileHash -LiteralPath $boot -Algorithm SHA256).Hash -ne $expected){throw 'Deployed boot image hash mismatch.'}
    }catch{
        if($hadBoot){Copy-Item -LiteralPath $backup -Destination $boot -Force -ErrorAction Stop}
        throw
    }
    # Previous boot image is intentionally retained for recovery.
}
