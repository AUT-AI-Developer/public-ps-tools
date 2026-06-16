<#
.SYNOPSIS
Runs DISM RestoreHealth and returns a structured result.

.DESCRIPTION
Runs DISM /Online /Cleanup-Image /RestoreHealth. The script is self-contained for RMM, scheduled task, or direct console use. It writes a detailed log and emits or writes one final structured result.

.PARAMETER OutputFormat
Controls final structured result output. Object is best for PowerShell callers, Json is best for stdout parsing, and None is best when ResultPath is used.

.PARAMETER LogPath
Optional log path. Defaults to C:\Temp\Invoke-DismRestoreHealth-<Timestamp>.log.

.PARAMETER ResultPath
Optional JSON result path for durable machine-readable output.
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Object','Json','None')]
    [string]$OutputFormat = 'Object',

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [string]$ResultPath
)

$ScriptName = 'Invoke-DismRestoreHealth'
$Operation = 'DismRestoreHealth'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path -Path 'C:\Temp' -ChildPath ('{0}-{1}.log' -f $ScriptName, $Timestamp) }

function Write-Log {
    [CmdletBinding()]
    Param([Parameter(Mandatory = $true)][string]$Message,[Parameter(Mandatory = $false)][ValidateSet('Debug','Information','Warning','Error')][string]$Level = 'Information')
    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $directory = Split-Path -Path $script:LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
    Add-Content -LiteralPath $script:LogPath -Value $entry -Encoding UTF8
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-ErrorObject {
    Param([string]$Message,[string]$RecommendedAction)
    return [pscustomobject]@{ Target = 'LocalComputer'; Operation = $script:Operation; Message = $Message; Category = 'Execution'; RecommendedAction = $RecommendedAction }
}

function Complete-Script {
    Param([pscustomobject]$Result)
    if (-not [string]::IsNullOrWhiteSpace($Result.ResultPath)) {
        $resultDirectory = Split-Path -Path $Result.ResultPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($resultDirectory) -and -not (Test-Path -LiteralPath $resultDirectory -PathType Container)) { New-Item -Path $resultDirectory -ItemType Directory -Force | Out-Null }
        $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Result.ResultPath -Encoding UTF8
    }
    Write-Log -Message ('Completed with status {0}, exit code {1}. {2}' -f $Result.Status, $Result.ExitCode, $Result.Message)
    switch ($OutputFormat) { 'Json' { $Result | ConvertTo-Json -Depth 8 -Compress } 'Object' { Write-Output $Result } 'None' { } }
    exit $Result.ExitCode
}

$script:LogPath = $LogPath
$script:Operation = $Operation
$result = [pscustomobject]@{
    ScriptName = $ScriptName
    Operation = $Operation
    Status = 'Failed'
    ExitCode = 1
    Changed = $false
    Message = 'DISM RestoreHealth did not complete.'
    LogPath = $LogPath
    ResultPath = $ResultPath
    RecommendedAction = 'ReviewLog'
    Data = [pscustomobject]@{ ToolExitCode = $null; RawStatus = 'Unknown'; RepairAttempted = $true; SfcRequired = $false; NativeOutputPath = $null }
    Errors = @()
}

Write-Log -Message 'Starting DISM RestoreHealth.'

if (-not (Test-Administrator)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'Administrative elevation is required.'; $result.RecommendedAction = 'RunElevated'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'RunElevated'; Complete-Script -Result $result
}

$dismPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\dism.exe'
if (-not (Test-Path -LiteralPath $dismPath -PathType Leaf)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'dism.exe was not found.'; $result.RecommendedAction = 'ReviewSystemPath'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewSystemPath'; Complete-Script -Result $result
}

$output = & $dismPath /Online /Cleanup-Image /RestoreHealth 2>&1
$toolExitCode = $LASTEXITCODE
$outputText = ($output | Out-String).Trim()
$outputPath = Join-Path -Path $env:TEMP -ChildPath ('{0}-{1}.txt' -f $Operation, $Timestamp)
if (-not [string]::IsNullOrWhiteSpace($outputText)) { Set-Content -LiteralPath $outputPath -Value $outputText -Encoding UTF8 }
$result.Data.ToolExitCode = $toolExitCode
$result.Data.NativeOutputPath = $outputPath

if ($toolExitCode -eq 0 -and ($outputText -match 'The restore operation completed successfully' -or $outputText -match 'The operation completed successfully')) {
    $result.Status = 'Changed'; $result.ExitCode = 0; $result.Changed = $true; $result.Message = 'DISM RestoreHealth completed successfully.'; $result.RecommendedAction = 'RunSfcScan'; $result.Data.RawStatus = 'Success'; $result.Data.SfcRequired = $true
}
elseif ($toolExitCode -ne 0) {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = ('DISM RestoreHealth failed with native exit code {0}.' -f $toolExitCode); $result.RecommendedAction = 'ReviewCBSLog'; $result.Data.RawStatus = 'Failed'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewCBSLog'
}
else {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'Unable to determine DISM RestoreHealth status from output.'; $result.RecommendedAction = 'ReviewLog'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewLog'
}

Complete-Script -Result $result
