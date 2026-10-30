function Resolve-RuntimeDisplayInf([string]$SourceInf,$Log,[string]$RuntimeRoot=$env:SystemRoot){
 # Reuse an identical offline-injected package instead of reimporting installed Windows files.
 try{
  $package=Split-Path (Split-Path $SourceInf -Parent) -Leaf
  $candidate=Join-Path (Join-Path (Join-Path $RuntimeRoot 'System32\DriverStore\FileRepository') $package) (Split-Path $SourceInf -Leaf)
  if((Test-Path -LiteralPath $candidate) -and (Get-FileHash -LiteralPath $candidate).Hash -eq (Get-FileHash -LiteralPath $SourceInf).Hash){
   $Log.Add('DRIVER_LOAD_SOURCE=INJECTED_RUNTIME; '+$candidate);return $candidate
  }
 }catch{$Log.Add('Runtime INF validation failed: '+$_.Exception.Message)}
 $Log.Add('DRIVER_LOAD_SOURCE=INSTALLED_WINDOWS_FALLBACK; '+$SourceInf);return $SourceInf
}
function Save-GpuInitializationTrace([string]$Directory,[string]$Phase,$Log){
 try{
  [void][IO.Directory]::CreateDirectory($Directory)
  $stamp=[DateTimeOffset]::UtcNow.ToString('o')
  $devices=@(Get-WmiObject Win32_PnPEntity -ErrorAction Stop | Where-Object {$_.DeviceID -match '^PCI\\VEN_(10DE|8086)'})
  [pscustomobject]@{Utc=$stamp;Phase=$Phase;Devices=@($devices|Select-Object Name,DeviceID,PNPClass,ConfigManagerErrorCode,Status,Service)}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Directory ($Phase+'.devices.json')) -Encoding UTF8
  $setup=Join-Path $env:SystemRoot 'INF\setupapi.dev.log'
  if(Test-Path -LiteralPath $setup){Copy-Item -LiteralPath $setup -Destination (Join-Path $Directory ($Phase+'.setupapi.dev.log')) -Force}
  try{
   Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddMinutes(-30)} -MaxEvents 300 -ErrorAction Stop |
    Where-Object {$_.ProviderName -match 'nvlddmkm|Kernel-PnP|UserPnp|Display|Service Control Manager'} |
    Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Directory ($Phase+'.events.json')) -Encoding UTF8
  }catch{$Log.Add('EVENT_TRACE_UNAVAILABLE '+$Phase+': '+$_.Exception.Message)}
  $Log.Add('INITIALIZATION_TRACE '+$Phase+' UTC='+$stamp+' Directory='+$Directory)
 }catch{$Log.Add('INITIALIZATION_TRACE_FAILED '+$Phase+': '+$_.Exception.Message)}
}
function Get-ActiveNvidiaPackagePair($Kernel,$Log){
 # Resolve only beside the running kernel, never from another Windows installation.
 try{
  if(!$Kernel){throw 'No active kernel'}
  $dir=Split-Path -Parent $Kernel.Path
  $runtimeRoot=[IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')+'\'
  if(!([IO.Path]::GetFullPath($dir)+'\').StartsWith($runtimeRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Package is outside running Windows'}
  $smi=Join-Path $dir 'nvidia-smi.exe';$nvml=Join-Path $dir 'nvml.dll';$loader=Join-Path $dir 'nvml_loader.dll'
  if(!(Test-Path -LiteralPath $nvml)){throw 'Active package NVML missing'}
  
  if(!(Test-NvidiaKernelVersion $Kernel $nvml)){throw 'Active package version mismatch'}
  $hash=(Get-FileHash -LiteralPath $nvml).Hash
  if((Test-Path -LiteralPath $loader) -and $hash -eq (Get-FileHash -LiteralPath $loader).Hash){throw 'Package nvml.dll is the loader, not a distinct implementation'}
  $Log.Add('ACTIVE_PACKAGE_PAIR selected: SMI='+$smi+'; NVML='+$nvml+'; NVML_SHA256='+$hash)
  return [pscustomobject]@{Smi=$smi;Nvml=$nvml;Source='ACTIVE_KERNEL_PACKAGE_PAIR'}
 }catch{$Log.Add('ACTIVE_PACKAGE_PAIR unavailable: '+$_.Exception.Message);return $null}
}
function Get-ActiveNvidiaKernel {
 try{
  $driver=Get-WmiObject Win32_SystemDriver -Filter "Name='nvlddmkm'" -ErrorAction Stop
  if(!$driver -or !$driver.Started){return $null}
  $path=[Environment]::ExpandEnvironmentVariables(([string]$driver.PathName).Trim('"'))
  if($path.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)){$path=Join-Path $env:SystemRoot $path.Substring(12)}
  if($path.StartsWith('\??\')){$path=$path.Substring(4)}
  $resolved=[IO.Path]::GetFullPath($path)
  if(!$resolved.StartsWith(([IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){return $null}
  $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($resolved)
  [pscustomobject]@{Path=$resolved;Version=$v.FileVersion;Build=$v.FileBuildPart;Private=$v.FilePrivatePart;Hash=(Get-FileHash -LiteralPath $resolved).Hash}
 }catch{return $null}
}
function Test-NvidiaKernelVersion($Kernel,[string]$Nvml){
 if(!$Kernel){return $false}
 try{$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($Nvml);return ($v.FileBuildPart -eq $Kernel.Build -and $v.FilePrivatePart -eq $Kernel.Private)}catch{return $false}
}
function Get-ReadyDisplayDevice([string]$InstanceID){
 if(!$InstanceID){return $false}
 try{
  $item=Get-WmiObject Win32_PnPEntity -ErrorAction Stop | Where-Object DeviceID -eq $InstanceID | Select-Object -First 1
  return ($item -and $null -ne $item.ConfigManagerErrorCode -and [int]$item.ConfigManagerErrorCode -eq 0 -and $item.PNPClass -eq 'Display')
 }catch{return $false}
}
function Add-GpuRuntimeDiagnostics($Log){
 foreach($class in @('Win32_VideoController','Win32_SystemDriver')){
  try{
   $items=Get-WmiObject $class -ErrorAction Stop
   if($class -eq 'Win32_SystemDriver'){$items=@($items|Where-Object Name -in @('nvlddmkm','igfx','igfxn','dxgkrnl','BasicDisplay','BasicRender'))}
   foreach($item in $items){$Log.Add('RUNTIME '+($item|Select-Object Name,PNPDeviceID,DriverVersion,State,Started,Status,ConfigManagerErrorCode,PathName|ConvertTo-Json -Compress))}
  }catch{$Log.Add('Runtime diagnostic unavailable: '+$class+'; '+$_.Exception.Message)}
 }
 $setup=Join-Path $env:SystemRoot 'INF\setupapi.dev.log'
 if(Test-Path $setup){
  $Log.Add('SETUPAPI filtered recent lines (diagnostic only):')
  Get-Content -LiteralPath $setup -Tail 300 -ErrorAction SilentlyContinue|Where-Object {$_ -match '(?i)nvdm|nvlddmkm|iigd|!!!|0xC0000493'}|ForEach-Object{$Log.Add([string]$_)}
 }
}
