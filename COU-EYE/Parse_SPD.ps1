[CmdletBinding()]
param(
 [string]$InputPath = '',
 [string]$SourceManifest = '',
 [string]$DataRoot = ''
)
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
if(-not $InputPath){$InputPath=Join-Path $scriptRoot 'SPD_INBOX'}
if(-not $SourceManifest){$SourceManifest=Join-Path $scriptRoot 'SPD_INBOX\SOURCES.csv'}
if(-not $DataRoot){$DataRoot=$scriptRoot}
Set-StrictMode -Version 2
$lock=$null
$exitCode=0
try {
 if(-not ('CouI.SpdEngine' -as [type])) { Add-Type -Path (Join-Path $scriptRoot 'Tools\SpdEngine.dll') }
 $DataRoot=[IO.Path]::GetFullPath($DataRoot)
 foreach($d in @('DB','SPD_Results','SPD_Results\RAW','SPD_Results\REPORTS')) {
  [void][IO.Directory]::CreateDirectory((Join-Path $DataRoot $d))
 }
 # OS releases this exclusive lock even if the process is interrupted.
 $lock=[IO.File]::Open((Join-Path $DataRoot 'SPD_Results\import.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $rawDir=Join-Path $DataRoot 'SPD_Results\RAW'
 $reportDir=Join-Path $DataRoot 'SPD_Results\REPORTS'
 $manifest=@{}
 if(Test-Path -LiteralPath $SourceManifest -PathType Leaf) {
  foreach($s in @(Import-Csv -LiteralPath $SourceManifest)) {
   if($s.SHA256 -notmatch '^[0-9a-fA-F]{64}$'){throw 'SOURCES.csv contains an invalid SHA256.'}
   if($s.SourceType -notin @('UNVERIFIED','OFFICIAL_SPD','PHYSICAL_SPD_VERIFIED','REFERENCE_SPD')){throw 'Invalid source type in SOURCES.csv.'}
   if($s.SourceType -ne 'UNVERIFIED' -and ([string]::IsNullOrWhiteSpace($s.SourceReference) -or [string]::IsNullOrWhiteSpace($s.VerifiedBy))){throw 'Non-default source claims require SourceReference and VerifiedBy.'}
   $key=$s.SHA256.ToLowerInvariant()
   if($manifest.ContainsKey($key)){throw 'Duplicate SHA256 in SOURCES.csv.'}
   $manifest[$key]=$s
  }
 }
 function Save-Json($value,[string]$path) {
  ConvertTo-Json -InputObject $value -Depth 12 | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
  Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
 }
 function Save-Csv($rows,$columns,[string]$path) {
  if(@($rows).Count -gt 0){$rows | Select-Object $columns | Export-Csv -LiteralPath ($path+'.tmp') -NoTypeInformation -Encoding UTF8}
  else {('"'+($columns -join '","')+'"') | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8}
  Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
 }
 if(-not(Test-Path -LiteralPath $InputPath)){throw ('Input path not found: '+$InputPath)}
 $item=Get-Item -LiteralPath $InputPath
 $files=@()
 if($item.PSIsContainer){$files=@(Get-ChildItem -LiteralPath $InputPath -File -Recurse | Where-Object {$_.Extension.ToLowerInvariant() -in @('.bin','.spd','.rom')} | Sort-Object FullName)}
 elseif($item.Extension.ToLowerInvariant() -in @('.bin','.spd','.rom')){$files=@($item)}
 else{throw 'Expected a directory or binary .bin/.spd/.rom file.'}
 $run=New-Object 'System.Collections.Generic.List[object]'
 foreach($f in $files){
  try {
   if($f.Length -gt 1048576){throw 'File exceeds 1 MiB SPD input limit.'}
   $bytes=[IO.File]::ReadAllBytes($f.FullName)
   $h=[CouI.SpdEngine]::Hash($bytes)
   $bin=Join-Path $rawDir ($h+'.bin');$metaPath=Join-Path $rawDir ($h+'.source.json')
   $duplicate=Test-Path -LiteralPath $bin
   if($duplicate){if((Get-FileHash -LiteralPath $bin -Algorithm SHA256).Hash.ToLowerInvariant() -ne $h){throw 'Archived raw file hash mismatch; restore archive before retrying.'}}
   else{[IO.File]::WriteAllBytes(($bin+'.tmp'),$bytes);Move-Item -LiteralPath ($bin+'.tmp') -Destination $bin}
   $sourceType='UNVERIFIED';$reference='';$verifiedBy=''
   if($manifest.ContainsKey($h)){$s=$manifest[$h];$sourceType=$s.SourceType;$reference=$s.SourceReference;$verifiedBy=$s.VerifiedBy}
   $meta=@()
   if(Test-Path -LiteralPath $metaPath){$loaded=Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json;$meta=@($loaded)}
   $same=@($meta | Where-Object {$_.FileName -ceq $f.Name -and $_.SourceType -eq $sourceType -and $_.SourceReference -ceq $reference -and $_.VerifiedBy -ceq $verifiedBy})
   if($same.Count -eq 0){$meta+= [pscustomobject]@{FileName=$f.Name;SourceType=$sourceType;SourceReference=$reference;VerifiedBy=$verifiedBy;ImportedUTC=[DateTime]::UtcNow.ToString('o')}}
   Save-Json -value @($meta) -path $metaPath
   $r=[CouI.SpdEngine]::Parse($bytes)
   $run.Add([pscustomobject]@{FileName=$f.Name;SHA256=$h;Duplicate=$duplicate;Status=$r.Status;Detail=$r.Notes})
   if($r.Status -ne 'PARSED'){$exitCode=2}
  }catch{$exitCode=2;$run.Add([pscustomobject]@{FileName=$f.Name;SHA256='';Duplicate=$false;Status='ERROR';Detail=$_.Exception.Message})}
 }
 # Rebuild from the immutable raw archive. A rerun repairs interrupted DB writes.
 $fingerprints=New-Object 'System.Collections.Generic.List[object]'
 $profiles=New-Object 'System.Collections.Generic.List[object]'
 foreach($f in @(Get-ChildItem -LiteralPath $rawDir -Filter '*.bin' -File | Sort-Object Name)) {
  $r=[CouI.SpdEngine]::Parse([IO.File]::ReadAllBytes($f.FullName))
  if($r.SHA256 -ne $f.BaseName){throw ('Archive SHA256 mismatch: '+$f.Name)}
  $metaPath=Join-Path $rawDir ($r.SHA256+'.source.json')
  $sources=@()
  if(Test-Path -LiteralPath $metaPath){$loaded=Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json;$sources=@($loaded)}
  $sourceTypes=(@($sources | ForEach-Object {$_.SourceType} | Sort-Object -Unique) -join ';')
  if(-not $sourceTypes){$sourceTypes='UNVERIFIED'}
  $confidence='UNVERIFIED'
  # Claims are supplied by the operator; CRC never upgrades source confidence.
  if($sourceTypes -match 'REFERENCE_SPD'){$confidence='REFERENCE_CLAIMED'}
  if($sourceTypes -match 'PHYSICAL_SPD_VERIFIED'){$confidence='PHYSICAL_VERIFICATION_CLAIMED'}
  if($sourceTypes -match 'OFFICIAL_SPD'){$confidence='OFFICIAL_SOURCE_CLAIMED'}
  $row=[ordered]@{}
  foreach($field in @('SHA256','ParserVersion','Length','Generation','Revision','Status','ModuleType','ModuleManufacturerID','ModuleManufacturer','DRAMManufacturerID','DRAMManufacturer','PartNumber','Serial','ManufactureDateBCD','CapacityMiB','CapacityStatus','Ranks','DeviceWidth','BusWidth','Channels','JEDECSpeedMTs','TimingStatus','tCK_ps','tAA_ps','tRCD_ps','tRP_ps','tRAS_ps','tRC_ps','SupportedCL','BaseCRC','ModuleCRC','XMP','XMPHeaderCRC','EXPO','EXPOCRC','Notes')){$row[$field]=$r.$field}
  $row.SourceTypes=$sourceTypes;$row.Confidence=$confidence;$row.SourceCount=$sources.Count
  $row.SourceEvidenceJSON=ConvertTo-Json -InputObject @($sources) -Compress -Depth 5
  $fingerprints.Add([pscustomobject]$row)
  foreach($p in $r.Profiles){
   $eligible=$r.Status -eq 'PARSED' -and $p.Status -eq 'DECODED' -and $r.BaseCRC -eq 'PASS'
   if($p.Kind -like 'XMP_3*' -and $r.XMPHeaderCRC -ne 'PASS'){$eligible=$false}
   $profiles.Add([pscustomobject][ordered]@{SHA256=$r.SHA256;Generation=$r.Generation;ModuleManufacturerID=$r.ModuleManufacturerID;PartNumber=$r.PartNumber;CapacityMiB=$r.CapacityMiB;Kind=$p.Kind;ProfileNumber=$p.Number;Offset=$p.Offset;SpeedMTs=$p.SpeedMTs;tCK_ps=$p.tCK_ps;tAA_ps=$p.tAA_ps;tRCD_ps=$p.tRCD_ps;tRP_ps=$p.tRP_ps;tRAS_ps=$p.tRAS_ps;tRC_ps=$p.tRC_ps;Status=$p.Status;CRC=$p.CRC;BaseCRC=$r.BaseCRC;EligibleForCandidateMatch=$eligible;SourceTypes=$sourceTypes;Confidence=$confidence})
  }
  Save-Json -value ([ordered]@{SPD=$r;Sources=@($sources);Confidence=$confidence}) -path (Join-Path $reportDir ($r.SHA256+'.json'))
 }
 $fcols=@('SHA256','ParserVersion','Length','Generation','Revision','Status','ModuleType','ModuleManufacturerID','ModuleManufacturer','DRAMManufacturerID','DRAMManufacturer','PartNumber','Serial','ManufactureDateBCD','CapacityMiB','CapacityStatus','Ranks','DeviceWidth','BusWidth','Channels','JEDECSpeedMTs','TimingStatus','tCK_ps','tAA_ps','tRCD_ps','tRP_ps','tRAS_ps','tRC_ps','SupportedCL','BaseCRC','ModuleCRC','XMP','XMPHeaderCRC','EXPO','EXPOCRC','Notes','SourceTypes','Confidence','SourceCount','SourceEvidenceJSON')
 $pcols=@('SHA256','Generation','ModuleManufacturerID','PartNumber','CapacityMiB','Kind','ProfileNumber','Offset','SpeedMTs','tCK_ps','tAA_ps','tRCD_ps','tRP_ps','tRAS_ps','tRC_ps','Status','CRC','BaseCRC','EligibleForCandidateMatch','SourceTypes','Confidence')
 Save-Csv -rows $fingerprints.ToArray() -columns $fcols -path (Join-Path $DataRoot 'DB\SPD_FINGERPRINT_DB.csv')
 Save-Csv -rows $profiles.ToArray() -columns $pcols -path (Join-Path $DataRoot 'DB\RAM_PROFILE_INDEX.csv')
 Save-Csv -rows $run.ToArray() -columns @('FileName','SHA256','Duplicate','Status','Detail') -path (Join-Path $DataRoot 'SPD_Results\LAST_IMPORT.csv')
 Write-Host ('COU-EYE SPD: {0} input files; {1} unique fingerprints; {2} profiles.' -f $files.Count,$fingerprints.Count,$profiles.Count)
 if($files.Count -eq 0){Write-Host 'No binary inputs. Copy raw SPD files into SPD_INBOX and rerun.'}
 if($exitCode -ne 0){Write-Warning 'Some inputs require review. See SPD_Results\LAST_IMPORT.csv and REPORTS.'}
} catch {Write-Error -ErrorAction Continue $_; $exitCode=1}
finally {if($null -ne $lock){$lock.Dispose()}}
exit $exitCode
