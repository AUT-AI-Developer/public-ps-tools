<#
.SYNOPSIS
Runs System File Checker and returns a structured result.

.DESCRIPTION
Runs SFC /scannow, preserves the complete native output in a separate text file,
normalizes embedded NUL characters and whitespace for status classification, and
returns a stable structured result for standalone or orchestrated RMM execution.

.PARAMETER OutputFormat
Controls success-stream result output: Object, Json, or None.

.PARAMETER LogPath
Optional operational log path. Defaults to C:\Temp\Logs.

.PARAMETER ResultPath
Optional structured JSON result path. Defaults beneath C:\Temp\Logs\results.

.PARAMETER Quiet
Suppresses non-essential console presentation while preserving persistent log
output, result files, failure handling, and exit codes.

.OUTPUTS
PSCustomObject, JSON text, or no success-stream output according to OutputFormat.

.EXAMPLE
.\Invoke-SfcScan.ps1 -OutputFormat Object

Runs SFC and returns the structured result object.

.NOTES
Default target: Windows PowerShell 5.1. Administrative elevation and 64-bit
Windows PowerShell are required on a 64-bit operating system.
#>
#Requires -Version 5.1

[CmdletBinding(PositionalBinding = $false)]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Object', 'Json', 'None')]
    [string]$OutputFormat = 'Object',

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [string]$ResultPath,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

Set-StrictMode -Version 2.0

function ConvertTo-SingleQuotedArgument {
    Param([string]$Value)
    if ($null -eq $Value) { return "''" }
    return ("'{0}'" -f ($Value -replace "'", "''"))
}

function Get-RelayParameterText {
    $parts = @('-OutputFormat {0}' -f (ConvertTo-SingleQuotedArgument -Value $OutputFormat))
    if ($LogPath) { $parts += '-LogPath {0}' -f (ConvertTo-SingleQuotedArgument -Value $LogPath) }
    if ($ResultPath) { $parts += '-ResultPath {0}' -f (ConvertTo-SingleQuotedArgument -Value $ResultPath) }
    if ($Quiet) { $parts += '-Quiet' }
    return ($parts -join ' ')
}

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $sysnativePowerShell -PathType Leaf)) {
        Write-Error '64-bit PowerShell is required, but Sysnative Windows PowerShell was not found.'
        exit 3
    }

    $relayScriptPath = $null
    $deleteRelayScript = $false
    if ($PSCommandPath) {
        $relayScriptPath = $PSCommandPath
    }
    else {
        $relayDirectory = Join-Path -Path $env:TEMP -ChildPath 'AUT-WindowsHealth-Relay'
        if (-not (Test-Path -LiteralPath $relayDirectory -PathType Container)) {
            New-Item -Path $relayDirectory -ItemType Directory -Force | Out-Null
        }
        $relayScriptPath = Join-Path -Path $relayDirectory -ChildPath ('Invoke-SfcScan-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $relayScriptPath -Value $MyInvocation.MyCommand.ScriptBlock.ToString() -Encoding UTF8
        $deleteRelayScript = $true
    }

    try {
        $relayCommand = '& {0} {1}' -f (ConvertTo-SingleQuotedArgument -Value $relayScriptPath), (Get-RelayParameterText)
        $relayProcess = Start-Process -FilePath $sysnativePowerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $relayCommand) -Wait -PassThru -WindowStyle Hidden
        exit $relayProcess.ExitCode
    }
    finally {
        if ($deleteRelayScript -and $relayScriptPath -and (Test-Path -LiteralPath $relayScriptPath -PathType Leaf)) {
            Remove-Item -LiteralPath $relayScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$ScriptName = 'Invoke-SfcScan'
$Operation = 'SfcScan'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogRoot = 'C:\Temp\Logs'

if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path -Path $LogRoot -ChildPath ('{0}-{1}.log' -f $ScriptName, $Timestamp)
}
$resultsDirectory = Join-Path -Path $LogRoot -ChildPath 'results'
if (-not (Test-Path -LiteralPath $resultsDirectory -PathType Container)) {
    New-Item -Path $resultsDirectory -ItemType Directory -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path -Path $resultsDirectory -ChildPath ('{0}-result-{1}.json' -f $ScriptName, $Timestamp)
}
$script:LogPath = $LogPath

function Write-Log {
    Param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('Debug', 'Information', 'Warning', 'Error', 'Critical')][string]$Level = 'Information'
    )
    $directory = Split-Path -Path $script:LogPath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    Add-Content -LiteralPath $script:LogPath -Value ('{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Operation, $Message) -Encoding UTF8
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NativeOutputPath {
    Param([string]$OperationName, [string]$OutputTimestamp)
    $logDirectory = Split-Path -Path $script:LogPath -Parent
    if ([string]::IsNullOrWhiteSpace($logDirectory)) { $logDirectory = $LogRoot }
    $scanDirectory = Join-Path -Path $logDirectory -ChildPath 'scan-results'
    if (-not (Test-Path -LiteralPath $scanDirectory -PathType Container)) {
        New-Item -Path $scanDirectory -ItemType Directory -Force | Out-Null
    }
    return (Join-Path -Path $scanDirectory -ChildPath ('{0}-{1}.txt' -f $OperationName, $OutputTimestamp))
}

function Test-OutputPattern {
    Param([string]$Text, [string]$Pattern)
    if ($null -eq $Text) { return $false }
    $cleanText = $Text.Replace([char]0, [char]32)
    $cleanPattern = $Pattern.Replace([char]0, [char]32)
    if ($cleanText -match [regex]::Escape($cleanPattern)) { return $true }
    return (($cleanText -replace '\s', '') -match [regex]::Escape(($cleanPattern -replace '\s', '')))
}

function New-ErrorObject {
    Param([string]$Message, [string]$RecommendedAction)
    return [pscustomobject]@{ Target = 'LocalComputer'; Operation = $Operation; Message = $Message; Category = 'Execution'; RecommendedAction = $RecommendedAction }
}

function Publish-Result {
    Param([pscustomobject]$Result)
    $resultDirectoryPath = Split-Path -Path $Result.ResultPath -Parent
    if ($resultDirectoryPath -and -not (Test-Path -LiteralPath $resultDirectoryPath -PathType Container)) {
        New-Item -Path $resultDirectoryPath -ItemType Directory -Force | Out-Null
    }
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Result.ResultPath -Encoding UTF8 -ErrorAction Stop
    $completionLevel = if ($Result.ExitCode -eq 0) { 'Information' } elseif ($Result.ExitCode -eq 4) { 'Error' } else { 'Critical' }
    Write-Log -Message ('Completed status={0}; exit={1}; nativeExit={2}; rawStatus={3}; changed={4}; recommendedAction={5}; nativeOutput={6}; result={7}.' -f $Result.Status, $Result.ExitCode, $Result.Data.ToolExitCode, $Result.Data.RawStatus, $Result.Changed, $Result.RecommendedAction, $Result.Data.NativeOutputPath, $Result.ResultPath) -Level $completionLevel
    switch ($OutputFormat) {
        'Json' { $Result | ConvertTo-Json -Depth 8 -Compress }
        'Object' { Write-Output $Result }
        'None' { }
    }
}

$result = [pscustomobject]@{
    ScriptName = $ScriptName; Operation = $Operation; Status = 'Failed'; ExitCode = 1; Changed = $false
    Message = 'SFC scan did not complete.'; LogPath = $LogPath; ResultPath = $ResultPath; RecommendedAction = 'ReviewLog'
    Data = [pscustomobject]@{ ToolExitCode = $null; RawStatus = 'Unknown'; ViolationsDetected = $false; Repaired = $false; NativeOutputPath = $null; Is64BitProcess = [Environment]::Is64BitProcess }
    Errors = @()
}

Write-Log -Message ('Starting SFC scan; log={0}; result={1}.' -f $LogPath, $ResultPath)
if (-not (Test-Administrator)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'Administrative elevation is required.'; $result.RecommendedAction = 'RunElevated'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'RunElevated'
    Publish-Result -Result $result
    exit $result.ExitCode
}

$sfc = Join-Path -Path $env:WINDIR -ChildPath 'System32\sfc.exe'
if (-not (Test-Path -LiteralPath $sfc -PathType Leaf)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'sfc.exe was not found.'; $result.RecommendedAction = 'ReviewWindowsInstallation'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewWindowsInstallation'
    Publish-Result -Result $result
    exit $result.ExitCode
}

$nativeOutputPath = Get-NativeOutputPath -OperationName $Operation -OutputTimestamp $Timestamp
$result.Data.NativeOutputPath = $nativeOutputPath
Write-Log -Message ('Executing "{0}" /scannow; nativeOutput={1}.' -f $sfc, $nativeOutputPath) -Level 'Debug'
& $sfc /scannow *> $nativeOutputPath
$result.Data.ToolExitCode = $LASTEXITCODE
Write-Log -Message ('SFC native exit code={0}.' -f $result.Data.ToolExitCode) -Level 'Debug'

try {
    $text = Get-Content -LiteralPath $nativeOutputPath -Raw -ErrorAction Stop
}
catch {
    $result.Message = 'Unable to read SFC native output.'
    $result.RecommendedAction = 'ReviewLog'
    $result.Errors += New-ErrorObject -Message ('{0} {1}' -f $result.Message, $_.Exception.Message) -RecommendedAction 'ReviewLog'
    Publish-Result -Result $result
    exit $result.ExitCode
}

if (Test-OutputPattern -Text $text -Pattern 'Windows Resource Protection did not find any integrity violations') {
    $result.Status = 'NoActionNeeded'; $result.ExitCode = 0; $result.Message = 'SFC did not find integrity violations.'; $result.RecommendedAction = 'None'; $result.Data.RawStatus = 'NoViolations'
}
elseif (Test-OutputPattern -Text $text -Pattern 'Windows Resource Protection found corrupt files and successfully repaired them') {
    $result.Status = 'Changed'; $result.ExitCode = 0; $result.Changed = $true; $result.Message = 'SFC found corrupt files and successfully repaired them.'; $result.RecommendedAction = 'None'; $result.Data.RawStatus = 'Repaired'; $result.Data.ViolationsDetected = $true; $result.Data.Repaired = $true
}
elseif (Test-OutputPattern -Text $text -Pattern 'Windows Resource Protection found corrupt files but was unable to fix some of them') {
    $result.Status = 'PartialSuccess'; $result.ExitCode = 4; $result.Message = 'SFC found corrupt files but was unable to fix some of them.'; $result.RecommendedAction = 'RunDismRestoreHealth'; $result.Data.RawStatus = 'ViolationsFound'; $result.Data.ViolationsDetected = $true
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'RunDismRestoreHealth'
}
elseif (Test-OutputPattern -Text $text -Pattern 'Windows Resource Protection could not perform the requested operation') {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'SFC could not perform the requested operation.'; $result.RecommendedAction = 'RunDismRestoreHealth'; $result.Data.RawStatus = 'CouldNotRun'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'RunDismRestoreHealth'
}
elseif ($result.Data.ToolExitCode -ne 0) {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = ('SFC failed with native exit code {0}.' -f $result.Data.ToolExitCode); $result.RecommendedAction = 'ReviewCBSLog'; $result.Data.RawStatus = 'Failed'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewCBSLog'
}
else {
    $result.Message = 'Unable to determine SFC status from output.'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewLog'
}

Write-Log -Message ('Classified SFC as {0}: {1}' -f $result.Data.RawStatus, $result.Message)
Publish-Result -Result $result
exit $result.ExitCode
