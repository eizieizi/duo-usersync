param(
    [Switch]$Install,
    [Switch]$AutoSync,
    [Switch]$ManualSync
)

#Source Functions
. .\functions.ps1

#DUO Path is hardcoded in the installer of DUO Auth Proxy, so it makes no sense to make this customizable through the user
$duo_installpath="C:\Program Files\Duo Security Authentication Proxy"


if($PSBoundParameters.Values.Count -eq 0) {
    Write-Host "Please run Script with arguments"
}

if ($Install) {

    #Install AD-DS Module if not already there
    if (-Not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Host "ActiveDirectory RSAT Module does not exist, installing.."
        #For Clients
        #Add-WindowsCapability -online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" 
        #For Servers
        Install-WindowsFeature -Name "RSAT-AD-PowerShell" -IncludeAllSubFeature
    }

    Invoke-ScriptInstall
    #Install Scheduled Task
    [Int]$interval = Invoke-GetInput -Question "Please specify the Interval in which the local Group should be synced with DUO in minutes: " -Suggestion "15"
    Invoke-ScheduledTask -ScriptPath "`"$duo_installpath\usersync\sync.ps1`"" -Arguments "-AutoSync" -Interval $interval -WorkDir "$duo_installpath\usersync\" -TaskName "DUO Usersync Script"
}

if ($AutoSync -or $ManualSync) {

    if (Test-Path -Path "$duo_installpath\usersync\variables.ps1") {
        #Source Variables with encrypted Authentiction Details
        . "$duo_installpath\usersync\variables.ps1"

        #Decrypt encrypted fields
        $admin_ikey=Invoke-DecryptString -EncryptedString $admin_ikey
        $admin_skey=Invoke-DecryptString -EncryptedString $admin_skey
        $directory_key=Invoke-DecryptString -EncryptedString $directory_key


        if ($AutoSync) {
            Invoke-LoggingMessage -LogMessage "Auto Sync was triggered, starting User Sync Process"
            Invoke-LoggingMessage -LogMessage "Current User Format for DUO is $username_format - Logging entries will always show Users as UserPrincipalName regardless of the specified DUO format"
            Invoke-ResyncUsers -hostname $hostname -admin_ikey $admin_ikey -admin_skey $admin_skey -ADSyncGroupDN $ad_group -directory_key $directory_key -username_format $username_format
        }

        if ($ManualSync) {
            Write-Host "Manual Run was triggered, starting User Sync Process"
            Invoke-LoggingMessage -LogMessage "Manual Sync was triggered, starting User Sync Process"
            Invoke-LoggingMessage -LogMessage "Current User Format for DUO is $username_format - Logging entries will always show Users as UserPrincipalName regardless of the specified DUO format"
            Invoke-ResyncUsers -hostname $hostname -admin_ikey $admin_ikey -admin_skey $admin_skey -ADSyncGroupDN $ad_group -directory_key $directory_key -username_format $username_format
        }    
        
        #Line Break to separate Logging Entries per script run
        Invoke-LoggingMessage -LogMessage "Finished execution of Script `n"
    }
    else {
        Write-Host "No variable file found in $duo_installpath\usersync\variables.ps1 `n Please run Script again with -install parameter"
        }
}