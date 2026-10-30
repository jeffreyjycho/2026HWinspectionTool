$ErrorActionPreference='SilentlyContinue'
$rows=@()
foreach($v in Get-Volume | Where-Object {$_.DriveLetter}){
    $root=([string]$v.DriveLetter)+':\'
    $role=@()
    if(Test-Path (Join-Path $root 'COUEYE_BOOT.TAG')){$role+='BOOT'}
    if(Test-Path (Join-Path $root 'COUEYE_DATA.TAG')){$role+='DATA'}
    if(Test-Path (Join-Path $root 'COU-EYE\COUEYE.TAG')){$role+='APP'}
    if($role.Count){
        $rows += [pscustomobject]@{
            Role=($role -join '+')
            Drive=$v.DriveLetter
            Label=$v.FileSystemLabel
            FileSystem=$v.FileSystem
            SizeGB=[math]::Round($v.Size/1GB,2)
            FreeGB=[math]::Round($v.SizeRemaining/1GB,2)
            BootWim=(Test-Path (Join-Path $root 'sources\boot.wim'))
            AppTag=(Test-Path (Join-Path $root 'COU-EYE\COUEYE.TAG'))
            DataTag=(Test-Path (Join-Path $root 'COUEYE_DATA.TAG'))
        }
    }
}
$rows | Format-Table -AutoSize
if(!($rows.Role -match 'BOOT')){Write-Warning 'COUEYE_BOOT.TAG volume not found.'}
if(!($rows.Role -match 'DATA')){Write-Warning 'COUEYE_DATA.TAG volume not found.'}
if(!($rows.Role -match 'APP')){Write-Warning 'COU-EYE application tag not found.'}
