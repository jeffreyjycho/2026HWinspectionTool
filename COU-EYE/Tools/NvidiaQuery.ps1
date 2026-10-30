function Invoke-NvidiaCommand([string]$Executable,[string]$Arguments,[int]$TimeoutSeconds=15) {
    $p=New-Object Diagnostics.Process
    $p.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $p.StartInfo.FileName=$Executable;$p.StartInfo.Arguments=$Arguments
    $p.StartInfo.WorkingDirectory=Split-Path -Parent $Executable
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    $modules=New-Object 'Collections.Generic.HashSet[string]'
    $watch=[Diagnostics.Stopwatch]::StartNew();$moduleError=''
    try{
        [void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        while(!$p.HasExited -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
            try{$p.Refresh();foreach($m in $p.Modules){[void]$modules.Add($m.FileName)}}catch{$moduleError=$_.Exception.Message}
            [void]$p.WaitForExit(10)
        }
        if(!$p.HasExited){
            try{$p.Kill();[void]$p.WaitForExit(2000)}catch{}
            return [pscustomobject]@{ExitCode=124;Text='NVIDIA query timed out';TimedOut=$true;Modules=@($modules);ModuleError=$moduleError}
        }
        return [pscustomobject]@{ExitCode=$p.ExitCode;Text=($stdout.Result+"`n"+$stderr.Result).Trim();TimedOut=$false;Modules=@($modules);ModuleError=$moduleError}
    }catch{$cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException};return [pscustomobject]@{ExitCode=125;Text=('PROCESS_START_OR_READ_ERROR NativeErrorCode='+$cause.NativeErrorCode+'; '+$cause.Message);TimedOut=$false}}
    finally{$p.Dispose()}
}
function Invoke-NvidiaQueryRetry([string]$Executable,[string]$Arguments,$Log,[scriptblock]$Runner={param($e,$a) Invoke-NvidiaCommand $e $a},[int[]]$Delays=@(0,3,8)) {
    $attempt=0
    foreach($delay in $Delays){
        if($delay -gt 0){Start-Sleep -Seconds $delay};$attempt++
        $result=& $Runner $Executable $Arguments
        $Log.Add(('NVML attempt {0}: exit={1}; {2}' -f $attempt,$result.ExitCode,$result.Text))
        foreach($module in $result.Modules){$Log.Add('LOADED_MODULE attempt='+$attempt+'; '+$module)}
        if(!@($result.Modules|Where-Object {$_ -match '(?i)\\nvml[^\\]*\.dll$'}).Count){$Log.Add('NVML_MODULE_NOT_OBSERVED: short-lived process or module enumeration unavailable; not proof of DLL absence.')}
        if($result.ModuleError){$Log.Add('MODULE_TRACE_NOTE: '+$result.ModuleError)}
        if($result.ExitCode -eq 0 -or $result.TimedOut){break}
    }
    return $result
}
function Test-NvidiaPair([string]$Smi,[string]$Nvml) {
    $a=[Diagnostics.FileVersionInfo]::GetVersionInfo($Smi)
    $b=[Diagnostics.FileVersionInfo]::GetVersionInfo($Nvml)
    $av='{0}.{1}.{2}.{3}' -f $a.FileMajorPart,$a.FileMinorPart,$a.FileBuildPart,$a.FilePrivatePart
    $bv='{0}.{1}.{2}.{3}' -f $b.FileMajorPart,$b.FileMinorPart,$b.FileBuildPart,$b.FilePrivatePart
    return [pscustomobject]@{Compatible=($av -eq $bv -and $av -ne '0.0.0.0');SmiVersion=$av;NvmlVersion=$bv}
}
