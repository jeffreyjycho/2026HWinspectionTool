function Resolve-SavedResult([string]$root,$record){
    foreach($name in @($record.ResultCsvName,$record.CoreResultCsvName)){
        if(!$name){continue}
        if([IO.Path]::GetFileName([string]$name) -ne [string]$name){throw 'Invalid saved result filename.'}
        $path=Join-Path (Join-Path $root 'Results') $name
        if(Test-Path -LiteralPath $path){return $path}
    }
    throw 'Saved hardware specification CSV not found.'
}
function Get-ResultEvidence([string]$csv){
    $complete='NO';$percent='미확인'
    $path=$csv -replace '\.csv$','_INSPECTION.csv'
    if(Test-Path -LiteralPath $path){
        $record=@(Import-Csv -LiteralPath $path|Select-Object -First 1)
        if($record.Count){
            if($record[0].InspectionComplete -eq 'YES'){$complete='YES'}
            if($record[0].EvidenceCompleteness){$percent=[string]$record[0].EvidenceCompleteness}
        }
    }
    [pscustomobject]@{Complete=$complete;Percent=$percent}
}
function Get-ResumeResultContext([string]$root,[string]$resumeFile){
    $record=Get-Content -LiteralPath $resumeFile -Raw|ConvertFrom-Json
    $csv=Resolve-SavedResult $root $record
    $evidence=Get-ResultEvidence $csv
    $complete=$evidence.Complete;$percent=$evidence.Percent
    if($record.MergedSummaryName){
        $name=[string]$record.MergedSummaryName
        if([IO.Path]::GetFileName($name) -ne $name){throw 'Invalid summary filename.'}
        $path=Join-Path (Join-Path $root 'Results') $name
        if(Test-Path $path){
            $summary=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
            $complete=if($summary.InspectionComplete -eq 'YES'){'YES'}else{'NO'}
            $percent=[string]$summary.EvidenceCompleteness
        }
    }
    if($record.State -match 'ERROR' -or $record.Error){$complete='NO'}
    $notice=if($record.Error){'정밀검사 오류 · 기본 사양 표시: '+$record.Error}else{'저장된 사양 · 확보하지 못한 증거는 미확인으로 표시됩니다.'}
    if($record.CoreRestored -eq $false){$notice+=' · Core 부트 복원 실패: 재부팅 전 로그 확인 필요'}
    [pscustomobject]@{Csv=$csv;Record=$record;Complete=$complete;Percent=$percent;Notice=$notice}
}
