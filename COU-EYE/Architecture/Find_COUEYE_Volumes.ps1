$ErrorActionPreference='SilentlyContinue'
$found=@()
foreach($d in Get-PSDrive -PSProvider FileSystem){
 $root=$d.Root
 $app=Join-Path $root 'COU-EYE\COUEYE.TAG'
 $boot=Join-Path $root 'COUEYE_BOOT.TAG'
 $data=Join-Path $root 'COUEYE_DATA.TAG'
 $deep=Join-Path $root 'COUEYE_DEEP.TAG'
 if(Test-Path $app){$found+=[pscustomobject]@{Role='APP';Drive=$d.Name;Root=$root;Tag=$app}}
 if(Test-Path $boot){$found+=[pscustomobject]@{Role='BOOT';Drive=$d.Name;Root=$root;Tag=$boot}}
 if(Test-Path $data){$found+=[pscustomobject]@{Role='DATA';Drive=$d.Name;Root=$root;Tag=$data}}
 if(Test-Path $deep){$found+=[pscustomobject]@{Role='DEEP';Drive=$d.Name;Root=$root;Tag=$deep}}
}
$found | Format-Table -AutoSize
