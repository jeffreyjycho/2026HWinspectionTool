param([Parameter(Mandatory=$true)][string]$ResumeFile,[Parameter(Mandatory=$true)][string]$StateFile)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
# The hardware cards are shared with the Core results screen. No power action here.
& (Join-Path $root 'COU_EYE_UI.ps1') -ResumeFile $ResumeFile -FinalStateFile $StateFile