# Read-only acquisition. No firmware programming or driver state changes are used.
function Get-NvidiaRomAdapter([string]$Text,$Target,$Telemetry) {
    $found=@()
    foreach($line in ($Text -split '\r?\n')){
        if($line -match '(?i)<(\d+)>.*\(([0-9a-f]{4}),\s*([0-9a-f]{4}),\s*([0-9a-f]{4}),\s*([0-9a-f]{4})\).*S:([0-9a-f]{2,8}),\s*B:([0-9a-f]{2}),\s*D:([0-9a-f]{2}),\s*F:([0-9a-f]{1,2})(?![0-9a-f])'){
            $m=$Matches
            $function=[Convert]::ToUInt32($m[9],16);if($function -gt 7){continue}
            $bus=('{0:X8}:{1}:{2}.{3}' -f [Convert]::ToUInt32($m[6],16),$m[7],$m[8],$function)
            if($m[2] -eq $Target.VEN -and $m[3] -eq $Target.DEV -and $m[4] -eq $Target.SUBVENDOR_ID -and $m[5] -eq $Target.SUBSYS -and $bus -eq $Telemetry.BusID){$found+= [int]$m[1]}
        }
    }
    if($found.Count -ne 1){throw 'ROM_ADAPTER_AMBIGUOUS_OR_MISMATCH: exact PCI IDs and bus required'}
    return $found[0]
}
function Test-NvidiaRomImage([byte[]]$Bytes,$Target,$Telemetry,[string]$DbPath) {
    if($Bytes.Length -lt 512 -or $Bytes.Length -gt 16MB){throw 'ROM_SIZE_INVALID'}
    $offset=0;$images=0;$last=$false
    while(!$last){
        if($images -ge 64 -or $offset+26 -gt $Bytes.Length -or $Bytes[$offset] -ne 0x55 -or $Bytes[$offset+1] -ne 0xAA){throw 'ROM_HEADER_INVALID'}
        $pcir=$offset+[BitConverter]::ToUInt16($Bytes,$offset+24)
        if($pcir -lt $offset+26 -or $pcir+24 -gt $Bytes.Length -or [Text.Encoding]::ASCII.GetString($Bytes,$pcir,4) -ne 'PCIR'){throw 'ROM_PCIR_INVALID'}
        $ven='{0:X4}' -f [BitConverter]::ToUInt16($Bytes,$pcir+4)
        $dev='{0:X4}' -f [BitConverter]::ToUInt16($Bytes,$pcir+6)
        if($ven -ne $Target.VEN -or $dev -ne $Target.DEV){throw 'ROM_PCI_MISMATCH'}
        $length=512*[int][BitConverter]::ToUInt16($Bytes,$pcir+16)
        if($length -lt 512 -or $offset+$length -gt $Bytes.Length -or $pcir+24 -gt $offset+$length){throw 'ROM_TRUNCATED'}
        if($Bytes[$pcir+20] -eq 0){
            $sum=0;for($j=$offset;$j -lt $offset+$length;$j++){$sum=($sum+[int]$Bytes[$j]) -band 255}
            if($sum -ne 0){throw 'ROM_LEGACY_CHECKSUM_INVALID'}
        }
        $last=($Bytes[$pcir+21] -band 128) -ne 0
        $offset+=$length;$images++
    }
    # Version corroborates the acquired image; it is never used as a substitute for bytes.
    $ascii=[Text.Encoding]::ASCII.GetString($Bytes)
    $version=[string]$Telemetry.VBIOS
    if($version -notmatch '^[0-9A-Fa-f]{2}(\.[0-9A-Fa-f]{2}){4}$' -or $ascii.IndexOf($version,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw 'ROM_VBIOS_NOT_CORROBORATED'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}
    if(!(Test-Path -LiteralPath $DbPath)){throw 'ROM_REFERENCE_DB_UNAVAILABLE'}
    $matchesDb=@(Import-Csv -LiteralPath $DbPath -ErrorAction Stop | Where-Object {$_.SHA256 -eq $hash})
    foreach($entry in $matchesDb){if($entry.PciVendorID -ne $Target.VEN -or $entry.PciDeviceID -ne $Target.DEV){throw 'ROM_DB_IDENTITY_CONFLICT'}}
    [pscustomobject]@{SHA256=$hash;Size=$Bytes.Length;Images=$images;VBIOS=$version;DatabaseComparison=$(if($matchesDb.Count){'HASH_MATCH'}else{'NO_REFERENCE_MATCH'});Profiles=@($matchesDb.ProfileID)}
}
function Invoke-NvidiaRomRead($Root,$Target,$Telemetry,$TraceDirectory,$Log,
    [scriptblock]$Runner={param($e,$a) Invoke-NvidiaCommand $e $a 30}) {
    $ErrorActionPreference='Stop'
    $result=[ordered]@{Status='BLOCKED';Reason='ROM not acquired';Schema='COU-EYE_ROM_V1';Utc=[DateTimeOffset]::UtcNow.ToString('o');HWID=$Target.HWID;UUID=$Telemetry.UUID;BusID=$Telemetry.BusID;ToolSHA256='';ReadOnly=$true;File='';SHA256='';DatabaseComparison='';Index=$null}
    $manifest=''
    try{
        $dir=Join-Path $TraceDirectory ('rom-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $manifest=Join-Path $dir 'manifest.json'
        $exe=Join-Path $Root 'Tools\NvFlash\nvflash64.exe'
        $pin=Join-Path $Root 'Tools\NvFlash\SHA256.txt'
        if(!(Test-Path -LiteralPath $exe) -or !(Test-Path -LiteralPath $pin)){throw 'ROM_TOOL_MISSING: original nvflash64.exe and SHA256.txt are required'}
        $hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        if((Get-Content -LiteralPath $pin -Raw).Trim() -ne $hash){throw 'ROM_TOOL_HASH_MISMATCH'}
        $result.ToolSHA256=$hash
        $list=& $Runner $exe '--list'
        $list.Text | Set-Content (Join-Path $dir 'list-before.txt') -Encoding UTF8
        if($list.TimedOut -or $list.ExitCode -ne 0){throw ('ROM_LIST_FAILED exit='+$list.ExitCode)}
        $idx=Get-NvidiaRomAdapter $list.Text $Target $Telemetry;$result.Index=$idx
        $rom=Join-Path $dir 'adapter.rom';$confirm=Join-Path $dir 'adapter-confirm.rom'
        foreach($path in @($rom,$confirm)){
            # Arguments are fixed to the read/save operation, validated numeric index and new generated path.
            if($path.Contains('"')){throw 'ROM_PATH_INVALID'}
            $reply=& $Runner $exe ('--index='+$idx+' --save "'+$path+'"')
            $reply.Text | Set-Content ($path+'.log') -Encoding UTF8
            if($reply.TimedOut -or $reply.ExitCode -ne 0){throw ('ROM_SAVE_FAILED exit='+$reply.ExitCode)}
            if(!(Test-Path -LiteralPath $path)){throw 'ROM_OUTPUT_MISSING'}
            if((Get-Item -LiteralPath $path).Length -gt 16MB){throw 'ROM_SIZE_INVALID'}
        }
        if((Get-FileHash $rom).Hash -ne (Get-FileHash $confirm).Hash){throw 'ROM_REPEAT_READ_MISMATCH'}
        $after=& $Runner $exe '--list'
        $after.Text | Set-Content (Join-Path $dir 'list-after.txt') -Encoding UTF8
        if($after.TimedOut -or $after.ExitCode -ne 0 -or (Get-NvidiaRomAdapter $after.Text $Target $Telemetry) -ne $idx){throw 'ROM_ADAPTER_CHANGED'}
        $check=Test-NvidiaRomImage ([IO.File]::ReadAllBytes($rom)) $Target $Telemetry (Join-Path $Root 'DB\VBIOS_PROFILE_INDEX.csv')
        $result.File=$rom;$result.SHA256=$check.SHA256;$result.DatabaseComparison=$check.DatabaseComparison
        $check | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'validation.json') -Encoding UTF8
        $result.Status='VERIFIED';$result.Reason='Live ROM saved twice with identical SHA256; adapter PCI/BDF, ROM PCI IDs, structure, legacy checksum and VBIOS verified. DB='+$check.DatabaseComparison+'; File='+$rom+'; SHA256='+$check.SHA256
    }catch{$result.Reason=$_.Exception.Message}
    finally{
        if($manifest){try{$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8 -ErrorAction Stop}catch{$result.Status='BLOCKED';$result.Reason='ROM_MANIFEST_WRITE_FAILED: '+$_.Exception.Message}}
    }
    $Log.Add('ROM_DIRECT '+$result.Status+' '+$result.Reason)
    return [pscustomobject]$result
}
