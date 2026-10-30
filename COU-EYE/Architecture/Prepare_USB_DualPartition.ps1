param(
    [Parameter(Mandatory=$true)][int]$DiskNumber,
    [Parameter(Mandatory=$true)][string]$WinPEMediaRoot,
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [int]$BootSizeMB = 16384,
    [switch]$Execute,
    [string]$ConfirmErase = ''
)
$ErrorActionPreference='Stop'

function Require-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ throw 'Run PowerShell as Administrator.' }
}
function RootDriveLetter([string]$path){
    $r=[IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $path).Path)
    if($r -match '^([A-Za-z]):'){ return $matches[1].ToUpper() }
    return $null
}
function Get-FreeLetter {
    $used=@((Get-PSDrive -PSProvider FileSystem).Name | ForEach-Object {$_.ToUpper()})
    foreach($c in 'R','S','T','U','V','W','Y','Z','Q','P','N','M') { if($used -notcontains $c){ return $c } }
    throw 'No free drive letter available.'
}

Require-Admin
if(!(Test-Path -LiteralPath $WinPEMediaRoot)){ throw 'WinPEMediaRoot not found.' }
if(!(Test-Path -LiteralPath (Join-Path $WinPEMediaRoot 'sources\boot.wim'))){ throw 'WinPE media must contain sources\boot.wim.' }
if(!(Test-Path -LiteralPath (Join-Path $PackageRoot 'COUEYE.TAG'))){ throw 'PackageRoot must be the COU-EYE application root containing COUEYE.TAG.' }

$disk=Get-Disk -Number $DiskNumber -ErrorAction Stop
$pkgLetter=RootDriveLetter $PackageRoot
if($pkgLetter){
    $pkgPart=Get-Partition -DriveLetter $pkgLetter -ErrorAction SilentlyContinue
    if($pkgPart -and $pkgPart.DiskNumber -eq $DiskNumber){ throw 'PackageRoot is on the target disk. Copy COU-EYE to the technician PC before erasing the USB.' }
}

$plan=[pscustomobject]@{
    DiskNumber=$DiskNumber
    FriendlyName=$disk.FriendlyName
    BusType=$disk.BusType
    SizeGB=[math]::Round($disk.Size/1GB,2)
    BootPartitionMB=$BootSizeMB
    BootFileSystem='FAT32'
    BootLabel='COUEYE_BOOT'
    DataFileSystem='NTFS'
    DataLabel='COUEYE_DATA'
    WinPEMediaRoot=(Resolve-Path $WinPEMediaRoot).Path
    PackageRoot=(Resolve-Path $PackageRoot).Path
    Execute=[bool]$Execute
}
$plan | Format-List

if($disk.BusType -ne 'USB'){ throw ('Safety stop: target disk BusType is '+$disk.BusType+', not USB.') }
if($disk.Size -lt 32GB){ throw 'Target disk is smaller than 32 GB; V1.3.11 dual-partition profile expects a 64 GB-class USB.' }
if($BootSizeMB -lt 8192 -or $BootSizeMB -gt 32768){ throw 'BootSizeMB must be between 8192 and 32768.' }

if(!$Execute){
    Write-Host ''
    Write-Host 'DRY RUN ONLY. No disk changes were made.'
    Write-Host 'To execute, re-run with -Execute -ConfirmErase ERASE-COUEYE'
    exit 0
}
if($ConfirmErase -ne 'ERASE-COUEYE'){ throw 'Destructive operation blocked. Exact confirmation token required: ERASE-COUEYE' }

$bootLetter=Get-FreeLetter
# Reserve the next available letter after the first selection.
$used=@((Get-PSDrive -PSProvider FileSystem).Name | ForEach-Object {$_.ToUpper()}) + $bootLetter
$dataLetter=$null
foreach($c in 'S','T','U','V','W','Y','Z','Q','P','N','M','L') { if($used -notcontains $c){$dataLetter=$c;break} }
if(!$dataLetter){ throw 'No second free drive letter available.' }

Write-Host ('ERASING USB disk '+$DiskNumber+' ('+$disk.FriendlyName+') ...')
Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
$diskAfter=Get-Disk -Number $DiskNumber
if($diskAfter.PartitionStyle -eq 'RAW'){Initialize-Disk -Number $DiskNumber -PartitionStyle MBR}
elseif($diskAfter.PartitionStyle -ne 'MBR'){throw ('Safety stop: disk partition style after Clear-Disk is '+$diskAfter.PartitionStyle+'; expected RAW/MBR.')}
$boot=New-Partition -DiskNumber $DiskNumber -Size ($BootSizeMB*1MB) -DriveLetter $bootLetter -IsActive
Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'COUEYE_BOOT' -Confirm:$false | Out-Null
$data=New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter $dataLetter
Format-Volume -Partition $data -FileSystem NTFS -NewFileSystemLabel 'COUEYE_DATA' -Confirm:$false | Out-Null

$bootRoot=$bootLetter+':\'
$dataRoot=$dataLetter+':\'
Write-Host 'Copying Microsoft WinPE media to boot partition...'
& robocopy.exe $WinPEMediaRoot $bootRoot /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP | Out-Null
if($LASTEXITCODE -ge 8){ throw ('Robocopy WinPE media failed with exit code '+$LASTEXITCODE) }
# BOOT must contain WinPE only. Older media trees may still carry a COU-EYE app copy.
$bootApp=Join-Path $bootRoot 'COU-EYE'
if(Test-Path -LiteralPath $bootApp){Remove-Item -LiteralPath $bootApp -Recurse -Force}
New-Item -ItemType File -Force -Path (Join-Path $bootRoot 'COUEYE_BOOT.TAG') | Out-Null

$appDest=Join-Path $dataRoot 'COU-EYE'
New-Item -ItemType Directory -Force -Path $appDest | Out-Null
Write-Host 'Copying COU-EYE application to data partition...'
& robocopy.exe $PackageRoot $appDest /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP | Out-Null
if($LASTEXITCODE -ge 8){ throw ('Robocopy COU-EYE package failed with exit code '+$LASTEXITCODE) }
New-Item -ItemType File -Force -Path (Join-Path $dataRoot 'COUEYE_DATA.TAG') | Out-Null

foreach($d in @('Drivers','DeepPE','Results','Logs','Scratch')){ New-Item -ItemType Directory -Force -Path (Join-Path $appDest $d) | Out-Null }

Write-Host ''
Write-Host 'COU-EYE dual-partition USB prepared.'
Write-Host ('BOOT : '+$bootRoot+' FAT32 COUEYE_BOOT')
Write-Host ('DATA : '+$dataRoot+' NTFS  COUEYE_DATA')
Write-Host 'Next: run Architecture\Validate_USB_Layout.ps1 and perform a Core PE boot test before DeepPE deployment.'
