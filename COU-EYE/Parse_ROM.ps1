param([string]$Path = "")
$ErrorActionPreference="SilentlyContinue"
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$D=Join-Path $Root "DB"
$Out=Join-Path $Root "ROM_Results"
if(!$Path){$Path=Join-Path $Root "ROM_INBOX"}
New-Item -ItemType Directory -Force -Path $Out|Out-Null

$HashDb=@();$hashDbPath=Join-Path $D "VBIOS_PROFILE_INDEX.csv";if(Test-Path $hashDbPath){$HashDb=@(Import-Csv $hashDbPath)}
$RuntimeDb=@();$runDbPath=Join-Path $D "VBIOS_RUNTIME_INDEX.csv";if(Test-Path $runDbPath){$RuntimeDb=@(Import-Csv $runDbPath)}

function S($v){if($null-eq$v){""}else{([string]$v).Trim()}}
function Hash256($bytes){$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}}
function UniqueList($items){$o=@();foreach($x in @($items)){$v=S $x;if($v -and $o -notcontains $v){$o+=$v}};return $o}
function AllMatches($text,$pat){$a=@();foreach($m in [regex]::Matches($text,$pat,[Text.RegularExpressions.RegexOptions]::IgnoreCase)){ $v=$m.Value.Trim();if($v -and $a -notcontains $v){$a+=$v} };return $a}
function ShortText([string]$text,[int]$max=240){if(!$text){return ""};$t=$text.Trim();if($t.Length-le$max){return $t};return $t.Substring(0,$max-3)+"..."}
function Get-PrintableStrings($bytes){$ascii=[Text.Encoding]::ASCII.GetString($bytes);$a=@();foreach($m in [regex]::Matches($ascii,'[\x20-\x7E]{6,}')){$v=$m.Value.Trim();if($v){$a+=$v}};return $a}
function Get-PciIds($bytes){
    $ids=@();$ascii=[Text.Encoding]::ASCII.GetString($bytes);$start=0
    while($true){
        $idx=$ascii.IndexOf('PCIR',$start,[StringComparison]::Ordinal);if($idx-lt0){break}
        if($idx+8-le$bytes.Length){$ven=("{0:X4}"-f[BitConverter]::ToUInt16($bytes,$idx+4));$dev=("{0:X4}"-f[BitConverter]::ToUInt16($bytes,$idx+6));$pair="${ven}:${dev}";if($ids-notcontains$pair){$ids+=$pair}}
        $start=$idx+4
    }
    return $ids
}
function PartnerGroup([string[]]$codes){
    $groups=@();foreach($code in @($codes)){$c=(S $code).ToLower();$g=""
        if($c-match'asus$'){$g='ASUS'}elseif($c-match'msi$'){$g='MSI'}elseif($c-match'gigabyte$'){$g='GIGABYTE'}elseif($c-match'evga$'){$g='EVGA'}elseif($c-match'colorful$'){$g='COLORFUL'}elseif($c-match'dell$'){$g='DELL'}elseif($c-match'hp$'){$g='HP'}elseif($c-match'lenovo$'){$g='LENOVO'}elseif($c-match'pny desktop$'){$g='PNY'}elseif($c-match'nvidia$'){$g='NVIDIA'}elseif($c-match'galaxy$'){$g='GALAX/KFA2 BOARD GROUP'}elseif($c-match'palit$'){$g='PALIT/GAINWARD BOARD GROUP'}elseif($c-match'pcp$'){$g='PC PARTNER BOARD GROUP'}elseif($c-match'ask$'){$g='ASK BOARD PARTNER GROUP'}
        if($g-and$groups-notcontains$g){$groups+=$g}
    };return $groups
}
function Get-AmdPartnerGroups($strings){
    $g=@();$map=[ordered]@{'asus'='ASUS';'gigabyte'='GIGABYTE';'sapphire'='SAPPHIRE';'msi'='MSI';'asrock'='ASROCK';'tul'='TUL/POWERCOLOR BOARD GROUP';'xfx'='XFX';'dell'='DELL';'lenovo'='LENOVO';'hp'='HP'}
    foreach($st in @($strings)){
        if($st -notmatch '(?i)NAVI|POLARIS|BAFFIN|LEXA|RX\d|PPID|GV-|11[35]-|APM\d|G\d{5,}|D\d{5,}'){continue}
        $low=$st.ToLower()
        foreach($key in $map.Keys){$label=$map[$key];if($low.Contains($key) -and $g -notcontains $label){$g+=$label}}
    };return $g
}
function Get-AmdAsic($strings,$clean){
    $families=@();foreach($m in [regex]::Matches($clean,'\b(?:NAVI\d+(?:EXT)?|POLARIS\s*\d+|BAFFIN|LEXA)\b',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){$v=$m.Value.ToUpper().Replace(' ','');if($families-notcontains$v){$families+=$v}}
    $family=if($families.Count-gt0){$families[0]}else{""}
    foreach($f in $families){if($f.EndsWith('EXT')-and($families-contains$f.Substring(0,$f.Length-3))){$family=$f;break}}
    $variant="";$vars=@();$tokens=@('KXTM','KXTX','XTXH','XTLH','XTGODPL','XTX','XT','XL')
    foreach($st in @($strings)){
        if($st-match'(?i)MEM_BringUp|Baseline'){continue}
        $isStrong=$st-match'(?i)(?:ASUS|GBT|GIGABYTE|XFX|TUL|SAPPHIRE|ASROCK|WPG|AMD|DELL|MSI)[A-Z0-9_\-]*'
        foreach($t in $tokens){if($st-match("(?i)_"+[regex]::Escape($t)+"(?:_|\b)") -or $st-match("(?i)\bNAVI\d+(?:EXT)?(?:\s+Gaming)?\s+"+[regex]::Escape($t)+"\b")){if($vars-notcontains$t){$vars+=$t};if(!$variant-and$isStrong){$variant=$t}}}
    }
    if(!$variant-and$vars.Count-gt0){$variant=$vars[0]}
    return [pscustomobject]@{Family=$family;Variant=$variant;Families=($families-join'|');Variants=($vars-join'|')}
}
function Parse-Nvidia($strings,$clean){
    $vbs=@(AllMatches $clean '\b[0-9A-F]{2}(?:\.[0-9A-F]{2}){4}\b'|ForEach-Object{$_.ToUpper()})
    $oems=@(AllMatches $clean '\b[0-9A-F]{2}\.[0-9A-F]{2}\.[0-9A-F]{2}\.[0-9A-F]{2}\.[A-Z]{1,4}[0-9A-Z]{1,8}\b'|Where-Object{$_-notmatch'^[0-9A-F]{2}(?:\.[0-9A-F]{2}){4}$'}|ForEach-Object{$_.ToUpper()})
    $partner=@(AllMatches $clean '\b\d{5,9}\s*(?:pny desktop|gigabyte|colorful|galaxy|palit|evga|asus|msi|dell|hp|lenovo|zotac|inno3d|gainward|kfa2|maxsun|asrock|pcp|ask|nvidia)\b')
    $msi=@(AllMatches $clean '\bMSINV[0-9A-Z.]{5,30}\b');$pn=@(AllMatches $clean 'BIOS-P/N@[A-Z0-9._-]{3,40}');$pg=@(AllMatches $clean '\bPG\d{2,4}\s+SKU\s*[0-9A-Z-]{1,10}(?:\s+VGA BIOS)?\b')
    $board=@();$products=@();foreach($st in @($strings)){
        foreach($m in [regex]::Matches($st,'\b(?:ROG-MATRIX|ROG-ASTRAL|ASTRAL|GUNDAM-ROG|ROG-STRIX|STRIX|TUF|DUAL|PRIME|NOCTUA)-(?:RTX|GTX)[0-9A-Z-]+',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){if($board-notcontains$m.Value){$board+=$m.Value}}
        if(($st-match'(?i)\bPPID[A-Z0-9]' -or $st-match'(?i)\bGV-N[A-Z0-9]' -or $st-match'(?i)\b(?:NVIDIA\s+)?(?:GeForce\s+)?(?:RTX|GTX)\s*[0-9A-Z ]{2,20}\s+VGA BIOS' -or $st-match'(?i)\bRTXPRO[0-9A-Z_-]{4,60}') -and $st.Length-le180){if($products-notcontains$st){$products+=$st}}
    }
    foreach($x in $board+$msi+$pn){if($x-and$products-notcontains$x){$products+=$x}}
    return [pscustomobject]@{FirmwareType='NVIDIA_VBIOS';VBIOS=$(if($vbs.Count){$vbs[0]}else{""});VBIOSAll=($vbs-join'|');OEM=$(if($oems.Count){$oems[0]}else{""});Partner=($partner-join'|');PartnerGroup=((PartnerGroup $partner)-join'|');MSI=($msi-join'|');BiosPN=($pn-join'|');PG=($pg-join'|');ASICFamily='';ASICVariant='';ASICFamilies='';ASICVariants='';Board=($board-join'|');Products=($products-join' || ');Configs='';ModelHints='';VRAMHints='';MemTypes='';MemVendors='';PowerHints='';Conflict=''}
}
function Parse-Amd($strings,$clean){
    $atoms=@();foreach($m in [regex]::Matches($clean,'0\d{2}\.\d{3}\.\d{3}\.\d{3}(?:\.\d{6})?',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){if($atoms-notcontains$m.Value){$atoms+=$m.Value}}
    $asic=Get-AmdAsic $strings $clean;$pn=@();$products=@();$configs=@();$models=@();$vram=@();$memtypes=@();$memvendors=@();$power=@();$relevant=@()
    foreach($st in @($strings)){
        $rel=$st-match'(?i)NAVI|POLARIS|BAFFIN|LEXA|RX\d{3,4}|GDDR|GDR6|PPID|GV-R|ROG|STRIX|TUF|PRIME|DUAL|AREZ|APM\d|G\d{5,}|D\d{5,}|11[35]-|ASUS_|GBT_|XFX_|TUL_|SAPPHIRE_|ASROCK_|WPG|MSI'
        if($rel){$relevant+=$st}
        foreach($m in [regex]::Matches($st,'\b11[35]-[A-Z0-9._-]{3,48}',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){if($pn-notcontains$m.Value){$pn+=$m.Value}}
        if(($st-match'(?i)\b(?:PPID|GV-R|ROG-STRIX-RX|STRIX-RX|TUF-RX|PRIME-RX|DUAL[_-]RX|AREZ-RX)')-and$st.Length-le180){if($products-notcontains$st){$products+=$st}}
        if($rel-and$st.Length-ge8-and$st.Length-le190-and$st-notmatch'(?i)MEM_BringUp|Baseline|\.bin\s*$'){
            if($st-match'(?i)\b(?:NAVI\d+(?:EXT)?|POLARIS\s*\d+|BAFFIN|LEXA)\b.*(?:XT|XTX|XL|KXT|GDDR|\d+GB|Gaming|Production)' -or $st-match'(?i)(?:ASUS|GBT|XFX|TUL|SAPPHIRE|ASROCK|WPG|AMD|DELL|MSI)[A-Z0-9_\-]*(?:XT|XTX|XL|KXT|APM|G\d|D\d)'){if($configs-notcontains$st){$configs+=$st}}
        }
        foreach($m in [regex]::Matches($st,'\bRX\s*\d{3,4}\s*(?:XT|D|X)?\b',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){$v=($m.Value.ToUpper()-replace'\s+','');if($models-notcontains$v){$models+=$v}}
    }
    foreach($st in $relevant){
        foreach($m in [regex]::Matches($st,'(?<!\d)(2|4|6|8|12|16|24|32|48|64|96)\s*GB\b',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){if($vram-notcontains$m.Groups[1].Value){$vram+=$m.Groups[1].Value}}
        foreach($m in [regex]::Matches($st,'_(2|4|6|8|12|16|24|32|48|64|96)G(?:B|D6|D5|_)?',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){if($vram-notcontains$m.Groups[1].Value){$vram+=$m.Groups[1].Value}}
        foreach($m in [regex]::Matches($st,'\b(?:GDDR\s*[356]|GDR6)\b',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){$v=$m.Value.ToUpper().Replace(' ','');if($v-eq'GDR6'){$v='GDDR6'};if($memtypes-notcontains$v){$memtypes+=$v}}
        foreach($mv in @('SAMSUNG','HYNIX','MICRON','ELPIDA')){if($st.ToUpper().Contains($mv)-and$memvendors-notcontains$mv){$memvendors+=$mv}}
        foreach($m in [regex]::Matches($st,'(?<!\d)(\d{2,3})\s*W\b',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){$n=[int]$m.Groups[1].Value;if($n-ge50-and$n-le600-and$power-notcontains([string]$n)){$power+=[string]$n}}
    }
    $conflict=if($vram.Count-gt1){'VRAM_HINT_CONFLICT'}else{''}
    return [pscustomobject]@{FirmwareType='AMD_ATOMBIOS';VBIOS=$(if($atoms.Count){$atoms[0]}else{""});VBIOSAll=($atoms-join'|');OEM='';Partner='';PartnerGroup=((Get-AmdPartnerGroups $strings)-join'|');MSI='';BiosPN=($pn-join'|');PG='';ASICFamily=$asic.Family;ASICVariant=$asic.Variant;ASICFamilies=$asic.Families;ASICVariants=$asic.Variants;Board='';Products=($products-join' || ');Configs=(($configs|Select-Object -First 16)-join' || ');ModelHints=($models-join'|');VRAMHints=($vram-join'|');MemTypes=($memtypes-join'|');MemVendors=($memvendors-join'|');PowerHints=($power-join'|');Conflict=$conflict}
}
function ParseOne($file){
    $bytes=[IO.File]::ReadAllBytes($file.FullName);$strings=@(Get-PrintableStrings $bytes);$clean=($strings-join' ');$sha=Hash256 $bytes;$profileId='ROM-'+$sha.Substring(0,16)
    $ids=@(Get-PciIds $bytes);$ven="";$dev="";foreach($id in $ids){$p=$id.Split(':');if($p.Count-eq2-and($p[0]-eq'10DE'-or$p[0]-eq'1002'-or$p[0]-eq'8086')){$ven=$p[0];$dev=$p[1];break}};if(!$ven-and$ids.Count-gt0){$p=$ids[0].Split(':');$ven=$p[0];$dev=$p[1]}
    if($ven-eq'10DE'){$pinfo=Parse-Nvidia $strings $clean}elseif($ven-eq'1002'){$pinfo=Parse-Amd $strings $clean}else{$pinfo=[pscustomobject]@{FirmwareType='OTHER';VBIOS='';VBIOSAll='';OEM='';Partner='';PartnerGroup='';MSI='';BiosPN='';PG='';ASICFamily='';ASICVariant='';ASICFamilies='';ASICVariants='';Board='';Products='';Configs='';ModelHints='';VRAMHints='';MemTypes='';MemVendors='';PowerHints='';Conflict=''}}

    $exact=@($HashDb|Where-Object{(S $_.SHA256).ToUpper()-eq$sha});$runtime=@();if($exact.Count-eq0-and$ven-and$dev-and$pinfo.VBIOS){$runtime=@($RuntimeDb|Where-Object{(S $_.PciVendorID).ToUpper()-eq$ven-and(S $_.PciDeviceID).ToUpper()-eq$dev-and(S $_.VBIOSVersion).ToUpper()-eq$pinfo.VBIOS.ToUpper()})}
    $confidence='PARSED_NO_DB_MATCH';$match='NONE';$ref='';$dbAsic='';$dbVariants='';$dbGroups='';$dbBoards='';$dbProducts='';$dbConflict=''
    if($exact.Count-gt0){$e=$exact[0];$match='EXACT ROM HASH';$ref=S $e.SourceLabels;$dbAsic=S $e.ASICFamily;$dbVariants=S $e.ASICVariant;$dbGroups=S $e.PartnerGroup;$dbBoards=S $e.BoardString;$dbProducts=S $e.ProductStrings;$dbConflict=S $e.EvidenceConflict;if([int]$e.DistinctLabelCount-gt1){$confidence='ROM_PROFILE_AMBIGUOUS'}else{$confidence='ROM_HASH_MATCH'}}
    elseif($runtime.Count-gt0){$r=$runtime[0];$match='PCI+FIRMWARE PROFILE';$ref=S $r.ReferenceLabels;$dbAsic=S $r.ASICFamilies;$dbVariants=S $r.ASICVariants;$dbGroups=S $r.PartnerGroups;$dbBoards=S $r.BoardStrings;$dbProducts=S $r.ProductStrings;$dbConflict=S $r.EvidenceConflicts;$confidence=S $r.MatchClass}
    if($pinfo.Conflict){$confidence='EVIDENCE_CONFLICT'}

    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss';$safe=$file.BaseName-replace'[\\/:*?"<>|]','_';$txt=Join-Path $Out ("${stamp}_${safe}_ROM.txt")
    $o=New-Object Collections.Generic.List[string]
    $o.Add('COU-EYE V1.0 - UNIVERSAL ROM PARSER');$o.Add('File: '+$file.FullName);$o.Add('PROFILE ID: '+$profileId);$o.Add('SHA256: '+$sha);$o.Add('PCI: '+$ven+':'+$dev);$o.Add('PCI IDs ALL: '+($ids-join'|'));$o.Add('FIRMWARE TYPE: '+$pinfo.FirmwareType);$o.Add('VBIOS / ATOMBIOS: '+$pinfo.VBIOS)
    if($pinfo.OEM){$o.Add('OEM VBIOS TAG: '+$pinfo.OEM)};if($pinfo.Partner){$o.Add('PARTNER CODE: '+$pinfo.Partner)};if($pinfo.PartnerGroup){$o.Add('PARTNER / BOARD GROUP: '+$pinfo.PartnerGroup)};if($pinfo.ASICFamily){$o.Add('ASIC FAMILY: '+$pinfo.ASICFamily)};if($pinfo.ASICVariant){$o.Add('ASIC VARIANT: '+$pinfo.ASICVariant)};if($pinfo.MSI){$o.Add('MSI INTERNAL: '+$pinfo.MSI)};if($pinfo.BiosPN){$o.Add('BIOS / BOARD P/N: '+$pinfo.BiosPN)};if($pinfo.PG){$o.Add('PG/SKU: '+$pinfo.PG)};if($pinfo.Board){$o.Add('BOARD FAMILY: '+$pinfo.Board)};if($pinfo.Products){$o.Add('PRODUCT STRING(S): '+(ShortText $pinfo.Products 900))};if($pinfo.Configs){$o.Add('CONFIG STRING(S): '+(ShortText $pinfo.Configs 900))};if($pinfo.ModelHints){$o.Add('INTERNAL MODEL HINT(S): '+$pinfo.ModelHints)};if($pinfo.VRAMHints){$o.Add('VRAM HINT(S) GB: '+$pinfo.VRAMHints)};if($pinfo.MemTypes){$o.Add('MEMORY TYPE HINT(S): '+$pinfo.MemTypes)};if($pinfo.MemVendors){$o.Add('MEMORY VENDOR HINT(S): '+$pinfo.MemVendors)};if($pinfo.PowerHints){$o.Add('POWER HINT(S) W: '+$pinfo.PowerHints)};if($pinfo.Conflict){$o.Add('EVIDENCE CONFLICT: '+$pinfo.Conflict)}
    $o.Add('DB MATCH: '+$match);if($ref){$o.Add('REFERENCE PROFILE(S): '+(ShortText $ref 700))};if($dbAsic){$o.Add('DB ASIC: '+$dbAsic)};if($dbVariants){$o.Add('DB ASIC VARIANT: '+$dbVariants)};if($dbGroups){$o.Add('DB PARTNER GROUP(S): '+(ShortText $dbGroups 400))};if($dbBoards){$o.Add('DB BOARD FAMILY: '+(ShortText $dbBoards 500))};if($dbProducts){$o.Add('DB PRODUCT STRING(S): '+(ShortText $dbProducts 900))};if($dbConflict){$o.Add('DB EVIDENCE CONFLICT: '+$dbConflict)};$o.Add('CONFIDENCE: '+$confidence)
    $o.Add('NOTE: filename brand/GPU/VRAM are reference labels only. PCI IDs may be shared across multiple AMD GPU models. Exact retail SKU is not asserted from filename, firmware version, partner code, ASIC string or hash alone. Conflicting ROM hints are surfaced as EVIDENCE_CONFLICT.')
    $o|Out-File $txt -Encoding UTF8
    return [pscustomobject]@{File=$file.Name;ProfileID=$profileId;SHA256=$sha;PciVendorID=$ven;PciDeviceID=$dev;FirmwareType=$pinfo.FirmwareType;VBIOS_ATOMBIOS=$pinfo.VBIOS;ASICFamily=$pinfo.ASICFamily;ASICVariant=$pinfo.ASICVariant;BiosPartNumber=$pinfo.BiosPN;PartnerGroup=$pinfo.PartnerGroup;ProductStrings=$pinfo.Products;ConfigStrings=$pinfo.Configs;InternalModelHints=$pinfo.ModelHints;VRAMHintsGB=$pinfo.VRAMHints;MemoryTypeHints=$pinfo.MemTypes;MemoryVendorHints=$pinfo.MemVendors;PowerHintsW=$pinfo.PowerHints;EvidenceConflict=$pinfo.Conflict;DBMatch=$match;Confidence=$confidence;ReferenceProfiles=$ref;ResultFile=$txt}
}

$files=@();if(Test-Path $Path -PathType Leaf){$files=@(Get-Item $Path)}elseif(Test-Path $Path -PathType Container){$files=@(Get-ChildItem $Path -Filter '*.rom' -File)}
if($files.Count-eq0){Write-Host '[INFO] No ROM files found.';Write-Host ('Place .rom files in: '+(Join-Path $Root 'ROM_INBOX'));exit 0}
$batch=@();foreach($f in $files){$r=ParseOne $f;$batch+=$r;Write-Host '';Write-Host ('ROM: '+$f.Name);Write-Host ('  PCI='+$r.PciVendorID+':'+$r.PciDeviceID+'  FW='+$r.VBIOS_ATOMBIOS);if($r.ASICFamily){Write-Host ('  ASIC='+$r.ASICFamily+' '+$r.ASICVariant)};Write-Host ('  DB='+$r.DBMatch+'  CONFIDENCE='+$r.Confidence);if($r.EvidenceConflict){Write-Host ('  CONFLICT='+$r.EvidenceConflict)}}
$batchCsv=Join-Path $Out ((Get-Date -Format 'yyyyMMdd_HHmmss')+'_ROM_PARSE_RESULTS.csv');$batch|Export-Csv $batchCsv -NoTypeInformation -Encoding UTF8
Write-Host '';Write-Host ('Batch CSV: '+$batchCsv)
