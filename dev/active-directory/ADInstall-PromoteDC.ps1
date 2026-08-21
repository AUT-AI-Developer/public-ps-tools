#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DomainAdminUser
)

$ErrorActionPreference = 'Stop'
$LogPath = 'C:\ADDSInstall.log'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $Entry = "[$Timestamp] $Message"
    Write-Host $Entry
    Add-Content -Path $LogPath -Value $Entry
}

try {
    Write-Log "Starting additional domain controller deployment for domain '$DomainName'."

    # Do not attempt to promote a server that is already a domain controller.
    $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($ComputerSystem.DomainRole -ge 4) {
        throw "This server is already a domain controller (DomainRole=$($ComputerSystem.DomainRole))."
    }

    # A new DC must be able to locate the existing domain through DNS.
    # Point the server's NIC DNS at an existing AD DNS/DC before running this script.
    $SrvRecord = "_ldap._tcp.dc._msdcs.$DomainName"
    Write-Log "Checking AD DNS discovery using '$SrvRecord'."

    try {
        $DiscoveredDCs = Resolve-DnsName -Name $SrvRecord -Type SRV -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -eq 'SRV' }
    }
    catch {
        throw "Unable to locate an existing domain controller for '$DomainName' through DNS. Configure this server's preferred DNS server to point to an existing AD DNS/domain controller, then retry. Original error: $($_.Exception.Message)"
    }

    if (-not $DiscoveredDCs) {
        throw "DNS lookup succeeded but returned no domain controller SRV records for '$DomainName'."
    }

    $DcNames = ($DiscoveredDCs.NameTarget | Sort-Object -Unique) -join ', '
    Write-Log "Discovered domain controller(s): $DcNames"

    # Install AD DS, DNS, GPMC, and their management tools.
    Write-Log 'Installing AD DS, DNS, GPMC, and management tools.'

    $Features = @(
        'AD-Domain-Services',
        'DNS',
        'GPMC'
    )

    $FeatureInstallParams = @{
        Name                   = $Features
        IncludeAllSubFeature   = $true
        IncludeManagementTools = $true
        ErrorAction            = 'Stop'
    }

    $FeatureResult = Install-WindowsFeature @FeatureInstallParams

    $FeatureResult | Format-List * | Out-File -FilePath $LogPath -Append

    if (-not $FeatureResult.Success) {
        throw 'One or more required Windows features failed to install. Review C:\ADDSInstall.log.'
    }

    Write-Log 'Required Windows features are installed.'

    Import-Module ADDSDeployment -ErrorAction Stop

    # Allow either DOMAIN\user, user@domain, or a simple username.
    # A simple username is converted to username@domain.
    if ($DomainAdminUser -match '[@\\]') {
        $CredentialUser = $DomainAdminUser
    }
    else {
        $CredentialUser = "$DomainAdminUser@$DomainName"
    }

    Write-Host ''
    Write-Host "Enter the domain password for: $CredentialUser"
    $DomainAdminPassword = Read-Host -Prompt 'Domain admin password' -AsSecureString
    $DomainCredential = [System.Management.Automation.PSCredential]::new(
        $CredentialUser,
        $DomainAdminPassword
    )

    Write-Host ''
    Write-Host 'The AD DS promotion wizard will also prompt you to enter and confirm a Directory Services Restore Mode (DSRM) password.'
    Write-Host 'The server will reboot automatically after a successful promotion.'
    Write-Host ''

    Write-Log "Beginning promotion of '$env:COMPUTERNAME' as an additional writable DC in '$DomainName'."

    # SafeModeAdministratorPassword is intentionally omitted so that
    # Install-ADDSDomainController securely prompts for and confirms the DSRM password.
    $PromotionParams = @{
        DomainName  = $DomainName
        Credential  = $DomainCredential
        InstallDns  = $true
        Force       = $true
        ErrorAction = 'Stop'
    }

    Install-ADDSDomainController @PromotionParams
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Error $_
    exit 1
}
