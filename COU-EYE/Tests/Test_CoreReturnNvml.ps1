param([string]$TempRoot=$env:TEMP)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'DeepPE\CoreReturn.ps1')
. (Join-Path $root 'Tools\NvidiaQuery.ps1')
$dir=Join-Path $TempRoot ('return1311_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$resume=Join-Path $dir 'resume.json';$guard=Join-Path $dir 'return.guard'
$script:checks=0;$script:reboots=0
function Assert($ok,$label){if(!$ok){throw ('FAIL: '+$label)};$script:checks++;Write-Output ('PASS: '+$label)}
function Throws([scriptblock]$fn){try{& $fn|Out-Null;return $false}catch{return $true}}
Write-ReturnJson $resume ([pscustomobject]@{AssetID='Dell';State='DEEP_COMPLETE';ResultCsvName='saved.csv'})
Assert (Throws {Request-CoreReturn $resume $guard $false {$script:reboots++}}) 'Restore failure blocks reboot'
Assert ($script:reboots -eq 0 -and !(Test-Path $guard)) 'Blocked restore consumes no reboot'
Request-CoreReturn $resume $guard $true {
 $r=Get-Content $resume -Raw|ConvertFrom-Json
 Assert ($r.ReturnState -eq 'CORE_RETURN_REQUESTED' -and (Test-Path $guard)) 'Resume and guard persisted before reboot'
 $script:reboots++
}
Assert ($script:reboots -eq 1) 'Exactly one reboot callback'
Assert (Throws {Request-CoreReturn $resume $guard $true {$script:reboots++}}) 'Repeated invocation blocked'
Assert ($script:reboots -eq 1) 'Repeated invocation cannot reboot again'
$guard2=Join-Path $dir 'failed.guard'
Assert (Throws {Request-CoreReturn $resume $guard2 $true {throw 'simulated wpeutil failure'}}) 'Reboot command failure propagated'
Assert (Test-Path $guard2) 'Failed command retains guard against loops'
'not json'|Set-Content (Join-Path $dir 'invalid.json')
Assert (Throws {Request-CoreReturn (Join-Path $dir 'invalid.json') (Join-Path $dir 'invalid.guard') $true {$script:reboots++}}) 'Corrupt resume blocks reboot'
$log=New-Object Collections.Generic.List[string];$script:calls=0
$r=Invoke-NvidiaQueryRetry 'fake' 'query' $log {param($e,$a) $script:calls++;[pscustomobject]@{ExitCode=$(if($script:calls -lt 3){255}else{0});Text='test';TimedOut=$false}} @(0,0,0)
Assert ($r.ExitCode -eq 0 -and $script:calls -eq 3) 'Delayed NVML initialization recovers on third attempt'
$script:calls=0
$r=Invoke-NvidiaQueryRetry 'fake' 'query' $log {$script:calls++;[pscustomobject]@{ExitCode=255;Text='Driver Not Loaded';TimedOut=$false}} @(0,0,0)
Assert ($r.ExitCode -eq 255 -and $script:calls -eq 3) 'Persistent failure remains failure with bounded attempts'
$script:calls=0
$r=Invoke-NvidiaQueryRetry 'fake' 'query' $log {$script:calls++;[pscustomobject]@{ExitCode=124;Text='timeout';TimedOut=$true}} @(0,0,0)
Assert ($r.ExitCode -eq 124 -and $script:calls -eq 1) 'Timeout is not retried'
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$r=Invoke-NvidiaCommand $ps '-NoProfile -Command "[Console]::Out.WriteLine(''row''); [Console]::Error.WriteLine(''diagnostic''); exit 7"' 10
Assert ($r.ExitCode -eq 7 -and $r.Text -match 'row' -and $r.Text -match 'diagnostic') 'Real child captures both streams and exit code'
$r=Invoke-NvidiaCommand $ps '-NoProfile -Command "Start-Sleep -Seconds 30"' 1
Assert ($r.ExitCode -eq 124 -and $r.TimedOut) 'Real hung child terminated within timeout'
$pair=Test-NvidiaPair $ps $ps
Assert $pair.Compatible 'Matching version pair accepted'
$pair=Test-NvidiaPair $ps (Join-Path $env:SystemRoot 'System32\kernel32.dll')
Assert (!$pair.Compatible) 'Mismatched version pair rejected'
$row=[pscustomobject]@{ComponentKey='GPU:1';EvidenceItem='GPU_NVML_QUERY';Status='BLOCKED';Reason='Core deferred';BlocksCompletion='YES'}
$core=Join-Path $dir 'core.csv';$deep=Join-Path $dir 'deep.csv';$merged=Join-Path $dir 'merged.csv'
$row|Export-Csv $core -NoTypeInformation;$row.Reason='Deep exit 255';$row|Export-Csv $deep -NoTypeInformation
& (Join-Path $root 'DeepPE\Merge_Evidence.ps1') $core $deep $merged
$result=Import-Csv $merged
Assert ($result.Reason -eq 'Deep exit 255' -and $result.Status -eq 'BLOCKED') 'Latest Deep failure replaces equal-rank Core deferral'
$row.Status='VERIFIED';$row.Reason='Core verified';$row|Export-Csv $core -NoTypeInformation
& (Join-Path $root 'DeepPE\Merge_Evidence.ps1') $core $deep $merged
Assert ((Import-Csv $merged).Status -eq 'VERIFIED') 'Merge preserves stronger evidence'
Write-Output ('PASS: '+$script:checks+' Core return/NVML regression checks')
