$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'Run this comparison from the Dell installed Windows, not WinPE.'}
. (Join-Path $PSScriptRoot 'NvidiaQuery.ps1')
. (Join-Path $PSScriptRoot 'GpuRuntime.ps1')
$dir=Join-Path $root ('Logs\NvidiaWindows\'+[DateTimeOffset]::UtcNow.ToString('yyyyMMdd_HHmmss_fff'))
[void][IO.Directory]::CreateDirectory($dir)
$log=Join-Path $dir 'comparison.txt'
$lines=New-Object Collections.Generic.List[string]
$lines.Add('COU-EYE nvml2 Windows comparison. Diagnostic only; does not change inspection results.')
$lines.Add('UTC='+[DateTimeOffset]::UtcNow.ToString('o'))
$lines.Add((Get-WmiObject Win32_ComputerSystemProduct|Select-Object Vendor,Name,UUID|Format-List|Out-String))
$lines.Add((Get-WmiObject Win32_VideoController|Select-Object Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode|Format-List|Out-String))
$kernel=Get-ActiveNvidiaKernel
$lines.Add(($kernel|Format-List|Out-String))
$smi=Join-Path $env:SystemRoot 'System32\nvidia-smi.exe';$nvml=Join-Path $env:SystemRoot 'System32\nvml.dll'
if((Test-Path $smi) -and (Test-Path $nvml)){
 $pair=Test-NvidiaPair $smi $nvml
 $lines.Add(($pair|Format-List|Out-String))
 if($pair.Compatible -and (Test-NvidiaKernelVersion $kernel $nvml)){
  Add-GpuRuntimeDiagnostics $lines
  $reply=Invoke-NvidiaQueryRetry $smi '--query-gpu=name,memory.total,vbios_version,pci.bus_id,uuid,driver_version --format=csv,noheader,nounits' $lines
  $lines.Add('FINAL exit='+$reply.ExitCode+'; '+$reply.Text)
 }else{$lines.Add('Active kernel/runtime versions could not be matched.')}
}else{$lines.Add('NVIDIA runtime binaries absent from System32.')}
$lines|Set-Content -LiteralPath $log -Encoding UTF8
Write-Host ('Saved: '+$log)
