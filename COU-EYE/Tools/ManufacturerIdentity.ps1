# Passive identity resolution only: no driver loading, SMBus access or reboot.
$script:identityDb=Join-Path (Split-Path $PSScriptRoot -Parent) 'DB'
$script:identityJedec=@{}
$script:identityPci=@{}
$script:identityRamUsers=@()
$script:identityGpuUsers=@()
$p=Join-Path $script:identityDb 'RAM_JEDEC_MANUFACTURERS.csv'
if(Test-Path -LiteralPath $p){foreach($r in Import-Csv -LiteralPath $p){$script:identityJedec["$($r.Bank):$($r.Code)"]=$r.Name}}
$p=Join-Path $script:identityDb 'pci.ids'
if(Test-Path -LiteralPath $p){foreach($line in [IO.File]::ReadLines($p)){
 if($line -match '^C\s'){break}
 if($line -match '^([0-9A-Fa-f]{4})\s{2}(.+)$'){$script:identityPci[$matches[1].ToUpperInvariant()]=$matches[2].Trim()}
}}
$p=Join-Path $script:identityDb 'RAM_USER_CONFIRMED.csv'
if(Test-Path -LiteralPath $p){$script:identityRamUsers=@(Import-Csv -LiteralPath $p)}
$p=Join-Path $script:identityDb 'GPU_USER_CONFIRMED.csv'
if(Test-Path -LiteralPath $p){$script:identityGpuUsers=@(Import-Csv -LiteralPath $p)}
function Identity-Text($value){return ([string]$value).Trim()}
function Identity-Known($value){
 $v=Identity-Text $value
 return ($v -and $v -notmatch '^(?i:unknown.*|reserved.*|unassigned.*|none|n/a|not specified|not available|undefined|unavailable|default string|system serial number|serial number|manufacturer\d*|oem.*|to be filled.*|0+|f+|미확인)$')
}
function Identity-Brand($value){
 $v=Identity-Text $value
 switch -Regex ($v){
  '^Samsung(?: Electronics.*)?$' {return '삼성전자'}
  '^SK Hynix(?: .*)?$|^Hynix$' {return 'SK hynix'}
  '^Micron(?: Technology)?$' {return 'Micron'}
  '^Kingston(?: .*)?$' {return 'Kingston'}
  '^A-?DATA(?: Technology)?$' {return 'ADATA'}
  '^G[ .-]?Skill(?: .*)?$' {return 'G.SKILL'}
  '^Team Group(?: .*)?$' {return 'TeamGroup'}
  '^Micro-Star ' {return 'MSI'}
  '^ASUSTeK ' {return 'ASUS'}
  '^Gigabyte ' {return 'GIGABYTE'}
  '^ZOTAC ' {return 'ZOTAC'}
  '^ASRock ' {return 'ASRock'}
  default {return $v}
 }
}
function Identity-Result($brand,$source,$key){
 [pscustomobject]@{Brand=$brand;Source=$source;Key=$key}
}
function Resolve-RamManufacturer($row){
 $raw=Identity-Text $row.Manufacturer
 $hex=$raw -replace '^(?i:0x)',''
 # Only known SMBIOS ID shapes. The first word identifies the MODULE,
 # never use the trailing DRAM-chip vendor to infer the module brand.
 if($hex -match '^(?i:[0-9a-f]{4}|[0-9a-f]{4}0000[0-9a-f]{4})$'){
  $bank=[Convert]::ToInt32($hex.Substring(0,2),16) -band 127
  $byte=[Convert]::ToInt32($hex.Substring(2,2),16)
  $bits=0;for($i=0;$i -lt 8;$i++){$bits+=($byte -shr $i) -band 1}
  $key="$bank"+':'+($byte -band 127)
  if($bits % 2 -eq 1 -and $script:identityJedec.ContainsKey($key) -and (Identity-Known $script:identityJedec[$key])){
   return Identity-Result (Identity-Brand $script:identityJedec[$key]) 'SMBIOS_MODULE_JEDEC' $key
  }
 }elseif((Identity-Known $raw) -and $raw -notmatch '^(?i:0x)?[0-9a-f]+$' -and $raw -notmatch '^\d+$'){
  return Identity-Result (Identity-Brand $raw) 'SMBIOS_MANUFACTURER_TEXT' $raw
 }
 $serial=Identity-Text $row.Serial
 if(Identity-Known $serial){
  $hits=@($script:identityRamUsers|Where-Object{
   $_.Verification -eq 'USER_CONFIRMED' -and (Identity-Text $_.Serial) -eq $serial -and
   (Identity-Text $_.ManufacturerRaw) -eq $raw -and
   (Identity-Text $_.PartNumber) -eq (Identity-Text $row.PartNumber) -and
   (Identity-Text $_.CapacityGB) -eq (Identity-Text $row.CapacityGB)
  })
  $brands=@($hits|ForEach-Object{if(Identity-Known $_.Brand){Identity-Brand $_.Brand}}|Select-Object -Unique)
  if($brands.Count -eq 1){return Identity-Result $brands[0] 'USER_CONFIRMED' $serial}
  if($brands.Count -gt 1){return Identity-Result '' 'USER_CONFLICT' $serial}
 }
 return Identity-Result '' 'UNKNOWN' $raw
}
function Resolve-GpuManufacturer($row){
 $sv=(Identity-Text $row.SubvendorID).ToUpperInvariant()
 $ven=(Identity-Text $row.VendorID).ToUpperInvariant()
 # OEM subsystem owner is not a retail graphics-card SKU or proof of factory.
 if($sv -match '^[0-9A-F]{4}$' -and $sv -notin @('0000','FFFF','10DE','1002','8086') -and $script:identityPci.ContainsKey($sv)){
  $brand=Identity-Brand $script:identityPci[$sv]
  $source='PCI_SUBVENDOR'
  if($sv -in @('1028','103C','17AA','1025','144D','104D')){$brand+=' (OEM)';$source='PCI_SUBVENDOR_OEM'}
  return Identity-Result $brand $source $sv
 }
 # Integrated GPU has a chip manufacturer, not a separate retail card brand.
 if([string]$row.Notes -match '^Integrated;' -and $script:identityPci.ContainsKey($ven)){
  return Identity-Result (Identity-Brand $script:identityPci[$ven]) 'INTEGRATED_CHIP_VENDOR' $ven
 }
 $serial=Identity-Text $row.Serial
 if((Identity-Known $serial) -and $serial -notlike 'GPU-*'){
  $hits=@($script:identityGpuUsers|Where-Object{
   $_.Verification -eq 'USER_CONFIRMED' -and (Identity-Text $_.Serial) -eq $serial -and
   (Identity-Text $_.VendorID) -eq $ven -and $ven -match '^[0-9A-F]{4}$' -and
   (Identity-Text $_.DeviceID) -eq (Identity-Text $row.DeviceID) -and ([string]$row.DeviceID) -match '^[0-9A-Fa-f]{4}$' -and
   (Identity-Text $_.SubvendorID) -eq $sv -and $sv -match '^[0-9A-F]{4}$' -and
   (Identity-Text $_.SubsystemID) -eq (Identity-Text $row.SubsystemID) -and ([string]$row.SubsystemID) -match '^[0-9A-Fa-f]{4}$'
  })
  $brands=@($hits|ForEach-Object{if(Identity-Known $_.Brand){Identity-Brand $_.Brand}}|Select-Object -Unique)
  if($brands.Count -eq 1){return Identity-Result $brands[0] 'USER_CONFIRMED' $serial}
  if($brands.Count -gt 1){return Identity-Result '' 'USER_CONFLICT' $serial}
 }
 return Identity-Result '' 'UNKNOWN' $sv
}



function Resolve-StorageManufacturer($row){
 # Resolve explicit brand tokens only. Generic bus/driver names and controller
 # vendors do not establish the drive maker. Do not infer from a serial prefix.
 $raw=Identity-Text $row.Manufacturer
 $model=Identity-Text $row.Model
 if($model -match '(?i)\b(virtual|raid volume|storage space|logical volume)\b'){
  return Identity-Result '' 'UNKNOWN_VIRTUAL_STORAGE' ''
 }
 $rules=@(
  @('(?i)\bSamsung\b','삼성전자'),
  @('(?i)\bWestern Digital\b|\bWDC?\b','Western Digital (WD)'),
  @('(?i)\bSeagate\b','Seagate'),
  @('(?i)\bKingston\b','Kingston'),
  @('(?i)\bCrucial\b','Crucial'),
  @('(?i)\bMicron\b','Micron'),
  @('(?i)\bSK[ _-]?hynix\b|\bHynix\b','SK hynix'),
  @('(?i)\bKioxia\b','KIOXIA'),
  @('(?i)\bToshiba\b','Toshiba'),
  @('(?i)\bA-?DATA\b','ADATA'),
  @('(?i)\bSanDisk\b','SanDisk'),
  @('(?i)\bCorsair\b','Corsair'),
  @('(?i)\bIntel\b','Intel'),
  @('(?i)\bSolidigm\b','Solidigm'),
  @('(?i)\bTranscend\b','Transcend'),
  @('(?i)\bLexar\b','Lexar'),
  @('(?i)\bPatriot\b','Patriot'),
  @('(?i)\bTeamGroup\b|\bTeam Group\b','TeamGroup'),
  @('(?i)\bPNY\b','PNY'),
  @('(?i)\bPlextor\b','Plextor')
 )
 $modelBrands=@($rules|Where-Object{$model -match $_[0]}|ForEach-Object{$_[1]}|Select-Object -Unique)
 $rawBrands=@($rules|Where-Object{$raw -match $_[0]}|ForEach-Object{$_[1]}|Select-Object -Unique)
 # A named model brand is more specific than a generic driver manufacturer.
 # Conflicting explicit names remain unresolved instead of guessing rebranding.
 $all=@(@($modelBrands)+@($rawBrands)|Select-Object -Unique)
 if($all.Count -gt 1){return Identity-Result '' 'STORAGE_BRAND_CONFLICT' $model}
 if($modelBrands.Count -eq 1){return Identity-Result $modelBrands[0] 'STORAGE_MODEL_BRAND' $model}
 if($rawBrands.Count -eq 1){return Identity-Result $rawBrands[0] 'STORAGE_MANUFACTURER_TEXT' $raw}
 return Identity-Result '' 'UNKNOWN' $model
}
