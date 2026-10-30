function Invoke-NvmlDirectProbe([string]$Root,[string]$Nvml,[string]$TraceDirectory,$Log,[scriptblock]$Runner={param($e,$a) Invoke-NvidiaCommand $e $a 15}){
 try{
  $exe=Join-Path $Root 'Tools\NvmlProbe.exe'
  if(!(Test-Path -LiteralPath $exe)){throw 'NvmlProbe.exe missing'}
  [void][IO.Directory]::CreateDirectory($TraceDirectory)
  $output=Join-Path $TraceDirectory ('direct-nvml-'+[guid]::NewGuid().ToString('N')+'.txt')
  $Log.Add('DIRECT_PROBE_REQUEST DLL='+$Nvml+'; Output='+$output+'; TimeoutSeconds=15')
  $result=& $Runner $exe ('"'+$Nvml+'" "'+$output+'"')
  $Log.Add('DIRECT_PROBE_PROCESS exit='+$result.ExitCode+'; TimedOut='+$result.TimedOut+'; '+$result.Text)
  if(Test-Path -LiteralPath $output){
   $lines=@(Get-Content -LiteralPath $output);foreach($line in $lines){$Log.Add('DIRECT_PROBE '+$line)}
   if($result.ExitCode -eq 0 -and !$result.TimedOut){ConvertFrom-NvmlTelemetry $lines $Log}
  }
  else{$Log.Add('DIRECT_PROBE_NO_FILE: process did not produce milestones; inspect launch/policy/runtime error, not an NVML return code.')}
 }catch{$Log.Add('DIRECT_PROBE_UNAVAILABLE '+$_.Exception.Message)}
 # Rows are candidates only; caller must match exact target PCI identity.
}
function ConvertFrom-NvmlTelemetry($Lines,$Log){
 try{
  $rows=@();$complete=@($Lines|Where-Object {$_ -match ' TELEMETRY_COMPLETE count=\d+$'})
  if($complete.Count -ne 1){throw 'Missing or duplicate completion marker'}
  $expected=[int]([regex]::Match($complete[0],'count=(\d+)$').Groups[1].Value)
  foreach($line in $Lines){
   if($line -notmatch ' GPU_RECORD\t'){continue}
   $parts=($line -replace '^.*? GPU_RECORD\t','') -split "`t"
   if($parts.Count -ne 8){throw 'Invalid record fields'}
   $name=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[0]))
   $bytes=[uint64]$parts[1];$vbios=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))
   $uuid=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[3]))
   $bus=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[4]))
   $driver=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[7]))
   if(!$name.Trim() -or !$vbios.Trim() -or $uuid -notmatch '^GPU-[0-9a-fA-F-]+$' -or $bytes -eq 0 -or $bytes -eq [uint64]::MaxValue -or $bus -notmatch '^[0-9a-fA-F]{8}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$' -or $parts[5] -notmatch '^[0-9a-fA-F]{4}10DE$' -or $parts[6] -notmatch '^[0-9a-fA-F]{8}$' -or !$driver.Trim()){throw 'Incomplete or invalid telemetry'}
   $rows += [pscustomobject]@{Name=$name;MemoryMiB=[math]::Floor($bytes/1MB);MemoryGB=[math]::Round($bytes/1GB,2);VBIOS=$vbios.ToUpper();UUID=$uuid;BusID=$bus.ToUpper();VEN='10DE';DEV=$parts[5].Substring(0,4).ToUpper();SUBSYS=$parts[6].Substring(0,4).ToUpper();SUBVENDOR_ID=$parts[6].Substring(4,4).ToUpper();DriverVersion=$driver;Source='NVIDIA_NVML_DIRECT'}
  }
  if($rows.Count -ne $expected -or $expected -lt 1 -or @($rows.UUID|Select-Object -Unique).Count -ne $rows.Count -or @($rows.BusID|Select-Object -Unique).Count -ne $rows.Count){throw 'Count mismatch or duplicate identity'}
  return $rows
 }catch{$Log.Add('DIRECT_TELEMETRY_REJECTED '+$_.Exception.Message)}
}
function Select-NvmlTargetRow($Rows,$Target,$Targets,$Log){
 $matches=@($Rows|Where-Object {$_.VEN -eq $Target.VEN -and $_.DEV -eq $Target.DEV -and $_.SUBSYS -eq $Target.SUBSYS -and $_.SUBVENDOR_ID -eq $Target.SUBVENDOR_ID})
 $peers=@($Targets|Where-Object {$_.VEN -eq $Target.VEN -and $_.DEV -eq $Target.DEV -and $_.SUBSYS -eq $Target.SUBSYS -and $_.SUBVENDOR_ID -eq $Target.SUBVENDOR_ID})
 if($matches.Count -ne 1 -or $peers.Count -ne 1){$Log.Add('DIRECT_TARGET_REJECTED: missing/ambiguous exact VEN DEV SUBSYS SUBVENDOR match for '+$Target.InstanceID);return}
 $row=$matches[0]
 # Registry location, when exposed, independently checks bus/device/function.
 $location='';try{$location=(Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\'+$Target.InstanceID) -Name LocationInformation -ErrorAction Stop).LocationInformation}catch{}
 if($location -match '(?i)PCI bus (\d+), device (\d+), function (\d+)'){
  $suffix='{0:X2}:{1:X2}.{2}' -f [int]$Matches[1],[int]$Matches[2],[int]$Matches[3]
  if(!$row.BusID.EndsWith(':'+$suffix)){ $Log.Add('DIRECT_TARGET_REJECTED: PCI location mismatch');return }
  $Log.Add('DIRECT_TARGET_LOCATION_MATCH '+$row.BusID)
 }else{$Log.Add('DIRECT_TARGET_LOCATION_UNAVAILABLE: unique exact four-part PCI identity used; bus not independently verified.')}
 $Log.Add('DIRECT_TARGET_VERIFIED '+$Target.InstanceID+' UUID='+$row.UUID+' BusID='+$row.BusID)
 return $row
}
function Invoke-NvmlPrimaryProbe($Root,$Nvml,$TraceDirectory,$Log,[int[]]$Delays=@(0,3,8),[scriptblock]$Probe={param($r,$n,$t,$l) Invoke-NvmlDirectProbe $r $n $t $l}) {
    $attempt=0
    foreach($delay in $Delays){
        if($delay -gt 0){Start-Sleep -Seconds $delay};$attempt++
        $rows=@(& $Probe $Root $Nvml $TraceDirectory $Log)
        $Log.Add('DIRECT_PRIMARY_ATTEMPT '+$attempt+' rows='+$rows.Count)
        if($rows.Count -gt 0){return $rows}
    }
}
