param([string]$TempRoot='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if(-not ('CouI.SpdEngine' -as [type])){Add-Type -Path (Join-Path $root 'Tools\SpdEngine.dll')}
$script:checks=0
function Assert($ok,$message){if(-not $ok){throw ('FAIL: '+$message)};$script:checks++;Write-Host ('PASS: '+$message)}
function U16([byte[]]$b,[int]$p,[int]$value){$b[$p]=$value-band 255;$b[$p+1]=($value-shr 8)-band 255}
# Independent reference CRC, deliberately not calling the engine under test.
function CRC([byte[]]$b,[int]$start,[int]$length){
 $v=0
 for($i=$start;$i-lt ($start+$length);$i++){
  for($j=7;$j-ge 0;$j--){$bit=(($v-shr 15)-bxor ($b[$i]-shr $j))-band 1;$v=($v-shl 1)-band 65535;if($bit){$v=$v-bxor 0x1021}}
 }
 return $v
}
function FixCRC([byte[]]$b,[int]$start,[int]$length){U16 $b ($start+$length) (CRC $b $start $length)}
function TextBytes([byte[]]$b,[int]$p,[string]$s){[Array]::Copy([Text.Encoding]::ASCII.GetBytes($s),0,$b,$p,$s.Length)}
function DDR4 {
 $b=New-Object byte[] 512;$b[0]=0x23;$b[1]=0x11;$b[2]=12;$b[3]=2;$b[4]=5;$b[12]=1;$b[13]=3
 $b[18]=7;$b[125]=214;$b[24]=112;$b[25]=112;$b[26]=112;$b[27]=17;$b[28]=0;$b[29]=112;$b[20]=128
 $b[320]=128;$b[321]=206;$b[323]=0x26;$b[324]=0x40;$b[325]=1;$b[328]=4;TextBytes $b 329 'SYNTHETIC-DDR4-8GB';$b[350]=128;$b[351]=44
 $b[384]=12;$b[385]=74;$b[386]=1;$b[387]=32;$p=393;$b[$p+3]=5;$b[$p+8]=80;$b[$p+9]=80;$b[$p+10]=80;$b[$p+11]=17;$b[$p+12]=0;$b[$p+13]=80
 FixCRC $b 0 126;FixCRC $b 128 126
 return ,$b
}
function DDR5 {
 $b=New-Object byte[] 1024;$b[0]=0x30;$b[1]=0x10;$b[2]=18;$b[3]=5;$b[4]=4;$b[6]=32;$b[235]=0x22
 U16 $b 20 400;U16 $b 30 14000;U16 $b 32 14000;U16 $b 34 14000;U16 $b 36 32000;U16 $b 38 46000;$b[25]=4
 $b[512]=128;$b[513]=44;$b[517]=18;$b[520]=52;TextBytes $b 521 'SYNTHETIC-DDR5-16GB';$b[552]=128;$b[553]=173
 $b[640]=12;$b[641]=74;$b[642]=48;$b[643]=1
 $p=704;U16 $b ($p+5) 320;U16 $b ($p+13) 10000;U16 $b ($p+15) 12000;U16 $b ($p+17) 12000;U16 $b ($p+19) 28000;U16 $b ($p+21) 40000
 FixCRC $b 640 62;FixCRC $b 704 62
 TextBytes $b 832 'EXPO';$b[836]=16;$b[837]=1;$p=842
 U16 $b ($p+4) 300;U16 $b ($p+6) 10000;U16 $b ($p+8) 12000;U16 $b ($p+10) 12000;U16 $b ($p+12) 28000;U16 $b ($p+14) 40000
 FixCRC $b 832 126;FixCRC $b 0 510
 return ,$b
}
try{
 Assert (([CouI.SpdEngine]::CRC16([Text.Encoding]::ASCII.GetBytes('123456789'),0,9))-eq 0x31c3) 'CRC-16/XMODEM published check vector'
 Assert (([CouI.SpdEngine]::Hash([byte[]]@()))-eq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'SHA256 empty-file known vector'
 $a=DDR4;$b=DDR5;$r=[CouI.SpdEngine]::Parse($a);$s=[CouI.SpdEngine]::Parse($b)
 Assert ($r.Status-eq 'PARSED' -and $r.BaseCRC-eq 'PASS' -and $r.ModuleCRC-eq 'PASS') 'DDR4 CRC regions and parse status'
 Assert ($r.CapacityMiB-eq 8192 -and $r.ModuleType-eq 'UDIMM') 'DDR4 8 GiB geometry'
 Assert ($r.tCK_ps-eq 833 -and $r.JEDECSpeedMTs-eq 2400.96) 'DDR4 signed fine timebase'
 Assert ($r.ModuleManufacturerID-eq '80CE' -and $r.ModuleManufacturer-eq 'Samsung' -and $r.Serial-eq '01000004') 'DDR4 identity offsets and raw byte order'
 Assert ($r.PartNumber-eq 'SYNTHETIC-DDR4-8GB' -and $r.DRAMManufacturer-eq 'Micron') 'DDR4 part number and DRAM manufacturer'
 $xp=@($r.Profiles|Where-Object {$_.Kind-eq 'XMP_2.0'})
 Assert ($xp.Count-eq 1 -and $xp[0].SpeedMTs-eq 3200 -and $xp[0].CRC-eq 'NOT_DEFINED') 'DDR4 XMP2 enabled profile and no invented CRC'
 Assert ($s.Status-eq 'PARSED' -and $s.CapacityMiB-eq 16384 -and $s.ModuleType-eq 'CUDIMM') 'DDR5 16 GiB two-subchannel geometry'
 Assert ($s.ModuleManufacturer-eq 'Micron' -and $s.DRAMManufacturer-eq 'SK hynix' -and $s.Serial-eq '12000034') 'DDR5 identity offsets'
 Assert ($s.JEDECSpeedMTs-eq 5000 -and $s.tRAS_ps-eq 32000 -and $s.SupportedCL-eq '40') 'DDR5 JEDEC timing and CL bitmap'
 $xp=@($s.Profiles|Where-Object {$_.Kind-eq 'XMP_3.0'});$ep=@($s.Profiles|Where-Object {$_.Kind-eq 'EXPO_1.0'})
 Assert ($xp.Count-eq 1 -and $xp[0].SpeedMTs-eq 6250 -and $xp[0].CRC-eq 'PASS' -and $s.XMPHeaderCRC-eq 'PASS') 'DDR5 XMP3 profile and header CRC'
 Assert ($ep.Count-eq 1 -and $ep[0].SpeedMTs-eq 6666.67 -and $ep[0].CRC-eq 'PASS') 'DDR5 EXPO profile and section CRC'
 $c=$b.Clone();$c[20]=$c[20]-bxor 1;Assert (([CouI.SpdEngine]::Parse($c)).Status-eq 'CRC_FAIL') 'Corrupt base is retained with CRC_FAIL'
 $c=$b.Clone();$c[710]=$c[710]-bxor 1;$z=[CouI.SpdEngine]::Parse($c)
 Assert (@($z.Profiles|Where-Object {$_.Kind-eq 'XMP_3.0'})[0].Status-eq 'CRC_FAIL') 'Profile CRC failure is local to profile'
 $c=$b.Clone();$c[234]=64;FixCRC $c 0 510;$z=[CouI.SpdEngine]::Parse($c)
 Assert ($null-eq $z.CapacityMiB -and $z.CapacityStatus-eq 'UNSUPPORTED_GEOMETRY') 'Asymmetric geometry never gets guessed capacity'
 $c=$b.Clone();$c[4]=36;FixCRC $c 0 510
 Assert ($null-eq ([CouI.SpdEngine]::Parse($c)).CapacityMiB) 'Stacked DDR5 capacity explicitly unsupported'
 $c=$a.Clone();$c[17]=1;FixCRC $c 0 126
 Assert ($null-eq ([CouI.SpdEngine]::Parse($c)).JEDECSpeedMTs) 'Reserved timebase does not produce JEDEC speed'
 $c=$b.Clone();$c[1]=0x20
 Assert (([CouI.SpdEngine]::Parse($c)).Status-eq 'UNSUPPORTED_REVISION') 'Unknown major revision is not decoded'
 foreach($fixture in @($a,$b)){
  for($n=0;$n-lt $fixture.Length;$n++){$short=New-Object byte[] $n;[Array]::Copy($fixture,$short,$n);$null=[CouI.SpdEngine]::Parse($short)}
 }
 Assert $true 'Every truncation length of DDR4 and DDR5 parses without exception'
 $rand=New-Object Random 1234
 for($i=0;$i-lt 300;$i++){$f=New-Object byte[] ($rand.Next(0,1200));$rand.NextBytes($f);if($f.Length-ge 3){$f[2]=@(12,18)[$i%2]};$null=[CouI.SpdEngine]::Parse($f)}
 Assert $true '300 deterministic malformed input cases do not crash'
 if(-not $TempRoot){$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('COUI-SPD-'+[Guid]::NewGuid().ToString('N'))}
 $TempRoot=[IO.Path]::GetFullPath($TempRoot);$inbox=Join-Path $TempRoot 'input with spaces';[void][IO.Directory]::CreateDirectory($inbox)
 [IO.File]::WriteAllBytes((Join-Path $inbox 'a.spd'),$a);[IO.File]::WriteAllBytes((Join-Path $inbox 'duplicate.bin'),$a);[IO.File]::WriteAllBytes((Join-Path $inbox 'b.spd'),$b)
 $manifest=Join-Path $inbox 'SOURCES.csv'
 [pscustomobject]@{SHA256=[CouI.SpdEngine]::Hash($a);SourceType='REFERENCE_SPD';SourceReference='SYNTHETIC TEST ONLY';VerifiedBy='Self-test'}|Export-Csv $manifest -NoTypeInformation
 $ps=(Get-Process -Id $PID).Path
 & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Parse_SPD.ps1') -InputPath $inbox -DataRoot $TempRoot -SourceManifest $manifest
 Assert ($LASTEXITCODE-eq 0) 'Importer succeeds from paths with spaces'
 $dbPath=Join-Path $TempRoot 'DB\SPD_FINGERPRINT_DB.csv';$piPath=Join-Path $TempRoot 'DB\RAM_PROFILE_INDEX.csv'
 $db=@(Import-Csv $dbPath);$pi=@(Import-Csv $piPath)
 Assert ($db.Count-eq 2 -and $pi.Count-eq 5) 'SHA256 deduplication and JEDEC/XMP/EXPO profile counts'
 Assert (@($db|Where-Object {$_.Generation-eq 'DDR4'})[0].SourceCount-eq '2') 'Duplicate filename sources retained as evidence'
 Assert (@($db|Where-Object {$_.Generation-eq 'DDR4'})[0].Confidence-eq 'REFERENCE_CLAIMED') 'Source claims separate from CRC confidence'
 Assert (@($db|Where-Object {$_.Generation-eq 'DDR5'})[0].Confidence-eq 'UNVERIFIED') 'No automatic trust upgrade for valid CRC'
 $before=(Get-FileHash $dbPath).Hash
 & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Parse_SPD.ps1') -InputPath $inbox -DataRoot $TempRoot -SourceManifest $manifest
 Assert ($LASTEXITCODE-eq 0 -and (Get-FileHash $dbPath).Hash-eq $before) 'Repeated import is byte-for-byte idempotent'
 $c=$a.Clone();$c[325]=2;[IO.File]::WriteAllBytes((Join-Path $inbox 'different-serial.spd'),$c)
 [IO.File]::WriteAllBytes((Join-Path $inbox 'empty.bin'),[byte[]]@())
 & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Parse_SPD.ps1') -InputPath $inbox -DataRoot $TempRoot -SourceManifest $manifest
 Assert ($LASTEXITCODE-eq 2) 'Partial/rejected input returns review exit code 2'
 Assert (@(Import-Csv $dbPath).Count-eq 4) 'Different serial remains distinct; empty evidence is retained'
 $bad=@(Get-ChildItem (Join-Path $TempRoot 'SPD_Results\RAW') -Filter '*.bin')|Select-Object -First 1
 [IO.File]::WriteAllBytes($bad.FullName,[byte[]]@(1,2,3))
 $ErrorActionPreference='Continue'
 & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Parse_SPD.ps1') -InputPath $inbox -DataRoot $TempRoot -SourceManifest $manifest 2>$null
 $ErrorActionPreference='Stop'
 Assert ($LASTEXITCODE-eq 1) 'Archive tampering is detected before database replacement'
 Write-Host ('SPD SELF TEST: PASS ({0} assertions). Test evidence: {1}' -f $script:checks,$TempRoot)
 exit 0
}catch{Write-Error -ErrorAction Continue $_;exit 1}
