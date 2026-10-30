function Write-ReturnJson($Path,$Record) {
    $json=$Record|ConvertTo-Json -Depth 8
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $stream=[IO.File]::Open($Path+'.tmp',[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    Move-Item -LiteralPath ($Path+'.tmp') -Destination $Path -Force -ErrorAction Stop
}
function Request-CoreReturn([string]$ResumeFile,[string]$GuardFile,[bool]$CoreRestored,[scriptblock]$Reboot) {
    if(!$CoreRestored){throw 'Core restore was not verified; automatic reboot blocked.'}
    $record=Get-Content -LiteralPath $ResumeFile -Raw -ErrorAction Stop|ConvertFrom-Json
    if(Test-Path -LiteralPath $GuardFile){throw 'Core return already requested; repeated reboot blocked.'}
    $record|Add-Member NoteProperty CoreRestored $true -Force
    $record|Add-Member NoteProperty ReturnState 'CORE_RETURN_REQUESTED' -Force
    $record|Add-Member NoteProperty ReturnRequestedAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    Write-ReturnJson $ResumeFile $record
    # CreateNew makes concurrent callers fail closed. A crash after this point requires manual reboot.
    $stream=[IO.File]::Open($GuardFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($record.ReturnRequestedAt);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    & $Reboot
}
