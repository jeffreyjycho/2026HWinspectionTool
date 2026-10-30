param(
 [Parameter(Mandatory=$true)][string]$RequestJson,
 [string]$DriverManifest='',
 [string]$SourceWim='',
 [string]$WorkspaceRoot='',
 [string]$WorkspaceVhdx='',
 [int]$WorkspaceVhdxMB=12288,
 [string]$PreferredWorkspaceDrive='R',
 [switch]$Execute,
 [switch]$DeployToBoot,
 [bool]$AutoRestoreCore=$true,
 [bool]$AutoRebootToCore=$true,
 [IO.FileStream]$LockHandle=$null,
 [string]$RunId=([guid]::NewGuid().ToString('N')),
 [switch]$KeepWorkspaceAttached
)
$ErrorActionPreference='Stop'
if(!$AutoRebootToCore){throw 'V1.3.11 requires one automatic CoreSafe return reboot. AutoRebootToCore=false is unsupported.'}
. (Join-Path $PSScriptRoot 'PrepSafety.ps1')
$script:DeepLogDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) ('Logs\DeepPrep\'+$RunId)
function Find-TaggedRoot([string]$tag){foreach($d in Get-PSDrive -PSProvider FileSystem){$p=Join-Path $d.Root $tag;if(Test-Path -LiteralPath $p){return $d.Root}};return $null}
function SafeName([string]$s){return ([regex]::Replace($s,'[^A-Za-z0-9._-]','_'))}
function KstNow { [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9)) }
function Get-FreeDriveLetter([string]$preferred){
    $choices=@($preferred,'R','Q','V','W','U','P','O')|Where-Object{$_}|Select-Object -Unique
    foreach($c in $choices){if(-not(Get-PSDrive -Name $c -ErrorAction SilentlyContinue)){return $c}}
    throw 'No free drive letter is available for the DeepPE VHDX workspace.'
}
function Invoke-DiskPartScript([string[]]$lines){
    $tmp=Join-Path $env:TEMP ('COUEYE_diskpart_'+[guid]::NewGuid().ToString('N')+'.txt')
    try{
        [IO.File]::WriteAllLines($tmp,$lines,[Text.Encoding]::ASCII)
        $out=Invoke-DeepNative 'diskpart.exe' @('/s',$tmp) 'VHDX 연결/해제'

        return $out
    }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Ensure-WorkspaceVhdx([string]$path,[int]$sizeMB,[string]$preferredLetter){
    $existing=$null
    if(Test-Path -LiteralPath $path){$existing=Get-DeepWorkspaceVolume $path}
    if($existing -and $existing.DriveLetter){return [pscustomobject]@{Root=([string]$existing.DriveLetter+':\');Created=$false;AttachedByScript=$false;DriveLetter=[string]$existing.DriveLetter}}
    $letter=Get-FreeDriveLetter $preferredLetter
    $created=$false
    if(!(Test-Path -LiteralPath $path)){
        $created=$true
        $cmds=@(
            ('create vdisk file="'+$path+'" maximum='+$sizeMB+' type=expandable'),
            ('select vdisk file="'+$path+'"'),
            'attach vdisk',
            'create partition primary',
            'format fs=ntfs quick label=COUEYE_WORK',
            ('assign letter='+$letter),
            'exit'
        )
        Invoke-DiskPartScript $cmds|Out-Null
    }else{
        $cmds=@(('select vdisk file="'+$path+'"'),'attach vdisk','exit')
        if(!$existing){Invoke-DiskPartScript $cmds|Out-Null}
        Start-Sleep -Milliseconds 500
        $vol=Get-DeepWorkspaceVolume $path
        if($vol -and -not $vol.DriveLetter){
            try{
                $img=Get-DiskImage -ImagePath $path -ErrorAction Stop
                $disk=$img|Get-Disk -ErrorAction Stop
                $part=@($disk|Get-Partition|Where-Object{$_.Type-ne'Reserved'}|Select-Object -First 1)
                if($part.Count){Set-Partition -DiskNumber $disk.Number -PartitionNumber $part[0].PartitionNumber -NewDriveLetter $letter -ErrorAction Stop}
            }catch{throw ('Workspace drive letter assignment failed: '+$_.Exception.Message)}
        }
    }
    Start-Sleep -Milliseconds 800
    $vol=Get-DeepWorkspaceVolume $path
    if(!$vol -or !$vol.DriveLetter){throw 'COUEYE_WORK VHDX was attached but no usable drive letter was found.'}
    return [pscustomobject]@{Root=([string]$vol.DriveLetter+':\');Created=$created;AttachedByScript=$true;DriveLetter=[string]$vol.DriveLetter}
}
function Detach-WorkspaceVhdx([string]$path){
    if(!(Test-Path -LiteralPath $path)){return}
    try{Invoke-DiskPartScript @(('select vdisk file="'+$path+'"'),'detach vdisk','exit')|Out-Null}catch{Write-Warning ('Workspace VHDX detach failed: '+$_.Exception.Message)}
}
if(!(Test-Path -LiteralPath $RequestJson)){throw 'RequestJson not found.'}
$r=Get-Content -LiteralPath $RequestJson -Raw|ConvertFrom-Json
$dataRoot=Find-TaggedRoot 'COUEYE_DATA.TAG'
$bootRoot=Find-TaggedRoot 'COUEYE_BOOT.TAG'
if(!$dataRoot){throw 'COUEYE_DATA.TAG volume not found. V1.3.11 DeepPE requires the data partition.'}
if(!$bootRoot){throw 'COUEYE_BOOT.TAG volume not found. V1.3.11 DeepPE requires the boot partition.'}
$appRoot=Join-Path $dataRoot 'COU-EYE'
if(!(Test-Path -LiteralPath (Join-Path $appRoot 'COUEYE.TAG'))){throw 'COU-EYE app not found on data partition.'}
if(!$WorkspaceRoot){$WorkspaceRoot=Join-Path $appRoot 'DeepPE'}
$working=Join-Path $WorkspaceRoot 'Working';$golden=Join-Path $WorkspaceRoot 'Golden'
New-Item -ItemType Directory -Force -Path $working,$golden|Out-Null
# V1.3.11 direct/manual guard. Normal operator flow already holds DEEP_PREP.lock in Prepare_Deep_UI.ps1.
$manualLock=$null
if(!$LockHandle){
    $manualLockPath=Join-Path $working 'DEEP_PREP.lock'
    try{
        $manualLock=[IO.File]::Open($manualLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $manualLock.SetLength(0);$b=[Text.Encoding]::UTF8.GetBytes(('Version=1.3.11'+[Environment]::NewLine+'PID='+$PID+[Environment]::NewLine+'StartedAt='+(KstNow).ToString('o')));$manualLock.Write($b,0,$b.Length);$manualLock.Flush()
    }catch{if($manualLock){$manualLock.Dispose()};throw 'Another DeepPE preparation is already running. Duplicate execution was blocked.'}
}
try{
if($LockHandle -and (!$LockHandle.CanWrite -or [IO.Path]::GetFullPath($LockHandle.Name) -ine [IO.Path]::GetFullPath((Join-Path $working 'DEEP_PREP.lock')))){throw 'Invalid preparation lock owner.'}
$bootWim=Join-Path $bootRoot 'sources\boot.wim'
$coreBootSibling=Join-Path $bootRoot 'sources\boot.core.wim'
$coreBackup=Join-Path $golden 'core.boot.wim'
if(!$SourceWim){
    if(Test-Path -LiteralPath $coreBackup){$SourceWim=$coreBackup}
    elseif(Test-Path -LiteralPath $coreBootSibling){$SourceWim=$coreBootSibling}
    else{$SourceWim=$bootWim}
}
if(!(Test-Path -LiteralPath $SourceWim)){throw ('Source WIM not found: '+$SourceWim)}
if(!$WorkspaceVhdx){$WorkspaceVhdx=Join-Path $WorkspaceRoot 'Workspace.vhdx'}
if(!$DriverManifest){$DriverManifest=$RequestJson -replace '_DEEP_SCAN_REQUEST\.json$','_DRIVER_RESOLUTION.csv'}
if(!(Test-Path -LiteralPath $DriverManifest)){
    Write-Host 'Driver manifest not found; resolving deep drivers first...'
    & (Join-Path $appRoot 'DeepPE\Resolve_DeepDrivers.ps1') -RequestJson $RequestJson -OutputManifest $DriverManifest
}
$manifest=@(Import-Csv -LiteralPath $DriverManifest)
$drivers=@($manifest|Where-Object{$_.Resolution-eq'RESOLVED' -and $_.InfPath -and (Test-Path -LiteralPath $_.InfPath)}|Select-Object -ExpandProperty InfPath -Unique)
if($drivers.Count -eq 0){throw 'No resolved driver INF is available for DeepPE injection.'}
$asset=SafeName ([string]$r.AssetID)
# V1.3.11: every preparation gets a unique staging WIM. Reusing AssetID-only names can collide with a stale DISM/file handle.
$runToken=(KstNow).ToString('yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
$out=Join-Path $working ($asset+'_'+$runToken+'_deep.boot.wim')
$coreStatus=$RequestJson -replace '_DEEP_SCAN_REQUEST\.json$','_EVIDENCE_STATUS.csv'
$pending=Join-Path $working 'DEEP_PENDING.json'
$plan=[pscustomobject]@{
    AssetID=$r.AssetID;PlatformIdentitySHA256=$r.PlatformIdentitySHA256;SourceWim=$SourceWim;OutputWim=$out;
    DriverCount=$drivers.Count;Drivers=$drivers;WorkspaceVhdx=$WorkspaceVhdx;WorkspaceVhdxMB=$WorkspaceVhdxMB;
    BootWimPath=$bootWim;CoreBootSibling=$coreBootSibling;CoreBackup=$coreBackup;DeployToBoot=[bool]$DeployToBoot;
    AutoRestoreCore=[bool]$AutoRestoreCore;Execute=[bool]$Execute
}
$plan|Format-List
if(!$Execute){Write-Host 'DRY RUN ONLY. VHDX/WIM were not modified. Re-run with -Execute after reviewing the plan.';exit 0}

$ws=$null;$mounted=$false;$committed=$false
try{
    $ws=Ensure-WorkspaceVhdx $WorkspaceVhdx $WorkspaceVhdxMB $PreferredWorkspaceDrive
    $mount=Join-Path $ws.Root ('Mount_'+$RunId);$scratch=Join-Path $ws.Root ('Scratch_'+$RunId)
    New-Item -ItemType Directory -Force -Path $mount,$scratch|Out-Null
    Reset-DeepMountWorkspace $ws.Root $working $scratch
    Write-Host ('DeepPE workspace ready: '+$ws.Root+' (VHDX='+$WorkspaceVhdx+')')
    Publish-DeepStage '원본 이미지 복사'
    Copy-Item -LiteralPath $SourceWim -Destination $out -Force
    Invoke-DeepDism @('/Mount-Image',('/ImageFile:'+$out),'/Index:1',('/MountDir:'+$mount),('/ScratchDir:'+$scratch)) '정밀 이미지 마운트'|Out-Null

    $mounted=$true
    foreach($inf in $drivers){
        Write-Host ('Injecting driver: '+$inf)
        Invoke-DeepDism @(('/Image:'+$mount),'/Add-Driver',('/Driver:'+$inf),('/ScratchDir:'+$scratch)) ('드라이버 추가: '+[IO.Path]::GetFileName($inf))|Out-Null

    }
    $sn=Join-Path $mount 'Windows\System32\startnet.cmd'
    $deepStart=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'startnet_deep.cmd') -Raw -ErrorAction Stop
    Set-Content -LiteralPath $sn -Value $deepStart -Encoding ASCII
    Invoke-DeepDism @('/Unmount-Image',('/MountDir:'+$mount),'/Commit',('/ScratchDir:'+$scratch)) '이미지 저장'|Out-Null

    $mounted=$false;$committed=$true
}catch{
    $originalError=$_
    try{
        if($ws){Reset-DeepMountWorkspace $ws.Root $working $scratch}
    }catch{Write-Warning ('RecoveryRequired: '+$_.Exception.Message);$KeepWorkspaceAttached=$true}
    throw $originalError
}finally{
    if($ws -and $ws.AttachedByScript -and -not $KeepWorkspaceAttached){
        try{
            $remaining=@(Get-DeepMountInventory|Where-Object{Test-DeepChildPath $_.MountDir $ws.Root})
            if($remaining.Count){throw 'Registered mounts remain; VHDX retained.'}
            Detach-WorkspaceVhdx $WorkspaceVhdx
        }catch{Write-Warning ('RecoveryRequired: '+$_.Exception.Message)}
    }
}

$size=(Get-Item -LiteralPath $out).Length
Write-Host ('DeepPE WIM size: {0:N1} MiB' -f ($size/1MB))
if($size -ge 4GB){throw 'DeepPE WIM is >=4GB and cannot be deployed as a single file to FAT32.'}
if(!(Test-Path -LiteralPath $coreStatus)){throw ('Core evidence status not found: '+$coreStatus)}
if(!(Test-Path -LiteralPath $coreBackup)){Copy-Item -LiteralPath $SourceWim -Destination $coreBackup -Force}
if($DeployToBoot){Install-DeepBootImage $out $bootWim $RunId}
$coreResultCsv=$coreStatus -replace '_EVIDENCE_STATUS\.csv$','.csv'
[pscustomobject]@{
 Schema='COU-EYE_DEEP_PENDING_V1';Version='1.3.11';RunId=$RunId;AssetID=$r.AssetID;Coucode=$r.Coucode;PlatformIdentitySHA256=$r.PlatformIdentitySHA256;
 RequestJson=$RequestJson;RequestJsonName=[IO.Path]::GetFileName($RequestJson);DriverManifest=$DriverManifest;DriverManifestName=[IO.Path]::GetFileName($DriverManifest);
 CoreEvidenceStatus=$coreStatus;CoreEvidenceStatusName=[IO.Path]::GetFileName($coreStatus);CoreResultCsvName=$(if(Test-Path -LiteralPath $coreResultCsv){[IO.Path]::GetFileName($coreResultCsv)}else{''});
 DeepWim=$out;BootWimPath=$bootWim;CoreBootBackup=$coreBackup;AppRoot=$appRoot;AutoRestoreCore=[bool]$AutoRestoreCore;
 AutoRebootToCore=[bool]$AutoRebootToCore;Headless=$true;WorkspaceVhdx=$WorkspaceVhdx;CreatedAt=(KstNow).ToString('o')
}|ConvertTo-Json -Depth 6|Out-File -LiteralPath ($pending+'.tmp') -Encoding UTF8
if($DeployToBoot){Move-Item -LiteralPath ($pending+'.tmp') -Destination $pending -Force}else{Move-Item -LiteralPath ($pending+'.tmp') -Destination ($pending+'.not-deployed') -Force}
$deepState=Join-Path $working 'DEEP_STATE.json'
[pscustomobject]@{Schema='COU-EYE_DEEP_STATE_V1';Version='1.3.11';State='PREPARED_FOR_HEADLESS_BOOT';AssetID=$r.AssetID;PlatformIdentitySHA256=$r.PlatformIdentitySHA256;DeepWim=$out;PendingFile=$pending;UpdatedAt=(KstNow).ToString('o')}|ConvertTo-Json -Depth 5|Out-File -LiteralPath $deepState -Encoding UTF8
Write-Host ('Deep pending state: '+$pending)
Write-Host ('Deep state: '+$deepState)
if($DeployToBoot){
    # Boot deployment was verified before publishing pending state.
    Write-Host 'DeepPE boot.wim deployed to COUEYE_BOOT.'
    Write-Host 'Reboot the target PC from the COU-EYE USB. Deep mode will restore Core boot.wim and show the final result screen after ONE automatic return reboot into CoreSafe. Select the USB again if the firmware boots internal Windows.'
}else{Write-Host 'DeepPE WIM prepared but NOT deployed. Re-run with -Execute -DeployToBoot after reviewing size/state.'}


}finally{
if($manualLock){$manualLock.Dispose()}
}

