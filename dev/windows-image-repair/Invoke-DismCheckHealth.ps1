<#
.SYNOPSIS
Runs DISM CheckHealth and returns a structured result.

.DESCRIPTION
Runs DISM /Online /Cleanup-Image /CheckHealth. The script is self-contained for RMM, scheduled task, or direct console use. It writes a detailed log and emits or writes one final structured result. If started in a 32-bit PowerShell host on a 64-bit Windows OS, it relaunches in 64-bit Windows PowerShell before running DISM.

.PARAMETER OutputFormat
Controls final structured result output. Object is best for PowerShell callers, Json is best for stdout parsing, and None is best when ResultPath is used.

.PARAMETER LogPath
Optional log path. Defaults to C:\Temp\Invoke-DismCheckHealth-<Timestamp>.log.

.PARAMETER ResultPath
Optional JSON result path for durable machine-readable output.

.PARAMETER SelfSourceUrl
Raw script URL used only when the script must relaunch from an in-memory 32-bit PowerShell session into 64-bit PowerShell.
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Object','Json','None')]
    [string]$OutputFormat = 'Object',

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [string]$ResultPath,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SelfSourceUrl = 'https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/dev/windows-image-repair/Invoke-DismCheckHealth.ps1'
)

function ConvertTo-SingleQuotedArgument {
    Param([string]$Value)
    if ($null -eq $Value) { return "''" }
    return ("'{0}'" -f ($Value -replace "'", "''"))
}

function Get-RelayParameterText {
    $parts = @()
    $parts += ('-OutputFormat {0}' -f (ConvertTo-SingleQuotedArgument -Value $OutputFormat))
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $parts += ('-LogPath {0}' -f (ConvertTo-SingleQuotedArgument -Value $LogPath)) }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $parts += ('-ResultPath {0}' -f (ConvertTo-SingleQuotedArgument -Value $ResultPath)) }
    if (-not [string]::IsNullOrWhiteSpace($SelfSourceUrl)) { $parts += ('-SelfSourceUrl {0}' -f (ConvertTo-SingleQuotedArgument -Value $SelfSourceUrl)) }
    return ($parts -join ' ')
}

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $sysnativePowerShell -PathType Leaf)) {
        Write-Error '64-bit PowerShell is required, but Sysnative Windows PowerShell was not found.'
        exit 3
    }

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $argumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-OutputFormat',$OutputFormat,'-SelfSourceUrl',$SelfSourceUrl)
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $argumentList += @('-LogPath',$LogPath) }
        if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $argumentList += @('-ResultPath',$ResultPath) }
    }
    else {
        $relayParameters = Get-RelayParameterText
        $sourceUrlArgument = ConvertTo-SingleQuotedArgument -Value $SelfSourceUrl
        $scriptCommand = ('[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ScriptText = (New-Object Net.WebClient).DownloadString({0}); & ([scriptblock]::Create($ScriptText)) {1}' -f $sourceUrlArgument, $relayParameters)
        $argumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$scriptCommand)
    }

    $process = Start-Process -FilePath $sysnativePowerShell -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    exit $process.ExitCode
}

$ScriptName = 'Invoke-DismCheckHealth'
$Operation = 'DismCheckHealth'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path -Path 'C:\Temp' -ChildPath ('{0}-{1}.log' -f $ScriptName, $Timestamp) }

function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('Debug','Information','Warning','Error')][string]$Level = 'Information'
    )
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

function Get-NativeOutputPath {
    Param([string]$OperationName,[string]$OutputTimestamp)
    $logDirectory = Split-Path -Path $script:LogPath -Parent
    if ([string]::IsNullOrWhiteSpace($logDirectory)) { $logDirectory = 'C:\Temp' }
    $scanResultDirectory = Join-Path -Path $logDirectory -ChildPath 'scan-results'
    if (-not (Test-Path -LiteralPath $scanResultDirectory -PathType Container)) { New-Item -Path $scanResultDirectory -ItemType Directory -Force | Out-Null }
    return (Join-Path -Path $scanResultDirectory -ChildPath ('{0}-{1}.txt' -f $OperationName, $OutputTimestamp))
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
    Message = 'DISM CheckHealth did not complete.'
    LogPath = $LogPath
    ResultPath = $ResultPath
    RecommendedAction = 'ReviewLog'
    Data = [pscustomobject]@{ ToolExitCode = $null; RawStatus = 'Unknown'; CorruptionDetected = $false; Repairable = $false; DismScanRequired = $false; DismRestoreRequired = $false; SfcRequired = $false; NativeOutputPath = $null; Is64BitProcess = [Environment]::Is64BitProcess }
    Errors = @()
}

Write-Log -Message 'Starting DISM CheckHealth.'
Write-Log -Message ('PowerShell host is 64-bit process: {0}.' -f [Environment]::Is64BitProcess)

if (-not (Test-Administrator)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'Administrative elevation is required.'; $result.RecommendedAction = 'RunElevated'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'RunElevated'; Complete-Script -Result $result
}

$dismPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\dism.exe'
if (-not (Test-Path -LiteralPath $dismPath -PathType Leaf)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'dism.exe was not found.'; $result.RecommendedAction = 'ReviewSystemPath'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewSystemPath'; Complete-Script -Result $result
}

$output = & $dismPath /Online /Cleanup-Image /CheckHealth 2>&1
$toolExitCode = $LASTEXITCODE
$outputText = ($output | Out-String).Trim()
$outputPath = Get-NativeOutputPath -OperationName $Operation -OutputTimestamp $Timestamp
if (-not [string]::IsNullOrWhiteSpace($outputText)) { Set-Content -LiteralPath $outputPath -Value $outputText -Encoding UTF8 }
$result.Data.ToolExitCode = $toolExitCode
$result.Data.NativeOutputPath = $outputPath

if ($toolExitCode -ne 0) {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = ('DISM CheckHealth failed with native exit code {0}.' -f $toolExitCode); $result.RecommendedAction = 'ReviewLog'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewLog'
}
elseif ($outputText -match 'No component store corruption detected') {
    $result.Status = 'NoActionNeeded'; $result.ExitCode = 0; $result.Message = 'No component store corruption detected.'; $result.RecommendedAction = 'RunSfcScan'; $result.Data.RawStatus = 'NoCorruption'; $result.Data.SfcRequired = $true
}
elseif ($outputText -match 'The component store is repairable') {
    $result.Status = 'Success'; $result.ExitCode = 0; $result.Message = 'The component store is repairable.'; $result.RecommendedAction = 'RunDismScanHealth'; $result.Data.RawStatus = 'Repairable'; $result.Data.CorruptionDetected = $true; $result.Data.Repairable = $true; $result.Data.DismScanRequired = $true
}
elseif ($outputText -match 'The component store cannot be repaired') {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'The component store cannot be repaired automatically.'; $result.RecommendedAction = 'ManualRepairRequired'; $result.Data.RawStatus = 'NotRepairable'; $result.Data.CorruptionDetected = $true; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ManualRepairRequired'
}
else {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'Unable to determine DISM CheckHealth status from output.'; $result.RecommendedAction = 'ReviewLog'; $result.Errors += New-ErrorObject -Message $result.Message -RecommendedAction 'ReviewLog'
}

Complete-Script -Result $result
