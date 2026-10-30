param([Parameter(Mandatory=$true)][string]$RequestFile)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'DeepPE\PrepSafety.ps1')
$request=Import-Clixml -LiteralPath $RequestFile
if(!$request.RunId -or $request.RunId -notmatch '^[a-f0-9]{32}$'){throw 'V1.3.11 requires an isolated preparation request RunId.'}
$expected=Join-Path (Split-Path -Parent $RequestFile) ($request.RunId+'.deep-prep.state.xml')
if([IO.Path]::GetFullPath($request.ProgressFile) -ine [IO.Path]::GetFullPath($expected)){throw 'Progress path does not belong to this request.'}
function KstNow { [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9)) }
function SafeName([string]$s){return ([regex]::Replace($s,'[^A-Za-z0-9._-]','_'))}
function Acquire-DeepPrepLock {
    $working=Join-Path $root 'DeepPE\Working'
    [void][IO.Directory]::CreateDirectory($working)
    $lockPath=Join-Path $working 'DEEP_PREP.lock'
    try{
        $stream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }catch{
        throw '정밀 검사 환경 준비가 이미 진행 중입니다. 중복 실행을 차단했습니다. 현재 준비 작업이 끝날 때까지 기다려주세요.'
    }
    try{
        $stream.SetLength(0)
        $payload=('Version=1.3.11' + [Environment]::NewLine + 'PID=' + $PID + [Environment]::NewLine + 'Waybill=' + $request.WaybillNumber + [Environment]::NewLine + 'StartedAt=' + (KstNow).ToString('o'))
        $bytes=[Text.Encoding]::UTF8.GetBytes($payload)
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush()
    }catch{}
    return [pscustomobject]@{Path=$lockPath;Stream=$stream}
}
function Release-DeepPrepLock($lock){
    if(!$lock){return}
    try{$lock.Stream.Dispose()}catch{}
    # Lock file persists; only the exclusive handle indicates ownership.
}
function Write-UiState([string]$state,[string]$stage,[hashtable]$extra=@{}){
    $o=[ordered]@{RunId=$request.RunId;Phase='DeepPrep';State=$state;Stage=$stage;WaybillNumber=$request.WaybillNumber;Coucode=$request.Coucode;UpdatedAt=(KstNow).ToString('o')}
    foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
    Write-DeepProgressFile $request.ProgressFile ([pscustomobject]$o)
}
$deepPrepLog=[string]$request.DeepPrepLog
function Update-DeepProgress([string]$stage){Write-UiState 'Running' $stage @{DeepPrepLog=$deepPrepLog}}
$prepLock=$null
function Archive-StaleDeepState {
    $working=Join-Path $root 'DeepPE\Working'
    $cache=Join-Path $root 'DeepPE\Cache'
    [void][IO.Directory]::CreateDirectory($working)
    [void][IO.Directory]::CreateDirectory($cache)
    $stamp=(KstNow).ToString('yyyyMMdd_HHmmss_fff')
    foreach($name in @('DEEP_PENDING.json','DEEP_RESUME.json','DEEP_STATE.json')){
        $src=Join-Path $working $name
        if(Test-Path -LiteralPath $src){
            $dst=Join-Path $cache ('STALE_'+[IO.Path]::GetFileNameWithoutExtension($name)+'_'+$stamp+'.json')
            Move-Item -LiteralPath $src -Destination $dst -Force
        }
    }
}
try{
    $prepLock=Acquire-DeepPrepLock

    if(!$request.DeepScanRequest -or !(Test-Path -LiteralPath $request.DeepScanRequest)){throw 'Deep scan request was not found.'}
    Archive-StaleDeepState
    $safe=SafeName ([string]$request.WaybillNumber)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $deepPrepLog))
    Write-UiState 'Running' '정밀 검사 환경을 준비하고 있습니다' @{
        ResultCsv=$request.ResultCsv;Summary=$request.Summary;EvidenceStatus=$request.EvidenceStatus;DeepScanRequest=$request.DeepScanRequest;
        InspectionComplete=$request.InspectionComplete;EvidenceCompleteness=$request.EvidenceCompleteness;Outcome=$request.Outcome;DeepPrepLog=$deepPrepLog
    }
    & (Join-Path $root 'DeepPE\Prepare_DeepPE.ps1') -RequestJson ([string]$request.DeepScanRequest) -Execute -DeployToBoot -AutoRebootToCore:$true -LockHandle $prepLock.Stream -RunId $request.RunId *>&1 | Out-File -LiteralPath $deepPrepLog -Append -Encoding Unicode
    if(-not $?){throw 'Headless DeepPE preparation returned a failure status.'}
    $pending=Join-Path $root 'DeepPE\Working\DEEP_PENDING.json'
    if(!(Test-Path -LiteralPath $pending)){throw 'DeepPE was prepared but DEEP_PENDING.json was not created.'}
    $pendingState=Get-Content -LiteralPath $pending -Raw|ConvertFrom-Json
    if($pendingState.RunId -ne $request.RunId){throw 'Prepared image belongs to a different request.'}
    Write-UiState 'DeepReady' '정밀 검사 환경 준비 완료 · 재부팅 대기' @{
        ResultCsv=$request.ResultCsv;Summary=$request.Summary;EvidenceStatus=$request.EvidenceStatus;DeepScanRequest=$request.DeepScanRequest;
        InspectionComplete=$request.InspectionComplete;EvidenceCompleteness=$request.EvidenceCompleteness;Outcome=$request.Outcome;
        DeepPrepLog=$deepPrepLog;PendingFile=$pending
    }
    exit 0
}catch{
    $err=$_.Exception.Message
    try{
        if([string]::IsNullOrWhiteSpace($deepPrepLog)){
            $safe=SafeName ([string]$request.WaybillNumber)
            $deepPrepLog=Join-Path $root ('Logs\DEEP_PREP_ERROR_'+$safe+'_'+(KstNow).ToString('yyyyMMdd_HHmmss')+'.log')
        }
        ('['+(KstNow).ToString('o')+'] '+$err)|Out-File -LiteralPath $deepPrepLog -Append -Encoding Unicode
        ($_ | Format-List * -Force | Out-String)|Out-File -LiteralPath $deepPrepLog -Append -Encoding Unicode
    }catch{}
    Write-UiState 'Error' '정밀 검사 환경을 준비하지 못했습니다' @{Message=$err;DeepPrepLog=$deepPrepLog}
    exit 1
}finally{

    Release-DeepPrepLock $prepLock
}
