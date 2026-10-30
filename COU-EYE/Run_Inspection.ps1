param([Parameter(Mandatory=$true)][string]$RequestFile)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$request=Import-Clixml -LiteralPath $RequestFile

function Write-UiState([string]$state,[string]$stage,[hashtable]$extra=@{}){
    $o=[ordered]@{State=$state;Stage=$stage;WaybillNumber=$request.WaybillNumber;Coucode=$request.Coucode}
    foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
    $tmp=$request.ProgressFile+'.tmp'
    [pscustomobject]$o|Export-Clixml -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $request.ProgressFile -Force
}
function SafeName([string]$s){return ([regex]::Replace($s,'[^A-Za-z0-9._-]','_'))}
function Test-HeadlessGpuRequired([string]$requestJson){
    if(!$requestJson -or !(Test-Path -LiteralPath $requestJson)){return $false}
    try{
        $j=Get-Content -LiteralPath $requestJson -Raw|ConvertFrom-Json
        $items=@($j.Requests|Where-Object{
            $_.Status -in @('BLOCKED','ERROR','PRESENT_UNVERIFIED') -and
            $_.EvidenceItem -in @('GPU_DRIVER_LOADED','GPU_PNP_STARTED','GPU_NVML_QUERY')
        })
        return ($items.Count -gt 0)
    }catch{return $false}
}

$coreProgress=$request.ProgressFile+'.core.xml'
try {
    if([string]::IsNullOrWhiteSpace($request.WaybillNumber)-or [string]::IsNullOrWhiteSpace($request.Coucode)){throw 'Waybill number and Coucode are required.'}
    Remove-Item -LiteralPath $coreProgress -Force -ErrorAction SilentlyContinue
    Write-UiState 'Running' 'Core Evidence 수집 중'
    & (Join-Path $root 'Collect.ps1') -WaybillNumber $request.WaybillNumber -Coucode $request.Coucode -ProgressFile $coreProgress -GpuScanMode CoreSafe *> $request.LogFile
    if(!(Test-Path -LiteralPath $coreProgress)){throw 'Core inspection did not produce a completion record. See the run log.'}
    $state=Import-Clixml -LiteralPath $coreProgress
    if($state.State-ne 'Complete'){throw 'Core inspection did not produce a completion record. See the run log.'}

    # Basic specification collection is complete. Deep evidence remains optional and separately recorded.
    Write-UiState 'CoreComplete' '사양 확인 완료' @{
        ResultCsv=$state.ResultCsv;Summary=$state.Summary;EvidenceStatus=$state.EvidenceStatus;DeepScanRequest=$state.DeepScanRequest;
        InspectionComplete=$state.InspectionComplete;EvidenceCompleteness=$state.EvidenceCompleteness;Outcome=$state.Outcome
    }
    exit 0
}catch{
    [pscustomobject]@{State='Error';Stage='검사를 완료하지 못했습니다';Message=$_.Exception.Message;LogFile=$request.LogFile}|Export-Clixml -LiteralPath ($request.ProgressFile+'.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($request.ProgressFile+'.tmp') -Destination $request.ProgressFile -Force
    exit 1
}
