param(
 [Parameter(Mandatory=$true)][string]$CoreEvidenceStatus,
 [Parameter(Mandatory=$true)][string]$DeepEvidenceStatus,
 [Parameter(Mandatory=$true)][string]$OutputCsv,
 [string]$OutputSummary=''
)
$ErrorActionPreference='Stop'
function KstNow { [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9)) }
$rank=@{ERROR=0;COVERAGE_GAP=1;BLOCKED=2;PRESENT_UNVERIFIED=3;VERIFIED_FALLBACK=4;VERIFIED=5;NOT_PRESENT=5}
$core=@(Import-Csv -LiteralPath $CoreEvidenceStatus);$deep=@(Import-Csv -LiteralPath $DeepEvidenceStatus)
$map=@{}
foreach($row in @($core+$deep)){
 $key=([string]$row.ComponentKey)+'|'+([string]$row.EvidenceItem)
 $r=if($rank.ContainsKey([string]$row.Status)){$rank[[string]$row.Status]}else{-1}
 if(!$map.ContainsKey($key)){$map[$key]=[pscustomobject]@{Rank=$r;Row=$row}}
 elseif($r -ge $map[$key].Rank){$map[$key]=[pscustomobject]@{Rank=$r;Row=$row}}
}
$merged=@($map.Keys|Sort-Object|ForEach-Object{$map[$_].Row})
$merged|Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
$blocking=@($merged|Where-Object{$_.BlocksCompletion-eq'YES'})
$verified=@($blocking|Where-Object{$_.Status -in @('VERIFIED','VERIFIED_FALLBACK','NOT_PRESENT')})
$pc=if($blocking.Count){[math]::Round(100.0*$verified.Count/$blocking.Count,1)}else{100}
$complete=if($verified.Count-eq$blocking.Count){'YES'}else{'NO'}
if(!$OutputSummary){$OutputSummary=[IO.Path]::ChangeExtension($OutputCsv,'.summary.json')}
[pscustomobject]@{Schema='COU-EYE_MERGED_EVIDENCE_V1';InspectionComplete=$complete;EvidenceCompleteness=$pc;BlockingCount=$blocking.Count;VerifiedBlockingCount=$verified.Count;CoreEvidenceStatus=$CoreEvidenceStatus;DeepEvidenceStatus=$DeepEvidenceStatus;MergedEvidenceStatus=$OutputCsv;GeneratedAt=(KstNow).ToString('o')}|ConvertTo-Json -Depth 5|Out-File -LiteralPath $OutputSummary -Encoding UTF8
Write-Host ('Merged evidence: '+$OutputCsv)
Write-Host ('InspectionComplete='+$complete+' EvidenceCompleteness='+$pc+'%')
