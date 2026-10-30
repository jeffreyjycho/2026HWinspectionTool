function Write-BootTrace([string]$AppRoot,[string]$Stage,[string]$Detail='') {
 try {
  $dir=Join-Path $AppRoot 'Logs\Boot';[void][IO.Directory]::CreateDirectory($dir)
  $pending=Join-Path $AppRoot 'DeepPE\Working\DEEP_PENDING.json'
  $run='';foreach($path in @($pending,(Join-Path $AppRoot 'DeepPE\Working\DEEP_RESUME.json'))){if(Test-Path -LiteralPath $path){try{$run=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).RunId;if($run){break}}catch{}}}
  $entry=[pscustomobject]@{Utc=[DateTimeOffset]::UtcNow.ToString('o');Patch='1.3.11-bootlog1';Stage=$Stage;RunId=$run;PID=$PID;Computer=$env:COMPUTERNAME;SystemRoot=$env:SystemRoot;Detail=$Detail}
  $bytes=[Text.Encoding]::UTF8.GetBytes(($entry|ConvertTo-Json -Compress)+[Environment]::NewLine)
  $stream=[IO.File]::Open((Join-Path $dir ('events_'+$PID+'.jsonl')),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 }catch{Write-Warning ('Boot trace write failed: '+$_.Exception.Message)}
}
