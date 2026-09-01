<#
.SYNOPSIS
Runs the Windows image health repair workflow and returns a structured result.

.DESCRIPTION
Runs DISM CheckHealth, conditionally runs DISM ScanHealth and RestoreHealth, and
then runs SFC verification. The orchestrator can download the four child scripts
from an approved raw GitHub source. Child scripts execute in separate Windows
PowerShell processes and append to the same detailed run log.

The workflow supports Windows client and Windows Server operating systems,
requires administrative elevation, and requires a 64-bit PowerShell process for
DISM and SFC work. On a 64-bit operating system, a 32-bit launch is relayed to
Sysnative Windows PowerShell using the exact script content already executing.

.PARAMETER OutputFormat
Controls success-stream output. Object returns the structured result object,
Json returns compressed JSON, and None suppresses success-stream result output.

.PARAMETER LogPath
Optional path for the consolidated run log. Defaults to
C:\Temp\Logs\WindowsImageHealthRepair-<timestamp>.log.

.PARAMETER ResultPath
Optional path for the consolidated RMM-facing JSON result. Defaults beneath
C:\Temp\Logs\results.

.PARAMETER WorkingDirectory
Directory used for downloaded child scripts and transient child-result JSON.
Defaults to C:\Temp\AUT-WindowsHealth.

.PARAMETER ChildScriptBaseUrl
Raw GitHub directory URL used to acquire child scripts. Production execution
should use a commit-pinned URL together with RequirePinnedSource.

.PARAMETER ForceDownload
Refreshes child scripts even when cached copies already exist.

.PARAMETER RequirePinnedSource
Requires ChildScriptBaseUrl to contain an exact 40-character Git commit SHA and
forces child refresh so a run cannot mix cached and moving-source versions.

.PARAMETER Quiet
Suppresses non-essential console presentation. Persistent log detail, result
files, failure handling, and exit codes are preserved.

.OUTPUTS
PSCustomObject when OutputFormat is Object, JSON text when OutputFormat is Json,
or no success-stream output when OutputFormat is None. The process exit code is
also set according to the structured result.

.EXAMPLE
.\Invoke-WindowsImageHealthRepair.ps1 -ForceDownload

Runs the workflow and refreshes child scripts from the configured source.

.EXAMPLE
.\Invoke-WindowsImageHealthRepair.ps1 -ChildScriptBaseUrl 'https://raw.githubusercontent.com/ExampleOrg/ExampleRepo/0123456789abcdef0123456789abcdef01234567/scripts/windows-health' -RequirePinnedSource -Quiet -OutputFormat None

Runs an unattended workflow from an immutable child-script source.

.NOTES
Default target: Windows PowerShell 5.1. Administrative elevation and a supported
Windows client or Windows Server operating system are required. The script is
intended for RMM/unattended use and writes durable artifacts beneath C:\Temp\Logs
unless caller-supplied paths override the log or result path.
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
    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory = 'C:\Temp\AUT-WindowsHealth',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ChildScriptBaseUrl = 'https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/scripts/windows-health',

    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload,

    [Parameter(Mandatory = $false)]
    [switch]$RequirePinnedSource,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

Set-StrictMode -Version 2.0

function ConvertTo-SingleQuotedArgument {
    Param([string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return ("'{0}'" -f ($Value -replace "'", "''"))
}

function Get-RelayParameterText {
    $parts = @()
    $parts += ('-OutputFormat {0}' -f (ConvertTo-SingleQuotedArgument -Value $OutputFormat))

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $parts += ('-LogPath {0}' -f (ConvertTo-SingleQuotedArgument -Value $LogPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $parts += ('-ResultPath {0}' -f (ConvertTo-SingleQuotedArgument -Value $ResultPath))
    }

    $parts += ('-WorkingDirectory {0}' -f (ConvertTo-SingleQuotedArgument -Value $WorkingDirectory))
    $parts += ('-ChildScriptBaseUrl {0}' -f (ConvertTo-SingleQuotedArgument -Value $ChildScriptBaseUrl))

    if ($ForceDownload) { $parts += '-ForceDownload' }
    if ($RequirePinnedSource) { $parts += '-RequirePinnedSource' }
    if ($Quiet) { $parts += '-Quiet' }

    return ($parts -join ' ')
}

function Test-PinnedChildScriptSource {
    Param([string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return $false
    }

    return ($BaseUrl -match '^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-fA-F]{40}/scripts/windows-health/?$')
}

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $sysnativePowerShell -PathType Leaf)) {
        Write-Error '64-bit PowerShell is required, but Sysnative Windows PowerShell was not found.'
        exit 3
    }

    $relayScriptPath = $null
    $deleteRelayScript = $false

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $relayScriptPath = $PSCommandPath
    }
    else {
        $relayDirectory = Join-Path -Path $env:TEMP -ChildPath 'AUT-WindowsHealth-Relay'
        if (-not (Test-Path -LiteralPath $relayDirectory -PathType Container)) {
            New-Item -Path $relayDirectory -ItemType Directory -Force | Out-Null
        }

        $relayScriptPath = Join-Path -Path $relayDirectory -ChildPath ('Invoke-WindowsImageHealthRepair-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
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

$ScriptName = 'Invoke-WindowsImageHealthRepair'
$Operation = 'WindowsImageHealthRepair'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogRoot = 'C:\Temp\Logs'

if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path -Path $LogRoot -ChildPath ('WindowsImageHealthRepair-{0}.log' -f $Timestamp)
}

$resultDirectory = Join-Path -Path $LogRoot -ChildPath 'results'
if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
    New-Item -Path $resultDirectory -ItemType Directory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path -Path $resultDirectory -ChildPath ('WindowsImageHealthRepair-{0}.json' -f $Timestamp)
}

$script:LogPath = $LogPath

function Write-Log {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$Level = 'Information'
    )

    $directory = Split-Path -Path $script:LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $entry = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Operation, $Message
    Add-Content -LiteralPath $script:LogPath -Value $entry -Encoding UTF8
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OperatingSystemInfo {
    try {
        return Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    }
    catch {
        Write-Log -Message ('Get-CimInstance failed while resolving operating system information: {0}' -f $_.Exception.Message) -Level 'Warning'
    }

    try {
        return Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
    }
    catch {
        Write-Log -Message ('Get-WmiObject failed while resolving operating system information: {0}' -f $_.Exception.Message) -Level 'Error'
        return $null
    }
}

function ConvertTo-CompactOperatingSystemInfo {
    Param([object]$OperatingSystem)

    if ($null -eq $OperatingSystem) {
        return $null
    }

    $productType = 0
    [void][int]::TryParse([string]$OperatingSystem.ProductType, [ref]$productType)

    return [pscustomobject]@{
        Caption = [string]$OperatingSystem.Caption
        Version = [string]$OperatingSystem.Version
        BuildNumber = [string]$OperatingSystem.BuildNumber
        ProductType = $productType
        OSArchitecture = [string]$OperatingSystem.OSArchitecture
    }
}

function Test-SupportedWindowsOperatingSystem {
    Param([object]$OperatingSystem)

    if ($null -eq $OperatingSystem) {
        return $false
    }

    $productType = 0
    if (-not [int]::TryParse([string]$OperatingSystem.ProductType, [ref]$productType)) {
        return $false
    }

    return ($productType -eq 1 -or $productType -eq 2 -or $productType -eq 3)
}

function New-ErrorObject {
    Param(
        [string]$OperationName,
        [string]$Message,
        [string]$RecommendedAction
    )

    return [pscustomobject]@{
        Target = 'LocalComputer'
        Operation = $OperationName
        Message = $Message
        Category = 'Execution'
        RecommendedAction = $RecommendedAction
    }
}

function Publish-Result {
    Param([pscustomobject]$Result)

    $resultDirectoryPath = Split-Path -Path $Result.ResultPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($resultDirectoryPath) -and -not (Test-Path -LiteralPath $resultDirectoryPath -PathType Container)) {
        New-Item -Path $resultDirectoryPath -ItemType Directory -Force | Out-Null
    }

    try {
        $Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Result.ResultPath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Log -Message ('Failed to write consolidated result file {0}: {1}' -f $Result.ResultPath, $_.Exception.Message) -Level 'Critical'
        throw
    }

    $completionLevel = 'Information'
    if ($Result.ExitCode -ne 0) {
        $completionLevel = 'Critical'
    }

    Write-Log -Message ('Final status={0}; exit={1}; changed={2}; recommendedAction={3}; result={4}.' -f $Result.Status, $Result.ExitCode, $Result.Changed, $Result.RecommendedAction, $Result.ResultPath) -Level $completionLevel

    switch ($OutputFormat) {
        'Json' { $Result | ConvertTo-Json -Depth 10 -Compress }
        'Object' { Write-Output $Result }
        'None' { }
    }
}

function Save-ChildScript {
    Param(
        [string]$ScriptName,
        [string]$DestinationPath
    )

    $mustRefresh = $ForceDownload -or $RequirePinnedSource
    if ((Test-Path -LiteralPath $DestinationPath -PathType Leaf) -and -not $mustRefresh) {
        Write-Log -Message ('Using cached child script {0}.' -f $DestinationPath) -Level 'Debug'
        return $true
    }

    $directory = Split-Path -Path $DestinationPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $uri = '{0}/{1}' -f $ChildScriptBaseUrl.TrimEnd('/'), $ScriptName
    Write-Log -Message ('Downloading child script {0} from {1}.' -f $ScriptName, $uri)

    try {
        Invoke-WebRequest -Uri $uri -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        Write-Log -Message ('Downloaded child script to {0}.' -f $DestinationPath) -Level 'Debug'
        return (Test-Path -LiteralPath $DestinationPath -PathType Leaf)
    }
    catch {
        Write-Log -Message ('Child download failed for {0}: {1}' -f $ScriptName, $_.Exception.Message) -Level 'Error'
        return $false
    }
}

function Invoke-ChildHealthScript {
    Param(
        [string]$ScriptPath,
        [string]$ChildResultPath,
        [string]$OperationName
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{
            ScriptName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
            Operation = $OperationName
            Status = 'DependencyMissing'
            ExitCode = 3
            Changed = $false
            Message = 'Child script was not found.'
            LogPath = $script:LogPath
            ResultPath = $ChildResultPath
            RecommendedAction = 'ReviewScriptDeployment'
            Data = $null
            Errors = @(New-ErrorObject -OperationName $OperationName -Message 'Child script was not found.' -RecommendedAction 'ReviewScriptDeployment')
        }
    }

    $powershellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        $powershellPath = 'powershell.exe'
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath,
        '-OutputFormat', 'None',
        '-LogPath', $script:LogPath,
        '-ResultPath', $ChildResultPath
    )
    if ($Quiet) {
        $arguments += '-Quiet'
    }

    Write-Log -Message ('Starting child operation {0}; executable={1}; script={2}; result={3}.' -f $OperationName, $powershellPath, $ScriptPath, $ChildResultPath)
    & $powershellPath @arguments
    $childExitCode = $LASTEXITCODE
    Write-Log -Message ('Child process {0} exited with code {1}.' -f $OperationName, $childExitCode) -Level 'Debug'

    if (Test-Path -LiteralPath $ChildResultPath -PathType Leaf) {
        try {
            $childResult = Get-Content -LiteralPath $ChildResultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            Write-Log -Message ('Child {0} returned status={1}; exit={2}; changed={3}; recommendedAction={4}.' -f $OperationName, $childResult.Status, $childResult.ExitCode, $childResult.Changed, $childResult.RecommendedAction)
            return $childResult
        }
        catch {
            Write-Log -Message ('Unable to parse child result {0}: {1}' -f $ChildResultPath, $_.Exception.Message) -Level 'Error'
        }
    }

    return [pscustomobject]@{
        ScriptName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
        Operation = $OperationName
        Status = 'Failed'
        ExitCode = $childExitCode
        Changed = $false
        Message = 'Child result file was not created or parsed.'
        LogPath = $script:LogPath
        ResultPath = $ChildResultPath
        RecommendedAction = 'ReviewLog'
        Data = $null
        Errors = @(New-ErrorObject -OperationName $OperationName -Message 'Child result file was not created or parsed.' -RecommendedAction 'ReviewLog')
    }
}

$result = [pscustomobject]@{
    ScriptName = $ScriptName
    Operation = $Operation
    Status = 'Failed'
    ExitCode = 1
    Changed = $false
    Message = 'Windows image health workflow did not complete.'
    LogPath = $LogPath
    ResultPath = $ResultPath
    RecommendedAction = 'ReviewLog'
    Data = [pscustomobject]@{
        Operations = @()
        FinalRecommendedAction = 'ReviewLog'
        RebootRecommended = $false
        WorkingDirectory = $WorkingDirectory
        ChildScriptBaseUrl = $ChildScriptBaseUrl
        DownloadedScripts = @()
        OperatingSystem = $null
        Is64BitProcess = [Environment]::Is64BitProcess
        PinnedSourceRequired = [bool]$RequirePinnedSource
    }
    Errors = @()
}

Write-Log -Message 'Starting Windows image health repair workflow.'
Write-Log -Message ('LogPath={0}; ResultPath={1}; WorkingDirectory={2}; ChildScriptBaseUrl={3}; ForceDownload={4}; RequirePinnedSource={5}; Quiet={6}.' -f $LogPath, $ResultPath, $WorkingDirectory, $ChildScriptBaseUrl, [bool]$ForceDownload, [bool]$RequirePinnedSource, [bool]$Quiet) -Level 'Debug'
Write-Log -Message ('ProcessArchitecture64Bit={0}; OSArchitecture64Bit={1}; Identity={2}.' -f [Environment]::Is64BitProcess, [Environment]::Is64BitOperatingSystem, [Security.Principal.WindowsIdentity]::GetCurrent().Name) -Level 'Debug'

if ($RequirePinnedSource -and -not (Test-PinnedChildScriptSource -BaseUrl $ChildScriptBaseUrl)) {
    $result.Status = 'ValidationFailed'
    $result.ExitCode = 2
    $result.Message = 'RequirePinnedSource requires ChildScriptBaseUrl to contain a 40-character Git commit SHA.'
    $result.RecommendedAction = 'UsePinnedCommitSource'
    $result.Data.FinalRecommendedAction = 'UsePinnedCommitSource'
    $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'UsePinnedCommitSource'
    Publish-Result -Result $result
    exit $result.ExitCode
}

$operatingSystem = Get-OperatingSystemInfo
$result.Data.OperatingSystem = ConvertTo-CompactOperatingSystemInfo -OperatingSystem $operatingSystem
if ($operatingSystem) {
    Write-Log -Message ('OS Caption={0}; Version={1}; Build={2}; ProductType={3}.' -f $operatingSystem.Caption, $operatingSystem.Version, $operatingSystem.BuildNumber, $operatingSystem.ProductType)
}

if (-not (Test-SupportedWindowsOperatingSystem -OperatingSystem $operatingSystem)) {
    $result.Status = 'ValidationFailed'
    $result.ExitCode = 2
    $result.Message = 'This workflow is supported only on Windows client or Windows Server operating systems.'
    $result.RecommendedAction = 'RunOnSupportedWindows'
    $result.Data.FinalRecommendedAction = 'RunOnSupportedWindows'
    $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'RunOnSupportedWindows'
    Publish-Result -Result $result
    exit $result.ExitCode
}

$elevated = Test-Administrator
Write-Log -Message ('AdministrativeElevation={0}.' -f $elevated) -Level 'Debug'
if (-not $elevated) {
    $result.Status = 'DependencyMissing'
    $result.ExitCode = 3
    $result.Message = 'Administrative elevation is required.'
    $result.RecommendedAction = 'RunElevated'
    $result.Data.FinalRecommendedAction = 'RunElevated'
    $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'RunElevated'
    Publish-Result -Result $result
    exit $result.ExitCode
}

if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null
}

$childNames = @(
    'Invoke-DismCheckHealth.ps1',
    'Invoke-DismScanHealth.ps1',
    'Invoke-DismRestoreHealth.ps1',
    'Invoke-SfcScan.ps1'
)

foreach ($childName in $childNames) {
    $destination = Join-Path -Path $WorkingDirectory -ChildPath $childName
    if (-not (Save-ChildScript -ScriptName $childName -DestinationPath $destination)) {
        $result.Status = 'DependencyMissing'
        $result.ExitCode = 3
        $result.Message = 'Unable to download required child script {0}.' -f $childName
        $result.RecommendedAction = 'ReviewNetworkAccess'
        $result.Data.FinalRecommendedAction = 'ReviewNetworkAccess'
        $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'ReviewNetworkAccess'
        Publish-Result -Result $result
        exit $result.ExitCode
    }
    $result.Data.DownloadedScripts += $destination
}

$check = Invoke-ChildHealthScript -ScriptPath (Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-DismCheckHealth.ps1') -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-DismCheckHealth-result-{0}.json' -f $Timestamp)) -OperationName 'DismCheckHealth'
$result.Data.Operations += $check
if ($check.ExitCode -ne 0) {
    $result.Status = 'Failed'
    $result.ExitCode = 1
    $result.Message = 'DISM CheckHealth failed or reported a non-repairable condition.'
    $result.RecommendedAction = $check.RecommendedAction
    $result.Data.FinalRecommendedAction = $check.RecommendedAction
    $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $check.RecommendedAction
    Publish-Result -Result $result
    exit $result.ExitCode
}

if ($check.RecommendedAction -eq 'RunDismScanHealth') {
    Write-Log -Message 'CheckHealth reported repairable corruption; running ScanHealth.'
    $scan = Invoke-ChildHealthScript -ScriptPath (Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-DismScanHealth.ps1') -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-DismScanHealth-result-{0}.json' -f $Timestamp)) -OperationName 'DismScanHealth'
    $result.Data.Operations += $scan

    if ($scan.ExitCode -ne 0) {
        $result.Status = 'Failed'
        $result.ExitCode = 1
        $result.Message = 'DISM ScanHealth failed or reported a non-repairable condition.'
        $result.RecommendedAction = $scan.RecommendedAction
        $result.Data.FinalRecommendedAction = $scan.RecommendedAction
        $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $scan.RecommendedAction
        Publish-Result -Result $result
        exit $result.ExitCode
    }

    if ($scan.RecommendedAction -eq 'RunDismRestoreHealth') {
        Write-Log -Message 'ScanHealth confirmed repairable corruption; running RestoreHealth.'
        $restore = Invoke-ChildHealthScript -ScriptPath (Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-DismRestoreHealth.ps1') -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-DismRestoreHealth-result-{0}.json' -f $Timestamp)) -OperationName 'DismRestoreHealth'
        $result.Data.Operations += $restore

        if ($restore.ExitCode -ne 0) {
            $result.Status = 'Failed'
            $result.ExitCode = 1
            $result.Message = 'DISM RestoreHealth failed.'
            $result.RecommendedAction = $restore.RecommendedAction
            $result.Data.FinalRecommendedAction = $restore.RecommendedAction
            $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $restore.RecommendedAction
            Publish-Result -Result $result
            exit $result.ExitCode
        }
    }
    else {
        Write-Log -Message 'ScanHealth did not require RestoreHealth; skipping RestoreHealth.'
    }
}
else {
    Write-Log -Message 'CheckHealth found no component-store corruption; skipping ScanHealth and RestoreHealth.'
}

Write-Log -Message 'Running SFC final verification.'
$sfc = Invoke-ChildHealthScript -ScriptPath (Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-SfcScan.ps1') -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-SfcScan-result-{0}.json' -f $Timestamp)) -OperationName 'SfcScan'
$result.Data.Operations += $sfc

foreach ($operationResult in $result.Data.Operations) {
    if ($operationResult.Changed -eq $true) {
        $result.Changed = $true
    }
}

if ($sfc.ExitCode -eq 0) {
    $result.ExitCode = 0
    if ($result.Changed) {
        $result.Status = 'Changed'
        $result.Message = 'Windows image health workflow completed and changed system state.'
    }
    else {
        $result.Status = 'NoActionNeeded'
        $result.Message = 'Windows image health workflow completed with no repair action required.'
    }
    $result.RecommendedAction = 'None'
    $result.Data.FinalRecommendedAction = 'None'
}
elseif ($sfc.Status -eq 'PartialSuccess') {
    $result.Status = 'PartialSuccess'
    $result.ExitCode = 4
    $result.Message = 'Workflow completed but SFC reported unresolved corruption.'
    $result.RecommendedAction = $sfc.RecommendedAction
    $result.Data.FinalRecommendedAction = $sfc.RecommendedAction
    $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $sfc.RecommendedAction
}
else {
    $result.Status = 'Failed'
    $result.ExitCode = 1
    $result.Message = 'Workflow failed during SFC verification.'
    $result.RecommendedAction = $sfc.RecommendedAction
    $result.Data.FinalRecommendedAction = $sfc.RecommendedAction
    $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $sfc.RecommendedAction
}

Publish-Result -Result $result
exit $result.ExitCode
