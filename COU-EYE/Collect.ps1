param([Alias('WaybillNumber')][string]$AssetID='', [string]$Coucode='', [string]$ProgressFile='', [ValidateSet('CoreSafe','DeepHeadless')][string]$GpuScanMode='CoreSafe')

# Keep scanner and identifier text in PowerShell; never interpolate it into CMD.
if ([string]::IsNullOrWhiteSpace($AssetID)) { $AssetID = Read-Host 'Enter waybill number' }
$AssetID = $AssetID.Trim()
if (!$AssetID) { $AssetID = 'NO_ASSET_ID' }
while ([string]::IsNullOrWhiteSpace($Coucode)) {
    $Coucode = Read-Host 'Enter inspector Coucode (required)'
    if ([string]::IsNullOrWhiteSpace($Coucode)) { Write-Host '[INPUT] Coucode is required.' }
}
$Coucode = $Coucode.Trim()

$ErrorActionPreference = "SilentlyContinue"
$Version = "1.3.11"
function Set-InspectionProgress([string]$stage) {
 if($ProgressFile){
  $value=[pscustomobject]@{State='Running';Stage=$stage}
  $value|Export-Clixml -LiteralPath ($ProgressFile+'.tmp') -Encoding UTF8 -ErrorAction Stop
  Move-Item -LiteralPath ($ProgressFile+'.tmp') -Destination $ProgressFile -Force -ErrorAction Stop
 }
}
Set-InspectionProgress '장비 정보 수집 준비'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'Tools\NvidiaQuery.ps1')
. (Join-Path $Root 'Tools\GpuRuntime.ps1')
. (Join-Path $Root 'Tools\NvmlProbe.ps1')
. (Join-Path $Root 'Tools\NvidiaRom.ps1')
. (Join-Path $Root 'Tools\ManufacturerIdentity.ps1')
$R = Join-Path $Root "Results"
$L = Join-Path $Root "Logs"
$D = Join-Path $Root "DB"
New-Item -ItemType Directory -Force -Path $R,$L | Out-Null

function S($v) { if ($null -eq $v) { "" } else { ([string]$v).Trim() } }
function GB($v) { if ($null -eq $v) { 0 } else { [math]::Round(([double]$v / 1GB),2) } }
function UpperHex($v) { if ($v) { ([string]$v).Trim().ToUpper() } else { "" } }

function ByteHash([byte[]]$bytes) {
    if ($null -eq $bytes) { return "" }
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","") } finally { $sha.Dispose() }
}
function TextHash([string]$text) {
    if ($null -eq $text) { return "" }
    return ByteHash ([Text.Encoding]::UTF8.GetBytes($text))
}
# WinPE may keep a stale/non-Korean local timezone while its UTC clock is correct.
# Always derive audit timestamps from UTC and convert them to the fixed Korea offset.
function Get-KstWallClock {
    return [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9))
}
function KstString([string]$format='o') {
    return (Get-KstWallClock).ToString($format,[Globalization.CultureInfo]::InvariantCulture)
}
function MemoryTypeName($code) {
    $n=0; [int]::TryParse((S $code),[ref]$n) | Out-Null
    switch ($n) { 20 {"DDR"} 21 {"DDR2"} 24 {"DDR3"} 26 {"DDR4"} 30 {"LPDDR4"} 34 {"DDR5"} 35 {"LPDDR5"} default { if($n){"SMBIOS_TYPE_$n"}else{"Unknown"} } }
}
function FormFactorName($code) {
    $n=0; [int]::TryParse((S $code),[ref]$n) | Out-Null
    switch ($n) { 8 {"DIMM"} 12 {"SODIMM"} 13 {"SRIMM"} 15 {"FB-DIMM"} 16 {"Die"} default { if($n){"FORM_$n"}else{"Unknown"} } }
}
function BusTypeName($code) {
    $n=0; [int]::TryParse((S $code),[ref]$n) | Out-Null
    switch ($n) { 3 {"ATA"} 7 {"USB"} 8 {"RAID"} 10 {"SAS"} 11 {"SATA"} 17 {"NVMe"} 18 {"SCM"} 19 {"UFS"} default { if($n){"BUS_$n"}else{"Unknown"} } }
}
function Decode-CpuidSignature([string]$processorId) {
    $id=(S $processorId).Replace(' ','').ToUpper()
    if($id -notmatch '^[0-9A-F]+$' -or $id.Length -lt 8){ return $null }
    $sigHex=$id.Substring($id.Length-8,8)
    try { $eax=[Convert]::ToUInt32($sigHex,16) } catch { return $null }
    $stepping=[int]($eax -band 0xF)
    $baseModel=[int](($eax -shr 4) -band 0xF)
    $baseFamily=[int](($eax -shr 8) -band 0xF)
    $extModel=[int](($eax -shr 16) -band 0xF)
    $extFamily=[int](($eax -shr 20) -band 0xFF)
    $family=if($baseFamily -eq 0xF){$baseFamily+$extFamily}else{$baseFamily}
    $model=if($baseFamily -in @(0x6,0xF)){($extModel -shl 4)+$baseModel}else{$baseModel}
    [pscustomobject]@{SignatureHex=$sigHex;Family=$family;Model=$model;Stepping=$stepping;BaseFamily=$baseFamily;BaseModel=$baseModel;ExtendedFamily=$extFamily;ExtendedModel=$extModel}
}
function Get-StorageProtocol($disk,$deepMatch) {
    $model=((S $disk.Model)+' '+(S $disk.Caption)+' '+(S $disk.PNPDeviceID)).ToUpper()
    $iface=(S $disk.InterfaceType).ToUpper()
    $bus=if($deepMatch){(BusTypeName $deepMatch.BusType).ToUpper()}else{$iface}
    if($model -match '\bNVME\b|NVME\\|VEN_NVME'){ return 'NVMe' }
    if($iface -eq 'USB' -or $bus -eq 'USB'){ return 'USB' }
    if($iface -eq 'IDE' -or $iface -eq 'SATA' -or $bus -eq 'SATA' -or $bus -eq 'ATA'){ return 'SATA/ATA' }
    if($bus -eq 'RAID'){ return 'Storage device behind RAID/RST controller' }
    if($bus -eq 'SAS'){ return 'SAS/SCSI' }
    return $(if($iface){$iface}else{$bus})
}
function ContainsCI([string]$hay,[string]$needle) {
    if (!(S $needle)) { return $true }
    if (!(S $hay)) { return $false }
    return $hay.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0
}
function Get-GpuType([string]$ven,[string]$cc,[string]$pciName,[string]$desc) {
    $n=((S $pciName)+" "+(S $desc))
    if ($ven -eq "8086" -and $n -match '(?i)Core Ultra.*Arc|Arc.*(?:130V|140V|130T|140T)|Meteor Lake|Lunar Lake') { return "Integrated" }
    if ((S $cc).StartsWith("0302")) { return "Discrete" }
    if ($ven -eq "10DE") { return "Discrete" }
    if ($ven -eq "8086") {
        if ($n -match '(?i)\bArc\b|Battlemage|Alchemist|DG2') { return "Discrete" }
        return "Integrated"
    }
    if ($ven -eq "1002") {
        if ($n -match '(?i)Radeon\s+RX|Radeon\s+PRO|Radeon\s+Pro|Instinct') { return "Discrete" }
        if ($n -match '(?i)Graphics|APU') { return "Integrated" }
        return "Display"
    }
    if ((S $cc).StartsWith("0300")) { return "Discrete" }
    return "Display"
}
function CapacityApproxMatch($expected,$actual) {
    $e=0.0;$a=0.0
    if(![double]::TryParse((S $expected),[ref]$e)){return $true}
    if(![double]::TryParse((S $actual),[ref]$a)){return $false}
    if($e -le 0){return $true}
    $ratio=$a/$e
    return ($ratio -ge 0.90 -and $ratio -le 1.05)
}

# -----------------------------------------------------------------------------
# PCI.IDS DATABASE
# The bundled pci.ids is the primary PCI vendor/device/subsystem name source.
# GPU_ID_DB.csv is retained only as a fallback.
# -----------------------------------------------------------------------------
$PciVendor = @{}
$PciDevice = @{}
$PciSubsystem = @{}
$pciIdsPath = Join-Path $D "pci.ids"
if (Test-Path $pciIdsPath) {
    $curVendor = ""
    $curDevice = ""
    foreach ($line in [System.IO.File]::ReadLines($pciIdsPath)) {
        if ($line -match '^C\s') { break }
        if ($line -match '^\t\t([0-9A-Fa-f]{4})\s+([0-9A-Fa-f]{4})\s{2}(.+)$') {
            if ($curVendor -and $curDevice) {
                $sv = $matches[1].ToUpper(); $sd = $matches[2].ToUpper()
                $PciSubsystem["${curVendor}:${curDevice}:${sv}:${sd}"] = $matches[3].Trim()
            }
        } elseif ($line -match '^\t([0-9A-Fa-f]{4})\s{2}(.+)$') {
            if ($curVendor) {
                $curDevice = $matches[1].ToUpper()
                $PciDevice["${curVendor}:${curDevice}"] = $matches[2].Trim()
            }
        } elseif ($line -match '^([0-9A-Fa-f]{4})\s{2}(.+)$') {
            $curVendor = $matches[1].ToUpper()
            $curDevice = ""
            $PciVendor[$curVendor] = $matches[2].Trim()
        }
    }
}

$FallbackGpu = @{}
$fallbackDb = Join-Path $D "GPU_ID_DB.csv"
if (Test-Path $fallbackDb) {
    Import-Csv $fallbackDb | ForEach-Object {
        $FallbackGpu[(UpperHex $_.VEN) + ":" + (UpperHex $_.DEV)] = $_.Model
    }
}

function PciVendorName([string]$ven) {
    $ven = UpperHex $ven
    if ($PciVendor.ContainsKey($ven)) { return $PciVendor[$ven] }
    if ($ven) { return "PCI Vendor $ven" }
    return ""
}
function PciDeviceName([string]$ven,[string]$dev) {
    $ven=UpperHex $ven; $dev=UpperHex $dev; $k="${ven}:${dev}"
    if ($PciDevice.ContainsKey($k)) { return $PciDevice[$k] }
    if ($FallbackGpu.ContainsKey($k)) { return $FallbackGpu[$k] }
    return "Unknown PCI device (VEN_${ven}&DEV_${dev})"
}
function PciSubsystemName([string]$ven,[string]$dev,[string]$sv,[string]$sd) {
    $ven=UpperHex $ven; $dev=UpperHex $dev; $sv=UpperHex $sv; $sd=UpperHex $sd
    $k="${ven}:${dev}:${sv}:${sd}"
    if ($PciSubsystem.ContainsKey($k)) { return $PciSubsystem[$k] }
    return ""
}
function FriendlyGpuName([string]$pciName,[string]$ven,[string]$dev) {
    if ($pciName -match '\[([^\]]*(?:GeForce|Radeon|Graphics|Arc)[^\]]*)\]') { return $matches[1].Trim() }
    if ($pciName -match '\[(GeForce[^\]]+)\]') { return $matches[1].Trim() }
    if ($FallbackGpu.ContainsKey("${ven}:${dev}")) { return $FallbackGpu["${ven}:${dev}"] }
    return $pciName
}

# Reference DBs. These are evidence/candidate sources, not automatic retail-SKU proof.
$VbiosProfiles = @()
$vbiosDbPath = Join-Path $D "VBIOS_FINGERPRINT_DB.csv"
if (Test-Path $vbiosDbPath) { $VbiosProfiles = @(Import-Csv $vbiosDbPath) }
$VbiosHashProfiles = @()
$vbiosHashPath = Join-Path $D "VBIOS_PROFILE_INDEX.csv"
if (Test-Path $vbiosHashPath) { $VbiosHashProfiles = @(Import-Csv $vbiosHashPath) }
$VbiosRuntime = @()
$vbiosRuntimePath = Join-Path $D "VBIOS_RUNTIME_INDEX.csv"
if (Test-Path $vbiosRuntimePath) { $VbiosRuntime = @(Import-Csv $vbiosRuntimePath) }
$PciProfileIndex = @()
$pciProfilePath = Join-Path $D "PCI_DEVICE_PROFILE_INDEX.csv"
if (Test-Path $pciProfilePath) { $PciProfileIndex = @(Import-Csv $pciProfilePath) }
$ObservedGpu = @()
$ogp = Join-Path $D "GPU_OBSERVED_PROFILES.csv"
if (Test-Path $ogp) { $ObservedGpu = @(Import-Csv $ogp) }
$ObservedRam = @()
$orp = Join-Path $D "RAM_OBSERVED_PROFILES.csv"
if (Test-Path $orp) { $ObservedRam = @(Import-Csv $orp) }
$KoreaMaster = @()
$kmp = Join-Path $D "KOREA_PRODUCT_MASTER.csv"
if (Test-Path $kmp) { $KoreaMaster = @(Import-Csv $kmp | Where-Object { (S $_.ProductID) }) }

$stamp = KstString "yyyyMMdd_HHmmss_fff"
$safe = $AssetID -replace '[\\/:*?"<>|]','_'
if (!$safe) { $safe = "NO_ASSET_ID" }
$base = "${stamp}_${safe}"
$csv = Join-Path $R "${base}.csv"
$sum = Join-Path $R "${base}_SUMMARY.txt"
$raw = Join-Path $L "${base}_RAW.txt"
$pciraw = Join-Path $L "${base}_PCI.txt"
$pciPostRaw = Join-Path $L "${base}_PCI_POST_DRIVER.txt"
$gpuStageLog = Join-Path $L "${base}_GPU_DRIVER_STAGE.txt"
$pcicsv = Join-Path $R "${base}_PCI_DEVICES.csv"
$nvidiaLog = Join-Path $L "${base}_NVIDIA.txt"
$storageCsv = Join-Path $R "${base}_STORAGE_DEEP.csv"
$productMatchCsv = Join-Path $R "${base}_KOREA_PRODUCT_MATCH.csv"
$coverageCsv = Join-Path $R "${base}_COVERAGE_GAPS.csv"
$smbiosBin = Join-Path $L "${base}_SMBIOS.bin"
$platformIdentityFile = Join-Path $L "${base}_PLATFORM_IDENTITY.txt"
$sessionCsv = Join-Path $R "${base}_INSPECTION.csv"
$evidencePlanCsv = Join-Path $R "${base}_EVIDENCE_PLAN.csv"
$evidenceStatusCsv = Join-Path $R "${base}_EVIDENCE_STATUS.csv"
$deepScanRequestJson = Join-Path $R "${base}_DEEP_SCAN_REQUEST.json"
$inspectionStartedAt = KstString 'yyyy-MM-ddTHH:mm:ss.fffzzz'
[pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;StartedAt=$inspectionStartedAt;TimeBasis='KST_FIXED_UTC+09';Version=$Version;GpuScanMode=$GpuScanMode;ResultBase=$base;InspectionComplete='PENDING';EvidenceCompleteness='0';Outcome='CORE_SCAN_RUNNING'} | Export-Csv $sessionCsv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

Set-InspectionProgress 'CPU · 메인보드 · 메모리 · 저장장치 확인'
$cs = Get-WmiObject Win32_ComputerSystem
$csp = Get-WmiObject Win32_ComputerSystemProduct
$bios = Get-WmiObject Win32_BIOS
$bb = Get-WmiObject Win32_BaseBoard
$cpu = @(Get-WmiObject Win32_Processor)
$ram = @(Get-WmiObject Win32_PhysicalMemory)
$disks = @(Get-WmiObject Win32_DiskDrive)
$physicalDisks = @(Get-WmiObject -Namespace "root\Microsoft\Windows\Storage" -Class MSFT_PhysicalDisk)
$total = 0
$ram | ForEach-Object { $total += [double]$_.Capacity }
$totalGB = [math]::Round($total/1GB,0)

# Raw SMBIOS is retained as a forensic snapshot only. Its binary layout can contain
# volatile bytes and is NOT used as the stable machine identity fingerprint.
$smbiosHash="";$smbiosMajor="";$smbiosMinor="";$platformIdentityHash="";$platformIdentityText=""
$smbios = Get-WmiObject -Namespace "root\wmi" -Class MSSmBios_RawSMBiosTables
if ($smbios -and $smbios.SMBiosData) {
    $sb=[byte[]]$smbios.SMBiosData
    [IO.File]::WriteAllBytes($smbiosBin,$sb)
    $smbiosHash=ByteHash $sb
    $smbiosMajor=S $smbios.SMBiosMajorVersion;$smbiosMinor=S $smbios.SMBiosMinorVersion
}
# Stable platform identity is a deterministic hash over normalized identity fields.
# It intentionally excludes raw SMBIOS bytes, timestamps, RAM map data, and firmware tables.
$cpuIds=(($cpu | ForEach-Object { (S $_.ProcessorId).ToUpper() }) -join '|')
$platformIdentityText = @(
    'SystemManufacturer='+(S $cs.Manufacturer).ToUpper(),
    'SystemModel='+(S $cs.Model).ToUpper(),
    'SystemSerial='+(S $bios.SerialNumber).ToUpper(),
    'SystemUUID='+(S $csp.UUID).ToUpper(),
    'BoardManufacturer='+(S $bb.Manufacturer).ToUpper(),
    'BoardProduct='+(S $bb.Product).ToUpper(),
    'BoardVersion='+(S $bb.Version).ToUpper(),
    'BoardSerial='+(S $bb.SerialNumber).ToUpper(),
    'CPUProcessorId='+$cpuIds
) -join "`n"
$platformIdentityHash=TextHash $platformIdentityText
@('COU-EYE PLATFORM IDENTITY V1',$platformIdentityText,'','SHA256='+$platformIdentityHash) | Out-File $platformIdentityFile -Encoding UTF8

# Optional Storage Management WMI. It is richer than Win32_DiskDrive when available.
$storageDeep=@()
$si=0
foreach($pd in $physicalDisks){
    $si++
    $deepBus=BusTypeName $pd.BusType
    $deepProto=if(((S $pd.FriendlyName).ToUpper() -match '\bNVME\b')){'NVMe'}elseif($deepBus -eq 'USB'){'USB'}elseif($deepBus -in @('ATA','SATA')){'SATA/ATA'}elseif($deepBus -eq 'RAID'){'Unknown device protocol behind RAID/RST controller'}else{$deepBus}
    $storageDeep += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Index=$si;FriendlyName=(S $pd.FriendlyName);SerialNumber=(S $pd.SerialNumber);FirmwareVersion=(S $pd.FirmwareVersion);DeviceProtocol=$deepProto;ControllerBusType=$deepBus;BusType=$deepBus;MediaType=(S $pd.MediaType);SizeGB=(GB $pd.Size);HealthStatus=(S $pd.HealthStatus);OperationalStatus=(S ($pd.OperationalStatus -join '|'));PhysicalSectorSize=(S $pd.PhysicalSectorSize);LogicalSectorSize=(S $pd.LogicalSectorSize)}
}
if($storageDeep.Count -gt 0){$storageDeep|Export-Csv $storageCsv -NoTypeInformation -Encoding UTF8}

# -----------------------------------------------------------------------------
# PCI BUS SCAN + GLOBAL PCI.IDS RESOLUTION
# -----------------------------------------------------------------------------
Set-InspectionProgress 'PCI 장치 및 그래픽카드 확인'
$pci = ""
$pn = "$env:SystemRoot\System32\pnputil.exe"
if (Test-Path $pn) {
    $pci = (& $pn /enum-devices /bus PCI /deviceids 2>&1 | Out-String)
    $pci | Out-File $pciraw -Encoding UTF8
}

$pciRows = @()
$gpus = @()
if ($pci) {
    $blocks = [regex]::Split($pci,'(?m)(?=^Instance ID:)')
    $pi = 0
    foreach ($b in $blocks) {
        $m = [regex]::Match($b,'PCI\\VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})(?:&SUBSYS_([0-9A-Fa-f]{8}))?(?:&REV_([0-9A-Fa-f]{2}))?')
        if (!$m.Success) { continue }
        $pi++
        $ven=$m.Groups[1].Value.ToUpper(); $dev=$m.Groups[2].Value.ToUpper(); $ss=$m.Groups[3].Value.ToUpper(); $rev=$m.Groups[4].Value.ToUpper()
        $sd=""; $sv=""
        if ($ss.Length -eq 8) { $sd=$ss.Substring(0,4); $sv=$ss.Substring(4,4) }
        $cm=[regex]::Match($b,'&CC_([0-9A-Fa-f]{4,6})'); $cc=if($cm.Success){$cm.Groups[1].Value.ToUpper()}else{""}
        $dm=[regex]::Match($b,'(?m)^Device Description:\s*(.+)$'); $desc=if($dm.Success){$dm.Groups[1].Value.Trim()}else{""}
        $im=[regex]::Match($b,'(?m)^Instance ID:\s*(.+)$'); $iid=if($im.Success){$im.Groups[1].Value.Trim()}else{""}
        $vname=PciVendorName $ven
        $dname=PciDeviceName $ven $dev
        $svname=PciVendorName $sv
        $ssname=PciSubsystemName $ven $dev $sv $sd
        $pciRows += [pscustomobject]@{
            AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode; Index=$pi; VendorID=$ven; VendorName=$vname; DeviceID=$dev; DeviceName=$dname;
            SubvendorID=$sv; SubvendorName=$svname; SubsystemID=$sd; SubsystemName=$ssname; Revision=$rev;
            ClassCode=$cc; DeviceDescription=$desc; InstanceID=$iid; HardwareID=$m.Value
        }
        if ($cc.StartsWith("03")) {
            $type = Get-GpuType $ven $cc $dname $desc
            $friendly = FriendlyGpuName $dname $ven $dev
            $gpus += [pscustomobject]@{
                Vendor=$vname; Model=$friendly; PciName=$dname; Type=$type; VEN=$ven; DEV=$dev; SUBSYS=$sd;
                SUBVENDOR_ID=$sv; SUBVENDOR=$svname; SubsystemName=$ssname; REV=$rev; CC=$cc; HWID=$m.Value; InstanceID=$iid
            }
        }
    }
    $gpus = @($gpus | Sort-Object HWID -Unique)
    $pciRows | Export-Csv $pcicsv -NoTypeInformation -Encoding UTF8
}

# -----------------------------------------------------------------------------
# NVIDIA DRIVER-ASSISTED ENRICHMENT
# V1.3.11 display-safe scan: CoreSafe never activates display drivers while GUI is visible.
# DeepHeadless is the only mode allowed to activate NVIDIA/Intel display drivers.
# Full Evidence Architecture treats failure as BLOCKED evidence, never as a silent PASS.
# Load the matching installed Windows NVIDIA INF into the live WinPE
# session with Microsoft's DrvLoad first. This avoids staging the full driver
# package into the small WinPE Driver Store. PnPUtil is only a guarded fallback
# when WinPE has enough free space for the source package.
# The installed Windows volume is read-only evidence/source; no target-OS reboot.
# -----------------------------------------------------------------------------
Set-InspectionProgress $(if($GpuScanMode -eq 'DeepHeadless'){'그래픽카드 Deep Evidence 확인'}else{'그래픽카드 기본 정보 확인'})
$nvidiaDeep = @{}
$nvidiaRom = @{}
$nvidiaDeepStatus = @{}
$nvidiaLines = New-Object Collections.Generic.List[string]
$nvidiaLines.Add("COU-EYE V$Version - NVIDIA DEEP SCAN")
$nvidiaLines.Add("Asset ID: " + $AssetID);$nvidiaLines.Add("Coucode: " + $Coucode)
$nvidiaLines.Add("Time: " + (KstString "yyyy-MM-dd HH:mm:ss zzz"))
$nvidiaLines.Add("")
$nvTargets = @($gpus | Where-Object {$_.VEN -eq "10DE" -and $_.Type -eq "Discrete"})
$loadedInfDirs = New-Object Collections.Generic.List[string]
$winRoots = New-Object Collections.Generic.List[string]
$drvload = Join-Path $env:SystemRoot "System32\drvload.exe"

$gpuDriverStage = @{}

function New-GpuDriverStage([string]$hwid,[string]$vendor) {
    $o=[pscustomobject]@{
        Vendor=$vendor;InfPath='';MatchStatus='BLOCKED';MatchReason='No compatible display INF was resolved.';
        LoadStatus='BLOCKED';LoadReason='Driver load was not completed.';LoadMethod='NONE';
        PnpStatus='BLOCKED';PnpReason='GPU PnP state was not verified as Started.';PnpRaw='';
        VendorQueryStatus='BLOCKED';VendorQueryReason='Vendor query was not completed.';
        RuntimeSmi='';RuntimeSmiSource='';RuntimeNvml='';RuntimeNvmlSource='';
        ServiceState='UNKNOWN';ServiceReason=''
    }
    $gpuDriverStage[$hwid]=$o
    return $o
}
function Get-PnpStateFromText([string]$text) {
    $status='';$class='';$driver='';$desc=''
    if($text -match '(?mi)^Status:\s*(.+)$'){$status=$matches[1].Trim()}
    if($text -match '(?mi)^Class Name:\s*(.+)$'){$class=$matches[1].Trim()}
    if($text -match '(?mi)^Driver Name:\s*(.+)$'){$driver=$matches[1].Trim()}
    if($text -match '(?mi)^Device Description:\s*(.+)$'){$desc=$matches[1].Trim()}
    return [pscustomobject]@{Status=$status;ClassName=$class;DriverName=$driver;Description=$desc}
}
function Find-NvidiaRuntimeBinary([string]$fileName,[string]$driverDir,[string]$windowsRoot) {
    $candidates=New-Object Collections.Generic.List[object]
    $runtimeRoot=$env:SystemRoot
    if(S $runtimeRoot){
        $candidates.Add([pscustomobject]@{Path=(Join-Path $runtimeRoot ('System32\'+$fileName));Source='DEEPPE_RUNTIME_SYSTEM32'})
        $runtimeRepo=Join-Path $runtimeRoot 'System32\DriverStore\FileRepository'
        if(Test-Path -LiteralPath $runtimeRepo){
            $hit=@(Get-ChildItem -LiteralPath $runtimeRepo -File -Recurse -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1)
            if($hit.Count){$candidates.Add([pscustomobject]@{Path=$hit[0].FullName;Source='DEEPPE_RUNTIME_DRIVERSTORE'})}
        }
    }
    if(S $driverDir){
        $candidates.Add([pscustomobject]@{Path=(Join-Path $driverDir $fileName);Source='MATCHED_DRIVER_PACKAGE'})
        if(Test-Path -LiteralPath $driverDir){
            $hit=@(Get-ChildItem -LiteralPath $driverDir -File -Recurse -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1)
            if($hit.Count){$candidates.Add([pscustomobject]@{Path=$hit[0].FullName;Source='MATCHED_DRIVER_PACKAGE_RECURSIVE'})}
        }
    }
    if(S $windowsRoot){
        $candidates.Add([pscustomobject]@{Path=(Join-Path $windowsRoot ('System32\'+$fileName));Source='TARGET_WINDOWS_SYSTEM32_FALLBACK'})
        $driveRoot=[IO.Path]::GetPathRoot($windowsRoot)
        if($driveRoot){$candidates.Add([pscustomobject]@{Path=(Join-Path $driveRoot ('Program Files\NVIDIA Corporation\NVSMI\'+$fileName));Source='TARGET_WINDOWS_NVSMI_FALLBACK'})}
    }
    foreach($c in $candidates){if($c.Path -and (Test-Path -LiteralPath $c.Path)){return $c}}
    return $null
}
function Find-CompatibleDisplayInf([object]$g,[string]$vendorPrefix='') {
    foreach ($letter in ([char[]](67..90))) {
        $drive=([string]$letter)+":"
        if ($drive -eq $env:SystemDrive) { continue }
        $repo=$drive+"\Windows\System32\DriverStore\FileRepository"
        if (!(Test-Path -LiteralPath $repo)) { continue }
        $dirs=if($vendorPrefix){@(Get-ChildItem -LiteralPath $repo -Directory -Filter ($vendorPrefix+"*.inf_amd64_*") -ErrorAction SilentlyContinue)}else{@(Get-ChildItem -LiteralPath $repo -Directory -ErrorAction SilentlyContinue)}
        $devPat=("DEV_"+$g.DEV).ToUpper()
        $subPat=if((S $g.SUBSYS) -and (S $g.SUBVENDOR_ID)){("SUBSYS_"+$g.SUBSYS+$g.SUBVENDOR_ID).ToUpper()}else{''}
        $fallback=$null
        foreach($dir in $dirs){
            foreach($inf in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue)){
                $txt='';try{$txt=(Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction Stop).ToUpper()}catch{continue}
                if($txt.IndexOf($devPat) -lt 0){continue}
                if($subPat -and $txt.IndexOf($subPat) -ge 0){return [pscustomobject]@{InfPath=$inf.FullName;WindowsRoot=($drive+'\Windows');ExactSubsystem=$true}}
                if(!$fallback){$fallback=[pscustomobject]@{InfPath=$inf.FullName;WindowsRoot=($drive+'\Windows');ExactSubsystem=$false}}
            }
        }
        if($fallback){return $fallback}
    }
    return $null
}
function Get-NvidiaServiceDiagnostics {
    $lines=New-Object Collections.Generic.List[string]
    $state='UNKNOWN';$reason=''
    try {
        $sc=Join-Path $env:SystemRoot 'System32\sc.exe'
        if(Test-Path -LiteralPath $sc){
            $q=(& $sc query nvlddmkm 2>&1 | Out-String).Trim()
            $qc=(& $sc qc nvlddmkm 2>&1 | Out-String).Trim()
            $lines.Add('sc query nvlddmkm: '+$q)
            $lines.Add('sc qc nvlddmkm: '+$qc)
            if($q -match '(?i)STATE\s*:\s*\d+\s+RUNNING'){$state='RUNNING';$reason='SCM reports nvlddmkm RUNNING.'}
            elseif($q -match '(?i)STATE\s*:\s*\d+\s+STOPPED'){$state='STOPPED';$reason='SCM reports nvlddmkm STOPPED.'}
            elseif($q -match '(?i)FAILED 1060|does not exist'){$state='MISSING';$reason='nvlddmkm service is not registered in the active DeepPE runtime.'}
        }
    } catch {$lines.Add('sc diagnostic exception: '+$_.Exception.Message)}
    try {
        $wd=Get-WmiObject Win32_SystemDriver -Filter "Name='nvlddmkm'" -ErrorAction SilentlyContinue
        if($wd){
            $lines.Add(("Win32_SystemDriver nvlddmkm: State={0}; Started={1}; Status={2}; Path={3}" -f (S $wd.State),(S $wd.Started),(S $wd.Status),(S $wd.PathName)))
            if($wd.Started -eq $true){$state='RUNNING';$reason='Win32_SystemDriver reports nvlddmkm Started=True.'}
        }
    } catch {$lines.Add('WMI system-driver diagnostic exception: '+$_.Exception.Message)}
    try {
        $sysHits=@()
        $direct=Join-Path $env:SystemRoot 'System32\drivers\nvlddmkm.sys'
        if(Test-Path -LiteralPath $direct){$sysHits+=Get-Item -LiteralPath $direct}
        $repo=Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
        if(Test-Path -LiteralPath $repo){$sysHits+=@(Get-ChildItem -LiteralPath $repo -Recurse -File -Filter 'nvlddmkm.sys' -ErrorAction SilentlyContinue | Select-Object -First 2)}
        foreach($h in $sysHits){$lines.Add('nvlddmkm.sys runtime path: '+$h.FullName)}
        if(!$sysHits.Count){$lines.Add('nvlddmkm.sys runtime path: NOT FOUND')}
    } catch {}
    return [pscustomobject]@{State=$state;Reason=$reason;Lines=$lines}
}

function Get-FreeBytesForPath([string]$path) {
    try {
        $root=[IO.Path]::GetPathRoot($path)
        if(!$root){return 0L}
        $name=$root.Substring(0,1)
        $psd=Get-PSDrive -Name $name -ErrorAction Stop
        return [int64]$psd.Free
    } catch { return 0L }
}
function Get-DirectoryBytes([string]$path) {
    try { return [int64]((Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) }
    catch { return 0L }
}
function Find-NvmlDll([string]$driverDir,[string]$windowsRoot) {
    # Exact NVML filename only. Search likely installed-Windows locations without
    # writing to the target OS. NVIDIA DCH packages may keep NVML outside the
    # display INF directory.
    $candidates=New-Object Collections.Generic.List[string]
    if(S $windowsRoot){
        $candidates.Add((Join-Path $windowsRoot 'System32\nvml.dll'))
        $driveRoot=[IO.Path]::GetPathRoot($windowsRoot)
        if($driveRoot){$candidates.Add((Join-Path $driveRoot 'Program Files\NVIDIA Corporation\NVSMI\nvml.dll'))}
    }
    if(S $driverDir){$candidates.Add((Join-Path $driverDir 'nvml.dll'))}
    foreach($c in $candidates){if(Test-Path -LiteralPath $c){return $c}}
    if(S $driverDir){
        $exact=@(Get-ChildItem -LiteralPath $driverDir -File -Recurse -Filter 'nvml.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if($exact.Count -gt 0){return $exact[0].FullName}
    }
    if(S $windowsRoot){
        $repo=Join-Path $windowsRoot 'System32\DriverStore\FileRepository'
        if(Test-Path -LiteralPath $repo){
            $nvDirs=@(Get-ChildItem -LiteralPath $repo -Directory -Filter 'nv*.inf_amd64_*' -ErrorAction SilentlyContinue)
            foreach($d in $nvDirs){
                $hit=@(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -Filter 'nvml.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)
                if($hit.Count -gt 0){return $hit[0].FullName}
            }
        }
    }
    return $null
}

$gpuTraceDir=$nvidiaLog+'.trace'
if($GpuScanMode -eq 'DeepHeadless'){Save-GpuInitializationTrace $gpuTraceDir '01-before-display-load' $nvidiaLines}
# nvml2: initialize hybrid display provider BEFORE NVIDIA activation/query.
# Intel graphics driver/PnP validation. V1.3.11 does not claim Intel vendor telemetry;
# it only verifies driver resolution, live load, and post-load PnP state.
$intelTargets=@($gpus|Where-Object{$_.VEN -eq '8086'})
foreach($ig in $intelTargets){
    $stage=New-GpuDriverStage $ig.HWID 'Intel'
    $res=Find-CompatibleDisplayInf $ig 'i'
    if(!$res){$res=Find-CompatibleDisplayInf $ig ''}
    if($res){
        $stage.InfPath=$res.InfPath
        $stage.MatchStatus='VERIFIED'
        $stage.MatchReason=$(if($res.ExactSubsystem){'Exact Intel DEV + SUBSYS INF resolved from target Windows DriverStore.'}else{'Intel DEV-matching INF resolved; exact subsystem match not found.'})
        if($GpuScanMode -eq 'DeepHeadless'){
            if(Get-ReadyDisplayDevice $ig.InstanceID){
                $stage.LoadStatus='VERIFIED';$stage.LoadMethod='PREBOUND';$stage.LoadReason='Active Display device already started; no redundant reload.'
            }elseif(Test-Path -LiteralPath $drvload){
                $runtimeIntelInf=Resolve-RuntimeDisplayInf $res.InfPath $nvidiaLines; $outIntel=(& $drvload $runtimeIntelInf 2>&1 | Out-String);$exitIntel=$LASTEXITCODE
                if($exitIntel -eq 0){$stage.LoadStatus='VERIFIED';$stage.LoadMethod='DRVLOAD';$stage.LoadReason='Intel display INF loaded successfully via DrvLoad in Headless DeepPE.'}
                else{$stage.LoadStatus='BLOCKED';$stage.LoadMethod='DRVLOAD';$stage.LoadReason=('Intel DrvLoad failed with exit code '+$exitIntel+'. '+$outIntel.Trim())}
            } else {$stage.LoadStatus='BLOCKED';$stage.LoadReason='drvload.exe not found in active WinPE runtime.'}
            Start-Sleep -Seconds 3
        } else {
            $stage.LoadStatus='BLOCKED';$stage.LoadMethod='DEFERRED_HEADLESS';$stage.LoadReason='Intel display-driver activation is deferred to Headless DeepPE to protect the visible WinPE GUI/display path.'
        }
    } else {
        $stage.MatchStatus='BLOCKED';$stage.MatchReason='Compatible Intel display INF was not resolved from installed Windows volumes.'
        $stage.LoadStatus='BLOCKED';$stage.LoadReason='Driver load not attempted because no matching INF was resolved.'
    }
    $targetEnum=''
    if($pn -and (Test-Path -LiteralPath $pn)){
        if(S $ig.InstanceID){$targetEnum=(& $pn /enum-devices /instanceid $ig.InstanceID /deviceids 2>&1 | Out-String)}
        if(!(S $targetEnum) -or $targetEnum -match '(?i)No devices were found|unknown option|invalid'){$targetEnum=(& $pn /enum-devices /bus PCI /deviceids 2>&1 | Out-String)}
    }
    $stage.PnpRaw=$targetEnum
    $pnpState=Get-PnpStateFromText $targetEnum
    if($pnpState.Status -eq 'Started' -and $pnpState.ClassName -eq 'Display'){$stage.PnpStatus='VERIFIED';$stage.PnpReason=("PnP reports Started / Display / Driver="+$pnpState.DriverName)}
    elseif($GpuScanMode -eq 'CoreSafe'){$stage.PnpStatus='BLOCKED';$stage.PnpReason='PnP Started/Display verification deferred until Headless DeepPE activates the display driver.'}
    else{$stage.PnpStatus='BLOCKED';$stage.PnpReason=("PnP not fully started. Status="+$pnpState.Status+"; Class="+$pnpState.ClassName+"; Driver="+$pnpState.DriverName)}
    $stage.VendorQueryStatus='BLOCKED';$stage.VendorQueryReason='Intel vendor/API deep telemetry is not yet integrated.'
}


if ($nvTargets.Count -gt 0) {
    foreach ($ng in $nvTargets) {
        $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='NOT_ATTEMPTED';Reason='Target detected; driver source search not completed yet.'}
        $stage=New-GpuDriverStage $ng.HWID 'NVIDIA'
        $nvidiaLines.Add("Target: VEN="+$ng.VEN+" DEV="+$ng.DEV+" SUBSYS="+$ng.SUBSYS+" SUBVENDOR="+$ng.SUBVENDOR_ID)
        $foundInf=$null; $winRoot=$null
        $nvResolved=Find-CompatibleDisplayInf $ng 'nv'
        if(!$nvResolved){$nvResolved=Find-CompatibleDisplayInf $ng ''}
        if($nvResolved){$foundInf=$nvResolved.InfPath;$winRoot=$nvResolved.WindowsRoot}
        if (!$foundInf) {
            $nvidiaLines.Add("Matching NVIDIA INF: NOT FOUND")
            $stage.MatchStatus='BLOCKED';$stage.MatchReason='Compatible NVIDIA DriverStore INF not found on installed Windows volumes.'
            $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='NOT_AVAILABLE';Reason=$stage.MatchReason}
            continue
        }

        $stage.InfPath=$foundInf;$stage.MatchStatus='VERIFIED';$stage.MatchReason=$(if($nvResolved -and $nvResolved.ExactSubsystem){'Exact NVIDIA DEV + SUBSYS INF resolved from target Windows DriverStore.'}else{'Compatible NVIDIA DEV-matching INF resolved; exact subsystem match not found.'})
        $nvidiaLines.Add("Matching NVIDIA INF: "+$foundInf)
        $infDir=Split-Path -Parent $foundInf
        if (!$loadedInfDirs.Contains($infDir)) { $loadedInfDirs.Add($infDir) }
        if (!$winRoots.Contains($winRoot)) { $winRoots.Add($winRoot) }
        $pkgBytes=Get-DirectoryBytes $infDir
        $xFree=Get-FreeBytesForPath $env:SystemRoot
        $nvidiaLines.Add(("Driver package source bytes: {0} ({1:N1} MiB)" -f $pkgBytes,($pkgBytes/1MB)))
        $nvidiaLines.Add(("WinPE system drive free bytes before load: {0} ({1:N1} MiB)" -f $xFree,($xFree/1MB)))

        $loadSucceeded=$false
        $loadMethod='NONE'
        $targetEnum=''
        if($GpuScanMode -eq 'DeepHeadless') {
            if (Get-ReadyDisplayDevice $ng.InstanceID) {
                $loadSucceeded=$true;$loadMethod='PREBOUND'
                $nvidiaLines.Add('NVIDIA already started as Display; redundant DrvLoad avoided.')
            } elseif (Test-Path -LiteralPath $drvload) {
                $runtimeNvInf=Resolve-RuntimeDisplayInf $foundInf $nvidiaLines; $drvOut=(& $drvload $runtimeNvInf 2>&1 | Out-String)
                $drvExit=$LASTEXITCODE
                $nvidiaLines.Add("drvload path: "+$drvload)
                $nvidiaLines.Add("drvload exit code: "+$drvExit)
                $nvidiaLines.Add("drvload raw: "+$drvOut.Trim())
                if($drvExit -eq 0){$loadSucceeded=$true;$loadMethod='DRVLOAD'}
            } else {
                $drvExit=-1
                $nvidiaLines.Add("drvload.exe: NOT FOUND")
            }

            # Guarded fallback: PnPUtil stages the package in WinPE and can exhaust X:.
            if(!$loadSucceeded) {
                $reserve=[int64](128MB)
                $need=[int64]($pkgBytes+$reserve)
                $xFree=Get-FreeBytesForPath $env:SystemRoot
                if($pn -and (Test-Path -LiteralPath $pn) -and $pkgBytes -gt 0 -and $xFree -gt $need) {
                    $nvidiaLines.Add(("PnPUtil fallback: ATTEMPT (free={0:N1} MiB, estimated need={1:N1} MiB)" -f ($xFree/1MB),($need/1MB)))
                    $install=(& $pn /add-driver $foundInf /install 2>&1 | Out-String)
                    $installExit=$LASTEXITCODE
                    $nvidiaLines.Add("pnputil add-driver exit code: "+$installExit)
                    $nvidiaLines.Add($install.Trim())
                    if($installExit -eq 0){$loadSucceeded=$true;$loadMethod='PNPUTIL_FALLBACK'}
                } else {
                    $nvidiaLines.Add(("PnPUtil fallback: SKIPPED (avoids WinPE disk exhaustion; free={0:N1} MiB, estimated need={1:N1} MiB)" -f ($xFree/1MB),($need/1MB)))
                }
            }
            Start-Sleep -Seconds 2
        } else {
            $loadMethod='DEFERRED_HEADLESS'
            $stage.LoadStatus='BLOCKED';$stage.LoadMethod=$loadMethod;$stage.LoadReason='Display-driver activation is deferred to the Headless DeepPE phase to protect the visible WinPE GUI/display path.'
            $stage.VendorQueryStatus='BLOCKED';$stage.VendorQueryReason='NVIDIA vendor telemetry is deferred to Headless DeepPE.'
            $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='PRESENT_UNVERIFIED';Reason='PCI identity and compatible driver match were collected. Display-driver activation/vendor telemetry were deferred to Headless DeepPE.'}
            $nvidiaLines.Add('CORE_SAFE: NVIDIA display-driver activation skipped. Headless DeepPE is required for Load/PnP/NVML evidence.')
        }

        if($pn -and (Test-Path -LiteralPath $pn)) {
            if(S $ng.InstanceID){$targetEnum=(& $pn /enum-devices /instanceid $ng.InstanceID /deviceids 2>&1 | Out-String)}
            if(!(S $targetEnum) -or $targetEnum -match '(?i)No devices were found|unknown option|invalid'){$targetEnum=(& $pn /enum-devices /bus PCI /deviceids 2>&1 | Out-String)}
        }
        $nvidiaLines.Add("Device state after scan mode="+$GpuScanMode+" load method="+$loadMethod+":")
        $nvidiaLines.Add((S $targetEnum))

        if($GpuScanMode -eq 'DeepHeadless') {
            if($loadSucceeded){$stage.LoadStatus='VERIFIED';$stage.LoadMethod=$loadMethod;$stage.LoadReason=('NVIDIA display INF loaded successfully via '+$loadMethod+'.')}
            else{$stage.LoadStatus='BLOCKED';$stage.LoadMethod=$loadMethod;$stage.LoadReason="NVIDIA driver load failed in Headless DeepPE (DrvLoad exit=$drvExit; PnPUtil fallback unavailable/skipped/failed).";$reason=$stage.LoadReason+" See NVIDIA log.";$nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='NOT_AVAILABLE';Reason=$reason}}
        }
        $pnpState=Get-PnpStateFromText $targetEnum
        $stage.PnpRaw=$targetEnum
        if($pnpState.Status -eq 'Started' -and $pnpState.ClassName -eq 'Display'){$stage.PnpStatus='VERIFIED';$stage.PnpReason=("PnP reports Started / Display / Driver="+$pnpState.DriverName)}
        elseif($GpuScanMode -eq 'CoreSafe'){$stage.PnpStatus='BLOCKED';$stage.PnpReason='PnP Started/Display verification deferred until Headless DeepPE activates the display driver.'}
        else{$stage.PnpStatus='BLOCKED';$stage.PnpReason=("PnP not fully started after load. Status="+$pnpState.Status+"; Class="+$pnpState.ClassName+"; Driver="+$pnpState.DriverName)}
    }

    if ($GpuScanMode -eq 'DeepHeadless' -and $loadedInfDirs.Count -gt 0 -and $winRoots.Count -gt 0) {
        # V1.3.11 runtime-first binary policy: DeepPE runtime binaries are preferred.
        # Target Windows binaries are fallback only and their source is logged explicitly.
        $infDir=$loadedInfDirs[0]; $winRoot=$winRoots[0]
        $smiInfo=Find-NvidiaRuntimeBinary 'nvidia-smi.exe' $infDir $winRoot
        $nvmlInfo=Find-NvidiaRuntimeBinary 'nvml.dll' $infDir $winRoot
        $smi=if($smiInfo){$smiInfo.Path}else{''}
        $nvml=if($nvmlInfo){$nvmlInfo.Path}else{''}
        # nvml3: choose a colocated pair from the ACTIVE runtime kernel package.
        # PATH alone does not override an executable-directory NVML loader.
        if($GpuScanMode -eq 'DeepHeadless'){
            $activePair=Get-ActiveNvidiaPackagePair (Get-ActiveNvidiaKernel) $nvidiaLines
            if($activePair){
                $smi=$activePair.Smi;$nvml=$activePair.Nvml
                $smiInfo=[pscustomobject]@{Source=$activePair.Source};$nvmlInfo=[pscustomobject]@{Source=$activePair.Source}
            }
        }
        if (!(S $nvml) -or !(Test-Path -LiteralPath $nvml)) {
            $nvidiaLines.Add("nvml.dll: NOT FOUND in DeepPE runtime, matched package, or target-Windows fallback.")
            foreach($ng in $nvTargets){
                $stage=$gpuDriverStage[$ng.HWID];if($stage){$stage.VendorQueryStatus='BLOCKED';$stage.VendorQueryReason='nvml.dll not found in any approved search tier.'}
            }
        }
        else {
                        $pair=if($smi -and (Test-Path -LiteralPath $smi)){Test-NvidiaPair $smi $nvml}else{[pscustomobject]@{Compatible=$false;SmiVersion='MISSING';NvmlVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($nvml).FileVersion}}
            $nvidiaLines.Add(('Runtime binary versions: SMI={0}; NVML={1}; pairCompatible={2}' -f $pair.SmiVersion,$pair.NvmlVersion,$pair.Compatible))
            # A matched-package pair is used only when both versions match each other and runtime NVML.
            $packageSmi=Join-Path $infDir 'nvidia-smi.exe';$packageNvml=Join-Path $infDir 'nvml.dll'
            if(!$pair.Compatible -and (Test-Path $packageSmi) -and (Test-Path $packageNvml)){
                $candidate=Test-NvidiaPair $packageSmi $packageNvml
                if($candidate.Compatible -and $candidate.NvmlVersion -eq $pair.NvmlVersion){
                    $smi=$packageSmi;$nvml=$packageNvml;$pair=$candidate
                    $smiInfo=[pscustomobject]@{Source='MATCHED_PACKAGE_PAIR'};$nvmlInfo=[pscustomobject]@{Source='MATCHED_PACKAGE_PAIR'}
                }
            }
            $nvmlDir=Split-Path -Parent $nvml
            $smiDir=Split-Path -Parent $smi
                        $kernel=Get-ActiveNvidiaKernel
            if($kernel){$nvidiaLines.Add(('Active kernel: {0}; Version={1}; SHA256={2}' -f $kernel.Path,$kernel.Version,$kernel.Hash))}
            else{$nvidiaLines.Add('Active kernel path/version could not be verified.')}
            $kernelCompatible=Test-NvidiaKernelVersion $kernel $nvml
            $nvidiaLines.Add('Kernel/NVML driver build compatible: '+$kernelCompatible)
            foreach($ig in $intelTargets){$is=$gpuDriverStage[$ig.HWID];$nvidiaLines.Add(('Intel before NVML: Load={0}; PnP={1}; {2}' -f $is.LoadStatus,$is.PnpStatus,$is.PnpReason))}
            $oldPath=$env:PATH
            $oldLoc=(Get-Location).Path
            $runtimeSystem32=Join-Path $env:SystemRoot 'System32'
            $env:PATH=$nvmlDir+";"+$smiDir+";"+$runtimeSystem32+";"+$env:SystemRoot
            try { Set-Location -LiteralPath $nvmlDir } catch {}
            $nvidiaLines.Add("nvidia-smi path: "+$smi)
            $nvidiaLines.Add("nvidia-smi source: "+$(if($smiInfo){$smiInfo.Source}else{'UNKNOWN'}))
            $nvidiaLines.Add("nvml exact path: "+$nvml)
            $nvidiaLines.Add("nvml source: "+$(if($nvmlInfo){$nvmlInfo.Source}else{'UNKNOWN'}))
            $nvidiaLines.Add("nvml directory added to PATH: "+$nvmlDir)
            foreach($ng in $nvTargets){
                $stage=$gpuDriverStage[$ng.HWID]
                if($stage){
                    $stage.RuntimeSmi=$smi;$stage.RuntimeSmiSource=$(if($smiInfo){$smiInfo.Source}else{'UNKNOWN'})
                    $stage.RuntimeNvml=$nvml;$stage.RuntimeNvmlSource=$(if($nvmlInfo){$nvmlInfo.Source}else{'UNKNOWN'})
                }
            }
            $svc=Get-NvidiaServiceDiagnostics
            foreach($ln in $svc.Lines){$nvidiaLines.Add($ln)}
            foreach($ng in $nvTargets){$stage=$gpuDriverStage[$ng.HWID];if($stage){$stage.ServiceState=$svc.State;$stage.ServiceReason=$svc.Reason}}
            Save-GpuInitializationTrace $gpuTraceDir '02-before-nvml' $nvidiaLines
            Add-GpuRuntimeDiagnostics $nvidiaLines
            $directRows=@(); if($kernelCompatible){$directRows=@(Invoke-NvmlPrimaryProbe $Root $nvml $gpuTraceDir $nvidiaLines)}
            $queryFields="name,memory.total,vbios_version,pci.bus_id,uuid,pci.device_id,pci.sub_device_id,driver_version"
                        if($directRows.Count -gt 0){
                $reply=[pscustomobject]@{ExitCode=-1;Text='SKIPPED_DIRECT_NVML_SUCCEEDED';TimedOut=$false}
            }elseif($pair.Compatible -and $kernelCompatible){
                $reply=Invoke-NvidiaQueryRetry $smi ('--query-gpu='+$queryFields+' --format=csv,noheader,nounits') $nvidiaLines
                # Only unsupported fields justify a shorter query; driver failures need initialization retry.
                if($reply.Text -match 'Field .* is not a valid field|not supported'){
                    $reply=Invoke-NvidiaQueryRetry $smi '--query-gpu=name,memory.total,vbios_version,pci.bus_id,uuid --format=csv,noheader,nounits' $nvidiaLines
                }
            }else{
                $reply=[pscustomobject]@{ExitCode=126;Text='Active NVIDIA kernel/NVML/SMI version could not be matched; query blocked to avoid mixed driver binaries.';TimedOut=$false}
            }

            Save-GpuInitializationTrace $gpuTraceDir '03-after-nvml' $nvidiaLines
            $queryExit=$reply.ExitCode;$qtxt=$reply.Text;$q=@($qtxt -split '\r?\n')
            $nvidiaLines.Add('nvidia-smi final exit code: '+$queryExit)
            $nvidiaLines.Add('nvidia-smi final raw: '+$qtxt)
            if($directRows.Count -eq 0 -and $pair.Compatible -and $kernelCompatible -and !$reply.TimedOut){
                $list=Invoke-NvidiaCommand $smi '-L'
                $nvidiaLines.Add('nvidia-smi -L exit code: '+$list.ExitCode+'; '+$list.Text)
            }
            try { Set-Location -LiteralPath $oldLoc } catch {}
            $env:PATH=$oldPath

            $deepList=@()
            if($queryExit -eq 0) {
                foreach ($line in @($q)) {
                    $parts=([string]$line).Split(',') | ForEach-Object {$_.Trim()}
                    $memMiB=0
                    if ($parts.Count -ge 5 -and $parts[1] -match '(\d+)') {
                        $memMiB=[int]$matches[1]
                        $ddev=""; $dsub=""; $driver=""
                        if ($parts.Count -ge 8) {
                            if ($parts[5] -match '(?i)0x([0-9A-F]{4})[0-9A-F]{4}') { $ddev=$matches[1].ToUpper() }
                            if ($parts[6] -match '(?i)0x([0-9A-F]{4})([0-9A-F]{4})') { $dsub=$matches[1].ToUpper() }
                            $driver=$parts[7]
                        }
                        $deepList += [pscustomobject]@{Name=$parts[0];MemoryMiB=$memMiB;MemoryGB=[math]::Round($memMiB/1024,2);VBIOS=$parts[2].ToUpper();BusID=$parts[3];UUID=$parts[4];DEV=$ddev;SUBSYS=$dsub;DriverVersion=$driver}
                    } elseif((S $line)) {
                        $nvidiaLines.Add("Unparsed query row: "+([string]$line))
                    }
                }
            } elseif($queryExit -ne -1 -and (S $qtxt)) {
                $nvidiaLines.Add("Query was not parsed because nvidia-smi exit code was non-zero.")
            }
            if($directRows.Count -gt 0){$deepList=$directRows;$nvidiaLines.Add("Telemetry source=NVIDIA_NVML_DIRECT; SMI exit (-1 means skipped)="+$queryExit)}
            $nvidiaLines.Add("Parsed GPU rows: "+$deepList.Count)
            foreach ($drow in $deepList) { $nvidiaLines.Add(("Parsed: Name={0}; DEV={1}; SUBSYS={2}; VRAMMiB={3}; VBIOS={4}; BUS={5}; Driver={6}" -f $drow.Name,$drow.DEV,$drow.SUBSYS,$drow.MemoryMiB,$drow.VBIOS,$drow.BusID,$drow.DriverVersion)) }
            foreach ($ng in $nvTargets) {
                $stage=$gpuDriverStage[$ng.HWID]
                if($directRows.Count -gt 0){$cand=@(Select-NvmlTargetRow $directRows $ng $nvTargets $nvidiaLines)}
                else{$cand=@($deepList | Where-Object {$_.DEV -eq $ng.DEV -and $_.SUBSYS -eq $ng.SUBSYS});if($cand.Count -ne 1){$cand=@()}}
                if ($cand.Count -gt 0) {
                    $nvidiaDeep[$ng.HWID]=$cand[0]
                    if($directRows.Count -gt 0){$nvidiaRom[$ng.HWID]=Invoke-NvidiaRomRead $Root $ng $cand[0] $gpuTraceDir $nvidiaLines}
                    if($stage){$stage.VendorQueryStatus='VERIFIED';$stage.VendorQueryReason='NVML telemetry succeeded and the GPU row was matched to the target PCI identity.'}
                    $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='DRIVER_VERIFIED';Reason='NVIDIA driver, PnP state, and target-matched GPU telemetry were verified.'}
                } else {
                    $reason=if($directRows.Count -gt 0){'Direct NVML telemetry was collected but exact target PCI identity could not be verified.'}elseif($queryExit -ne 0){"nvidia-smi/NVML query failed with exit code $queryExit; see NVIDIA log."}elseif($deepList.Count -eq 0){'nvidia-smi/NVML produced no parsable GPU record; see NVIDIA log.'}else{'NVIDIA query returned GPU records, but none could be mapped to this PCI device; see NVIDIA log.'}
                    if($stage){$stage.VendorQueryStatus='BLOCKED';$stage.VendorQueryReason=$reason}
                    if($stage -and $stage.PnpStatus -eq 'VERIFIED'){
                        $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='PRESENT_UNVERIFIED';Reason=('Driver/PnP verification succeeded, but vendor telemetry is blocked. '+$reason)}
                    } else {
                        $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='NOT_AVAILABLE';Reason=$reason}
                    }
                }
            }
        }
    }
} else { $nvidiaLines.Add("NVIDIA DEEP STATUS: NOT_ATTEMPTED - No discrete NVIDIA GPU detected by PCI scan.") }

# Normalize NVIDIA aggregate state from the staged driver evidence.
foreach($ng in $nvTargets){
    $stage=$gpuDriverStage[$ng.HWID]
    if($stage -and !$nvidiaDeep.ContainsKey($ng.HWID)){
        if($stage.PnpStatus -eq 'VERIFIED' -and $stage.VendorQueryStatus -ne 'VERIFIED'){
            $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='PRESENT_UNVERIFIED';Reason=('Driver match/load/PnP were verified; vendor telemetry remains blocked. '+$stage.VendorQueryReason)}
        } elseif($stage.LoadStatus -eq 'VERIFIED' -and $stage.PnpStatus -ne 'VERIFIED'){
            $nvidiaDeepStatus[$ng.HWID]=[pscustomobject]@{Status='PRESENT_UNVERIFIED';Reason=('Driver loaded, but PnP Started state was not verified. '+$stage.PnpReason)}
        }
    }
}

# Capture a second PCI inventory after live driver-load attempts. The original *_PCI.txt
# remains the pre-driver snapshot so PRE and POST states are never conflated.
$pciPost=''
if($pn -and (Test-Path -LiteralPath $pn)){
    $pciPost=(& $pn /enum-devices /bus PCI /deviceids 2>&1 | Out-String)
    if($GpuScanMode -eq 'CoreSafe'){
        ("COU-EYE CORE_SAFE: no display driver was activated in the visible GUI phase.`r`nPOST label represents a second non-mutating PCI snapshot.`r`n`r`n"+$pciPost) | Out-File $pciPostRaw -Encoding UTF8
    } else {$pciPost | Out-File $pciPostRaw -Encoding UTF8}
}

$stageLines=New-Object Collections.Generic.List[string]
$stageLines.Add("COU-EYE V$Version - GPU DRIVER STAGE EVIDENCE")
$stageLines.Add("Asset ID: "+$AssetID);$stageLines.Add("Coucode: "+$Coucode);$stageLines.Add("Time: "+(KstString "yyyy-MM-dd HH:mm:ss zzz"));$stageLines.Add("GPU Scan Mode: "+$GpuScanMode);$stageLines.Add("")
foreach($g in $gpus){
    $st=$gpuDriverStage[$g.HWID]
    if(!$st){continue}
    $stageLines.Add(("GPU {0}:{1} {2} | Match={3} | Load={4}({5}) | PnP={6} | VendorQuery={7}" -f $g.VEN,$g.DEV,$st.Vendor,$st.MatchStatus,$st.LoadStatus,$st.LoadMethod,$st.PnpStatus,$st.VendorQueryStatus))
    $stageLines.Add("  INF="+$st.InfPath)
    $stageLines.Add("  MatchReason="+$st.MatchReason)
    $stageLines.Add("  LoadReason="+$st.LoadReason)
    $stageLines.Add("  PnpReason="+$st.PnpReason)
    $stageLines.Add("  VendorQueryReason="+$st.VendorQueryReason)
    if($st.ServiceState -and $st.Vendor -eq 'NVIDIA'){$stageLines.Add("  nvlddmkm="+$st.ServiceState+" | "+$st.ServiceReason)}
    if($st.RuntimeSmi){$stageLines.Add("  nvidia-smi="+$st.RuntimeSmi+" ["+$st.RuntimeSmiSource+"]")}
    if($st.RuntimeNvml){$stageLines.Add("  nvml.dll="+$st.RuntimeNvml+" ["+$st.RuntimeNvmlSource+"]")}
    $stageLines.Add("")
}
$stageLines|Out-File $gpuStageLog -Encoding UTF8

if($nvTargets.Count -gt 0){
    foreach($ng in $nvTargets){
        $st=$nvidiaDeepStatus[$ng.HWID]
        if($st){$nvidiaLines.Add(("NVIDIA DEEP STATUS {0}:{1}: {2} - {3}" -f $ng.VEN,$ng.DEV,$st.Status,$st.Reason))}
        $sg=$gpuDriverStage[$ng.HWID]
        if($sg){
            $nvidiaLines.Add(("STAGE {0}:{1}: MATCH={2}; LOAD={3}/{4}; PNP={5}; NVML={6}; SERVICE={7}" -f $ng.VEN,$ng.DEV,$sg.MatchStatus,$sg.LoadStatus,$sg.LoadMethod,$sg.PnpStatus,$sg.VendorQueryStatus,$sg.ServiceState))
        }
    }
}
$nvidiaLines | Out-File $nvidiaLog -Encoding UTF8

function ShortText([string]$text,[int]$max=220) {
    if (!$text) { return "" }
    $t=([string]$text).Trim()
    if ($t.Length -le $max) { return $t }
    return $t.Substring(0,$max-3)+"..."
}
function Get-VbiosProfileMatch($g,$deep) {
    if (!$deep) { return $null }
    $ven=UpperHex $g.VEN; $dev=UpperHex $g.DEV; $vb=(S $deep.VBIOS).ToUpper()
    if (!$ven -or !$dev -or !$vb) { return $null }

    # COU-EYE prefers the deduplicated runtime index (PCI + VBIOS -> unique ROM profiles).
    $idx=@()
    if ($VbiosRuntime) {
        $idx=@($VbiosRuntime | Where-Object {
            (UpperHex $_.PciVendorID) -eq $ven -and (UpperHex $_.PciDeviceID) -eq $dev -and (S $_.VBIOSVersion).ToUpper() -eq $vb
        })
    }
    if ($idx.Count -gt 0) {
        $r=$idx[0]
        return [pscustomobject]@{
            Count=[int]$r.UniqueROMProfiles; Text=(S $r.ReferenceLabels); Confidence=(S $r.MatchClass);
            PartnerGroups=(S $r.PartnerGroups); BoardStrings=(S $r.BoardStrings); ProductStrings=(S $r.ProductStrings);
            RuntimeKey=(S $r.RuntimeKey)
        }
    }

    # Fallback for compatibility if runtime index is missing.
    if (!$VbiosProfiles) { return [pscustomobject]@{Count=0;Text="NO REFERENCE MATCH";Confidence="NONE";PartnerGroups="";BoardStrings="";ProductStrings="";RuntimeKey=("${ven}:${dev}:${vb}")} }
    $matches=@($VbiosProfiles | Where-Object {
        (UpperHex $_.PciVendorID) -eq $ven -and (UpperHex $_.PciDeviceID) -eq $dev -and (S $_.VBIOSVersion).ToUpper() -eq $vb
    })
    if ($matches.Count -eq 0) { return [pscustomobject]@{Count=0;Text="NO REFERENCE MATCH";Confidence="NONE";PartnerGroups="";BoardStrings="";ProductStrings="";RuntimeKey=("${ven}:${dev}:${vb}")} }
    $labels=@();$groups=@();$boards=@();$products=@();$hashes=@()
    foreach($p in $matches) {
        $label=((S $p.SourceBrandLabel)+" "+(S $p.SourceGPULabel)+" "+(S $p.SourceVRAMMiBLabel)+"MiB").Trim()
        if ($label -and $labels -notcontains $label) { $labels += $label }
        foreach($x in ((S $p.PartnerGroup)-split '\|')){if($x -and $groups -notcontains $x){$groups+=$x}}
        foreach($x in ((S $p.BoardString)-split '\|')){if($x -and $boards -notcontains $x){$boards+=$x}}
        foreach($x in ((S $p.ProductStrings)-split '\|\|')){if($x -and $products -notcontains $x.Trim()){$products+=$x.Trim()}}
        if((S $p.SHA256) -and $hashes -notcontains (S $p.SHA256)){$hashes+=(S $p.SHA256)}
    }
    $conf=if($hashes.Count -eq 1 -and $labels.Count -eq 1){"PROFILE_CANDIDATE"}else{"PROFILE_AMBIGUOUS"}
    return [pscustomobject]@{Count=$hashes.Count;Text=($labels -join " / ");Confidence=$conf;PartnerGroups=($groups -join " / ");BoardStrings=($boards -join " / ");ProductStrings=($products -join " / ");RuntimeKey=("${ven}:${dev}:${vb}")}
}
function Get-PciReferenceCoverage($g) {
    if (!$PciProfileIndex) { return $null }
    $ven=UpperHex $g.VEN; $dev=UpperHex $g.DEV
    $m=@($PciProfileIndex | Where-Object { (UpperHex $_.PciVendorID) -eq $ven -and (UpperHex $_.PciDeviceID) -eq $dev })
    if ($m.Count -eq 0) { return $null }
    $r=$m[0]
    return [pscustomobject]@{Count=[int]$r.UniqueROMProfiles;FirmwareTypes=(S $r.FirmwareTypes);ASICFamilies=(S $r.ASICFamilies);ASICVariants=(S $r.ASICVariants);InternalModelHints=(S $r.InternalModelHints);ReferenceLabels=(S $r.ReferenceLabels)}
}

function Get-ObservedGpuMatch($g,$deep) {
    if (!$ObservedGpu) { return $null }
    $m=@($ObservedGpu | Where-Object {
        (UpperHex $_.VEN) -eq $g.VEN -and (UpperHex $_.DEV) -eq $g.DEV -and
        ((!(S $_.SUBSYS)) -or (UpperHex $_.SUBSYS) -eq $g.SUBSYS) -and
        ((!(S $_.SUBVENDOR)) -or (UpperHex $_.SUBVENDOR) -eq $g.SUBVENDOR_ID) -and
        ((!(S $_.VBIOS)) -or ($deep -and (S $_.VBIOS).ToUpper() -eq $deep.VBIOS))
    })
    if ($m.Count -eq 0) { return $null }
    return ($m | ForEach-Object {$_.ObservedProduct}) -join " / "
}
function Get-RamObservedMatch($m) {
    if (!$ObservedRam) { return $null }
    $cap=[int](GB $m.Capacity); $mfg=S $m.Manufacturer; $pnm=S $m.PartNumber; $spd=[int](S $m.Speed)
    $hits=@($ObservedRam | Where-Object {
        (S $_.ManufacturerRaw) -eq $mfg -and
        ((!(S $_.PartNumber)) -or (S $_.PartNumber) -eq $pnm) -and
        ([int]$_.CapacityGB -eq $cap) -and
        ((!(S $_.ReportedSpeed)) -or ([int]$_.ReportedSpeed -eq $spd))
    })
    if ($hits.Count -eq 0) { return $null }
    $h=$hits[0]
    return [pscustomobject]@{Brand=$h.ObservedBrand;Model=$h.ObservedModel;Spec=$h.ObservedSpec;AutoAssert=$h.AutoAssertModel;Verification=$h.PhysicalVerification}
}

# -----------------------------------------------------------------------------
# KOREA PRODUCT MASTER MATCHER (candidate only; never overrides runtime evidence)
# -----------------------------------------------------------------------------
function Get-KoreaCandidates($row) {
    if (!$KoreaMaster -or $KoreaMaster.Count -eq 0) { return @() }
    $cat=(S $row.Category).ToUpper()
    $mapped=if($cat -like 'STORAGE*'){'STORAGE'}else{$cat}
    $hits=@($KoreaMaster | Where-Object {
        $mc=(S $_.Category).ToUpper()
        if($mc -ne $mapped){return $false}
        if((S $_.Brand) -and !(ContainsCI ((S $row.Manufacturer)+' '+(S $row.Model)) (S $_.Brand))){return $false}
        if((S $_.ManufacturerPartNumber) -and !(ContainsCI ((S $row.PartNumber)+' '+(S $row.Model)) (S $_.ManufacturerPartNumber))){return $false}
        if((S $_.ModelContains) -and !(ContainsCI (S $row.Model) (S $_.ModelContains))){return $false}
        if((S $_.CapacityGB) -and !(CapacityApproxMatch $_.CapacityGB $row.CapacityGB)){return $false}
        if((S $_.PCI_VEN) -and (UpperHex $_.PCI_VEN) -ne (UpperHex $row.VendorID)){return $false}
        if((S $_.PCI_DEV) -and (UpperHex $_.PCI_DEV) -ne (UpperHex $row.DeviceID)){return $false}
        if((S $_.PCI_SUBVENDOR) -and (UpperHex $_.PCI_SUBVENDOR) -ne (UpperHex $row.SubvendorID)){return $false}
        if((S $_.PCI_SUBSYS) -and (UpperHex $_.PCI_SUBSYS) -ne (UpperHex $row.SubsystemID)){return $false}
        return $true
    })
    return $hits
}

# -----------------------------------------------------------------------------
# RAW + NORMALIZED COMPONENT EVIDENCE CSV
# -----------------------------------------------------------------------------
@("ASSET_ID",$AssetID,"COUCODE",$Coucode,"TIMESTAMP_KST",(KstString 'yyyy-MM-ddTHH:mm:ss.fffzzz'),"SYSTEM",($cs|fl *|Out-String),"SYSTEM_PRODUCT",($csp|fl *|Out-String),"BIOS",($bios|fl *|Out-String),"BASEBOARD",($bb|fl *|Out-String),"CPU",($cpu|fl *|Out-String),"MEMORY",($ram|fl *|Out-String),"STORAGE",($disks|fl *|Out-String),"STORAGE_DEEP",($physicalDisks|fl *|Out-String),"GPU",($gpus|fl *|Out-String),"PLATFORM_IDENTITY_SHA256",$platformIdentityHash,"RAW_SMBIOS_SNAPSHOT_SHA256",$smbiosHash) | Out-File $raw -Encoding UTF8

Set-InspectionProgress '검수 결과 저장'
$rows=@()
$rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category="SYSTEM";Index=1;Manufacturer=(S $cs.Manufacturer);Model=(S $cs.Model);PartNumber=(S $cs.SystemType);Serial=(S $bios.SerialNumber);CapacityGB="";Speed="";VendorID="";DeviceID="";SubsystemID="";SubvendorID="";HardwareID=(S $csp.UUID);EvidenceLevel="WMI_SMBIOS";Notes=("UUID="+(S $csp.UUID)+"; SystemFamily="+(S $cs.SystemFamily)+"; SystemSKU="+(S $cs.SystemSKUNumber)+"; PlatformIdentitySHA256="+$platformIdentityHash+"; RawSMBIOSSnapshotSHA256="+$smbiosHash)}
$rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category="BIOS";Index=1;Manufacturer=(S $bios.Manufacturer);Model=(S $bios.SMBIOSBIOSVersion);PartNumber=(S $bios.Version);Serial=(S $bios.SerialNumber);CapacityGB="";Speed="";VendorID="";DeviceID="";SubsystemID="";SubvendorID="";HardwareID="";EvidenceLevel="WMI_SMBIOS";Notes=("ReleaseDate="+(S $bios.ReleaseDate)+"; SMBIOS="+$smbiosMajor+"."+$smbiosMinor+"; PlatformIdentitySHA256="+$platformIdentityHash+"; RawSMBIOSSnapshotSHA256="+$smbiosHash)}
$rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category="MAINBOARD";Index=1;Manufacturer=(S $bb.Manufacturer);Model=(S $bb.Product);PartNumber=(S $bb.Version);Serial=(S $bb.SerialNumber);CapacityGB="";Speed="";VendorID="";DeviceID="";SubsystemID="";SubvendorID="";HardwareID="";EvidenceLevel="WMI_SMBIOS";Notes=("Tag="+(S $bb.Tag)+"; PoweredOn="+(S $bb.PoweredOn))}
$i=0; foreach($c in $cpu){
    $i++;$cpuid=Decode-CpuidSignature (S $c.ProcessorId);$cpuidText=if($cpuid){("CPUIDSignature="+$cpuid.SignatureHex+"; CPUIDFamily="+$cpuid.Family+"; CPUIDModel="+$cpuid.Model+"; CPUIDStepping="+$cpuid.Stepping)}else{"CPUIDSignature=UNAVAILABLE"};$cpuNotes=("ProcessorId="+(S $c.ProcessorId)+"; "+$cpuidText+"; WMIFamilyCode="+(S $c.Family)+"; WMIRevision="+(S $c.Revision)+"; WMIStepping="+(S $c.Stepping)+"; Arch="+(S $c.Architecture)+"; Socket="+(S $c.SocketDesignation)+"; Cores="+(S $c.NumberOfCores)+"; EnabledCores="+(S $c.NumberOfEnabledCore)+"; Logical="+(S $c.NumberOfLogicalProcessors)+"; L2KB="+(S $c.L2CacheSize)+"; L3KB="+(S $c.L3CacheSize))
    $rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category="CPU";Index=$i;Manufacturer=(S $c.Manufacturer);Model=(S $c.Name);PartNumber=(S $c.Caption);Serial=(S $c.SerialNumber);CapacityGB="";Speed=(S $c.MaxClockSpeed);VendorID="";DeviceID="";SubsystemID="";SubvendorID="";HardwareID=(S $c.ProcessorId);EvidenceLevel="WMI_CPUID_EVIDENCE";Notes=$cpuNotes}
}
$i=0; foreach($m in $ram){
    $i++;$rm=Get-RamObservedMatch $m;$mt=MemoryTypeName $m.SMBIOSMemoryType;$ff=FormFactorName $m.FormFactor;$spd=if(S $m.ConfiguredClockSpeed){S $m.ConfiguredClockSpeed}else{S $m.Speed}
    $notes=("Locator="+(S $m.DeviceLocator)+"; Bank="+(S $m.BankLabel)+"; SMBIOSMemoryType="+$mt+"; FormFactor="+$ff+"; RatedSpeed="+(S $m.Speed)+"; ConfiguredSpeed="+(S $m.ConfiguredClockSpeed)+"; DataWidth="+(S $m.DataWidth)+"; TotalWidth="+(S $m.TotalWidth)+"; TypeDetail="+(S $m.TypeDetail)+"; SPD_DIRECT=NOT_AVAILABLE_WITHOUT_APPROVED_HELPER")
    if($rm){$notes += ("; ObservedProfile="+$rm.Brand+" "+$rm.Model+" "+$rm.Spec+"; Verification="+$rm.Verification+"; AutoAssert="+$rm.AutoAssert)}
    $rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category="RAM";Index=$i;Manufacturer=(S $m.Manufacturer);Model=$(if($rm -and $rm.AutoAssert -eq "YES"){$rm.Model}else{""});PartNumber=(S $m.PartNumber);Serial=(S $m.SerialNumber);CapacityGB=(GB $m.Capacity);Speed=$spd;VendorID="";DeviceID="";SubsystemID="";SubvendorID="";HardwareID=(S $m.DeviceLocator);EvidenceLevel="WMI_SMBIOS";Notes=$notes}
}
$i=0; foreach($x in $disks){
    $i++;$usb=((S $x.InterfaceType)-eq"USB")-or((S $x.PNPDeviceID)-match'^USB');$deepMatch=$null
    if($physicalDisks){
        $xs=(S $x.SerialNumber).Replace(' ','')
        if($xs){$deepMatch=@($physicalDisks|Where-Object{(S $_.SerialNumber).Replace(' ','') -eq $xs}|Select-Object -First 1)}
        if(!$deepMatch){$deepMatch=@($physicalDisks|Where-Object{ContainsCI (S $_.FriendlyName) (S $x.Model) -or ContainsCI (S $x.Model) (S $_.FriendlyName)}|Select-Object -First 1)}
        if($deepMatch -is [array] -and $deepMatch.Count){$deepMatch=$deepMatch[0]}
    }
    $controllerBus=if($deepMatch){BusTypeName $deepMatch.BusType}else{S $x.InterfaceType};$protocol=Get-StorageProtocol $x $deepMatch;$fw=if($deepMatch){S $deepMatch.FirmwareVersion}else{S $x.FirmwareRevision}
    $usb=$usb -or ($protocol -eq "USB") -or ($controllerBus -eq "USB")
    $sn=if(S $x.SerialNumber){S $x.SerialNumber}elseif($deepMatch){S $deepMatch.SerialNumber}else{""}
    $transportDisplay=if($protocol -eq 'NVMe' -and $controllerBus -eq 'RAID'){'NVMe via RAID/RST'}elseif($protocol){$protocol}else{$controllerBus}
    $notes=("Interface="+(S $x.InterfaceType)+"; DeviceProtocol="+$protocol+"; ControllerBus="+$controllerBus+"; TransportDisplay="+$transportDisplay+"; Firmware="+$fw+"; MediaType="+(S $x.MediaType)+"; Index="+(S $x.Index)+"; NVME_IDENTIFY_DIRECT=NOT_ENABLED")
    if($deepMatch){$notes += ("; StorageWMI=AVAILABLE; Health="+(S $deepMatch.HealthStatus)+"; PhysicalSector="+(S $deepMatch.PhysicalSectorSize)+"; LogicalSector="+(S $deepMatch.LogicalSectorSize))}
    $rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category=$(if($usb){"STORAGE_USB"}else{"STORAGE"});Index=$i;Manufacturer=(S $x.Manufacturer);Model=(S $x.Model);PartNumber=$fw;Serial=$sn;CapacityGB=(GB $x.Size);Speed="";VendorID="";DeviceID="";SubsystemID="";SubvendorID="";HardwareID=(S $x.PNPDeviceID);EvidenceLevel=$(if($deepMatch){"WMI_STORAGE_ENRICHED"}else{"WMI_STORAGE"});Notes=$notes}
}
$i=0; foreach($g in $gpus){
    $i++; $deep=if($nvidiaDeep.ContainsKey($g.HWID)){$nvidiaDeep[$g.HWID]}else{$null}; $cap=if($deep){$deep.MemoryGB}else{""};$ser=""
    $notes=($g.Type+"; PCIName="+$g.PciName+"; Subvendor="+$g.SUBVENDOR+"; SubsystemName="+$g.SubsystemName+"; CC="+$g.CC+"; REV="+$g.REV)
    if($g.VEN -eq '10DE'){ $nst=$nvidiaDeepStatus[$g.HWID]; if($nst){$notes += ("; NVIDIADeepStatus="+$nst.Status+"; NVIDIADeepReason="+$nst.Reason)}else{$notes += '; NVIDIADeepStatus=NOT_ATTEMPTED; NVIDIADeepReason=No deep-scan status was recorded.'} }
    $gst=$gpuDriverStage[$g.HWID]
    if($gst){$notes += ("; DriverMatch="+$gst.MatchStatus+"; DriverLoad="+$gst.LoadStatus+"; LoadMethod="+$gst.LoadMethod+"; PnPStarted="+$gst.PnpStatus+"; VendorQuery="+$gst.VendorQueryStatus+"; RuntimeSmiSource="+$gst.RuntimeSmiSource+"; RuntimeNvmlSource="+$gst.RuntimeNvmlSource)}
    $pcov=Get-PciReferenceCoverage $g
    if($pcov){$notes += ("; ROMDBProfiles="+$pcov.Count+"; ROMDBEvidence=PCI_REFERENCE_ONLY");if($pcov.ASICFamilies){$notes += ("; ROMDBASIC="+$pcov.ASICFamilies)};if($pcov.ASICVariants){$notes += ("; ROMDBVariants="+$pcov.ASICVariants)};if($pcov.InternalModelHints){$notes += ("; ROMDBModelHints="+$pcov.InternalModelHints)}}
    $evidence="PCI_VERIFIED"
    if($deep){$evidence="DRIVER_VERIFIED";$notes += ("; GPUUUID="+$deep.UUID+"; VRAMMiB="+$deep.MemoryMiB+"; VBIOS="+$deep.VBIOS+"; BusID="+$deep.BusID+"; Driver="+$deep.DriverVersion+"; Detection=DRIVER_VERIFIED");$vp=Get-VbiosProfileMatch $g $deep;if($vp){$notes += ("; VBIOSProfile="+$vp.Text+"; VBIOSProfileConfidence="+$vp.Confidence+"; VBIOSRuntimeKey="+$vp.RuntimeKey);if($vp.PartnerGroups){$notes += ("; PartnerGroups="+$vp.PartnerGroups)};if($vp.BoardStrings){$notes += ("; BoardCandidates="+$vp.BoardStrings)};if($vp.ProductStrings){$notes += ("; ProductCandidates="+$vp.ProductStrings)}}}
    $obs=Get-ObservedGpuMatch $g $deep;if($obs){$notes += ("; ObservedReferenceSample="+$obs+"; AutoAssertSKU=NO")}
    if($g.VEN -eq '8086' -and $g.Type -eq 'Discrete'){$notes += '; IntelDiscrete=PCI_VERIFIED; IntelLiveDeep=NOT_IMPLEMENTED'}
    $rows += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category="GPU";Index=$i;Manufacturer=$g.Vendor;Model=$(if($deep){$deep.Name}else{$g.Model});PartNumber="";Serial=$ser;CapacityGB=$cap;Speed="";VendorID=$g.VEN;DeviceID=$g.DEV;SubsystemID=$g.SUBSYS;SubvendorID=$g.SUBVENDOR_ID;HardwareID=$g.HWID;EvidenceLevel=$evidence;Notes=$notes}
}
# Keep Manufacturer and all original hardware evidence intact. Append resolved
# brand and source for audit; UI uses the same resolver, including historical CSVs.
foreach($identityRow in $rows){
 $identity=$null
 if($identityRow.Category -eq 'RAM'){$identity=Resolve-RamManufacturer $identityRow}
 if($identityRow.Category -eq 'GPU'){$identity=Resolve-GpuManufacturer $identityRow}
 if($identityRow.Category -eq 'STORAGE'){$identity=Resolve-StorageManufacturer $identityRow}
 if($identity){
  $safeBrand=([string]$identity.Brand) -replace '[;\r\n]',' '
  $identityRow.Notes+='; ResolvedManufacturer='+$safeBrand+'; ManufacturerSource='+$identity.Source+'; ManufacturerKey='+(([string]$identity.Key) -replace '[;\r\n]',' ')
 }
}
$rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8

# -----------------------------------------------------------------------------
# KOREA PRODUCT MASTER CANDIDATE MATCH + COVERAGE GAPS
# -----------------------------------------------------------------------------
$productMatches=@();$coverageGaps=@()
foreach($row in @($rows|Where-Object{$_.Category -in @('CPU','RAM','STORAGE','MAINBOARD','GPU')})){
    $cand=@(Get-KoreaCandidates $row)
    $status=if(!$KoreaMaster -or $KoreaMaster.Count-eq0){'MASTER_EMPTY'}elseif($cand.Count-eq0){'NO_MASTER_MATCH'}elseif($cand.Count-eq1){'CANDIDATE_MATCH'}else{'AMBIGUOUS_MATCH'}
    $productMatches += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category=$row.Category;Index=$row.Index;DetectedManufacturer=$row.Manufacturer;DetectedModel=$row.Model;DetectedPartNumber=$row.PartNumber;DetectedCapacityGB=$row.CapacityGB;PCI_VEN=$row.VendorID;PCI_DEV=$row.DeviceID;PCI_SUBVENDOR=$row.SubvendorID;PCI_SUBSYS=$row.SubsystemID;MatchStatus=$status;CandidateCount=$cand.Count;ProductIDs=(($cand|ForEach-Object{$_.ProductID})-join'|');RetailNames=(($cand|ForEach-Object{$_.RetailName})-join' | ');ReleaseYears=(($cand|ForEach-Object{$_.ReleaseYear}|Select-Object -Unique)-join'|');EvidenceLevel=$row.EvidenceLevel}
    if($status -ne 'CANDIDATE_MATCH'){
        $reason=if($status-eq'MASTER_EMPTY'){'KOREA_PRODUCT_MASTER_EMPTY'}elseif($status-eq'AMBIGUOUS_MATCH'){'MULTIPLE_PRODUCT_CANDIDATES'}else{'NEW_OR_UNREGISTERED_HARDWARE'}
        $coverageGaps += [pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;Category=$row.Category;DetectedKey=((S $row.Manufacturer)+' | '+(S $row.Model)+' | '+(S $row.PartNumber)+' | '+(S $row.VendorID)+':'+(S $row.DeviceID));Reason=$reason;SuggestedAction='Add/verify Korea retail SKU in DB/KOREA_PRODUCT_MASTER.csv; do not discard runtime evidence.'}
    }
}
$productMatches|Export-Csv $productMatchCsv -NoTypeInformation -Encoding UTF8
$coverageGaps|Export-Csv $coverageCsv -NoTypeInformation -Encoding UTF8


# -----------------------------------------------------------------------------
# V1.3.11 FULL EVIDENCE ARCHITECTURE
# NO SILENT SKIP: every required evidence item receives an explicit status.
# Current Core PE may finish collection while the inspection remains INCOMPLETE_EVIDENCE.
# DeepPE orchestration is represented by *_DEEP_SCAN_REQUEST.json; unsupported/missing
# deep evidence is BLOCKED, never silently promoted to VERIFIED.
# -----------------------------------------------------------------------------
Set-InspectionProgress '필수 증거 완전성 평가'
$evidencePlan = New-Object 'Collections.Generic.List[object]'
$evidenceStatus = New-Object 'Collections.Generic.List[object]'
function Add-EvidenceRecord {
    param(
        [string]$ComponentKey,[string]$Category,[int]$ComponentIndex,[string]$EvidenceItem,
        [string]$Requirement,[string]$PlannedSource,[string]$Status,[string]$ActualSource,
        [string]$Reason,[string]$BlocksCompletion='YES',[string]$NextAction=''
    )
    $evidencePlan.Add([pscustomobject]@{
        AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;ComponentKey=$ComponentKey;Category=$Category;ComponentIndex=$ComponentIndex;
        EvidenceItem=$EvidenceItem;Requirement=$Requirement;PlannedSource=$PlannedSource;BlocksCompletion=$BlocksCompletion;
        Rationale='Required evidence is explicit. Missing/blocked evidence must never be treated as verified.'
    }) | Out-Null
    $evidenceStatus.Add([pscustomobject]@{
        AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;ComponentKey=$ComponentKey;Category=$Category;ComponentIndex=$ComponentIndex;
        EvidenceItem=$EvidenceItem;Requirement=$Requirement;Status=$Status;ActualSource=$ActualSource;Reason=$Reason;
        BlocksCompletion=$BlocksCompletion;NextAction=$NextAction
    }) | Out-Null
}

$sysCoreOk = ((S $cs.Manufacturer) -and (S $cs.Model) -and (S $bios.SerialNumber) -and (S $csp.UUID) -and $platformIdentityHash)
Add-EvidenceRecord 'SYSTEM:1' 'SYSTEM' 1 'SYSTEM_IDENTITY' 'REQUIRED' 'SMBIOS/WMI + Platform Identity' $(if($sysCoreOk){'VERIFIED'}else{'ERROR'}) 'WMI_SMBIOS_PLATFORM_IDENTITY' $(if($sysCoreOk){'System identity, serial, UUID and stable platform identity were collected.'}else{'One or more required system identity fields are missing.'}) 'YES' 'Resolve missing SMBIOS/WMI identity fields before acceptance.'

$boardOk = ((S $bb.Manufacturer) -and (S $bb.Product) -and (S $bios.SMBIOSBIOSVersion))
Add-EvidenceRecord 'MAINBOARD:1' 'MAINBOARD' 1 'BOARD_BIOS_IDENTITY' 'REQUIRED' 'SMBIOS/WMI' $(if($boardOk){'VERIFIED'}else{'ERROR'}) 'WMI_SMBIOS' $(if($boardOk){'Board identity and BIOS version collected.'}else{'Mainboard or BIOS identity is incomplete.'}) 'YES' 'Resolve missing board/BIOS fields.'

$ci=0
foreach($c in $cpu){
    $ci++;$cp=Decode-CpuidSignature (S $c.ProcessorId);$ok=((S $c.Name) -and (S $c.ProcessorId) -and $cp)
    Add-EvidenceRecord ("CPU:"+$ci) 'CPU' $ci 'CPU_IDENTITY_CPUID' 'REQUIRED' 'WMI + CPUID signature decode' $(if($ok){'VERIFIED'}else{'ERROR'}) 'WMI_CPUID_EVIDENCE' $(if($ok){'ProcessorId and decoded CPUID family/model/stepping collected.'}else{'CPU ProcessorId or CPUID decode unavailable.'}) 'YES' 'Resolve CPU identity before acceptance.'
}

$ri=0
foreach($m in $ram){
    $ri++;$ff=FormFactorName $m.FormFactor;$mt=MemoryTypeName $m.SMBIOSMemoryType
    $ramCoreOk=((GB $m.Capacity) -gt 0 -and (S $m.DeviceLocator))
    Add-EvidenceRecord ("RAM:"+$ri) 'RAM' $ri 'RAM_SMBIOS' 'REQUIRED' 'SMBIOS/WMI' $(if($ramCoreOk){'VERIFIED'}else{'ERROR'}) 'WMI_SMBIOS' $(if($ramCoreOk){'Capacity/slot/SMBIOS memory data collected.'}else{'RAM SMBIOS evidence incomplete.'}) 'YES' 'Resolve RAM SMBIOS evidence.'
    $spdReason=if($ff -in @('DIMM','SODIMM')){'Direct SPD EEPROM evidence is required for socketed memory, but an approved live SPD reader is not integrated in Core PE.'}else{'Direct SPD accessibility is not yet proven for this memory topology ('+$mt+' '+$ff+'); COU-EYE must not assume it is unavailable.'}
    Add-EvidenceRecord ("RAM:"+$ri) 'RAM' $ri 'SPD_DIRECT' 'REQUIRED_IF_ACCESSIBLE' 'Approved SMBus/SPD direct reader + raw SPD SHA256/CRC/JEDEC IDs' 'BLOCKED' 'NOT_COLLECTED' $spdReason 'YES' 'Run Deep Evidence SPD engine when approved helper/driver is integrated; otherwise record hardware-not-exposed proof.'
}

$internalStorageRows=@($rows|Where-Object{$_.Category -eq 'STORAGE'})
foreach($sr in $internalStorageRows){
    $idx=[int]$sr.Index;$coreOk=((S $sr.Model) -and ((S $sr.Serial) -or (S $sr.HardwareID)))
    Add-EvidenceRecord ("STORAGE:"+$idx) 'STORAGE' $idx 'STORAGE_ENUMERATION' 'REQUIRED' 'Win32_DiskDrive + Storage Management WMI' $(if($coreOk){'VERIFIED'}else{'ERROR'}) $sr.EvidenceLevel $(if($coreOk){'Storage model/transport evidence collected.'}else{'Storage core evidence incomplete.'}) 'YES' 'Resolve storage enumeration.'
    $proto=if((S $sr.Notes) -match 'DeviceProtocol=([^;]+)'){$matches[1].Trim()}else{'UNKNOWN'}
    Add-EvidenceRecord ("STORAGE:"+$idx) 'STORAGE' $idx 'DIRECT_IDENTIFY' 'REQUIRED' 'NVMe Identify / ATA Identify raw data + firmware/serial cross-check' 'BLOCKED' 'NOT_COLLECTED' ('Direct NVMe/ATA Identify is not yet integrated. Observed protocol='+$proto) 'YES' 'Run approved direct-identify helper in Deep Evidence phase.'
}

$gi=0
foreach($g in $gpus){
    $gi++;$pciOk=((S $g.VEN) -and (S $g.DEV) -and (S $g.HWID))
    Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_PCI_IDENTITY' 'REQUIRED' 'PCI direct scan + pci.ids' $(if($pciOk){'VERIFIED'}else{'ERROR'}) 'PCI_DIRECT' $(if($pciOk){'PCI VEN/DEV/HWID evidence collected.'}else{'GPU PCI identity incomplete.'}) 'YES' 'Resolve PCI enumeration.'
    if($g.VEN -eq '10DE'){
        $gst=$gpuDriverStage[$g.HWID]
        $nst=$nvidiaDeepStatus[$g.HWID]
        $deepOk=$nvidiaDeep.ContainsKey($g.HWID)
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_DRIVER_MATCH' 'REQUIRED' 'Target Windows DriverStore / COU-EYE repository exact DEV+SUBSYS match' $(if($gst){$gst.MatchStatus}else{'BLOCKED'}) $(if($gst -and $gst.MatchStatus -eq 'VERIFIED'){'NVIDIA_INF_RESOLVER'}else{'NOT_COLLECTED'}) $(if($gst){$gst.MatchReason}else{'No NVIDIA driver-stage record.'}) 'YES' 'Resolve a compatible NVIDIA display INF before acceptance.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_DRIVER_LOADED' 'REQUIRED' 'DeepPE injected driver + DrvLoad/PnP activation' $(if($gst){$gst.LoadStatus}else{'BLOCKED'}) $(if($gst -and $gst.LoadStatus -eq 'VERIFIED'){('NVIDIA_'+$gst.LoadMethod)}else{'NOT_COLLECTED'}) $(if($gst){$gst.LoadReason}else{'NVIDIA driver load stage unavailable.'}) 'YES' 'Use DeepPE/offline driver injection and verify live load.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_PNP_STARTED' 'REQUIRED' 'PnPUtil post-driver state' $(if($gst){$gst.PnpStatus}else{'BLOCKED'}) $(if($gst -and $gst.PnpStatus -eq 'VERIFIED'){'PCI_POST_DRIVER'}else{'NOT_COLLECTED'}) $(if($gst){$gst.PnpReason}else{'NVIDIA PnP stage unavailable.'}) 'YES' 'Verify Display-class GPU reports Status=Started after driver load.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_NVML_QUERY' 'REQUIRED' 'Runtime-matched NVML/nvidia-smi telemetry' $(if($deepOk){'VERIFIED'}elseif($gst){$gst.VendorQueryStatus}else{'BLOCKED'}) $(if($deepOk -and $nvidiaDeep[$g.HWID].Source -eq 'NVIDIA_NVML_DIRECT'){'NVIDIA_NVML_DIRECT'}elseif($deepOk){'NVIDIA_SMI'}else{'NOT_COLLECTED'}) $(if($deepOk){'Target-matched live GPU telemetry collected; see NVIDIA log for the execution source.'}elseif($gst){$gst.VendorQueryReason}elseif($nst){$nst.Reason}else{'NVIDIA vendor telemetry unavailable.'}) 'YES' 'Verify runtime driver service and NVML communication; do not substitute PCI evidence.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_VENDOR_DEEP' 'ADVISORY' 'Aggregate NVIDIA deep state' $(if($deepOk){'VERIFIED'}else{'PRESENT_UNVERIFIED'}) $(if($deepOk){'NVIDIA_NVML'}else{'STAGED_GPU_EVIDENCE'}) $(if($nst){$nst.Reason}else{'Aggregate NVIDIA state unavailable.'}) 'NO' ''
    } elseif($g.VEN -eq '1002') {
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_VENDOR_DEEP' 'REQUIRED' 'AMD driver/API deep evidence' 'BLOCKED' 'NOT_COLLECTED' 'AMD live deep scan is not implemented in Core PE.' 'YES' 'Run AMD DeepPE/vendor evidence engine.'
    } elseif($g.VEN -eq '8086') {
        $gst=$gpuDriverStage[$g.HWID]
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_DRIVER_MATCH' 'REQUIRED' 'Target Windows DriverStore / COU-EYE repository DEV+SUBSYS match' $(if($gst){$gst.MatchStatus}else{'BLOCKED'}) $(if($gst -and $gst.MatchStatus -eq 'VERIFIED'){'INTEL_INF_RESOLVER'}else{'NOT_COLLECTED'}) $(if($gst){$gst.MatchReason}else{'No Intel driver-stage record.'}) 'YES' 'Resolve a compatible Intel graphics INF before acceptance.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_DRIVER_LOADED' 'REQUIRED' 'DeepPE injected driver + DrvLoad activation' $(if($gst){$gst.LoadStatus}else{'BLOCKED'}) $(if($gst -and $gst.LoadStatus -eq 'VERIFIED'){('INTEL_'+$gst.LoadMethod)}else{'NOT_COLLECTED'}) $(if($gst){$gst.LoadReason}else{'Intel driver load stage unavailable.'}) 'YES' 'Use DeepPE/offline driver injection and verify live load.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_PNP_STARTED' 'REQUIRED' 'PnPUtil post-driver state' $(if($gst){$gst.PnpStatus}else{'BLOCKED'}) $(if($gst -and $gst.PnpStatus -eq 'VERIFIED'){'PCI_POST_DRIVER'}else{'NOT_COLLECTED'}) $(if($gst){$gst.PnpReason}else{'Intel PnP stage unavailable.'}) 'YES' 'Verify Display-class GPU reports Status=Started after driver load.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_VENDOR_QUERY' 'REQUIRED' 'Intel vendor/API telemetry' 'BLOCKED' 'NOT_COLLECTED' 'Intel vendor/API deep telemetry is not yet integrated; driver/PnP stages are tracked separately.' 'YES' 'Integrate an approved Intel graphics telemetry engine.'
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_VENDOR_DEEP' 'ADVISORY' 'Aggregate Intel deep state' 'PRESENT_UNVERIFIED' 'STAGED_GPU_EVIDENCE' 'Intel driver/PnP stages are tracked separately; vendor telemetry remains pending.' 'NO' ''
    } else {
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_VENDOR_DEEP' 'REQUIRED' 'Vendor-specific deep evidence' 'BLOCKED' 'NOT_COLLECTED' 'No vendor deep engine is registered for this PCI vendor.' 'YES' 'Add approved vendor deep engine.'
    }
    if($g.Type -eq 'Discrete'){
        $rom=$nvidiaRom[$g.HWID]
        Add-EvidenceRecord ("GPU:"+$gi) 'GPU' $gi 'GPU_ROM_DIRECT' 'REQUIRED' 'Installed GPU ROM direct read + PCI/VBIOS validation + SHA256 + DB comparison' $(if($rom){$rom.Status}else{'BLOCKED'}) $(if($rom -and $rom.Status -eq 'VERIFIED'){'NVFLASH_READ_ONLY'}else{'NOT_COLLECTED'}) $(if($rom){$rom.Reason}else{'ROM read requires verified direct NVML telemetry in DeepPE.'}) 'YES' 'Inspect NVIDIA ROM trace and read-only acquisition manifest.'
    }
}

$pciOk=($pciRows.Count -gt 0)
Add-EvidenceRecord 'PCI:ALL' 'PCI' 1 'PCI_INVENTORY' 'REQUIRED' 'PnPUtil PCI bus enumeration' $(if($pciOk){'VERIFIED'}else{'ERROR'}) 'PCI_DIRECT' $(if($pciOk){('Enumerated '+$pciRows.Count+' PCI devices.')}else{'PCI inventory was empty or unavailable.'}) 'YES' 'Restore PnPUtil/PCI enumeration before acceptance.'

if($coverageGaps.Count -gt 0){
    Add-EvidenceRecord 'PRODUCT_MASTER:ALL' 'PRODUCT_MASTER' 1 'KOREA_PRODUCT_MASTER_COVERAGE' 'ADVISORY' 'Korea product master candidate DB' 'COVERAGE_GAP' 'RUNTIME_EVIDENCE_PRESERVED' ($coverageGaps.Count.ToString()+' product-master coverage gaps; hardware evidence remains preserved.') 'NO' 'Curate DB/KOREA_PRODUCT_MASTER.csv separately; never overwrite runtime evidence.'
}else{
    Add-EvidenceRecord 'PRODUCT_MASTER:ALL' 'PRODUCT_MASTER' 1 'KOREA_PRODUCT_MASTER_COVERAGE' 'ADVISORY' 'Korea product master candidate DB' 'VERIFIED_FALLBACK' 'PRODUCT_MASTER' 'No product-master coverage gap was emitted.' 'NO' ''
}

$evidencePlan | Export-Csv $evidencePlanCsv -NoTypeInformation -Encoding UTF8
$evidenceStatus | Export-Csv $evidenceStatusCsv -NoTypeInformation -Encoding UTF8
$blocking=@($evidenceStatus|Where-Object{$_.BlocksCompletion -eq 'YES'})
$verifiedBlocking=@($blocking|Where-Object{$_.Status -in @('VERIFIED','VERIFIED_FALLBACK')})
$evidenceCompleteness=if($blocking.Count -gt 0){[math]::Round((100.0*$verifiedBlocking.Count/$blocking.Count),1)}else{100.0}
$inspectionComplete=if($blocking.Count -eq $verifiedBlocking.Count){'YES'}else{'NO'}
$inspectionOutcome=if($inspectionComplete -eq 'YES'){'EVIDENCE_COMPLETE'}else{'INCOMPLETE_EVIDENCE'}
$deepRequests=@($evidenceStatus|Where-Object{$_.BlocksCompletion -eq 'YES' -and $_.Status -notin @('VERIFIED','VERIFIED_FALLBACK')}|ForEach-Object{
    $st=$_;$idx=0;if((S $st.ComponentKey) -match ':(\d+)$'){$idx=[int]$matches[1]}
    $componentRow=$null
    if($st.Category -in @('RAM','STORAGE','GPU')){$componentRow=@($rows|Where-Object{$_.Category -like ($st.Category+'*') -and [int]$_.Index -eq $idx}|Select-Object -First 1);if($componentRow.Count){$componentRow=$componentRow[0]}}
    [pscustomobject]@{
        ComponentKey=$st.ComponentKey;Category=$st.Category;EvidenceItem=$st.EvidenceItem;Status=$st.Status;Reason=$st.Reason;NextAction=$st.NextAction;
        DetectedManufacturer=$(if($componentRow){S $componentRow.Manufacturer}else{''});DetectedModel=$(if($componentRow){S $componentRow.Model}else{''});
        DetectedPartNumber=$(if($componentRow){S $componentRow.PartNumber}else{''});DetectedSerial=$(if($componentRow){S $componentRow.Serial}else{''});
        PCI_VEN=$(if($componentRow){S $componentRow.VendorID}else{''});PCI_DEV=$(if($componentRow){S $componentRow.DeviceID}else{''});
        PCI_SUBVENDOR=$(if($componentRow){S $componentRow.SubvendorID}else{''});PCI_SUBSYS=$(if($componentRow){S $componentRow.SubsystemID}else{''});
        HardwareID=$(if($componentRow){S $componentRow.HardwareID}else{''});
        PreferredDriverSourceOrder=@('TARGET_WINDOWS_DRIVERSTORE','COUEYE_DRIVER_REPOSITORY','MICROSOFT_INBOX')
    }
})
[pscustomobject]@{
    Schema='COU-EYE_DEEP_SCAN_REQUEST_V1';ArchitectureVersion='1.3.11';AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;GeneratedAt=(KstString 'o');Version=$Version;
    PlatformIdentitySHA256=$platformIdentityHash;InspectionComplete=$inspectionComplete;EvidenceCompleteness=$evidenceCompleteness;Outcome=$inspectionOutcome;
    Requests=$deepRequests
} | ConvertTo-Json -Depth 7 | Out-File $deepScanRequestJson -Encoding UTF8

# Rewrite inspection/session record with final evidence state while preserving StartedAt.
[pscustomobject]@{AssetID=$AssetID;WaybillNumber=$AssetID;Coucode=$Coucode;StartedAt=$inspectionStartedAt;CompletedAt=(KstString 'yyyy-MM-ddTHH:mm:ss.fffzzz');TimeBasis='KST_FIXED_UTC+09';Version=$Version;GpuScanMode=$GpuScanMode;ResultBase=$base;InspectionComplete=$inspectionComplete;EvidenceCompleteness=$evidenceCompleteness;Outcome=$inspectionOutcome;EvidencePlanFile=$evidencePlanCsv;EvidenceStatusFile=$evidenceStatusCsv;DeepScanRequestFile=$deepScanRequestJson} | Export-Csv $sessionCsv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

# -----------------------------------------------------------------------------
# INSPECTION EVIDENCE ONLY
# No baseline DB or acceptance decision is required.
# -----------------------------------------------------------------------------
# Inspection evidence only. No PASS/MISMATCH decision.
# HUMAN-READABLE SUMMARY
# -----------------------------------------------------------------------------
$o=New-Object Collections.Generic.List[string]
$o.Add("COU-EYE V$Version (Cou-Eye)");$o.Add("Hardware Evidence & Verification System");$o.Add("Time (KST): "+(KstString "yyyy-MM-dd HH:mm:ss zzz"));$o.Add("운송장 번호: "+$AssetID);$o.Add("Coucode: "+$Coucode);$o.Add("INSPECTION COMPLETE: "+$inspectionComplete);$o.Add("EVIDENCE COMPLETENESS: "+$evidenceCompleteness+"%");$o.Add("INSPECTION OUTCOME: "+$inspectionOutcome);$o.Add("")
$o.Add("GPU SCAN MODE: "+$GpuScanMode);$o.Add("");$o.Add("SYSTEM: "+(S $cs.Manufacturer)+" "+(S $cs.Model));$o.Add("SERIAL: "+(S $bios.SerialNumber));$o.Add("UUID: "+(S $csp.UUID));$o.Add("MAINBOARD: "+(S $bb.Manufacturer)+" "+(S $bb.Product)+" | REV="+(S $bb.Version));$o.Add("BIOS: "+(S $bios.Manufacturer)+" "+(S $bios.SMBIOSBIOSVersion));if($platformIdentityHash){$o.Add("PLATFORM IDENTITY SHA256: "+$platformIdentityHash+" [STABLE FIELDSET]")};if($smbiosHash){$o.Add("RAW SMBIOS SNAPSHOT SHA256: "+$smbiosHash+" [NON-STABLE SNAPSHOT]")};$o.Add("")
$o.Add("CPU:");$cpu|ForEach-Object{$cp=Decode-CpuidSignature (S $_.ProcessorId);$cpText=if($cp){("CPUID Family="+$cp.Family+" Model="+$cp.Model+" Stepping="+$cp.Stepping)}else{"CPUID=UNAVAILABLE"};$o.Add(" "+(S $_.Name)+" | ProcessorId="+(S $_.ProcessorId)+" | "+$cpText+" | WMI Family Code="+(S $_.Family)+" | Cores="+(S $_.NumberOfCores)+" Logical="+(S $_.NumberOfLogicalProcessors)+" | "+(S $_.MaxClockSpeed)+" MHz")};$o.Add("")
$o.Add("MEMORY: ${totalGB} GB")
$j=0; foreach($m in $ram){$j++;$mt=MemoryTypeName $m.SMBIOSMemoryType;$ff=FormFactorName $m.FormFactor;$line=(" DIMM{0}: {1}GB | {2} {3} | MFG={4} | PN={5} | SN={6} | Rated={7} / Configured={8} MT/s" -f $j,(GB $m.Capacity),$mt,$ff,(S $m.Manufacturer),(S $m.PartNumber),(S $m.SerialNumber),(S $m.Speed),(S $m.ConfiguredClockSpeed));$o.Add($line);$rm=Get-RamObservedMatch $m;if($rm){if($rm.AutoAssert -eq "YES"){$o.Add("        RESOLVED RAM: "+$rm.Brand+" "+$rm.Model+" | "+$rm.Spec+" [AUTOASSERT]")}else{$o.Add("        OBSERVED SAMPLE: "+$rm.Brand+" "+$rm.Model+" | "+$rm.Spec+" [REFERENCE ONLY]")}}}
$o.Add(" RAM SPD DIRECT : NOT ENABLED (approved helper/driver required)")
$o.Add("");$o.Add("STORAGE:");$j=0;foreach($x in $disks){$j++;$storageRow=@($rows|Where-Object {$_.Category -in @("STORAGE","STORAGE_USB") -and $_.Index -eq $j}|Select-Object -First 1);$tag=if($storageRow -and $storageRow[0].Category -eq "STORAGE_USB"){" [USB]"}else{""};$dm=$null;if($physicalDisks){$xs=(S $x.SerialNumber).Replace(' ','');if($xs){$dm=@($physicalDisks|Where-Object{(S $_.SerialNumber).Replace(' ','') -eq $xs}|Select-Object -First 1)};if(!$dm){$dm=@($physicalDisks|Where-Object{ContainsCI (S $_.FriendlyName) (S $x.Model) -or ContainsCI (S $x.Model) (S $_.FriendlyName)}|Select-Object -First 1)};if($dm -is [array] -and $dm.Count){$dm=$dm[0]}};$proto=Get-StorageProtocol $x $dm;$ctrl=if($dm){BusTypeName $dm.BusType}else{S $x.InterfaceType};$transport=if($proto -eq 'NVMe' -and $ctrl -eq 'RAID'){'NVMe via RAID/RST'}elseif($proto){$proto}else{$ctrl};$fwOut=if($dm -and (S $dm.FirmwareVersion)){S $dm.FirmwareVersion}else{S $x.FirmwareRevision};$snOut=if(S $x.SerialNumber){S $x.SerialNumber}elseif($dm){S $dm.SerialNumber}else{""};$o.Add((" Disk{0}{1}: {2} | {3}GB | SN={4} | FW={5} | Device={6} | Controller={7}" -f $j,$tag,(S $x.Model),(GB $x.Size),$snOut,$fwOut,$transport,$ctrl))}
if($storageDeep.Count -gt 0){$o.Add(" STORAGE MANAGEMENT WMI: AVAILABLE -> "+$storageCsv)}else{$o.Add(" STORAGE MANAGEMENT WMI: NOT AVAILABLE")};$o.Add(" NVMe/ATA DIRECT IDENTIFY: NOT ENABLED (approved helper/driver required)")
$o.Add("");$o.Add("GPU (PCI direct scan + pci.ids):")
if($gpus.Count -eq 0){$o.Add(" No PCI display controller found.");$o.Add(" Integrated GPU : NOT DETECTED");$o.Add(" Discrete GPU   : NOT INSTALLED / NOT DETECTED")}
else{
    $j=0
    foreach($g in $gpus){
        $j++;$o.Add((" GPU{0}: {1} | {2}" -f $j,$g.Vendor,$g.Model));$o.Add(("       TYPE={0} | VEN={1} DEV={2} SUBSYS={3} SUBVENDOR={4} ({5})" -f $g.Type,$g.VEN,$g.DEV,$g.SUBSYS,$g.SUBVENDOR_ID,$g.SUBVENDOR));$o.Add("       PCI DB="+$g.PciName);if($g.SubsystemName){$o.Add("       SUBSYSTEM DB="+$g.SubsystemName)};$o.Add("       HWID="+$g.HWID)
        if($g.VEN -eq '10DE'){ $nst=$nvidiaDeepStatus[$g.HWID]; if($nst){$o.Add(("       NVIDIA DEEP STATUS: {0} | {1}" -f $nst.Status,$nst.Reason))}else{$o.Add("       NVIDIA DEEP STATUS: NOT_ATTEMPTED | No status record")}}
        $gst=$gpuDriverStage[$g.HWID]
        if($gst){$o.Add(("       DRIVER STAGES: MATCH={0} | LOAD={1}/{2} | PNP={3} | VENDOR_QUERY={4}" -f $gst.MatchStatus,$gst.LoadStatus,$gst.LoadMethod,$gst.PnpStatus,$gst.VendorQueryStatus));if($gst.InfPath){$o.Add("       DRIVER INF: "+$gst.InfPath)};if($g.VEN -eq '10DE'){$o.Add(("       NVIDIA SERVICE: {0} | {1}" -f $gst.ServiceState,$gst.ServiceReason))}}
        $pcov=Get-PciReferenceCoverage $g;if($pcov){$o.Add(("       ROM DB COVERAGE: {0} unique profiles [PCI_REFERENCE_ONLY]" -f $pcov.Count));if($pcov.ASICFamilies){$o.Add("       ASIC FAMILY REFERENCE: "+(ShortText $pcov.ASICFamilies 180))};if($pcov.ASICVariants){$o.Add("       ASIC VARIANT REFERENCE: "+(ShortText $pcov.ASICVariants 180))};if($pcov.InternalModelHints){$o.Add("       INTERNAL MODEL HINT REFERENCE: "+(ShortText $pcov.InternalModelHints 220))}}
        if($nvidiaDeep.ContainsKey($g.HWID)){$deep=$nvidiaDeep[$g.HWID];$o.Add(("       NVIDIA DEEP: VRAM={0} MiB ({1} GB) | VBIOS={2}" -f $deep.MemoryMiB,$deep.MemoryGB,$deep.VBIOS));$o.Add(("                    BUS={0} | UUID={1}" -f $deep.BusID,$deep.UUID));$vp=Get-VbiosProfileMatch $g $deep;if($vp -and $vp.Count -gt 0){$o.Add("       VBIOS PROFILE: "+(ShortText $vp.Text 220)+" ["+$vp.Confidence+"]");$o.Add("       PROFILE KEY: "+$vp.RuntimeKey+" | UNIQUE ROMS="+$vp.Count);if($vp.PartnerGroups){$o.Add("       PARTNER GROUP: "+(ShortText $vp.PartnerGroups 180))};if($vp.BoardStrings){$o.Add("       BOARD FAMILY CANDIDATE: "+(ShortText $vp.BoardStrings 200))};if($vp.ProductStrings){$o.Add("       PRODUCT STRING CANDIDATE: "+(ShortText $vp.ProductStrings 240))}}}
        if($g.VEN -eq '8086' -and $g.Type -eq 'Discrete'){$o.Add('       INTEL ARC/DISCRETE: PCI_VERIFIED (live deep scan not implemented)')}
        $obs=Get-ObservedGpuMatch $g $deep;if($obs){$o.Add("       OBSERVED SAMPLE: "+$obs+" [REFERENCE ONLY]")}
    }
    $ig=@($gpus|Where-Object {$_.Type -eq "Integrated"});$dg=@($gpus|Where-Object {$_.Type -eq "Discrete"})
    if($ig.Count-gt0){$o.Add(" Integrated GPU : "+(($ig|ForEach-Object {$_.Model}) -join " / "))}else{$o.Add(" Integrated GPU : NOT DETECTED")}
    if($dg.Count-gt0){$o.Add(" Discrete GPU   : "+(($dg|ForEach-Object {$_.Model}) -join " / "))}else{$o.Add(" Discrete GPU   : NOT INSTALLED")}
}
$o.Add("");$o.Add("KOREA PRODUCT MASTER:")
if(!$KoreaMaster -or $KoreaMaster.Count-eq0){$o.Add(" Master DB is empty. Runtime hardware is preserved and every component is reported as a coverage gap.")}else{$o.Add(" Master records: "+$KoreaMaster.Count+" | Candidate matches: "+(@($productMatches|Where-Object{$_.MatchStatus-eq'CANDIDATE_MATCH'}).Count)+" | Coverage gaps: "+$coverageGaps.Count)}
$o.Add(" Match file : "+$productMatchCsv);$o.Add(" Gap file   : "+$coverageCsv)
$o.Add("");$o.Add("PCI INVENTORY CSV: "+$pcicsv);$o.Add("PCI PRE-DRIVER LOG: "+$pciraw);$o.Add("PCI POST-DRIVER LOG: "+$pciPostRaw);$o.Add("GPU DRIVER STAGE LOG: "+$gpuStageLog);$o.Add("NVIDIA LOG: "+$nvidiaLog)
$o.Add("EVIDENCE PLAN: "+$evidencePlanCsv)
$o.Add("EVIDENCE STATUS: "+$evidenceStatusCsv)
$o.Add("DEEP SCAN REQUEST: "+$deepScanRequestJson)
$o.Add("CORE HARDWARE SCAN COMPLETE")
if($inspectionComplete -eq 'YES'){$o.Add("FULL EVIDENCE COMPLETE")}else{$o.Add("FULL EVIDENCE INCOMPLETE - REQUIRED DEEP EVIDENCE REMAINS BLOCKED/ERROR") }
$o.Add("NOTE: COU-EYE V1.3.11 uses NO SILENT SKIP. Unknown hardware and unavailable deep scans are retained as explicit evidence states. BLOCKED/ERROR required evidence prevents INSPECTION COMPLETE=YES. Product-master gaps are advisory and never override runtime PCI/SMBIOS/WMI/driver/ROM evidence.")
$o | Out-File $sum -Encoding UTF8

Write-Host "";Write-Host "COU-EYE CORE SCAN COMPLETE";Write-Host ("Full Evidence Complete: "+$inspectionComplete+" | Completeness: "+$evidenceCompleteness+"% | Outcome: "+$inspectionOutcome);Write-Host "Evidence CSV: $csv";Write-Host "Summary: $sum";Write-Host "Evidence Plan: $evidencePlanCsv";Write-Host "Evidence Status: $evidenceStatusCsv";Write-Host "Deep Scan Request: $deepScanRequestJson";Write-Host "PCI Inventory: $pcicsv";Write-Host "Korea Product Match: $productMatchCsv";Write-Host "Coverage Gaps: $coverageCsv";Write-Host "NVIDIA Log: $nvidiaLog";Write-Host "";Get-Content $sum

if($ProgressFile){
 if(-not(Test-Path -LiteralPath $csv) -or -not(Test-Path -LiteralPath $sum) -or -not(Test-Path -LiteralPath $evidenceStatusCsv)){throw 'Required output file was not written.'}
 $uiStage=if($inspectionComplete -eq 'YES'){'검사 완료 · 필수 증거 확보'}else{'Core 검사 완료 · 필수 증거 미완료'}
 [pscustomobject]@{State='Complete';Stage=$uiStage;ResultCsv=$csv;Summary=$sum;EvidencePlan=$evidencePlanCsv;EvidenceStatus=$evidenceStatusCsv;DeepScanRequest=$deepScanRequestJson;InspectionComplete=$inspectionComplete;EvidenceCompleteness=$evidenceCompleteness;Outcome=$inspectionOutcome;WaybillNumber=$AssetID;Coucode=$Coucode;CompletedAt=(KstString 'yyyy-MM-dd HH:mm:ss zzz')} |
  Export-Clixml -LiteralPath ($ProgressFile+'.tmp') -Encoding UTF8 -ErrorAction Stop
 Move-Item -LiteralPath ($ProgressFile+'.tmp') -Destination $ProgressFile -Force -ErrorAction Stop
}

