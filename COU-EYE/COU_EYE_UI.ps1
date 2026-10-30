param([string]$PreviewDirectory='', [string]$ResultCsv='', [switch]$TestUI, [switch]$DebugConsole,[string]$ResumeFile='', [string]$FinalStateFile='')
$ErrorActionPreference='Stop'
$script:root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:root 'DeepPE\BootTrace.ps1')
Write-BootTrace $script:root 'UI_SCRIPT_ENTERED'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $script:root 'Tools\DarkControls.dll')
[CouEyeUI.PortableFont]::Load((Join-Path $script:root 'Tools\Fonts'))
. (Join-Path $script:root 'Tools\UI_Model.ps1')
. (Join-Path $script:root 'Tools\ResultSession.ps1')
. (Join-Path $script:root 'DeepPE\PrepSafety.ps1')
$script:activePrepId=''

[Windows.Forms.Application]::EnableVisualStyles()
$script:waybill='';$script:coucode='';$script:running=$false;$script:deepPrepStarting=$false;$script:worker=$null;$script:statePath='';$script:logPath='';$script:coreState=$null
$script:isOperatorFullScreen=(-not $TestUI -and [string]::IsNullOrWhiteSpace($PreviewDirectory) -and -not $DebugConsole)
if($script:isOperatorFullScreen){
 try{
  if(-not ('CouEyeConsoleWindow' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CouEyeConsoleWindow {
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
  }
  $hwnd=[CouEyeConsoleWindow]::GetConsoleWindow();if($hwnd-ne[IntPtr]::Zero){[void][CouEyeConsoleWindow]::ShowWindow($hwnd,0)}
 }catch{}
}
$script:form=New-Object Windows.Forms.Form
$form.Text='COU-EYE - Return Inspection';$form.ClientSize=New-Object Drawing.Size(920,740);$form.MinimumSize=New-Object Drawing.Size(820,660)
$form.BackColor=[Drawing.Color]::Black;$form.ForeColor=[Drawing.Color]::White;$form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,11)
if($script:isOperatorFullScreen){$form.FormBorderStyle=[Windows.Forms.FormBorderStyle]::None;$form.WindowState=[Windows.Forms.FormWindowState]::Maximized;$form.StartPosition='Manual'}
$script:header=New-Object Windows.Forms.Panel;$header.Dock='Top';$header.Height=84
$script:body=New-Object Windows.Forms.Panel;$body.Dock='Fill';$body.Padding=New-Object Windows.Forms.Padding(34)
$footer=New-Object Windows.Forms.Label;$footer.Dock='Bottom';$footer.Height=42;$footer.Text='COU-EYE 1.3.11  ·  CoreSafe Return · NO SILENT SKIP';$footer.TextAlign='MiddleCenter';$footer.ForeColor=[Drawing.Color]::FromArgb(120,120,120);$footer.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,9)
$form.Controls.Add($body);$form.Controls.Add($footer);$form.Controls.Add($header)
function Label($text,$size=11,$bold=$false){$l=New-Object Windows.Forms.Label;$l.UseCompatibleTextRendering=$false;$l.UseMnemonic=$false;$l.AutoEllipsis=$false;$l.Text=$text;$l.ForeColor=[Drawing.Color]::White;$l.BackColor=[Drawing.Color]::Transparent;$style=if($bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular};$l.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,$size,$style);return $l}
$brand=Label 'COU-EYE' 18 $true;$brand.SetBounds(28,20,180,36);$header.Controls.Add($brand)
$script:steps=Label '' 10;$steps.TextAlign='MiddleRight';$steps.Anchor='Top,Right';$steps.SetBounds(300,24,590,28);$steps.ForeColor=[Drawing.Color]::FromArgb(155,155,155);$header.Controls.Add($steps)
function Button($text){$b=New-Object CouEyeUI.ActionButton;$b.Text=$text;$b.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,12);return $b}
function Invoke-OperatorReboot {
 if($script:running -or (Test-DeepWorkerAlive $script:worker) -or (Test-DeepPreparationBusy $script:root)){
  [void][Windows.Forms.MessageBox]::Show($form,'검사 또는 정밀검사 준비가 진행 중입니다. 파일 손상을 방지하기 위해 이 단계에서는 재부팅할 수 없습니다. 완료 후 다시 시도해주세요.','COU-EYE 재부팅',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)
  return
 }
 $answer=[Windows.Forms.MessageBox]::Show($form,"장비를 재부팅하시겠습니까?`r`n`r`n재부팅 시 부팅 메뉴(Dell: F12, 다른 장비는 제조사 부팅 키)에서 COU-EYE USB를 선택하세요.`r`n정밀검사 준비 완료 상태라면 USB 부팅 후 정밀검사가 시작됩니다.`r`n검사 후 자동 재부팅 때도 같은 USB를 다시 선택해야 저장된 사양 화면이 열립니다.`r`n내장 Windows가 켜지면 다시 재부팅하여 USB를 선택하세요.",'COU-EYE 재부팅',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
 if($answer-ne[Windows.Forms.DialogResult]::Yes){return}
 try{
  $wpe=Join-Path $env:SystemRoot 'System32\wpeutil.exe'
  if(Test-Path -LiteralPath $wpe){Write-BootTrace $script:root 'REBOOT_COMMAND_REQUESTED' $wpe;& $wpe reboot;$rc=$LASTEXITCODE;Write-BootTrace $script:root 'REBOOT_COMMAND_RETURNED' ('ExitCode='+$rc);if($rc -ne 0){throw ('Reboot failed: '+$rc)};return}
  $shutdown=Join-Path $env:SystemRoot 'System32\shutdown.exe'
  if(Test-Path -LiteralPath $shutdown){Write-BootTrace $script:root 'REBOOT_COMMAND_REQUESTED' $shutdown;& $shutdown /r /t 0;$rc=$LASTEXITCODE;Write-BootTrace $script:root 'REBOOT_COMMAND_RETURNED' ('ExitCode='+$rc);if($rc -ne 0){throw ('Reboot failed: '+$rc)};return}
  throw '지원되는 재부팅 유틸리티를 찾지 못했습니다.'
 }catch{[void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'COU-EYE 재부팅 오류')}
}
$script:rebootButton=Button '재부팅'
$rebootButton.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,10,[Drawing.FontStyle]::Bold)
$rebootButton.Anchor='Top,Right';$rebootButton.SetBounds(770,19,120,42);$header.Controls.Add($rebootButton)
$rebootButton.Add_Click({Invoke-OperatorReboot})
function Layout-Header {
 $rw=120;$margin=28
 $rebootButton.SetBounds([Math]::Max(500,$header.ClientSize.Width-$rw-$margin),19,$rw,42)
 $steps.SetBounds(250,24,[Math]::Max(180,$rebootButton.Left-270),28)
}
$header.Add_Resize({Layout-Header})
function Clear-Body {while($body.Controls.Count){$c=$body.Controls[0];$body.Controls.Remove($c);$c.Dispose()};$form.AcceptButton=$null}
function Center-Card {if($script:centerCard-and -not $script:centerCard.IsDisposed){$script:centerCard.Left=[Math]::Max(16,[int](($body.ClientSize.Width-$script:centerCard.Width)/2));$script:centerCard.Top=[Math]::Max(18,[int](($body.ClientSize.Height-$script:centerCard.Height)/2)-14)}}
function Get-OperatorCardWidth([int]$preferred=920,[int]$minimum=700){return [Math]::Min($preferred,[Math]::Max($minimum,$body.ClientSize.Width-120))}
function Fit-SingleLineLabel($label,[float]$baseSize=11,[float]$minSize=8){
 for($sz=$baseSize;$sz-ge$minSize;$sz-=0.5){
  $old=$label.Font;$label.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,$sz,$old.Style);$old.Dispose()
  $measure=[Windows.Forms.TextRenderer]::MeasureText($label.Text,$label.Font)
  if($measure.Width-le($label.Width-10)){break}
 }
}
$body.Add_Resize({Center-Card})
function Show-Input([int]$step){
 Clear-Body;$script:inputStep=$step
 $steps.Text=if($step-eq 1){'01 운송장 번호   →   02 Coucode   →   03 검사'}else{'01 운송장 번호   →   02 Coucode   →   03 검사'}
 $script:centerCard=New-Object CouEyeUI.Card;$centerCard.Size=New-Object Drawing.Size(480,305);$body.Controls.Add($centerCard)
 $title=if($step-eq 1){'운송장 번호 입력'}else{'Coucode 입력'}
 $l=Label $title 19 $true;$l.TextAlign='MiddleCenter';$l.SetBounds(20,24,440,45);$centerCard.Controls.Add($l)
 $sub=Label $(if($step-eq 1){'운송장 번호를 입력해주세요.'}else{'Coucode를 입력해주세요.'}) 13;$sub.TextAlign='MiddleCenter';$sub.SetBounds(20,80,440,35);$centerCard.Controls.Add($sub)
 $inputBox=New-Object CouEyeUI.Card;$inputBox.SetBounds(25,135,430,53);$inputBox.Radius=10;$inputBox.BackColor=[Drawing.Color]::Black;$centerCard.Controls.Add($inputBox)
 $script:entry=New-Object CouEyeUI.Entry;$entry.Hint=$title;$entry.BorderStyle='None';$entry.BackColor=[Drawing.Color]::Black;$entry.ForeColor=[Drawing.Color]::White;$entry.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,14);$entry.SetBounds(15,13,397,29);$entry.MaxLength=100;$entry.AccessibleName=$title;$inputBox.Controls.Add($entry)
 $script:confirm=Button '확인';$confirm.SetBounds(25,207,430,46);$confirm.Enabled=$false;$centerCard.Controls.Add($confirm)
 $entry.Add_TextChanged({$confirm.Enabled=-not [string]::IsNullOrWhiteSpace($entry.Text)})
 $confirm.Add_Click({
  if([string]::IsNullOrWhiteSpace($entry.Text)){return}
  if($script:inputStep-eq 1){$script:waybill=$entry.Text.Trim();Show-Input 2}else{$script:coucode=$entry.Text.Trim();Start-Inspection}
 })
 if($step-eq 2){$back=Button '이전';$back.SetBounds(25,261,70,30);$back.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,9);$back.Add_Click({Show-Input 1});$centerCard.Controls.Add($back);$entry.Text=$script:coucode}else{$entry.Text=$script:waybill}
 $form.AcceptButton=$confirm;Center-Card;[void]$entry.Focus()
}
function Show-Progress {
 Clear-Body;$steps.Text='03 검사 진행'
 $w=Get-OperatorCardWidth 980 720;$h=[Math]::Min(500,[Math]::Max(430,$body.ClientSize.Height-100))
 $script:centerCard=New-Object CouEyeUI.Card;$centerCard.Size=New-Object Drawing.Size($w,$h);$body.Controls.Add($centerCard)
 $inner=$w-64
 $l=Label '장비를 확인하고 있습니다' 22 $true;$l.SetBounds(32,30,$inner,58);$l.TextAlign='MiddleCenter';$centerCard.Controls.Add($l)
 $way=Label ('운송장: '+$script:waybill) 12;$way.SetBounds(42,104,$w-84,38);$way.TextAlign='MiddleCenter';$centerCard.Controls.Add($way);Fit-SingleLineLabel $way 12 8
 $cc=Label ('Coucode: '+$script:coucode) 12;$cc.SetBounds(42,146,$w-84,38);$cc.TextAlign='MiddleCenter';$centerCard.Controls.Add($cc);Fit-SingleLineLabel $cc 12 9
 $script:stage=Label '검사 준비 중' 15 $true;$stage.SetBounds(44,207,$w-88,72);$stage.TextAlign='MiddleCenter';$centerCard.Controls.Add($stage)
 $bar=New-Object Windows.Forms.ProgressBar;$bar.Style='Marquee';$bar.MarqueeAnimationSpeed=35;$bar.SetBounds(82,305,$w-164,10);$centerCard.Controls.Add($bar)
 $hint=Label '기본 사양을 수집한 뒤 결과를 표시합니다.' 10;$hint.SetBounds(40,348,$w-80,31);$hint.TextAlign='MiddleCenter';$hint.ForeColor=[Drawing.Color]::Gray;$centerCard.Controls.Add($hint)
 $hint2=Label '기본 사양 확인에는 추가 재부팅이 필요하지 않습니다.' 10;$hint2.SetBounds(40,383,$w-80,42);$hint2.TextAlign='MiddleCenter';$hint2.ForeColor=[Drawing.Color]::FromArgb(135,135,135);$centerCard.Controls.Add($hint2);Center-Card
}
function Show-CoreCompleteDeepPrompt($state){
 $script:coreState=$state
 $rows=@(Import-Csv -LiteralPath $state.ResultCsv)
 Show-Result $rows $state.ResultCsv $false ([string]$state.InspectionComplete) ([string]$state.EvidenceCompleteness) ([string]$state.Outcome)
 $steps.Text='03 사양 확인 완료'
}
function Show-DeepPreparationProgress {
 Show-Progress;$steps.Text='03 정밀검사 준비';$stage.Text='정밀 검사 환경을 준비하고 있습니다'
}
function Show-DeepReady($state){
 $script:coreState=$state
 $rows=@(Import-Csv -LiteralPath $state.ResultCsv)
 Show-Result $rows $state.ResultCsv $false ([string]$state.InspectionComplete) ([string]$state.EvidenceCompleteness) ([string]$state.Outcome)
 $steps.Text='03 사양 확인 · 정밀검사 준비 완료'
 $script:resultHint.Text='사양을 확인할 수 있습니다. GPU 정밀검사는 아래 버튼으로 USB 재부팅 후 진행합니다.'
}
function Start-DeepPreparation($state){
 if($script:running -or $script:deepPrepStarting -or (Test-DeepWorkerAlive $script:worker) -or (Test-DeepPreparationBusy $script:root)){
  [void][Windows.Forms.MessageBox]::Show($form,'정밀 검사 환경 준비가 이미 진행 중입니다. 완료될 때까지 기다려주세요.','COU-EYE 정밀검사',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
  return
 }
 if($script:deepPrepButton){$script:deepPrepButton.Enabled=$false}
 $script:deepPrepStarting=$true
 try{
  Show-DeepPreparationProgress;$script:running=$true;$script:exitSeen=$false
  $jobs=Join-Path $script:root 'Logs\UI';[void][IO.Directory]::CreateDirectory($jobs);$id=[Guid]::NewGuid().ToString('N')
  $script:activePrepId=$id
  $script:statePath=Join-Path $jobs ($id+'.deep-prep.state.xml')
  $script:logPath=Join-Path $script:root ('Logs\DEEP_PREP_'+$id+'.log')
  Write-DeepProgressFile $script:statePath ([pscustomobject]@{State='Running';Phase='DeepPrep';RunId=$id;Stage='정밀 검사 준비 프로세스를 시작하고 있습니다';UpdatedAt=[DateTimeOffset]::UtcNow.ToString('o')})
  $prepRequest=Join-Path $jobs ($id+'.deep-prep.request.xml')
  [pscustomobject]@{RunId=$id;DeepPrepLog=$script:logPath;ProgressFile=$script:statePath;DeepScanRequest=[string]$state.DeepScanRequest;ResultCsv=[string]$state.ResultCsv;Summary=[string]$state.Summary;EvidenceStatus=[string]$state.EvidenceStatus;InspectionComplete=[string]$state.InspectionComplete;EvidenceCompleteness=[string]$state.EvidenceCompleteness;Outcome=[string]$state.Outcome;WaybillNumber=$script:waybill;Coucode=$script:coucode}|Export-Clixml -LiteralPath $prepRequest -Encoding UTF8
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=(Get-Process -Id $PID).Path;$info.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $script:root 'DeepPE\Prepare_Deep_UI.ps1')+'" -RequestFile "'+$prepRequest+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden'
  $script:worker=[Diagnostics.Process]::Start($info);$timer.Start()
 }catch{$script:running=$false;$script:deepPrepStarting=$false;Show-Failure $_.Exception.Message}
}
function Invoke-DeepReboot {
 Write-BootTrace $script:root 'DEEP_REBOOT_CLICKED'
 if((Test-DeepWorkerAlive $script:worker) -or (Test-DeepPreparationBusy $script:root)){return}
 $msg="정밀검사는 아직 완료되지 않았습니다. USB 부팅이 필요합니다.`r`n`r`n1. 재부팅 시 부팅 메뉴(Dell: F12, 다른 장비는 제조사 부팅 키)를 열어 COU-EYE USB를 선택하세요.`r`n2. 정밀검사 중 화면이 꺼져도 전원을 끄지 마세요.`r`n3. 검사 후 한 번 자동 재부팅됩니다. 이때도 같은 USB를 선택하면 CoreSafe에서 저장된 사양 화면이 열립니다.`r`n`r`n내장 Windows가 켜지면 다시 재부팅하여 USB를 선택하세요. 결과 화면으로 복귀하기 위한 USB 부팅은 재검사를 실행하는 단계가 아닙니다."
 $answer=[Windows.Forms.MessageBox]::Show($form,$msg,'COU-EYE 정밀검사',[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Warning)
 if($answer-ne[Windows.Forms.DialogResult]::OK){Write-BootTrace $script:root 'DEEP_REBOOT_CANCELLED';return}
 Write-BootTrace $script:root 'DEEP_REBOOT_CONFIRMED'
 Show-Progress;$steps.Text='03 정밀검사 재부팅';$stage.Text='부팅 메뉴(Dell: F12)에서 COU-EYE USB를 선택하세요';[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 800
 try{
  $wpe=Join-Path $env:SystemRoot 'System32\wpeutil.exe'
  if(Test-Path -LiteralPath $wpe){Write-BootTrace $script:root 'REBOOT_COMMAND_REQUESTED' $wpe;& $wpe reboot;$rc=$LASTEXITCODE;Write-BootTrace $script:root 'REBOOT_COMMAND_RETURNED' ('ExitCode='+$rc);if($rc -ne 0){throw ('Reboot failed: '+$rc)};return}
  $shutdown=Join-Path $env:SystemRoot 'System32\shutdown.exe'
  if(Test-Path -LiteralPath $shutdown){Write-BootTrace $script:root 'REBOOT_COMMAND_REQUESTED' $shutdown;& $shutdown /r /t 0;$rc=$LASTEXITCODE;Write-BootTrace $script:root 'REBOOT_COMMAND_RETURNED' ('ExitCode='+$rc);if($rc -ne 0){throw ('Reboot failed: '+$rc)};return}
  throw '지원되는 재부팅 유틸리티를 찾지 못했습니다.'
 }catch{Show-Failure $_.Exception.Message}
}
function Resize-ResultHeading($panel){
 $heading=$panel.Controls['ResultHeading'];$notice=$panel.Controls['ResultNotice']
 if(!$heading -or !$notice){return}
 $width=[Math]::Max(1,$panel.ClientSize.Width)
 $size=$heading.GetPreferredSize((New-Object Drawing.Size($width,0)))
 $heading.SetBounds(0,0,$width,[Math]::Max(48,$size.Height+12))
 $hintSize=$notice.GetPreferredSize((New-Object Drawing.Size($width,0)))
 $notice.SetBounds(0,$heading.Bottom+6,$width,[Math]::Max(36,$hintSize.Height+8))
 $warning=$panel.Controls['ResultBootWarning']
 if($warning -and $warning.Text){
  $warningSize=$warning.GetPreferredSize((New-Object Drawing.Size($width,0)))
  $warning.SetBounds(0,$notice.Bottom+4,$width,[Math]::Max(40,$warningSize.Height+10))
  $panel.Height=$warning.Bottom+8
 }else{$panel.Height=$notice.Bottom+8}
}
function Show-Result($rows,[string]$savedPath,[bool]$demo=$false,[string]$inspectionComplete='',[string]$evidenceCompleteness='',[string]$outcome=''){
 Clear-Body;$script:focusedCard=$null;$script:resultScrollPosition=0;$script:centerCard=$null;$steps.Text='04 장비 사양'
 $top=New-Object Windows.Forms.Panel;$top.Dock='Top';$top.Height=92;$body.Controls.Add($top)
 $resultTitle=if($demo){'장비 사양 · 화면 예시'}else{'장비 사양'}
 $title=Label $resultTitle 20 $true;$title.Name='ResultHeading';$title.SetBounds(0,0,800,48);$top.Controls.Add($title)
 $hintText='모델명 · 용량 · 시리얼번호를 확인하세요. 확인되지 않은 정보는 미확인으로 표시합니다.'
 $hint=Label $hintText 10;$hint.Name='ResultNotice';$hint.SetBounds(0,54,800,36);$hint.ForeColor=[Drawing.Color]::FromArgb(160,160,160);$top.Controls.Add($hint);$script:resultHint=$hint
 if(-not $demo -and $script:coreState -and $script:coreState.State -eq 'DeepReady'){

  $warningText='선택한 정밀검사 준비가 완료됐습니다. 실행하려면 아래 버튼을 누르고 재부팅 때 USB를 선택하세요.'
  $warning=Label $warningText 11 $true;$warning.Name='ResultBootWarning'
  $warning.ForeColor=[Drawing.Color]::FromArgb(255,100,100);$top.Controls.Add($warning)
 }
 $top.Add_Resize({Resize-ResultHeading $this})
 $hint.Add_TextChanged({Resize-ResultHeading $this.Parent})
 Resize-ResultHeading $top
 $bottom=New-Object Windows.Forms.Panel;$bottom.Dock='Bottom';$bottom.Height=112;$body.Controls.Add($bottom)
 $again=Button '다음 장비 검사';$again.SetBounds(0,14,240,43);$again.Add_Click({
  if($script:activeResumePath -and (Test-Path -LiteralPath $script:activeResumePath)){
   try{
    $cache=Join-Path $script:root 'DeepPE\Cache';[void][IO.Directory]::CreateDirectory($cache)
    Move-Item -LiteralPath $script:activeResumePath -Destination (Join-Path $cache ('OPERATOR_VIEWED_'+[guid]::NewGuid().ToString('N')+'.json'))
    $script:activeResumePath=''
   }catch{Show-Failure $_.Exception.Message;return}
  }
  $script:waybill='';$script:coucode='';$script:coreState=$null;Show-Input 1
 });$bottom.Controls.Add($again)
 $open=Button '결과 폴더 열기';$open.SetBounds(258,14,220,43);$open.Enabled=([bool]$savedPath -and -not $demo);$open.Tag=$savedPath;$open.Add_Click({Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+(Split-Path -Parent $this.Tag)+'"')});$bottom.Controls.Add($open)
 $form.AcceptButton=$null
 $power=Button '전원 끄기';$power.SetBounds(490,14,180,43);$bottom.Controls.Add($power)
 $power.Add_Click({
  if((Test-DeepWorkerAlive $script:worker) -or (Test-DeepPreparationBusy $script:root)){return}
  if([Windows.Forms.MessageBox]::Show($form,'장비 전원을 끄시겠습니까?','COU-EYE',[Windows.Forms.MessageBoxButtons]::YesNo) -ne [Windows.Forms.DialogResult]::Yes){return}
  $wpe=Join-Path $env:SystemRoot 'System32\wpeutil.exe'
  if(Test-Path $wpe){& $wpe shutdown}else{& (Join-Path $env:SystemRoot 'System32\shutdown.exe') /s /t 0}
 })
 if($script:coreState -and $script:coreState.DeepScanRequest -and !$demo){
  $script:deepPrepButton=Button $(if($script:coreState.State -eq 'DeepReady'){'정밀검사로 재부팅'}else{'추가 정밀검사 (선택)'})
  $script:deepPrepButton.SetBounds(0,65,420,40)
  $script:deepPrepButton.Add_Click({
   if($script:coreState.State -eq 'DeepReady'){Invoke-DeepReboot}else{Start-DeepPreparation $script:coreState}
  })
  $bottom.Controls.Add($script:deepPrepButton)
 }
 $scroll=New-Object Windows.Forms.FlowLayoutPanel;$scroll.Dock='Fill';$scroll.AutoScroll=$true;$scroll.FlowDirection='TopDown';$scroll.WrapContents=$false;$body.Controls.Add($scroll);$scroll.BringToFront();$script:resultPanel=$scroll
 foreach($item in @(Get-InspectionCards $rows)){
  $card=New-Object CouEyeUI.Card;$card.Width=810;$card.Margin=New-Object Windows.Forms.Padding(0,0,0,8)
  $title=Label $item.Title 13 $true;$title.Name='TitleText';$title.SetBounds(22,8,760,29);$card.Controls.Add($title)
  $text=Label $item.Body 11;$sz=[Windows.Forms.TextRenderer]::MeasureText($item.Body,$text.Font,(New-Object Drawing.Size(758,0)),[Windows.Forms.TextFormatFlags]::WordBreak)
  $text.Name='BodyText';$text.SetBounds(22,51,758,([Math]::Max(30,$sz.Height+10)));$text.ForeColor=[Drawing.Color]::FromArgb(218,218,218);$card.Height=$text.Bottom+20;$card.Controls.Add($text);$scroll.Controls.Add($card)
  $card.TabStop=$true;$card.AccessibleName=$item.Title+' 확대 / 전체 목록';$card.Cursor=[Windows.Forms.Cursors]::Hand
  $card.Add_Click({Toggle-ResultFocus $this})
  foreach($child in $card.Controls){$child.Cursor=[Windows.Forms.Cursors]::Hand;$child.Add_Click({Toggle-ResultFocus $this.Parent})}
  $card.Add_KeyDown({if($_.KeyCode-in @([Windows.Forms.Keys]::Enter,[Windows.Forms.Keys]::Space)){Toggle-ResultFocus $this;$_.SuppressKeyPress=$true}})
 }
 $scroll.Add_Resize({Resize-Results $this});Resize-Results $scroll
}
function Toggle-ResultFocus($card){
 $panel=$script:resultPanel
 if($script:focusedCard){
  $script:focusedCard=$null
  foreach($c in $panel.Controls){$c.Visible=$true}
  $script:resultHint.Text='부품을 클릭하면 크게 볼 수 있습니다. 다시 클릭하면 전체 목록으로 돌아옵니다.'
  Resize-Results $panel
  $panel.AutoScrollPosition=New-Object Drawing.Point(0,$script:resultScrollPosition)
 }else{
  $script:resultScrollPosition=-$panel.AutoScrollPosition.Y
  $script:focusedCard=$card
  $panel.AutoScrollPosition=New-Object Drawing.Point(0,0)
  foreach($c in $panel.Controls){$c.Visible=($c-eq $card)}
  $script:resultHint.Text='확대 보기 · 부품을 다시 클릭하거나 Esc 키를 누르면 전체 목록으로 돌아옵니다.'
  Resize-Results $panel
 }
 [void]$card.Focus()
}
function Set-ResultFont($label,[int]$size,[bool]$bold){
 if([Math]::Abs($label.Font.Size-$size)-gt 0.1){$old=$label.Font;$style=if($bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular};$label.Font=New-Object Drawing.Font([CouEyeUI.PortableFont]::Family,$size,$style);$old.Dispose()}
}
function Resize-Results($panel){
 if($script:resizingResults){return};$script:resizingResults=$true
 $panel.SuspendLayout()
 try{
  foreach($card in $panel.Controls){
   $zoom=($card-eq $script:focusedCard)
   # Reserve scrollbar space even before it appears, preventing width oscillation.
   $width=[Math]::Max(250,$panel.ClientSize.Width-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-12)
   $card.MinimumSize=New-Object Drawing.Size(0,0);$card.Width=$width
   $title=$card.Controls['TitleText'];$text=$card.Controls['BodyText']
   if(-not $text){continue}
   $size=if($zoom){[int][Math]::Max(18,[Math]::Min(32,[Math]::Floor($panel.ClientSize.Width/38)))}else{11}
   Set-ResultFont $text $size $false;Set-ResultFont $title $(if($zoom){$size+4}else{13}) $true
   foreach($label in @($title,$text)){
    $label.UseCompatibleTextRendering=$false;$label.UseMnemonic=$false;$label.AutoEllipsis=$false
    $label.Width=$width-44
    # Ask the very same Label renderer for its wrapped height, not a different text engine.
    $preferred=$label.GetPreferredSize((New-Object Drawing.Size($label.Width,0)))
    $label.Height=[Math]::Max(30,$preferred.Height+8)
   }
   $text.Top=$title.Bottom+4
   $height=$text.Bottom+12
   if($zoom){$height=[Math]::Max($height,$panel.ClientSize.Height-16)}
   # FlowLayoutPanel must scroll a tall card rather than constrain it to the viewport.
   $card.MinimumSize=New-Object Drawing.Size($width,$height)
   $card.Size=New-Object Drawing.Size($width,$height)
  }
 }finally{$panel.ResumeLayout($true);$script:resizingResults=$false}
}
$form.KeyPreview=$true
$form.Add_KeyDown({if($_.KeyCode-eq [Windows.Forms.Keys]::Escape -and $script:focusedCard -and -not $script:focusedCard.IsDisposed){Toggle-ResultFocus $script:focusedCard;$_.SuppressKeyPress=$true}})
function Show-Failure([string]$message){
 Clear-Body;$script:centerCard=New-Object CouEyeUI.Card;$centerCard.Size=New-Object Drawing.Size(640,300);$body.Controls.Add($centerCard)
 $l=Label '검사를 완료하지 못했습니다' 19 $true;$l.SetBounds(28,25,580,45);$centerCard.Controls.Add($l)
 $m=Label ($message+"`r`n수집 로그: "+$script:logPath) 10;$m.SetBounds(28,88,580,116);$centerCard.Controls.Add($m)
 $b=Button '입력 화면으로';$b.SetBounds(28,224,270,46);$b.Add_Click({Show-Input 1});$centerCard.Controls.Add($b)
 if($script:coreState -and $script:coreState.ResultCsv -and (Test-Path -LiteralPath $script:coreState.ResultCsv)){
  $spec=Button '수집된 사양 보기';$spec.SetBounds(310,224,298,46);$spec.Add_Click({Show-CoreCompleteDeepPrompt $script:coreState});$centerCard.Controls.Add($spec)
 }
 Center-Card
}
function Start-Inspection {
 if((Test-DeepWorkerAlive $script:worker) -or (Test-DeepPreparationBusy $script:root)){return}
 $script:activePrepId='' 
 if($TestUI){Show-Progress;return}
 Show-Progress;$script:running=$true;$script:exitSeen=$false
 try {
  $jobs=Join-Path $script:root 'Logs\UI';[void][IO.Directory]::CreateDirectory($jobs);$id=[Guid]::NewGuid().ToString('N')
  $script:statePath=Join-Path $jobs ($id+'.state.xml');$script:logPath=Join-Path $jobs ($id+'.log.txt');$request=Join-Path $jobs ($id+'.request.xml')
  [pscustomobject]@{WaybillNumber=$script:waybill;Coucode=$script:coucode;ProgressFile=$script:statePath;LogFile=$script:logPath}|Export-Clixml -LiteralPath $request -Encoding UTF8
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=(Get-Process -Id $PID).Path;$info.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $script:root 'Run_Inspection.ps1')+'" -RequestFile "'+$request+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden'
  $script:worker=[Diagnostics.Process]::Start($info);$timer.Start()
 }catch{$script:running=$false;Show-Failure $_.Exception.Message}
}
$script:timer=New-Object Windows.Forms.Timer;$timer.Interval=400
$timer.Add_Tick({
 try{
  if(Test-Path -LiteralPath $script:statePath){
   $state=$null
    try{$state=Import-Clixml -LiteralPath $script:statePath}catch{}
    if(!(Test-DeepStateOwner $state $script:activePrepId)){$state=$null}
   if($state.State-eq 'Running'){
    if($script:stage -and -not $script:stage.IsDisposed){
     $stage.Text=$state.Stage
     if($script:activePrepId -and $state.UpdatedAt){
      $age=[int]([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($state.UpdatedAt)).TotalSeconds
      $stage.Text += (' · 상태 갱신 '+[Math]::Max(0,$age)+'초 전')
     }
    }
   }
   elseif(!$script:activePrepId -and $state.State-in @('CoreCompleteDeepRequired','CoreComplete')){$timer.Stop();$script:running=$false;$script:deepPrepStarting=$false;$script:coreState=$state;Show-CoreCompleteDeepPrompt $state}
   elseif($state.State-eq 'DeepReady'){$timer.Stop();$script:running=$false;$script:deepPrepStarting=$false;$script:coreState=$state;Show-DeepReady $state}
   elseif(!$script:activePrepId -and $state.State-eq 'Complete'){$timer.Stop();$script:running=$false;$script:deepPrepStarting=$false;$rows=@(Import-Csv -LiteralPath $state.ResultCsv);Show-Result $rows $state.ResultCsv $false ([string]$state.InspectionComplete) ([string]$state.EvidenceCompleteness) ([string]$state.Outcome)}
   elseif($state.State-eq 'Error'){$timer.Stop();$script:running=$false;$script:deepPrepStarting=$false;if($state.DeepPrepLog){$script:logPath=$state.DeepPrepLog};Show-Failure $state.Message}
  }
  if($script:running-and $script:worker.HasExited){if(-not $script:exitSeen){$script:exitSeen=$true;return};$timer.Stop();$script:running=$false;$script:deepPrepStarting=$false;Show-Failure ('검사 프로세스 종료 (코드 '+$script:worker.ExitCode+'). 로그를 확인해주세요.')}
 }catch{$timer.Stop();$script:running=$false;$script:deepPrepStarting=$false;Show-Failure $_.Exception.Message}
})
$form.Add_FormClosing({if($script:running -or (Test-DeepWorkerAlive $script:worker) -or (Test-DeepPreparationBusy $script:root)){$_.Cancel=$true;[void][Windows.Forms.MessageBox]::Show($form,'Inspection is running. Please wait until it finishes.','COU-EYE')}})
function Save-Preview($name){$form.PerformLayout();$body.PerformLayout();$form.CreateControl();$form.Refresh();[Windows.Forms.Application]::DoEvents();$bmp=New-Object Drawing.Bitmap($form.Width,$form.Height);try{$form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$bmp.Width,$bmp.Height)));$bmp.Save((Join-Path $PreviewDirectory $name),[Drawing.Imaging.ImageFormat]::Png)}finally{$bmp.Dispose()}}
if($TestUI){
 $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-20000,-20000);$form.Show();Show-Input 1
 if($confirm.Enabled){throw 'Empty waybill accepted'};$entry.Text=' 001234 ';$confirm.PerformClick()
 if($script:inputStep-ne 2 -or $script:waybill-cne '001234'){throw 'Waybill transition failed'}
 $entry.Text=' ';if($confirm.Enabled){throw 'Whitespace Coucode accepted'};$entry.Text=' 0007 ';$confirm.PerformClick()
 if($script:coucode-cne '0007' -or $stage.Text-ne '검사 준비 중'){throw 'Coucode transition failed'}
 $testCsv=if($ResultCsv){$ResultCsv}else{Join-Path $script:root 'Tools\UI_DEMO.csv'};$rows=@(Import-Csv -LiteralPath $testCsv);Show-Result $rows '' $true
 $form.ClientSize=New-Object Drawing.Size(820,660);$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
 $click=[Windows.Forms.Control].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
 foreach($card in @($script:resultPanel.Controls)){
  $click.Invoke($card.Controls['BodyText'],@([EventArgs]::Empty))
  if($script:focusedCard-ne $card -or @($script:resultPanel.Controls|Where-Object Visible).Count-ne 1 -or $card.Controls['BodyText'].Font.Size-lt 18){throw 'Focus click failed'}
  $form.ClientSize=New-Object Drawing.Size(1280,900);[Windows.Forms.Application]::DoEvents()
  if($card.Controls['BodyText'].Font.Size-lt 24 -or $card.Controls['BodyText'].Right-gt $card.Width){throw 'Focus resize failed'}
  $click.Invoke($card.Controls['TitleText'],@([EventArgs]::Empty))
  if($script:focusedCard -or @($script:resultPanel.Controls|Where-Object Visible).Count-ne $script:resultPanel.Controls.Count -or $card.Controls['BodyText'].Font.Size-ne 11){throw 'Restore click failed'}
  $form.ClientSize=New-Object Drawing.Size(820,660);[Windows.Forms.Application]::DoEvents()
 }
 $panel=$script:resultPanel
 $panel.AutoScrollPosition=New-Object Drawing.Point(0,120);[Windows.Forms.Application]::DoEvents()
 $savedOffset=-$panel.AutoScrollPosition.Y
 $card=$panel.Controls[1];Toggle-ResultFocus $card;Toggle-ResultFocus $card
 if([Math]::Abs((-$panel.AutoScrollPosition.Y)-$savedOffset)-gt 2){throw 'Scroll position not restored'}
 $card=$panel.Controls[0];$original=$card.Controls['BodyText'].Text
 $card.Controls['BodyText'].Text=(('Long memory slot evidence Serial 1234567890 '+[Environment]::NewLine)*50)
 Toggle-ResultFocus $card;[Windows.Forms.Application]::DoEvents()
 if(-not $panel.VerticalScroll.Visible -or $card.Height-le $panel.ClientSize.Height){throw 'Long detail not scrollable'}
 $key=[Windows.Forms.Control].GetMethod('OnKeyDown',[Reflection.BindingFlags]'Instance,NonPublic')
 $keyArgs=New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Escape);$key.Invoke($form,[object[]]@($keyArgs.PSObject.BaseObject))
 if($script:focusedCard){throw 'Escape restore failed'}
 $card.Controls['BodyText'].Text=$original;Resize-Results $panel
 # Reach the last row in both list and focus modes using the actual viewport.
 $ramCard=@($script:resultPanel.Controls|Where-Object {$_.Controls['TitleText'].Text-eq '메모리'})[0]
 $ramText=$ramCard.Controls['BodyText'];$originalRam=$ramText.Text
 foreach($copies in @(1,16)){
  $ramText.Text=(($originalRam+"`r`n")*$copies)+'END-OF-RAM'
  foreach($focusMode in @($false,$true)){
   if($focusMode){Toggle-ResultFocus $ramCard}else{Resize-Results $script:resultPanel}
   [Windows.Forms.Application]::DoEvents()
   $preferred=$ramText.GetPreferredSize((New-Object Drawing.Size($ramText.Width,0)))
   if($ramText.Height-lt $preferred.Height -or $ramText.Bottom-gt $ramCard.ClientSize.Height){throw 'RAM content clipped'}
   $script:resultPanel.AutoScrollPosition=New-Object Drawing.Point(0,1000000)
   [Windows.Forms.Application]::DoEvents()
   if($focusMode -and ($ramCard.Bottom-gt $script:resultPanel.ClientSize.Height)){throw 'RAM end cannot be reached'}
   if($focusMode){Toggle-ResultFocus $ramCard}
  }
 }
 $ramText.Text=$originalRam;Resize-Results $script:resultPanel
 Write-Output 'RAM LAYOUT PASS: actual and repeated RAM records fit renderer height; final row reachable in focus.'
 Write-Output 'FOCUS EXTRA PASS: scroll position, long content scrolling, Escape restore.'
 Write-Output 'FOCUS UI PASS: each component, child text clicks, enlarge, resize, restore.'
 Write-Output 'UI FLOW PASS: empty input, whitespace, leading zeros, step transitions, progress, results, resize.'
 $form.ClientSize=New-Object Drawing.Size(1100,850)
 $testState=[pscustomobject]@{State='CoreCompleteDeepRequired';ResultCsv=$testCsv;DeepScanRequest='test-only.json';InspectionComplete='NO';EvidenceCompleteness='52.4';Outcome='INCOMPLETE_EVIDENCE'}
 Show-CoreCompleteDeepPrompt $testState
 if($script:resultPanel.Controls.Count -lt 5 -or !$script:deepPrepButton -or $form.AcceptButton){throw 'Core specifications/action/default Enter regression.'}
 if($PreviewDirectory){[void][IO.Directory]::CreateDirectory($PreviewDirectory);Save-Preview 'core-specifications.png'}
 $testState.State='DeepReady';Show-DeepReady $testState
 if($script:deepPrepButton.Text -ne '정밀검사로 재부팅' -or $form.AcceptButton){throw 'Ready requires explicit action regression.'}
 if($PreviewDirectory){Save-Preview 'ready-specifications.png'}
 Show-Failure 'Test only: simulated Deep preparation failure'
 $back=@($script:centerCard.Controls|Where-Object Text -eq '수집된 사양 보기')
 if($back.Count -ne 1){throw 'Failure-to-specification action missing'}
 $back[0].PerformClick()
 if($script:resultPanel.Controls.Count -lt 5){throw 'Failure recovery did not restore specification cards'}
 Write-Output 'SPECIFICATION FLOW PASS: Core cards, explicit Deep action, Ready cards, no default Enter, error return to cards.'
 $timer.Dispose();$form.Dispose();exit 0
}
if($PreviewDirectory){
 $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-20000,-20000);$form.Show();[Windows.Forms.Application]::DoEvents()
 [void][IO.Directory]::CreateDirectory($PreviewDirectory)
 Show-Input 1;Save-Preview '01-waybill.png';Show-Input 2;Save-Preview '02-coucode.png'
 $script:waybill='123456789012';$script:coucode='JEFFREY';Show-Progress;$stage.Text='CPU · 메모리 · 그래픽카드 상세 정보 확인 및 Evidence 상태 검증 중';Save-Preview '03-progress.png'
 $form.ClientSize=New-Object Drawing.Size(920,1120);$previewCsv=if($ResultCsv){$ResultCsv}else{Join-Path $script:root 'Tools\UI_DEMO.csv'};$rows=@(Import-Csv -LiteralPath $previewCsv);Show-Result $rows '' $true;Save-Preview '04-results.png';$form.ClientSize=New-Object Drawing.Size(920,740);Toggle-ResultFocus $script:resultPanel.Controls[0];Save-Preview '05-component-focus.png';Toggle-ResultFocus $script:focusedCard;$ramPreview=@($script:resultPanel.Controls|Where-Object {$_.Controls['TitleText'].Text-eq '메모리'})[0];Toggle-ResultFocus $ramPreview;Save-Preview '06-ram-top.png';$script:resultPanel.AutoScrollPosition=New-Object Drawing.Point(0,1000000);Save-Preview '07-ram-bottom.png'
 $timer.Dispose();$form.Dispose();exit 0
}
function Show-SavedSession([string]$path){
 if(Test-Path (Join-Path $env:SystemRoot 'System32\COUEYE_DEEP_SESSION.tag')){throw 'Still in DeepPE. Boot restored Core USB to display saved results.'}
 $context=Get-ResumeResultContext $script:root $path
 $rows=@(Import-Csv -LiteralPath $context.Csv)
 if(!$rows.Count){throw 'Saved hardware specification CSV is empty.'}
 $script:waybill=$rows[0].AssetID;$script:coucode=$rows[0].Coucode;$script:coreState=$null
 Show-Result $rows $context.Csv $false $context.Complete $context.Percent
 $script:resultHint.Text=$context.Notice
 $script:shownSession=$context
 $script:activeResumePath=$path
}
if($ResumeFile){
 Show-SavedSession $ResumeFile
}elseif($ResultCsv){
 $rows=@(Import-Csv -LiteralPath $ResultCsv)
 if($rows.Count){$script:waybill=$rows[0].AssetID;$script:coucode=$rows[0].Coucode}
 $evidence=Get-ResultEvidence $ResultCsv
 Show-Result $rows $ResultCsv $false $evidence.Complete $evidence.Percent
}else{
 $resumePath=Join-Path $script:root 'DeepPE\Working\DEEP_RESUME.json'
 $pendingPath=Join-Path $script:root 'DeepPE\Working\DEEP_PENDING.json'
 if(Test-Path -LiteralPath $resumePath){
  try{
   if(Test-Path (Join-Path $env:SystemRoot 'System32\COUEYE_DEEP_SESSION.tag')){throw 'Still in DeepPE. Boot restored Core USB to display saved results.'}
   Show-SavedSession $resumePath
   $FinalStateFile=Join-Path $script:root 'DeepPE\Working\DEEP_STATE.json'
  }catch{Show-Failure ('저장된 결과를 열지 못했습니다: '+$_.Exception.Message)}
 }elseif(Test-Path -LiteralPath $pendingPath){
  try{
   $record=Get-Content -LiteralPath $pendingPath -Raw|ConvertFrom-Json
   $csv=Resolve-SavedResult $script:root $record
   $rows=@(Import-Csv -LiteralPath $csv);$evidence=Get-ResultEvidence $csv
   $script:coreState=$null;Show-Result $rows $csv $false 'NO' $evidence.Percent
   $steps.Text='저장된 이전 장비 사양 · 정밀검사 대기'
   $script:resultHint.Text='이전 준비 요청의 사양입니다. 정밀검사 완료 기록은 없습니다. 새 장비는 다음 장비 검사를 선택하세요.'
  }catch{Show-Failure ('이전 사양을 열지 못했습니다: '+$_.Exception.Message)}
 }else{$script:waybill='';$script:coucode='';Show-Input 1}
}
$form.Add_Shown({
 Write-BootTrace $script:root 'UI_FORM_SHOWN' ('SavedResult='+[bool]$script:shownSession)
 if($script:shownSession -and $FinalStateFile){
  try{
   $record=$script:shownSession.Record
   if($record.ReturnState -eq 'CORE_RETURN_REQUESTED' -and (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')){
    . (Join-Path $script:root 'DeepPE\CoreReturn.ps1')
    $record.ReturnState='CORE_UI_SHOWN'
    $record|Add-Member NoteProperty CoreUiShownAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    Write-ReturnJson $script:activeResumePath $record
   }
   [pscustomobject]@{Version='1.3.11';State='FINAL_UI_SHOWN';AssetID=$record.AssetID;CoreRestored=($record.CoreRestored -eq $true);ResultCsv=$script:shownSession.Csv;UpdatedAt=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $FinalStateFile -Encoding UTF8
   ('FINAL_UI_SHOWN AssetID='+$record.AssetID+' '+[DateTimeOffset]::UtcNow.ToString('o'))|Add-Content -LiteralPath (Join-Path $script:root 'Logs\DEEP_FINAL_UI.log') -Encoding UTF8
  }catch{}
 }
})
Layout-Header
[void]$form.ShowDialog();$timer.Dispose();$form.Dispose()
