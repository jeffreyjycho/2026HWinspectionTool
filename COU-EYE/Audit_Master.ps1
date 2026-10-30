param([int]$StaleDays=45)
$ErrorActionPreference='SilentlyContinue'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$D=Join-Path $Root 'DB';$R=Join-Path $Root 'Results'
New-Item -ItemType Directory -Force -Path $R|Out-Null
$master=Join-Path $D 'KOREA_PRODUCT_MASTER.csv'
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$outCsv=Join-Path $R ("${stamp}_KOREA_MASTER_AUDIT.csv")
$outTxt=Join-Path $R ("${stamp}_KOREA_MASTER_AUDIT.txt")
function S($v){if($null-eq$v){''}else{([string]$v).Trim()}}
if(!(Test-Path $master)){Write-Host '[ERROR] DB/KOREA_PRODUCT_MASTER.csv not found';exit 1}
$rows=@(Import-Csv $master|Where-Object{S $_.ProductID})
$cats=@('GPU','RAM','MAINBOARD','STORAGE','CPU')
$audit=@()
$now=Get-Date
foreach($c in $cats){
  $cr=@($rows|Where-Object{(S $_.Category).ToUpper()-eq$c})
  $r24=@($cr|Where-Object{[int](S $_.ReleaseYear)-ge2024 -and (S $_.KoreaDistribution).ToUpper()-ne'NO'})
  $stale=@($r24|Where-Object{
    [datetime]$d=[datetime]::MinValue
    if(![datetime]::TryParse((S $_.LastVerifiedDate),[ref]$d)){return $true}
    return (($now-$d).TotalDays -gt $StaleDays)
  })
  $audit += [pscustomobject]@{Category=$c;TotalRecords=$cr.Count;Records2024Plus=$r24.Count;StaleOrUnverified=$stale.Count;FreshnessStatus=$(if($r24.Count-eq0){'NO_2024_PLUS_RECORDS'}elseif($stale.Count-gt0){'STALE_ROWS_PRESENT'}else{'OK'})}
}
$audit|Export-Csv $outCsv -NoTypeInformation -Encoding UTF8
$o=New-Object Collections.Generic.List[string]
$o.Add('COU-EYE V1.0 - KOREA PRODUCT MASTER AUDIT');$o.Add('Time: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'));$o.Add('Stale threshold: '+$StaleDays+' days');$o.Add('')
$o.Add('NOTE: This audit checks DB freshness/coverage by category. It does NOT prove the Korean market catalog is complete.')
$o.Add('')
foreach($a in $audit){$o.Add(($a.Category+': total='+$a.TotalRecords+' | 2024+='+$a.Records2024Plus+' | stale/unverified='+$a.StaleOrUnverified+' | '+$a.FreshnessStatus))}
$o.Add('');$o.Add('CSV: '+$outCsv)
$o|Out-File $outTxt -Encoding UTF8
Get-Content $outTxt
