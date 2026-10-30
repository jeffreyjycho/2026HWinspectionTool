param(
    [Parameter(Mandatory=$true)][string]$RequestJson,
    [string]$EvidenceCsv='',
    [string]$DriverRepoRoot='',
    [string]$OutputManifest=''
)
$ErrorActionPreference='Stop'
function S($v){if($null-eq$v){return ''};return ([string]$v).Trim()}
function Find-TaggedRoot([string]$tag){
    foreach($d in Get-PSDrive -PSProvider FileSystem){$p=Join-Path $d.Root $tag;if(Test-Path -LiteralPath $p){return $d.Root}}
    return $null
}
function Get-WindowsRoots {
    $roots=@()
    foreach($d in Get-PSDrive -PSProvider FileSystem){
        if($d.Name -eq 'X'){continue}
        $w=Join-Path $d.Root 'Windows'
        if(Test-Path -LiteralPath (Join-Path $w 'System32\DriverStore\FileRepository')){$roots+=$w}
    }
    return @($roots|Select-Object -Unique)
}
function Search-InfTree([string]$repo,[string]$ven,[string]$dev,[string]$subvendor,[string]$subsys,[string]$source){
    if(!(Test-Path -LiteralPath $repo)){return @()}
    $out=@();$devPat=('VEN_'+$ven+'&DEV_'+$dev).ToUpper();$subPat=''
    if($subsys -and $subvendor){$subPat=('SUBSYS_'+$subsys+$subvendor).ToUpper()}
    $infs=@(Get-ChildItem -LiteralPath $repo -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
    foreach($inf in $infs){
        $txt='';try{$txt=(Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction Stop).ToUpper()}catch{continue}
        if($txt.IndexOf($devPat) -lt 0){continue}
        $score=50
        if($subPat -and $txt.IndexOf($subPat) -ge 0){$score=100}
        $out += [pscustomobject]@{Source=$source;InfPath=$inf.FullName;Score=$score;ExactSubsystem=($score-eq100)}
    }
    return @($out|Sort-Object -Property @{Expression={ [int]$_.Score };Descending=$true},@{Expression={$_.InfPath}})
}

if(!(Test-Path -LiteralPath $RequestJson)){throw 'RequestJson not found.'}
$r=Get-Content -LiteralPath $RequestJson -Raw|ConvertFrom-Json
if(!$EvidenceCsv){$EvidenceCsv=$RequestJson -replace '_DEEP_SCAN_REQUEST\.json$','.csv'}
if(!(Test-Path -LiteralPath $EvidenceCsv)){throw ('Evidence CSV not found: '+$EvidenceCsv)}
$ev=Import-Csv -LiteralPath $EvidenceCsv
if(!$DriverRepoRoot){
    $data=Find-TaggedRoot 'COUEYE_DATA.TAG'
    if($data){$DriverRepoRoot=Join-Path $data 'COU-EYE\Drivers'}
}
if(!$OutputManifest){$OutputManifest=$RequestJson -replace '_DEEP_SCAN_REQUEST\.json$','_DRIVER_RESOLUTION.csv'}
$winRoots=Get-WindowsRoots
$rows=@()
foreach($q in @($r.Requests)){
    $idx=0;if((S $q.ComponentKey) -match ':(\d+)$'){$idx=[int]$matches[1]}
    $driverItems=@('GPU_DRIVER_MATCH','GPU_DRIVER_LOADED','GPU_PNP_STARTED','GPU_NVML_QUERY','GPU_VENDOR_QUERY','GPU_VENDOR_DEEP')
    if((S $q.EvidenceItem) -notin $driverItems){
        $rows += [pscustomobject]@{ComponentKey=$q.ComponentKey;EvidenceItem=$q.EvidenceItem;VendorID='';DeviceID='';SubvendorID='';SubsystemID='';Resolution='ENGINE_PENDING';Source='';InfPath='';Score=0;Reason='This evidence item is not resolved by a display-driver INF resolver.'}
        continue
    }
    $g=@($ev|Where-Object{$_.Category-eq'GPU' -and [int]$_.Index-eq$idx}|Select-Object -First 1)
    if(!$g){$rows += [pscustomobject]@{ComponentKey=$q.ComponentKey;EvidenceItem=$q.EvidenceItem;VendorID='';DeviceID='';SubvendorID='';SubsystemID='';Resolution='NO_COMPONENT_EVIDENCE';Source='';InfPath='';Score=0;Reason='GPU component row not found in evidence CSV.'};continue}
    $g=$g[0];$ven=(S $g.VendorID).ToUpper();$dev=(S $g.DeviceID).ToUpper();$sv=(S $g.SubvendorID).ToUpper();$ss=(S $g.SubsystemID).ToUpper()
    $cands=@()
    foreach($w in $winRoots){$repo=Join-Path $w 'System32\DriverStore\FileRepository';$cands+=Search-InfTree $repo $ven $dev $sv $ss ('TARGET_WINDOWS_DRIVERSTORE:'+([IO.Path]::GetPathRoot($w)))}
    if($DriverRepoRoot -and (Test-Path -LiteralPath $DriverRepoRoot)){$cands+=Search-InfTree $DriverRepoRoot $ven $dev $sv $ss 'COUEYE_DRIVER_REPOSITORY'}
    $best=@($cands|Sort-Object -Property @{Expression={ [int]$_.Score };Descending=$true},@{Expression={$_.Source}},@{Expression={$_.InfPath}}|Select-Object -First 1)
    if($best.Count){$b=$best[0];$rows += [pscustomobject]@{ComponentKey=$q.ComponentKey;EvidenceItem=$q.EvidenceItem;VendorID=$ven;DeviceID=$dev;SubvendorID=$sv;SubsystemID=$ss;Resolution='RESOLVED';Source=$b.Source;InfPath=$b.InfPath;Score=$b.Score;Reason=$(if($b.ExactSubsystem){'Exact DEV + SUBSYS INF match.'}else{'DEV match; subsystem-specific match was not found.'})}}
    else{$rows += [pscustomobject]@{ComponentKey=$q.ComponentKey;EvidenceItem=$q.EvidenceItem;VendorID=$ven;DeviceID=$dev;SubvendorID=$sv;SubsystemID=$ss;Resolution='NOT_FOUND';Source='';InfPath='';Score=0;Reason='No matching INF found in target Windows DriverStore or COU-EYE repository.'}}
}
$rows|Export-Csv -LiteralPath $OutputManifest -NoTypeInformation -Encoding UTF8
$rows|Format-Table -AutoSize
Write-Host ('Driver resolution manifest: '+$OutputManifest)
