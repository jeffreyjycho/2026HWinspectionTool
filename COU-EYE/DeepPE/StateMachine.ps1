param([Parameter(Mandatory=$true)][string]$RequestJson,[string]$StateFile='')
$ErrorActionPreference='Stop'
function KstNow { [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9)) }
if(!(Test-Path -LiteralPath $RequestJson)){throw 'Deep scan request not found.'}
$r=Get-Content -LiteralPath $RequestJson -Raw|ConvertFrom-Json
if(!$StateFile){$StateFile=[IO.Path]::ChangeExtension($RequestJson,'.deepstate.json')}
$state=[pscustomobject]@{Schema='COU-EYE_DEEP_STATE_V1';AssetID=$r.AssetID;PlatformIdentitySHA256=$r.PlatformIdentitySHA256;State='REQUESTED';RequestCount=@($r.Requests).Count;UpdatedAt=(KstNow).ToString('o');Note='V1.3.11 uses an operator-confirmed CoreSafe -> one reboot -> Headless DeepPE -> final operator UI flow; Core boot.wim is restored before the final screen. Display-driver activation remains isolated to headless DeepPE and all required evidence remains explicit.'}
$state|ConvertTo-Json -Depth 5|Out-File -LiteralPath $StateFile -Encoding UTF8
$state|Format-List
