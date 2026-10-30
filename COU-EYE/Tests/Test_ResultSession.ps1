param([string]$TempRoot=$env:TEMP)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Tools\ResultSession.ps1')
$temp=Join-Path $TempRoot ('results1310_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $temp 'Results')|Out-Null
$script:checks=0
function Assert($ok,$name){if(!$ok){throw ('FAIL: '+$name)};$script:checks++;'PASS: '+$name}
function Throws([scriptblock]$fn){try{& $fn|Out-Null;$false}catch{$true}}
$csv=Join-Path $temp 'Results\core.csv'
[pscustomobject]@{AssetID='test';Category='CPU';Model='Test CPU'}|Export-Csv $csv -NoTypeInformation
$record=[pscustomobject]@{ResultCsvName='missing.csv';CoreResultCsvName='core.csv';State='DEEP_ERROR';Error='GPU failed';CoreRestored=$false}
$resume=Join-Path $temp 'resume.json';$record|ConvertTo-Json|Set-Content $resume
$context=Get-ResumeResultContext $temp $resume
Assert ($context.Csv -eq $csv) 'Deep error falls back to saved Core specifications'
Assert ($context.Complete -eq 'NO') 'Missing evidence cannot imply full completion'
Assert ($context.Notice -match 'GPU failed') 'Deep error remains visible alongside specifications'
Assert ($context.Notice -match 'Core') 'Core restore failure remains visible'
Assert (Throws {Resolve-SavedResult $temp ([pscustomobject]@{ResultCsvName='..\foreign.csv'})}) 'Saved filename traversal rejected'
[pscustomobject]@{InspectionComplete='NO';EvidenceCompleteness='52.4'}|Export-Csv ($csv -replace '\.csv$','_INSPECTION.csv') -NoTypeInformation
Assert ((Get-ResultEvidence $csv).Percent -eq '52.4') 'Real evidence percentage used for direct CSV view'
[pscustomobject]@{InspectionComplete='YES';EvidenceCompleteness='100'}|ConvertTo-Json|Set-Content (Join-Path $temp 'Results\merged.json')
$record|Add-Member NoteProperty MergedSummaryName 'merged.json'
$record.State='DEEP_COMPLETE';$record.Error='';$record.CoreRestored=$true
$record|ConvertTo-Json|Set-Content $resume
Assert ((Get-ResumeResultContext $temp $resume).Complete -eq 'YES') 'Merged verified completion is displayed'
$record.State='DEEP_ERROR';$record.Error='merge failed';$record|ConvertTo-Json|Set-Content $resume
Assert ((Get-ResumeResultContext $temp $resume).Complete -eq 'NO') 'Error overrides stale successful summary'
# Execute actual Core/Ready transitions with a mock renderer and no GUI.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'COU_EYE_UI.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Show-CoreCompleteDeepPrompt','Show-DeepReady')){
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($node.Extent.Text))
}
function Show-Result($rows,$savedPath,$demo,$inspectionComplete,$evidenceCompleteness,$outcome){$script:rendered=@($rows);$script:resultHint=[pscustomobject]@{Text=''}}
$steps=[pscustomobject]@{Text=''}
$state=[pscustomobject]@{ResultCsv=$csv;InspectionComplete='NO';EvidenceCompleteness='52.4';State='CoreCompleteDeepRequired';DeepScanRequest='request.json'}
Show-CoreCompleteDeepPrompt $state
Assert ($script:rendered[0].Model -eq 'Test CPU') 'Core completion calls specification renderer immediately'
Assert ($script:coreState -eq $state) 'Optional Deep request remains available'
$state.State='DeepReady';Show-DeepReady $state
Assert ($script:rendered[0].Model -eq 'Test CPU') 'Prepared state retains specification cards'
Assert ($script:resultHint.Text -match 'USB') 'Prepared state explains explicit USB reboot'
'RESULT: '+$script:checks+' checks passed.'
