param([string]$TempRoot=$env:TEMP)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'DeepPE\PrepSafety.ps1')
$sandbox=Join-Path $TempRoot ('deep139_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$script:count=0
function Assert($ok,[string]$name){if(!$ok){throw ('FAIL: '+$name)};$script:count++;Write-Output ('PASS: '+$name)}
function Throws([scriptblock]$action){try{& $action|Out-Null;return $false}catch{return $true}}
Assert (!(Test-DeepStateOwner ([pscustomobject]@{State='CoreCompleteDeepRequired'}) 'abc')) 'Old Core completion rejected by Deep owner gate'
Assert (!(Test-DeepStateOwner ([pscustomobject]@{RunId='other';Phase='DeepPrep'}) 'abc')) 'Foreign request rejected'
Assert (Test-DeepStateOwner ([pscustomobject]@{RunId='abc';Phase='DeepPrep'}) 'abc') 'Current request accepted'
Assert (@(ConvertFrom-DeepMountInfo "Mounted images:`r`nNo mounted images found.`r`nThe operation completed successfully.").Count -eq 0) 'Explicit empty mount inventory accepted'
Assert (Throws {ConvertFrom-DeepMountInfo 'Error: 87'}) 'Failed/unknown inventory is not empty inventory'
Assert (Throws {ConvertFrom-DeepMountInfo 'Mount Dir : R:\Mount'}) 'Truncated inventory rejected'
$raw="Mount Dir : R:\Mount`r`nImage File : E:\COU-EYE\DeepPE\Working\old.wim`r`nImage Index : 1`r`nMounted Read/Write : Yes`r`nStatus : Invalid"
$entry=@(ConvertFrom-DeepMountInfo $raw)
Assert ($entry.Count -eq 1 -and $entry[0].Status -eq 'Invalid') 'English DISM image record parsed'
Assert (!(Test-DeepChildPath 'R:\MountOther\x' 'R:\Mount')) 'Sibling prefix cannot claim ownership'
Assert (!(Test-DeepChildPath 'R:\Mount\..\foreign' 'R:\Mount')) 'Parent traversal cannot claim ownership'

# Execute the actual UI timer handler without constructing a window.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'COU_EYE_UI.ps1'),[ref]$tokens,[ref]$parseErrors)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Tick'},$true)
$tick=$node.Arguments[0].ScriptBlock.GetScriptBlock()
$script:timer=New-Object psobject -Property @{Stopped=$false}
$script:timer|Add-Member ScriptMethod Stop {$this.Stopped=$true}
$script:stage=[pscustomobject]@{IsDisposed=$false;Text=''}
$script:activePrepId='abc';$script:running=$true;$script:exitSeen=$false
$script:worker=[pscustomobject]@{HasExited=$false;ExitCode=1}
$script:statePath=Join-Path $sandbox 'timer.xml'
function Show-CoreCompleteDeepPrompt($state){throw 'Old Core prompt must not be shown'}
function Show-Failure($message){$script:failure=$message}
[pscustomobject]@{State='CoreCompleteDeepRequired'}|Export-Clixml $script:statePath
& $tick
Assert ($script:running -and !$script:timer.Stopped) 'Actual timer keeps monitoring delayed Deep startup'
'<broken'|Set-Content $script:statePath
$script:worker.HasExited=$true
& $tick; & $tick
Assert ($script:timer.Stopped -and $script:failure -match '1') 'Unreadable XML does not suppress worker exit detection'
$script:running=$true;$script:timer.Stopped=$false;$script:failure=''
[pscustomobject]@{RunId='abc';Phase='DeepPrep';State='Error';Message='mount failed';DeepPrepLog='deep.log'}|Export-Clixml $script:statePath
& $tick
Assert ($script:failure -eq 'mount failed' -and $script:logPath -eq 'deep.log') 'Actual timer displays preparation error and correct log'

# Real cross-process exclusive lock and wrapper state isolation; no DISM/USB.
$app=Join-Path $sandbox 'app';$deep=Join-Path $app 'DeepPE';$jobs=Join-Path $app 'Logs\UI'
New-Item -ItemType Directory -Force $deep,$jobs,(Join-Path $deep 'Working')|Out-Null
Copy-Item (Join-Path $root 'DeepPE\PrepSafety.ps1'),(Join-Path $root 'DeepPE\Prepare_Deep_UI.ps1') $deep
@'
param($RequestJson,[switch]$Execute,[switch]$DeployToBoot,$AutoRebootToCore,$LockHandle,$RunId)
Update-DeepProgress 'stub servicing'
Start-Sleep -Seconds 4
throw 'SIMULATED_MOUNT_FAILURE'
'@|Set-Content (Join-Path $deep 'Prepare_DeepPE.ps1') -Encoding UTF8
'{}'|Set-Content (Join-Path $app 'request.json')
$ids=@([guid]::NewGuid().ToString('N'),[guid]::NewGuid().ToString('N'))
$requests=@();$states=@()
foreach($id in $ids){
    $state=Join-Path $jobs ($id+'.deep-prep.state.xml');$states += $state
    $req=Join-Path $jobs ($id+'.deep-prep.request.xml');$requests += $req
    [pscustomobject]@{RunId=$id;ProgressFile=$state;DeepPrepLog=(Join-Path $app ('Logs\'+$id+'.log'));DeepScanRequest=(Join-Path $app 'request.json');WaybillNumber='test'}|Export-Clixml $req
}
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Launch($req){
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$ps
    $si.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $deep 'Prepare_Deep_UI.ps1')+'" -RequestFile "'+$req+'"'
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    return [Diagnostics.Process]::Start($si)
}
$p1=Launch $requests[0]
$deadline=[DateTime]::UtcNow.AddSeconds(10)
while(!(Test-Path $states[0]) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
Assert (Test-DeepPreparationBusy $app) 'Live preparation lock detected across processes'
$p2=Launch $requests[1]
Assert ($p2.WaitForExit(10000)) 'Duplicate request exits promptly'
Assert ((Import-Clixml $states[1]).State -eq 'Error') 'Duplicate receives its own error'
Assert ((Import-Clixml $states[0]).State -eq 'Running') 'Duplicate did not overwrite active progress'
Assert ($p1.WaitForExit(10000)) 'Owner exits after simulated failure'
Assert ((Import-Clixml $states[0]).Message -eq 'SIMULATED_MOUNT_FAILURE') 'Owner final error retained'
Assert (!(Test-DeepPreparationBusy $app)) 'Finally releases lock after failure'
Assert (Test-Path (Join-Path $deep 'Working\DEEP_PREP.lock')) 'Released persistent lock file does not block next run'
$p1.Dispose();$p2.Dispose()
@'
param($RequestJson,[switch]$Execute,[switch]$DeployToBoot,$AutoRebootToCore,$LockHandle,$RunId)
[pscustomobject]@{RunId=$RunId}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'Working\DEEP_PENDING.json') -Encoding UTF8
'@|Set-Content (Join-Path $deep 'Prepare_DeepPE.ps1') -Encoding UTF8
$p3=Launch $requests[0]
Assert ($p3.WaitForExit(10000)) 'Preparation can restart after released lock'
Assert ((Import-Clixml $states[0]).State -eq 'DeepReady') 'Matching successful preparation publishes DeepReady'
$p3.Dispose()
@'
param($RequestJson,[switch]$Execute,[switch]$DeployToBoot,$AutoRebootToCore,$LockHandle,$RunId)
[pscustomobject]@{RunId='wrong-run'}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'Working\DEEP_PENDING.json') -Encoding UTF8
'@|Set-Content (Join-Path $deep 'Prepare_DeepPE.ps1') -Encoding UTF8
$p4=Launch $requests[0]
Assert ($p4.WaitForExit(10000)) 'Foreign pending check finishes'
Assert ((Import-Clixml $states[0]).State -eq 'Error') 'Foreign pending cannot publish DeepReady'
$p4.Dispose()

# Mock native servicing only; execute real recovery policy.
$script:inventoryCalls=0;$script:discardCalls=0
function Get-DeepMountInventory { $script:inventoryCalls++;if($script:inventoryCalls -eq 1){[pscustomobject]@{MountDir='R:\Mount';ImageFile='E:\app\Working\old.wim';Status='Invalid'}} }
function Invoke-DeepDism($arguments,$stage){$script:discardCalls++}
function Get-Process {param($Name,$ErrorAction) return @()}
Reset-DeepMountWorkspace 'R:\' 'E:\app\Working' 'R:\Scratch'
Assert ($script:discardCalls -eq 1 -and $script:inventoryCalls -eq 2) 'Owned stale mount discarded and inventory rechecked'
function Get-DeepMountInventory {[pscustomobject]@{MountDir='R:\Mount';ImageFile='E:\foreign\old.wim';Status='Ok'}}
$script:discardCalls=0
Assert (Throws {Reset-DeepMountWorkspace 'R:\' 'E:\app\Working' 'R:\Scratch'}) 'Foreign image blocks recovery'
Assert ($script:discardCalls -eq 0) 'Foreign mount not modified'
function Get-DeepMountInventory {throw 'inventory query failed'}
Assert (Throws {Reset-DeepMountWorkspace 'R:\' 'E:\app\Working' 'R:\Scratch'}) 'Inventory failure blocks cleanup'
function Get-DeepMountInventory {[pscustomobject]@{MountDir='R:\Mount';ImageFile='E:\app\Working\old.wim';Status='Invalid'}}
Assert (Throws {Reset-DeepMountWorkspace 'R:\' 'E:\app\Working' 'R:\Scratch'}) 'Still-registered mount blocks continuation'
Remove-Item Function:\Get-Process

# Real small-file deployment; injected rename failure verifies rollback.
$source=Join-Path $sandbox 'source.wim';$boot=Join-Path $sandbox 'boot.wim'
'new image'|Set-Content $source;'old image'|Set-Content $boot
Install-DeepBootImage $source $boot 'success'
Assert ((Get-Content $boot -Raw) -match 'new image') 'Boot staging hash checked and deployed'
Assert ((Get-Content ($boot+'.success.previous') -Raw) -match 'old image') 'Previous boot image retained'
'old again'|Set-Content $boot
function Move-Item {param($LiteralPath,$Destination,$ErrorAction) if($LiteralPath -like '*.new'){throw 'injected rename failure'};Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop}
Assert (Throws {Install-DeepBootImage $source $boot 'failure'}) 'Deployment failure propagated'
Assert ((Get-Content $boot -Raw) -match 'old again') 'Deployment failure restores prior boot image'
Remove-Item Function:\Move-Item

# Real asynchronous native wrapper: nonzero exit and output are preserved.
$script:DeepLogDirectory=Join-Path $sandbox 'native'
$native=Join-Path $sandbox 'native.ps1'
"Write-Output 'native output'; exit 7"|Set-Content $native
Assert (Throws {Invoke-DeepNative $ps @('-NoProfile','-File',$native) 'native failure'}) 'Native nonzero exit propagated'
Assert (@(Get-ChildItem $script:DeepLogDirectory -Filter '*.result.json').Count -eq 1) 'Native exit metadata saved'
function Update-DeepProgress($stage){throw 'injected progress storage error'}
"Start-Sleep -Seconds 2; Write-Output 'completed despite progress error'; exit 0"|Set-Content $native
$result=Invoke-DeepNative $ps @('-NoProfile','-File',$native) 'progress failure' 1
Assert ($result -match 'completed despite progress error') 'Heartbeat write failure does not abandon native worker'
Write-Output ('RESULT: '+$script:count+' checks passed. Test artifacts: '+$sandbox)
