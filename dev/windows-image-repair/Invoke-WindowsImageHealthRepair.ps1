<#
.SYNOPSIS
Runs a conditional Windows image health repair workflow.

.DESCRIPTION
Runs DISM CheckHealth, conditionally runs DISM ScanHealth and RestoreHealth, and runs SFC verification. The script can download missing child scripts from GitHub into a local working folder, then calls those scripts out-of-process and returns one consolidated structured result.

.PARAMETER OutputFormat
Controls final structured result output. Object is best for PowerShell callers, Json is best for stdout parsing, and None is best when ResultPath is used.

.PARAMETER LogPath
Optional log path. Defaults to C:\Temp\Invoke-WindowsImageHealthRepair-<Timestamp>.log.

.PARAMETER ResultPath
Optional JSON result path for durable machine-readable output.

.PARAMETER WorkingDirectory
Local directory used to store downloaded child scripts and child result files. Defaults to C:\Temp\AUT-WindowsHealth.

.PARAMETER ChildScriptBaseUrl
Base raw GitHub URL used to download missing child scripts.

.PARAMETER SelfSourceUrl
Raw URL for this orchestrator script. Used only when a 32-bit PowerShell host must relaunch an in-memory GitHub execution into 64-bit PowerShell.

.PARAMETER ForceDownload
Downloads fresh copies of child scripts even when local copies already exist.
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
    [string]$WorkingDirectory = 'C:\Temp\AUT-WindowsHealth',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ChildScriptBaseUrl = 'https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/dev/windows-image-repair',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SelfSourceUrl = 'https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/dev/windows-image-repair/Invoke-WindowsImageHealthRepair.ps1',

    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload
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
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $parts += ('-WorkingDirectory {0}' -f (ConvertTo-SingleQuotedArgument -Value $WorkingDirectory)) }
    if (-not [string]::IsNullOrWhiteSpace($ChildScriptBaseUrl)) { $parts += ('-ChildScriptBaseUrl {0}' -f (ConvertTo-SingleQuotedArgument -Value $ChildScriptBaseUrl)) }
    if (-not [string]::IsNullOrWhiteSpace($SelfSourceUrl)) { $parts += ('-SelfSourceUrl {0}' -f (ConvertTo-SingleQuotedArgument -Value $SelfSourceUrl)) }
    if ($ForceDownload) { $parts += '-ForceDownload' }
    return ($parts -join ' ')
}

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $sysnativePowerShell -PathType Leaf)) {
        Write-Error '64-bit PowerShell is required, but Sysnative Windows PowerShell was not found.'
        exit 3
    }

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $argumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-OutputFormat',$OutputFormat,'-WorkingDirectory',$WorkingDirectory,'-ChildScriptBaseUrl',$ChildScriptBaseUrl,'-SelfSourceUrl',$SelfSourceUrl)
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $argumentList += @('-LogPath',$LogPath) }
        if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $argumentList += @('-ResultPath',$ResultPath) }
        if ($ForceDownload) { $argumentList += '-ForceDownload' }
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

$ScriptName = 'Invoke-WindowsImageHealthRepair'
$Operation = 'WindowsImageHealthRepair'
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

function Get-OperatingSystemInfo {
    try { return Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
    catch {
        try { return Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop }
        catch { return $null }
    }
}

function Test-Windows11Client {
    Param([object]$OperatingSystem)
    if ($null -eq $OperatingSystem) { return $false }
    if ([int]$OperatingSystem.ProductType -ne 1) { return $false }
    $buildNumber = 0
    if (-not [int]::TryParse([string]$OperatingSystem.BuildNumber, [ref]$buildNumber)) { return $false }
    if ($buildNumber -lt 22000) { return $false }
    return $true
}

function New-ErrorObject {
    Param([string]$OperationName,[string]$Message,[string]$RecommendedAction)
    return [pscustomobject]@{ Target = 'LocalComputer'; Operation = $OperationName; Message = $Message; Category = 'Execution'; RecommendedAction = $RecommendedAction }
}

function Complete-Script {
    Param([pscustomobject]$Result)
    if (-not [string]::IsNullOrWhiteSpace($Result.ResultPath)) {
        $resultDirectory = Split-Path -Path $Result.ResultPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($resultDirectory) -and -not (Test-Path -LiteralPath $resultDirectory -PathType Container)) { New-Item -Path $resultDirectory -ItemType Directory -Force | Out-Null }
        $Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Result.ResultPath -Encoding UTF8
    }
    Write-Log -Message ('Completed with status {0}, exit code {1}. {2}' -f $Result.Status, $Result.ExitCode, $Result.Message)
    switch ($OutputFormat) { 'Json' { $Result | ConvertTo-Json -Depth 10 -Compress } 'Object' { Write-Output $Result } 'None' { } }
    exit $Result.ExitCode
}

function Save-ChildScript {
    [CmdletBinding()]
    Param([string]$ScriptName,[string]$DestinationPath)

    if ((Test-Path -LiteralPath $DestinationPath -PathType Leaf) -and -not $ForceDownload) {
        Write-Log -Message ('Using existing child script {0}.' -f $DestinationPath)
        return $true
    }

    $directory = Split-Path -Path $DestinationPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }

    $baseUrl = $ChildScriptBaseUrl.TrimEnd('/')
    $uri = '{0}/{1}' -f $baseUrl, $ScriptName
    Write-Log -Message ('Downloading child script {0}.' -f $ScriptName)

    try {
        Invoke-WebRequest -Uri $uri -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) { return $true }
        return $false
    }
    catch {
        Write-Log -Message ('Failed to download child script {0}. Error: {1}' -f $ScriptName, $_.Exception.Message) -Level 'Error'
        return $false
    }
}

function Invoke-ChildHealthScript {
    [CmdletBinding()]
    Param([string]$ScriptPath,[string]$ChildResultPath,[string]$OperationName)

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath); Operation = $OperationName; Status = 'DependencyMissing'; ExitCode = 3; Changed = $false; Message = 'Child script was not found.'; LogPath = $script:LogPath; ResultPath = $ChildResultPath; RecommendedAction = 'ReviewScriptDeployment'; Data = $null; Errors = @(New-ErrorObject -OperationName $OperationName -Message 'Child script was not found.' -RecommendedAction 'ReviewScriptDeployment') }
    }

    $powershellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = 'powershell.exe' }

    Write-Log -Message ('Running child operation {0}.' -f $OperationName)
    $process = Start-Process -FilePath $powershellPath -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-OutputFormat','None','-ResultPath',$ChildResultPath) -Wait -PassThru -WindowStyle Hidden

    if (Test-Path -LiteralPath $ChildResultPath -PathType Leaf) {
        try { return (Get-Content -LiteralPath $ChildResultPath -Raw | ConvertFrom-Json) }
        catch { return [pscustomobject]@{ ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath); Operation = $OperationName; Status = 'Failed'; ExitCode = 1; Changed = $false; Message = 'Failed to parse child result file.'; LogPath = $script:LogPath; ResultPath = $ChildResultPath; RecommendedAction = 'ReviewLog'; Data = $null; Errors = @(New-ErrorObject -OperationName $OperationName -Message 'Failed to parse child result file.' -RecommendedAction 'ReviewLog') } }
    }

    return [pscustomobject]@{ ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath); Operation = $OperationName; Status = 'Failed'; ExitCode = $process.ExitCode; Changed = $false; Message = 'Child result file was not created.'; LogPath = $script:LogPath; ResultPath = $ChildResultPath; RecommendedAction = 'ReviewLog'; Data = $null; Errors = @(New-ErrorObject -OperationName $OperationName -Message 'Child result file was not created.' -RecommendedAction 'ReviewLog') }
}

$script:LogPath = $LogPath
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
    Data = [pscustomobject]@{ Operations = @(); FinalRecommendedAction = 'ReviewLog'; RebootRecommended = $false; WorkingDirectory = $WorkingDirectory; ChildScriptBaseUrl = $ChildScriptBaseUrl; DownloadedScripts = @(); OperatingSystem = $null; Is64BitProcess = [Environment]::Is64BitProcess }
    Errors = @()
}

Write-Log -Message 'Starting Windows image health repair workflow.'
Write-Log -Message ('PowerShell host is 64-bit process: {0}.' -f [Environment]::Is64BitProcess)

$operatingSystem = Get-OperatingSystemInfo
$result.Data.OperatingSystem = $operatingSystem
if (-not (Test-Windows11Client -OperatingSystem $operatingSystem)) {
    $result.Status = 'ValidationFailed'; $result.ExitCode = 2; $result.Message = 'This workflow is supported only on Windows 11 client systems.'; $result.RecommendedAction = 'RunOnWindows11Client'; $result.Data.FinalRecommendedAction = 'RunOnWindows11Client'; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'RunOnWindows11Client'; Complete-Script -Result $result
}

if (-not (Test-Administrator)) {
    $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = 'Administrative elevation is required.'; $result.RecommendedAction = 'RunElevated'; $result.Data.FinalRecommendedAction = 'RunElevated'; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'RunElevated'; Complete-Script -Result $result
}

if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null }

$childScriptNames = @('Invoke-DismCheckHealth.ps1','Invoke-DismScanHealth.ps1','Invoke-DismRestoreHealth.ps1','Invoke-SfcScan.ps1')
foreach ($childScriptName in $childScriptNames) {
    $destinationPath = Join-Path -Path $WorkingDirectory -ChildPath $childScriptName
    $downloaded = Save-ChildScript -ScriptName $childScriptName -DestinationPath $destinationPath
    if (-not $downloaded) {
        $result.Status = 'DependencyMissing'; $result.ExitCode = 3; $result.Message = ('Unable to download required child script {0}.' -f $childScriptName); $result.RecommendedAction = 'ReviewNetworkAccess'; $result.Data.FinalRecommendedAction = 'ReviewNetworkAccess'; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction 'ReviewNetworkAccess'; Complete-Script -Result $result
    }
    $result.Data.DownloadedScripts += $destinationPath
}

$checkScript = Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-DismCheckHealth.ps1'
$scanScript = Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-DismScanHealth.ps1'
$restoreScript = Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-DismRestoreHealth.ps1'
$sfcScript = Join-Path -Path $WorkingDirectory -ChildPath 'Invoke-SfcScan.ps1'

$check = Invoke-ChildHealthScript -ScriptPath $checkScript -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-DismCheckHealth-result-{0}.json' -f $Timestamp)) -OperationName 'DismCheckHealth'
$result.Data.Operations += $check

if ($check.ExitCode -ne 0) {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'DISM CheckHealth failed or reported a non-repairable condition.'; $result.RecommendedAction = $check.RecommendedAction; $result.Data.FinalRecommendedAction = $check.RecommendedAction; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $check.RecommendedAction; Complete-Script -Result $result
}

if ($check.RecommendedAction -eq 'RunDismScanHealth') {
    $scan = Invoke-ChildHealthScript -ScriptPath $scanScript -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-DismScanHealth-result-{0}.json' -f $Timestamp)) -OperationName 'DismScanHealth'
    $result.Data.Operations += $scan

    if ($scan.ExitCode -ne 0) {
        $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'DISM ScanHealth failed or reported a non-repairable condition.'; $result.RecommendedAction = $scan.RecommendedAction; $result.Data.FinalRecommendedAction = $scan.RecommendedAction; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $scan.RecommendedAction; Complete-Script -Result $result
    }

    if ($scan.RecommendedAction -eq 'RunDismRestoreHealth') {
        $restore = Invoke-ChildHealthScript -ScriptPath $restoreScript -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-DismRestoreHealth-result-{0}.json' -f $Timestamp)) -OperationName 'DismRestoreHealth'
        $result.Data.Operations += $restore
        if ($restore.ExitCode -ne 0) {
            $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'DISM RestoreHealth failed.'; $result.RecommendedAction = $restore.RecommendedAction; $result.Data.FinalRecommendedAction = $restore.RecommendedAction; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $restore.RecommendedAction; Complete-Script -Result $result
        }
    }
}

$sfc = Invoke-ChildHealthScript -ScriptPath $sfcScript -ChildResultPath (Join-Path -Path $WorkingDirectory -ChildPath ('Invoke-SfcScan-result-{0}.json' -f $Timestamp)) -OperationName 'SfcScan'
$result.Data.Operations += $sfc

$result.Changed = $false
foreach ($operationResult in $result.Data.Operations) { if ($operationResult.Changed -eq $true) { $result.Changed = $true } }

if ($sfc.ExitCode -eq 0) {
    $result.ExitCode = 0
    if ($result.Changed) { $result.Status = 'Changed'; $result.Message = 'Windows image health workflow completed and changed system state.' }
    else { $result.Status = 'NoActionNeeded'; $result.Message = 'Windows image health workflow completed with no repair action required.' }
    $result.RecommendedAction = 'None'; $result.Data.FinalRecommendedAction = 'None'
}
elseif ($sfc.Status -eq 'PartialSuccess') {
    $result.Status = 'PartialSuccess'; $result.ExitCode = 4; $result.Message = 'Workflow completed but SFC reported unresolved corruption.'; $result.RecommendedAction = $sfc.RecommendedAction; $result.Data.FinalRecommendedAction = $sfc.RecommendedAction; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $sfc.RecommendedAction
}
else {
    $result.Status = 'Failed'; $result.ExitCode = 1; $result.Message = 'Workflow failed during SFC verification.'; $result.RecommendedAction = $sfc.RecommendedAction; $result.Data.FinalRecommendedAction = $sfc.RecommendedAction; $result.Errors += New-ErrorObject -OperationName $Operation -Message $result.Message -RecommendedAction $sfc.RecommendedAction
}

Complete-Script -Result $result
