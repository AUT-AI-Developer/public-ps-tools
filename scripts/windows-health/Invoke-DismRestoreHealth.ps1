<#
.SYNOPSIS
Runs DISM RestoreHealth and returns a structured result.

.DESCRIPTION
Runs DISM /Online /Cleanup-Image /RestoreHealth, preserves the complete native
output in a separate text file, and returns a stable structured result for
standalone or orchestrated RMM execution. Failure and unclassified outcomes
capture bounded CBS, DISM, servicing-session, and relevant event-log evidence.

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
.\Invoke-DismRestoreHealth.ps1 -OutputFormat Object

Runs RestoreHealth and returns the structured result object.

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
        $relayScriptPath = Join-Path -Path $relayDirectory -ChildPath ('Invoke-DismRestoreHealth-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
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

$ScriptName = 'Invoke-DismRestoreHealth'
$Operation = 'DismRestoreHealth'
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
    $cleanText = $Text.Replace([char]0, '')
    $cleanPattern = $Pattern.Replace([char]0, '')
    if ($cleanText -match [regex]::Escape($cleanPattern)) { return $true }
    return (($cleanText -replace '\s', '') -match [regex]::Escape(($cleanPattern -replace '\s', '')))
}

function New-ErrorObject {
    Param([string]$Message, [string]$RecommendedAction)
    return [pscustomobject]@{ Target = 'LocalComputer'; Operation = $Operation; Message = $Message; Category = 'Execution'; RecommendedAction = $RecommendedAction }
}

function Export-ServicingDiagnostics {
    Param([datetime]$OperationStartTime, [string]$OutputTimestamp)

    $artifacts = @()
    $logDirectory = Split-Path -Path $script:LogPath -Parent
    if ([string]::IsNullOrWhiteSpace($logDirectory)) { $logDirectory = $LogRoot }
    $diagnosticsDirectory = Join-Path -Path $logDirectory -ChildPath 'diagnostics'
    if (-not (Test-Path -LiteralPath $diagnosticsDirectory -PathType Container)) {
        New-Item -Path $diagnosticsDirectory -ItemType Directory -Force | Out-Null
    }

    $prefix = Join-Path -Path $diagnosticsDirectory -ChildPath ('{0}-{1}' -f $Operation, $OutputTimestamp)
    $cbsPath = Join-Path -Path $env:WINDIR -ChildPath 'Logs\CBS\CBS.log'
    $dismLogPath = Join-Path -Path $env:WINDIR -ChildPath 'Logs\DISM\dism.log'
    $sessionsPath = Join-Path -Path $env:WINDIR -ChildPath 'servicing\Sessions\Sessions.xml'

    foreach ($item in @(
        @{ Source = $cbsPath; Destination = ($prefix + '-CBS-tail.txt'); Tail = 100 },
        @{ Source = $dismLogPath; Destination = ($prefix + '-DISM-tail.txt'); Tail = 100 }
    )) {
        try {
            if (Test-Path -LiteralPath $item.Source -PathType Leaf) {
                Get-Content -LiteralPath $item.Source -Tail $item.Tail -ErrorAction Stop | Set-Content -LiteralPath $item.Destination -Encoding UTF8
                $artifacts += $item.Destination
            }
        }
        catch {
            Write-Log -Message ('Unable to capture servicing log tail from {0}: {1}' -f $item.Source, $_.Exception.Message) -Level 'Warning'
        }
    }

    try {
        if (Test-Path -LiteralPath $cbsPath -PathType Leaf) {
            $filteredPath = $prefix + '-CBS-errors.txt'
            Get-Content -LiteralPath $cbsPath -Tail 2000 -ErrorAction Stop |
                Select-String -Pattern 'Error|CORRUPT|MISSING|HRESULT' |
                ForEach-Object { $_.Line } |
                Set-Content -LiteralPath $filteredPath -Encoding UTF8
            $artifacts += $filteredPath
        }
    }
    catch {
        Write-Log -Message ('Unable to capture filtered CBS diagnostics: {0}' -f $_.Exception.Message) -Level 'Warning'
    }

    try {
        if (Test-Path -LiteralPath $sessionsPath -PathType Leaf) {
            $sessionsDestination = $prefix + '-Sessions.xml'
            Copy-Item -LiteralPath $sessionsPath -Destination $sessionsDestination -Force -ErrorAction Stop
            $artifacts += $sessionsDestination
        }
    }
    catch {
        Write-Log -Message ('Unable to capture servicing Sessions.xml: {0}' -f $_.Exception.Message) -Level 'Warning'
    }

    $eventStart = $OperationStartTime.AddMinutes(-5)
    $eventQueries = @(
        @{ Name = 'Servicing-Operational'; LogName = 'Microsoft-Windows-Servicing/Operational'; Provider = $null },
        @{ Name = 'System-Servicing'; LogName = 'System'; Provider = 'Microsoft-Windows-Servicing' },
        @{ Name = 'WindowsUpdateClient-Operational'; LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Provider = $null },
        @{ Name = 'System-WindowsUpdateClient'; LogName = 'System'; Provider = 'Microsoft-Windows-WindowsUpdateClient' }
    )

    foreach ($query in $eventQueries) {
        try {
            $availableLog = Get-WinEvent -ListLog $query.LogName -ErrorAction SilentlyContinue
            if ($null -eq $availableLog) { continue }
            $filter = @{ LogName = $query.LogName; StartTime = $eventStart; Level = @(1, 2, 3) }
            if ($query.Provider) { $filter.ProviderName = $query.Provider }
            $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop | Sort-Object TimeCreated -Descending | Select-Object -First 100)
            if ($events.Count -gt 0) {
                $eventPath = $prefix + '-' + $query.Name + '-events.txt'
                $events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message | Format-List | Out-String -Width 4096 | Set-Content -LiteralPath $eventPath -Encoding UTF8
                $artifacts += $eventPath
            }
        }
        catch {
            Write-Log -Message ('Unable to capture {0} events: {1}' -f $query.Name, $_.Exception.Message) -Level 'Warning'
        }
    }

    Write-Log -Message ('Captured {0} servicing diagnostic artifact(s).' -f $artifacts.Count)
    return @($artifacts)
}

function Publish-Result {
    Param([pscustomobject]$Result)
    $resultDirectoryPath = Split-Path -Path $Result.ResultPath -Parent
    if ($resultDirectoryPath -and -not (Test-Path -LiteralPath $resultDirectoryPath -PathType Container)) {
        New-Item -Path $resultDirectoryPath -ItemType Directory -Force | Out-Null
    }
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Result.ResultPath -Encoding UTF8 -ErrorAction Stop
    $completionLevel = if ($Result.ExitCode -eq 0) { 'Information' } else { 'Critical' }
    Write-Log -Message ('Completed status={0}; exit={1}; nativeExit={2}; rawStatus={3}; recommendedAction={4}; nativeOutput={5}; result={6}.' -f $Result.Status, $Result.ExitCode, $Result.Data.ToolExitCode, $Result.Data.RawStatus, $Result.RecommendedAction, $Result.Data.NativeOutputPath, $Result.ResultPath) -Level $completionLevel
    switch ($OutputFormat) {
        'Json' { $Result | ConvertTo-Json -Depth 8 -Compress }
        'Object' { Write-Output $Result }
        'None' { }
    }
}

$result = [pscustomobject]@{
    ScriptName = $ScriptName; Operation = $Operation; Status = 'Failed'; ExitCode = 1; Changed = $false
    Message = 'DISM RestoreHealth did not complete.'; LogPath = $LogPath; ResultPath = $ResultPath; RecommendedAction = 'ReviewLog'
    Data = [pscustomobject]@{ ToolExitCode = $null; RawStatus = 'Unknown'; RestoreCompleted = $false; NativeOutputPath = $null; DiagnosticArtifacts = @(); Is64BitProcess = [Environment]::Is64BitProcess }
    Errors = @()
}

Write-Log -Message ('Starting DISM RestoreHealth; log={0}; result={1}.' -f $LogPath, $ResultPath)
if (-not (Test-Administrator)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'Administrative elevation is required.'; $result.RecommendedAction = 'RunElevated'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'RunElevated'
    Publish-Result -Result $result
    exit $result.ExitCode
}

$dism = Join-Path -Path $env:WINDIR -ChildPath 'System32\dism.exe'
if (-not (Test-Path -LiteralPath $dism -PathType Leaf)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'dism.exe was not found.'; $result.RecommendedAction = 'ReviewWindowsInstallation'
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewWindowsInstallation'
    Publish-Result -Result $result
    exit $result.ExitCode
}

$operationStartTime = Get-Date
$nativeOutputPath = Get-NativeOutputPath -OperationName $Operation -OutputTimestamp $Timestamp
$result.Data.NativeOutputPath = $nativeOutputPath
Write-Log -Message ('Executing "{0}" /Online /Cleanup-Image /RestoreHealth; nativeOutput={1}.' -f $dism, $nativeOutputPath) -Level 'Debug'
& $dism /Online /Cleanup-Image /RestoreHealth *> $nativeOutputPath
$result.Data.ToolExitCode = $LASTEXITCODE
Write-Log -Message ('DISM RestoreHealth native exit code={0}.' -f $result.Data.ToolExitCode) -Level 'Debug'

try {
    $text = Get-Content -LiteralPath $nativeOutputPath -Raw -ErrorAction Stop
}
catch {
    $result.Message = 'Unable to read DISM RestoreHealth native output.'
    $result.RecommendedAction = 'ReviewServicingDiagnostics'
    $result.Errors += New-ErrorObject -Message ('{0} {1}' -f $result.Message, $_.Exception.Message) -RecommendedAction 'ReviewServicingDiagnostics'
    $result.Data.DiagnosticArtifacts = @(Export-ServicingDiagnostics -OperationStartTime $operationStartTime -OutputTimestamp $Timestamp)
    Publish-Result -Result $result
    exit $result.ExitCode
}

if ($result.Data.ToolExitCode -eq 0 -and ((Test-OutputPattern -Text $text -Pattern 'The restore operation completed successfully') -or (Test-OutputPattern -Text $text -Pattern 'The operation completed successfully'))) {
    $result.Status = 'Changed'; $result.ExitCode = 0; $result.Changed = $true; $result.Message = 'DISM RestoreHealth completed successfully.'; $result.RecommendedAction = 'RunSfcScan'; $result.Data.RawStatus = 'Success'; $result.Data.RestoreCompleted = $true
}
elseif ($result.Data.ToolExitCode -ne 0) {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = ('DISM RestoreHealth failed with native exit code {0}.' -f $result.Data.ToolExitCode); $result.RecommendedAction = 'ReviewServicingDiagnostics'
    $result.Data.DiagnosticArtifacts = @(Export-ServicingDiagnostics -OperationStartTime $operationStartTime -OutputTimestamp $Timestamp)
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewServicingDiagnostics'
}
else {
    $result.Message = 'Unable to determine DISM RestoreHealth status from output.'; $result.RecommendedAction = 'ReviewServicingDiagnostics'
    $result.Data.DiagnosticArtifacts = @(Export-ServicingDiagnostics -OperationStartTime $operationStartTime -OutputTimestamp $Timestamp)
    $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewServicingDiagnostics'
}

Write-Log -Message ('Classified RestoreHealth as {0}: {1}' -f $result.Data.RawStatus, $result.Message)
Publish-Result -Result $result
exit $result.ExitCode
