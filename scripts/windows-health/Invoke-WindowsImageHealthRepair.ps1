<#
.SYNOPSIS
Runs a conditional Windows image health repair workflow.

.DESCRIPTION
Runs DISM CheckHealth, conditionally runs DISM ScanHealth and RestoreHealth, and runs SFC verification. Child scripts execute out-of-process but append to the same orchestrator log.
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory=$false)][ValidateSet('Object','Json','None')][string]$OutputFormat='Object',
    [Parameter(Mandatory=$false)][string]$LogPath,
    [Parameter(Mandatory=$false)][string]$ResultPath,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()][string]$WorkingDirectory='C:\Temp\AUT-WindowsHealth',
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()][string]$ChildScriptBaseUrl='https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/scripts/windows-health',
    [Parameter(Mandatory=$false)][switch]$ForceDownload,
    [Parameter(Mandatory=$false)][switch]$RequirePinnedSource,
    [Parameter(Mandatory=$false)][switch]$Quiet
)

function ConvertTo-SingleQuotedArgument { Param([string]$Value) if($null -eq $Value){return "''"}; return ("'{0}'" -f ($Value -replace "'","''")) }
function Get-RelayParameterText {
    $parts=@(); $parts+=('-OutputFormat {0}' -f (ConvertTo-SingleQuotedArgument $OutputFormat))
    if($LogPath){$parts+=('-LogPath {0}' -f (ConvertTo-SingleQuotedArgument $LogPath))}
    if($ResultPath){$parts+=('-ResultPath {0}' -f (ConvertTo-SingleQuotedArgument $ResultPath))}
    $parts+=('-WorkingDirectory {0}' -f (ConvertTo-SingleQuotedArgument $WorkingDirectory))
    $parts+=('-ChildScriptBaseUrl {0}' -f (ConvertTo-SingleQuotedArgument $ChildScriptBaseUrl))
    if($ForceDownload){$parts+='-ForceDownload'}; if($RequirePinnedSource){$parts+='-RequirePinnedSource'}; if($Quiet){$parts+='-Quiet'}
    return ($parts -join ' ')
}
function Test-PinnedChildScriptSource { Param([string]$BaseUrl) if([string]::IsNullOrWhiteSpace($BaseUrl)){return $false}; return ($BaseUrl -match '^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-fA-F]{40}/scripts/windows-health/?$') }

if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess){
    $sysnativePowerShell=Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if(-not(Test-Path -LiteralPath $sysnativePowerShell -PathType Leaf)){Write-Error '64-bit PowerShell is required, but Sysnative Windows PowerShell was not found.';exit 3}
    $relayScriptPath=$null;$deleteRelayScript=$false
    if($PSCommandPath){$relayScriptPath=$PSCommandPath}else{
        $relayDirectory=Join-Path $env:TEMP 'AUT-WindowsHealth-Relay';if(-not(Test-Path -LiteralPath $relayDirectory -PathType Container)){New-Item -Path $relayDirectory -ItemType Directory -Force|Out-Null}
        $relayScriptPath=Join-Path $relayDirectory ('Invoke-WindowsImageHealthRepair-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $relayScriptPath -Value $MyInvocation.MyCommand.ScriptBlock.ToString() -Encoding UTF8;$deleteRelayScript=$true
    }
    try{$cmd=('& {0} {1}' -f (ConvertTo-SingleQuotedArgument $relayScriptPath),(Get-RelayParameterText));$process=Start-Process -FilePath $sysnativePowerShell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd) -Wait -PassThru -WindowStyle Hidden;exit $process.ExitCode}
    finally{if($deleteRelayScript -and $relayScriptPath -and (Test-Path -LiteralPath $relayScriptPath -PathType Leaf)){Remove-Item -LiteralPath $relayScriptPath -Force -ErrorAction SilentlyContinue}}
}

$ScriptName='Invoke-WindowsImageHealthRepair';$Operation='WindowsImageHealthRepair';$Timestamp=Get-Date -Format 'yyyyMMdd-HHmmss';$LogRoot='C:\Temp\Logs'
if(-not(Test-Path -LiteralPath $LogRoot -PathType Container)){New-Item -Path $LogRoot -ItemType Directory -Force|Out-Null}
if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Join-Path $LogRoot ('WindowsImageHealthRepair-{0}.log' -f $Timestamp)}
$resultDirectory=Join-Path $LogRoot 'results';if(-not(Test-Path -LiteralPath $resultDirectory -PathType Container)){New-Item -Path $resultDirectory -ItemType Directory -Force|Out-Null}
if([string]::IsNullOrWhiteSpace($ResultPath)){$ResultPath=Join-Path $resultDirectory ('WindowsImageHealthRepair-{0}.json' -f $Timestamp)}
$script:LogPath=$LogPath

function Write-Log { Param([string]$Message,[ValidateSet('Debug','Information','Warning','Error')][string]$Level='Information') $d=Split-Path $script:LogPath -Parent;if($d -and -not(Test-Path -LiteralPath $d -PathType Container)){New-Item -Path $d -ItemType Directory -Force|Out-Null};Add-Content -LiteralPath $script:LogPath -Value ('{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Operation,$Message) -Encoding UTF8 }
function Test-Administrator { $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity);return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Get-OperatingSystemInfo { try{return Get-CimInstance Win32_OperatingSystem -ErrorAction Stop}catch{try{return Get-WmiObject Win32_OperatingSystem -ErrorAction Stop}catch{return $null}} }
function Test-SupportedWindowsOperatingSystem { Param([object]$OperatingSystem) if($null -eq $OperatingSystem){return $false};$productType=0;if(-not[int]::TryParse([string]$OperatingSystem.ProductType,[ref]$productType)){return $false};return ($productType -eq 1 -or $productType -eq 2 -or $productType -eq 3) }
function New-ErrorObject { Param([string]$OperationName,[string]$Message,[string]$RecommendedAction) return [pscustomobject]@{Target='LocalComputer';Operation=$OperationName;Message=$Message;Category='Execution';RecommendedAction=$RecommendedAction} }
function Complete-Script {
    Param([pscustomobject]$Result)
    $rd=Split-Path $Result.ResultPath -Parent;if($rd -and -not(Test-Path -LiteralPath $rd -PathType Container)){New-Item -Path $rd -ItemType Directory -Force|Out-Null}
    $Result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $Result.ResultPath -Encoding UTF8
    Write-Log ('Final status={0}; exit={1}; changed={2}; recommendedAction={3}; result={4}' -f $Result.Status,$Result.ExitCode,$Result.Changed,$Result.RecommendedAction,$Result.ResultPath)
    switch($OutputFormat){'Json'{$Result|ConvertTo-Json -Depth 10 -Compress}'Object'{Write-Output $Result}'None'{}}
    exit $Result.ExitCode
}
function Save-ChildScript {
    Param([string]$ScriptName,[string]$DestinationPath)
    $mustRefresh=$ForceDownload -or $RequirePinnedSource
    if((Test-Path -LiteralPath $DestinationPath -PathType Leaf) -and -not $mustRefresh){Write-Log ('Using cached child script {0}.' -f $DestinationPath);return $true}
    $directory=Split-Path $DestinationPath -Parent;if(-not(Test-Path -LiteralPath $directory -PathType Container)){New-Item -Path $directory -ItemType Directory -Force|Out-Null}
    $uri='{0}/{1}' -f $ChildScriptBaseUrl.TrimEnd('/'),$ScriptName;Write-Log ('Downloading child script {0} from {1}.' -f $ScriptName,$uri)
    try{Invoke-WebRequest -Uri $uri -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop;Write-Log ('Downloaded child script to {0}.' -f $DestinationPath);return (Test-Path -LiteralPath $DestinationPath -PathType Leaf)}catch{Write-Log ('Child download failed for {0}: {1}' -f $ScriptName,$_.Exception.Message) 'Error';return $false}
}
function Invoke-ChildHealthScript {
    Param([string]$ScriptPath,[string]$ChildResultPath,[string]$OperationName)
    if(-not(Test-Path -LiteralPath $ScriptPath -PathType Leaf)){return [pscustomobject]@{ScriptName=[IO.Path]::GetFileNameWithoutExtension($ScriptPath);Operation=$OperationName;Status='DependencyMissing';ExitCode=3;Changed=$false;Message='Child script was not found.';LogPath=$script:LogPath;ResultPath=$ChildResultPath;RecommendedAction='ReviewScriptDeployment';Data=$null;Errors=@(New-ErrorObject $OperationName 'Child script was not found.' 'ReviewScriptDeployment')}}
    $powershellPath=Join-Path $PSHOME 'powershell.exe';if(-not(Test-Path -LiteralPath $powershellPath -PathType Leaf)){$powershellPath='powershell.exe'}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-OutputFormat','None','-LogPath',$script:LogPath,'-ResultPath',$ChildResultPath);if($Quiet){$arguments+='-Quiet'}
    Write-Log ('Starting child operation {0}; script={1}; result={2}.' -f $OperationName,$ScriptPath,$ChildResultPath)
    $process=Start-Process -FilePath $powershellPath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if(Test-Path -LiteralPath $ChildResultPath -PathType Leaf){try{$child=Get-Content -LiteralPath $ChildResultPath -Raw|ConvertFrom-Json;Write-Log ('Child {0} returned status={1}; exit={2}; changed={3}; recommendedAction={4}.' -f $OperationName,$child.Status,$child.ExitCode,$child.Changed,$child.RecommendedAction);return $child}catch{Write-Log ('Unable to parse child result {0}: {1}' -f $ChildResultPath,$_.Exception.Message) 'Error'}}
    return [pscustomobject]@{ScriptName=[IO.Path]::GetFileNameWithoutExtension($ScriptPath);Operation=$OperationName;Status='Failed';ExitCode=$process.ExitCode;Changed=$false;Message='Child result file was not created or parsed.';LogPath=$script:LogPath;ResultPath=$ChildResultPath;RecommendedAction='ReviewLog';Data=$null;Errors=@(New-ErrorObject $OperationName 'Child result file was not created or parsed.' 'ReviewLog')}
}

$result=[pscustomobject]@{ScriptName=$ScriptName;Operation=$Operation;Status='Failed';ExitCode=1;Changed=$false;Message='Windows image health workflow did not complete.';LogPath=$LogPath;ResultPath=$ResultPath;RecommendedAction='ReviewLog';Data=[pscustomobject]@{Operations=@();FinalRecommendedAction='ReviewLog';RebootRecommended=$false;WorkingDirectory=$WorkingDirectory;ChildScriptBaseUrl=$ChildScriptBaseUrl;DownloadedScripts=@();OperatingSystem=$null;Is64BitProcess=[Environment]::Is64BitProcess;PinnedSourceRequired=[bool]$RequirePinnedSource};Errors=@()}

Write-Log 'Starting Windows image health repair workflow.'
Write-Log ('LogPath={0}; ResultPath={1}; WorkingDirectory={2}; ChildScriptBaseUrl={3}; ForceDownload={4}; RequirePinnedSource={5}; Quiet={6}.' -f $LogPath,$ResultPath,$WorkingDirectory,$ChildScriptBaseUrl,[bool]$ForceDownload,[bool]$RequirePinnedSource,[bool]$Quiet)
Write-Log ('ProcessArchitecture64Bit={0}; OSArchitecture64Bit={1}; Identity={2}.' -f [Environment]::Is64BitProcess,[Environment]::Is64BitOperatingSystem,[Security.Principal.WindowsIdentity]::GetCurrent().Name)

if($RequirePinnedSource -and -not(Test-PinnedChildScriptSource $ChildScriptBaseUrl)){$result.Status='ValidationFailed';$result.ExitCode=2;$result.Message='RequirePinnedSource requires ChildScriptBaseUrl to contain a 40-character Git commit SHA.';$result.RecommendedAction='UsePinnedCommitSource';$result.Data.FinalRecommendedAction='UsePinnedCommitSource';$result.Errors+=New-ErrorObject $Operation $result.Message 'UsePinnedCommitSource';Complete-Script $result}
$operatingSystem=Get-OperatingSystemInfo;$result.Data.OperatingSystem=$operatingSystem
if($operatingSystem){Write-Log ('OS Caption={0}; Version={1}; Build={2}; ProductType={3}.' -f $operatingSystem.Caption,$operatingSystem.Version,$operatingSystem.BuildNumber,$operatingSystem.ProductType)}
if(-not(Test-SupportedWindowsOperatingSystem $operatingSystem)){$result.Status='ValidationFailed';$result.ExitCode=2;$result.Message='This workflow is supported only on Windows client or Windows Server operating systems.';$result.RecommendedAction='RunOnSupportedWindows';$result.Data.FinalRecommendedAction='RunOnSupportedWindows';$result.Errors+=New-ErrorObject $Operation $result.Message 'RunOnSupportedWindows';Complete-Script $result}
$elevated=Test-Administrator;Write-Log ('AdministrativeElevation={0}.' -f $elevated);if(-not $elevated){$result.Status='DependencyMissing';$result.ExitCode=3;$result.Message='Administrative elevation is required.';$result.RecommendedAction='RunElevated';$result.Data.FinalRecommendedAction='RunElevated';$result.Errors+=New-ErrorObject $Operation $result.Message 'RunElevated';Complete-Script $result}

if(-not(Test-Path -LiteralPath $WorkingDirectory -PathType Container)){New-Item -Path $WorkingDirectory -ItemType Directory -Force|Out-Null}
$childNames=@('Invoke-DismCheckHealth.ps1','Invoke-DismScanHealth.ps1','Invoke-DismRestoreHealth.ps1','Invoke-SfcScan.ps1')
foreach($childName in $childNames){$destination=Join-Path $WorkingDirectory $childName;if(-not(Save-ChildScript $childName $destination)){$result.Status='DependencyMissing';$result.ExitCode=3;$result.Message=('Unable to download required child script {0}.' -f $childName);$result.RecommendedAction='ReviewNetworkAccess';$result.Data.FinalRecommendedAction='ReviewNetworkAccess';$result.Errors+=New-ErrorObject $Operation $result.Message 'ReviewNetworkAccess';Complete-Script $result};$result.Data.DownloadedScripts+=$destination}

$check=Invoke-ChildHealthScript (Join-Path $WorkingDirectory 'Invoke-DismCheckHealth.ps1') (Join-Path $WorkingDirectory ('Invoke-DismCheckHealth-result-{0}.json' -f $Timestamp)) 'DismCheckHealth';$result.Data.Operations+=$check
if($check.ExitCode -ne 0){$result.Status='Failed';$result.ExitCode=1;$result.Message='DISM CheckHealth failed or reported a non-repairable condition.';$result.RecommendedAction=$check.RecommendedAction;$result.Data.FinalRecommendedAction=$check.RecommendedAction;$result.Errors+=New-ErrorObject $Operation $result.Message $check.RecommendedAction;Complete-Script $result}

if($check.RecommendedAction -eq 'RunDismScanHealth'){
    Write-Log 'CheckHealth reported repairable corruption; running ScanHealth.'
    $scan=Invoke-ChildHealthScript (Join-Path $WorkingDirectory 'Invoke-DismScanHealth.ps1') (Join-Path $WorkingDirectory ('Invoke-DismScanHealth-result-{0}.json' -f $Timestamp)) 'DismScanHealth';$result.Data.Operations+=$scan
    if($scan.ExitCode -ne 0){$result.Status='Failed';$result.ExitCode=1;$result.Message='DISM ScanHealth failed or reported a non-repairable condition.';$result.RecommendedAction=$scan.RecommendedAction;$result.Data.FinalRecommendedAction=$scan.RecommendedAction;$result.Errors+=New-ErrorObject $Operation $result.Message $scan.RecommendedAction;Complete-Script $result}
    if($scan.RecommendedAction -eq 'RunDismRestoreHealth'){
        Write-Log 'ScanHealth confirmed repairable corruption; running RestoreHealth.'
        $restore=Invoke-ChildHealthScript (Join-Path $WorkingDirectory 'Invoke-DismRestoreHealth.ps1') (Join-Path $WorkingDirectory ('Invoke-DismRestoreHealth-result-{0}.json' -f $Timestamp)) 'DismRestoreHealth';$result.Data.Operations+=$restore
        if($restore.ExitCode -ne 0){$result.Status='Failed';$result.ExitCode=1;$result.Message='DISM RestoreHealth failed.';$result.RecommendedAction=$restore.RecommendedAction;$result.Data.FinalRecommendedAction=$restore.RecommendedAction;$result.Errors+=New-ErrorObject $Operation $result.Message $restore.RecommendedAction;Complete-Script $result}
    }else{Write-Log 'ScanHealth did not require RestoreHealth; skipping RestoreHealth.'}
}else{Write-Log 'CheckHealth found no component-store corruption; skipping ScanHealth and RestoreHealth.'}

Write-Log 'Running SFC final verification.'
$sfc=Invoke-ChildHealthScript (Join-Path $WorkingDirectory 'Invoke-SfcScan.ps1') (Join-Path $WorkingDirectory ('Invoke-SfcScan-result-{0}.json' -f $Timestamp)) 'SfcScan';$result.Data.Operations+=$sfc
foreach($operationResult in $result.Data.Operations){if($operationResult.Changed -eq $true){$result.Changed=$true}}
if($sfc.ExitCode -eq 0){$result.ExitCode=0;if($result.Changed){$result.Status='Changed';$result.Message='Windows image health workflow completed and changed system state.'}else{$result.Status='NoActionNeeded';$result.Message='Windows image health workflow completed with no repair action required.'};$result.RecommendedAction='None';$result.Data.FinalRecommendedAction='None'}
elseif($sfc.Status -eq 'PartialSuccess'){$result.Status='PartialSuccess';$result.ExitCode=4;$result.Message='Workflow completed but SFC reported unresolved corruption.';$result.RecommendedAction=$sfc.RecommendedAction;$result.Data.FinalRecommendedAction=$sfc.RecommendedAction;$result.Errors+=New-ErrorObject $Operation $result.Message $sfc.RecommendedAction}
else{$result.Status='Failed';$result.ExitCode=1;$result.Message='Workflow failed during SFC verification.';$result.RecommendedAction=$sfc.RecommendedAction;$result.Data.FinalRecommendedAction=$sfc.RecommendedAction;$result.Errors+=New-ErrorObject $Operation $result.Message $sfc.RecommendedAction}
Complete-Script $result
