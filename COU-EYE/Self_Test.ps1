param([string]$SPDTestRoot='')
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$D=Join-Path $Root 'DB'
function Check($name,$ok,$detail){[pscustomobject]@{Check=$name;Status=$(if($ok){'PASS'}else{'FAIL'});Detail=$detail}}
$r=@()
$r+=Check 'VERSION 1.3.11' ((Get-Content (Join-Path $Root 'VERSION.txt') -Raw) -match 'COU-EYE V1\.3\.11') ''
$r+=Check 'Collector version 1.3.11' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match '\$Version\s*=\s*"1\.3\.11"') ''
$r+=Check 'UI version 1.3.11' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'COU-EYE 1\.3\.11') ''
$r+=Check 'No runtime C# source compile in UI' (-not ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'Add-Type\s+-Path\s+.*\.cs')) ''
$r+=Check 'Corporate PE startnet template' (Test-Path (Join-Path $Root 'Corporate_PE\startnet.cmd')) ''
$r+=Check 'KST fixed-offset audit timestamp' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'KST_FIXED_UTC\+09') ''
$r+=Check 'Stable platform identity hash' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'PLATFORM IDENTITY SHA256') ''
$r+=Check 'Raw SMBIOS labelled non-stable snapshot' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'NON-STABLE SNAPSHOT') ''
$r+=Check 'NVIDIA deep diagnostics' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'Parsed GPU rows') ''
$r+=Check 'NVIDIA DrvLoad primary path' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'drvload\.exe') ''
$r+=Check 'NVIDIA guarded PnPUtil fallback' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'PnPUtil fallback: SKIPPED') ''
$r+=Check 'NVIDIA runtime-first binary lookup' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'Find-NvidiaRuntimeBinary') ''
$r+=Check 'GPU staged evidence' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'GPU_DRIVER_MATCH' -and (Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'GPU_NVML_QUERY') ''
$r+=Check 'PCI post-driver log' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match '_PCI_POST_DRIVER\.txt') ''
$r+=Check 'GPU driver stage log' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match '_GPU_DRIVER_STAGE\.txt') ''
$r+=Check 'NVIDIA service diagnostics' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'Get-NvidiaServiceDiagnostics') ''
$r+=Check 'DeepPE VHDX workspace' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match 'Workspace\.vhdx' -and (Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match 'COUEYE_WORK') ''
$r+=Check 'DeepPE core source priority' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match 'boot\.core\.wim') ''
$r+=Check 'Core GUI forces CoreSafe GPU mode' ((Get-Content (Join-Path $Root 'Run_Inspection.ps1') -Raw) -match 'GpuScanMode CoreSafe') ''
$r+=Check 'Headless Deep forces DeepHeadless GPU mode' ((Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'GpuScanMode DeepHeadless') ''
$r+=Check 'Core stops at operator Deep checkpoint' ((Get-Content (Join-Path $Root 'Run_Inspection.ps1') -Raw) -match 'CoreCompleteDeepRequired' -and -not ((Get-Content (Join-Path $Root 'Run_Inspection.ps1') -Raw) -match 'wpeutil\.exe')) ''
$r+=Check 'Operator-controlled Deep preparation' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_Deep_UI.ps1') -Raw) -match 'Prepare_DeepPE\.ps1' -and (Get-Content (Join-Path $Root 'DeepPE\Prepare_Deep_UI.ps1') -Raw) -match 'DeepReady') ''
$r+=Check 'Fullscreen operator UI' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'FormBorderStyle.*None' -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'WindowState.*Maximized') ''
$r+=Check 'Operator console hidden with debug override' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'ShowWindow' -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'DebugConsole') ''
$r+=Check 'Explicit Deep reboot confirmation' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match '정밀검사로 재부팅' -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'MessageBoxButtons.*OKCancel') ''
$r+=Check 'Headless boot-start marker' ((Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'DEEP_BOOT_STARTED' -and (Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'HEADLESS_STARTED') ''
$r+=Check 'Deep phase resolves tagged volumes' ((Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'COUEYE_DATA\.TAG' -and (Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'COUEYE_BOOT\.TAG') ''
$r+=Check 'Deep error returns to Core' ((Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'DEEP_ERROR' -and (Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'CoreRestored') ''
$r+=Check 'Display-driver load guarded by DeepHeadless' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match "GpuScanMode -eq 'DeepHeadless'") ''
$r+=Check 'Progress UI separates Waybill and Coucode' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match "운송장: " -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match "Coucode: ") ''
$r+=Check 'Guarded automatic return after Deep' ( ((Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match "Request-CoreReturn")) ''
$r+=Check 'Final UI displays shared hardware cards' ((Get-Content (Join-Path $Root 'DeepPE\Show_Deep_Final_UI.ps1') -Raw) -match 'COU_EYE_UI.ps1') ''
$r+=Check 'Final shown marker uses Shown event' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'Add_Shown' -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'FINAL_UI_SHOWN') ''
$r+=Check 'Collector UTC-derived KST' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'UtcNow.ToOffset') ''
$r+=Check 'Stale Deep state archive' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_Deep_UI.ps1') -Raw) -match 'Archive-StaleDeepState') ''
$r+=Check 'Core startup preserves saved results' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'Show-SavedSession' -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -notmatch 'STALE_STARTUP_DEEP_RESUME') ''
$r+=Check 'Persistent safe reboot control' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match "Button '재부팅'" -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'Invoke-OperatorReboot') ''
$r+=Check 'Unique DeepPE staging WIM' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match 'runToken' -and (Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match '_deep\.boot\.wim') ''
$r+=Check 'Result power actions require confirmation' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'MessageBoxButtons.*YesNo') ''
$r+=Check 'Deep state timestamps fixed KST' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match 'KstNow' -and (Get-Content (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1') -Raw) -match 'KstNow') ''

$r+=Check 'NO SILENT SKIP evidence engine' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match 'NO SILENT SKIP') ''
$r+=Check 'Evidence plan output' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match '_EVIDENCE_PLAN\.csv') ''
$r+=Check 'Evidence status output' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match '_EVIDENCE_STATUS\.csv') ''
$r+=Check 'Deep scan request output' ((Get-Content (Join-Path $Root 'Collect.ps1') -Raw) -match '_DEEP_SCAN_REQUEST\.json') ''
$r+=Check 'DeepPE prepare script' (Test-Path (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1')) ''
$r+=Check 'Driver repository' (Test-Path (Join-Path $Root 'Drivers\README.txt')) ''
$r+=Check 'USB tag discovery' (Test-Path (Join-Path $Root 'Architecture\Find_COUEYE_Volumes.ps1')) ''
$r+=Check 'USB dual-partition prepare script' (Test-Path (Join-Path $Root 'Architecture\Prepare_USB_DualPartition.ps1')) ''
$r+=Check 'USB layout validator' (Test-Path (Join-Path $Root 'Architecture\Validate_USB_Layout.ps1')) ''
$r+=Check 'Deep driver resolver' (Test-Path (Join-Path $Root 'DeepPE\Resolve_DeepDrivers.ps1')) ''
$r+=Check 'Deep phase runner' (Test-Path (Join-Path $Root 'DeepPE\Run_Deep_Phase.ps1')) ''
$r+=Check 'Evidence merge script' (Test-Path (Join-Path $Root 'DeepPE\Merge_Evidence.ps1')) ''
$r+=Check 'Core PE restore script' (Test-Path (Join-Path $Root 'DeepPE\Restore_CorePE.ps1')) ''
$r+=Check 'Explicit USB erase confirmation' ((Get-Content (Join-Path $Root 'Architecture\Prepare_USB_DualPartition.ps1') -Raw) -match 'ERASE-COUEYE') ''
$r+=Check 'DeepPE FAT32 4GB guard' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match '4GB') ''
$required=@('Collect.ps1','Parse_ROM.ps1','Start_COUI.cmd','DB\pci.ids','DB\VBIOS_FINGERPRINT_DB.csv','DB\VBIOS_PROFILE_INDEX.csv','DB\VBIOS_RUNTIME_INDEX.csv','DB\PCI_DEVICE_PROFILE_INDEX.csv','DB\KOREA_PRODUCT_MASTER.csv')
foreach($f in $required){$r+=Check ('FILE '+$f) (Test-Path (Join-Path $Root $f)) ''}
$fdb=@(Import-Csv (Join-Path $D 'VBIOS_FINGERPRINT_DB.csv'));$pdb=@(Import-Csv (Join-Path $D 'VBIOS_PROFILE_INDEX.csv'));$rdb=@(Import-Csv (Join-Path $D 'VBIOS_RUNTIME_INDEX.csv'));$idb=@(Import-Csv (Join-Path $D 'PCI_DEVICE_PROFILE_INDEX.csv'))
$counts=Get-Content (Join-Path $D 'ROM_COUNTS.json') -Raw|ConvertFrom-Json
$r+=Check 'ROM source rows' ($fdb.Count -eq $counts.SourceRows) $fdb.Count
$r+=Check 'Unique ROM profile rows' ($pdb.Count -eq $counts.UniqueProfiles) $pdb.Count
$r+=Check 'Runtime key rows' ($rdb.Count -eq $counts.RuntimeKeys) $rdb.Count
$r+=Check 'PCI profile rows' ($idb.Count -eq $counts.PCIDevices) $idb.Count
$r+=Check 'Unique SHA256 index keys' (@($pdb|Group-Object SHA256|Where-Object Count -gt 1).Count -eq 0) ''
$hashes=@{};foreach($p in $pdb){$hashes[$p.SHA256]=$true}
$r+=Check 'Every source hash indexed' (@($fdb|Where-Object {-not $hashes.ContainsKey($_.SHA256)}).Count -eq 0) ''
$r+=Check 'Source totals agree' (($pdb|Measure-Object SourceCount -Sum).Sum -eq $fdb.Count) ''
$r+=Check 'PCI totals agree' (($idb|Measure-Object UniqueROMProfiles -Sum).Sum -eq $pdb.Count) ''
$expectedRuntime=@($pdb|Where-Object VBIOSVersion).Count
$r+=Check 'Runtime totals agree' (($rdb|Measure-Object UniqueROMProfiles -Sum).Sum -eq $expectedRuntime) ''
$manifest=@(Import-Csv (Join-Path $D 'ROM_SOURCE_MANIFEST.csv'))
$r+=Check 'All imported source files indexed' (@($manifest|Where-Object {-not $hashes.ContainsKey($_.SHA256)}).Count -eq 0) $manifest.Count
$pci=Get-Content (Join-Path $D 'pci.ids') -Raw
$r+=Check 'pci.ids Intel Arc B580' ($pci -match '(?im)^\te20b\s+.*Arc B580') '8086:E20B'
$r+=Check 'pci.ids RTX 5050' ($pci -match '(?im)^\t2d83\s+.*RTX 5050') '10DE:2D83'
$r+=Check 'pci.ids RX 9060 XT family' ($pci -match '(?im)^\t7590\s+.*9060 XT') '1002:7590'
$r+=Check 'Deep prep exclusive lock' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_Deep_UI.ps1') -Raw) -match 'DEEP_PREP\.lock' -and (Get-Content (Join-Path $Root 'DeepPE\Prepare_Deep_UI.ps1') -Raw) -match 'FileShare]::None') ''
$r+=Check 'Deep prep UI re-entry guard' ((Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'deepPrepStarting' -and (Get-Content (Join-Path $Root 'COU_EYE_UI.ps1') -Raw) -match 'Test-DeepWorkerAlive') ''
$r+=Check 'Stale DISM mount recovery' ((Get-Content (Join-Path $Root 'DeepPE\Prepare_DeepPE.ps1') -Raw) -match 'Reset-DeepMountWorkspace' -and (Test-Path (Join-Path $Root 'DeepPE\PrepSafety.ps1'))) ''
foreach($f in @('STATUS_V1.3.md','VALIDATION_V1.3.txt','CHANGELOG_V1.3.0.txt','CHANGELOG_V1.3.1.txt','CHANGELOG_V1.3.2.txt','CHANGELOG_V1.3.3.txt','CHANGELOG_V1.3.4.txt','CHANGELOG_V1.3.5.txt','CHANGELOG_V1.3.11.txt','UPDATE_V1.3.11.txt','DeepPE\Show_Deep_Final_UI.ps1','BUILD_VALIDATION_V1.3.2.txt','BUILD_VALIDATION_V1.3.4.txt','BUILD_VALIDATION_V1.3.5.txt','Architecture\Prepare_USB_DualPartition.ps1','Architecture\Validate_USB_Layout.ps1','DeepPE\Resolve_DeepDrivers.ps1','DeepPE\Run_Deep_Phase.ps1','DeepPE\Merge_Evidence.ps1','DeepPE\Restore_CorePE.ps1','Architecture\USB_LAYOUT_GUIDE.txt','DeepPE\StateMachine.ps1','DeepPE\Prepare_Deep_UI.ps1','COU_EYE_UI.ps1','Run_Inspection.ps1','Start_COUI_Debug.cmd','Tools\UI_Model.ps1','Tools\DarkControls.cs','Tools\DarkControls.dll','Tools\Fonts\NanumGothic-Regular.ttf','Tools\Fonts\NanumGothic-Bold.ttf','Tools\Fonts\OFL.txt','Parse_SPD.ps1','Parse_SPD.cmd','Tools\SpdEngine.cs','Tools\SpdEngine.dll','Tests\Test_SPD.ps1','DB\SPD_FINGERPRINT_DB.csv','DB\RAM_PROFILE_INDEX.csv','SPD_INBOX\SOURCES.csv','STATUS_V1.3.md')){
 $r+=Check ('FILE '+$f) (Test-Path (Join-Path $Root $f)) ''
}
$r|Format-Table -AutoSize
if(@($r|Where-Object{$_.Status-eq'FAIL'}).Count -gt 0){exit 2}
$ps=(Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Tests\Test_SPD.ps1') -TempRoot $SPDTestRoot
exit $LASTEXITCODE
