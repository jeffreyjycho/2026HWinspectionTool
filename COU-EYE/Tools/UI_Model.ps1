. (Join-Path $PSScriptRoot 'ManufacturerIdentity.ps1')
function Display-Value($value) {
 $v=([string]$value).Trim()
 if(-not $v -or $v -match '^(?i:unknown|none|n/a|default string|system serial number|to be filled by o\.?e\.?m\.?)$'){return '미확인'}
 return $v
}
function Note-Value($text,$key){$m=[regex]::Match([string]$text,'(?:^|;\s*)'+[regex]::Escape($key)+'=([^;]*)');if($m.Success){return $m.Groups[1].Value.Trim()};return ''}
function Get-InspectionCards($rows) {
 $cards=New-Object 'Collections.Generic.List[object]'
 foreach($category in @('CPU','RAM','MAINBOARD','GPU','STORAGE')){
  $items=@($rows|Where-Object {$_.Category -eq $category -and -not ($category -eq 'STORAGE' -and (Note-Value $_.Notes 'Bus') -eq 'USB')})
  $title=@{CPU='CPU';RAM='메모리';MAINBOARD='메인보드';GPU='그래픽카드';STORAGE='저장장치'}[$category]
  $lines=New-Object 'Collections.Generic.List[string]'
  if(!$items.Count){$lines.Add('미확인')}
  foreach($r in $items){
   $serial=Display-Value $r.Serial
   if($serial -match '^(0+|F+)$'){$serial='미확인'}
   $model=Display-Value $r.Model
   switch($category){
    'CPU' {
     if($r.Serial -and ($r.Serial -eq $r.HardwareID -or $r.Serial -eq (Note-Value $r.Notes 'ProcessorId'))){$serial='미확인'}
     $lines.Add($model)
    }
    'RAM' {
     $type=Note-Value $r.Notes 'SMBIOSMemoryType'
     $locator=Display-Value $r.HardwareID
     $place=if($type -like 'LPDDR*'){'온보드 메모리 '+$r.Index}elseif($locator -ne '미확인'){'슬롯 '+$locator}else{'메모리 '+$r.Index+' (슬롯 미확인)'}
     $identity=Resolve-RamManufacturer $r
     $brand=if($identity.Brand){$identity.Brand}else{'제조사 미확인'}
     $rated=Note-Value $r.Notes 'RatedSpeed';$rate=0
     if(![int]::TryParse($rated,[ref]$rate) -or $rate -le 0){[void][int]::TryParse([string]$r.Speed,[ref]$rate)}
     $spec=Display-Value $type
     if($rate -gt 0){$spec+='-'+$rate;if($rate % 100 -eq 0 -and $type -match '^DDR([345])$'){$spec+=' (PC'+$Matches[1]+'-'+($rate*8)+')'}}
     $cap=Display-Value $r.CapacityGB;if($cap -ne '미확인'){$cap+='GB'}
     $lines.Add($place+' : '+$spec+' '+$cap+' / '+$brand)
    }
    'MAINBOARD' {
     $brand=Display-Value $r.Manufacturer
     if($brand -ne '미확인' -and $model -ne '미확인' -and !$model.StartsWith($brand,[StringComparison]::OrdinalIgnoreCase)){$model=$brand+' '+$model}
     $lines.Add($model)
    }
    'GPU' {
     $identity=Resolve-GpuManufacturer $r
     $brand=if($identity.Brand){$identity.Brand}else{'보드 제조사 미확인'}
     if(!$model.StartsWith($brand,[StringComparison]::OrdinalIgnoreCase)){$model=$brand+' / '+$model}
     if($r.Serial -like 'GPU-*'){$serial='미확인'}
     $cap=Display-Value $r.CapacityGB
     if($cap -ne '미확인' -and $model -notmatch '(?i)\b\d+\s*GB\b'){$model+=' / '+$cap+'GB'}
     $lines.Add($model)
    }
    'STORAGE' {
     $identity=Resolve-StorageManufacturer $r
     $brand=if($identity.Brand){$identity.Brand}else{'미확인'}
     $cap=Display-Value $r.CapacityGB
     if($cap -ne '미확인' -and $model -notmatch '(?i)\b\d+(?:\.\d+)?\s*[GT]B\b'){$model+=' / '+$cap+'GB'}
     $lines.Add($model+' / 제조사: '+$brand)
    }
   }
   $lines.Add('시리얼번호: '+$serial)
   if($items.Count -gt 1){$lines.Add('')}
  }
  $cards.Add([pscustomobject]@{Title=$title;Body=($lines.ToArray()-join "`r`n").Trim();Category=$category})
 }
 return $cards.ToArray()
}


