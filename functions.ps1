function Invoke-LoggingMessage {
    param (
        [parameter(Mandatory=$true)]
        [String]$LogMessage
    )
    
    "$(Get-Date -UFormat " %d/%m/%Y %T") $LogMessage" | Out-File -Append -FilePath "$duo_installpath\usersync\sync-log.txt"

    if (((Get-Item "$duo_installpath\usersync\sync-log.txt" ).length/100MB) -gt 100) {
        Remove-Item "$duo_installpath\usersync\sync-log.txt"
        Write-Host "Cleared Logging File because it was bigger than 100mb"
        "$(Get-Date -UFormat " %d/%m/%Y %T") Cleared Logging File because it was bigger than 100mb" | Out-File -Append -FilePath "$duo_installpath\usersync\sync-log.txt" 
    }
}


function Invoke-ScriptInstall {
    param (
    )

    if ($Install -or (-Not (Test-Path -Path "$duo_installpath\usersync\variables.ps1"))) {
        
        #Get necessary data from User
        if (-Not (Test-Path -Path "$duo_installpath\usersync\variables.ps1" )) {
    
            [String]$hostname = Invoke-GetInput -Question "Please specify the hostname of the DUO Tenant like this: api-b7axxxxx.duosecurity.com" 
            Write-Host $hostname
            [SecureString]$admin_ikey = Invoke-GetInput -Question "Please specify the Integration Key of the DUO Admin API Application like this: I54SI6Cxxxxxx" -SecureString
            [SecureString]$admin_skey = Invoke-GetInput -Question "Please specify the Secret Key of the DUO Admin API Application like this: LlXNoz9d5gEjiBxxxxxxxxxxxxxxxx" -SecureString
            [SecureString]$directory_key = Invoke-GetInput -Question "Please specify the Directory KEY of the DUO Sync Identity Source like this: DS56O1PYXO1N3Ixxxxxxx" -SecureString
            [String]$username_format = Invoke-GetInput -Question "Please specify the primary username format which is used in DUO Directory Sync configuration (SamAccountName | userPrincipalName): " -Suggestion "userPrincipalName"
            Write-Host $username_format
            [String]$ad_group = Invoke-GetInput -Question "Please specify the Active Directory Group to be synced to DUO as Distinguished Name: "
            Write-Host $ad_group


            #Create Folder Structure       
            if (-Not (Test-Path -Path "$duo_installpath\usersync" )) {
                New-Item -Path "$duo_installpath\usersync" -ItemType Directory | Out-Null
                Start-Sleep -s 3 #Sleep to give command New Item time to create directory
                Copy-Item -Path "$(Get-Location)\*" -Destination "$duo_installpath\usersync\"
                
                #Create Encryption Key for secrets
                $Key = New-Object Byte[] 32   # You can use 16 (128-bit), 24 (192-bit), or 32 (256-bit) for AES
                [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                $Key | Out-File "$duo_installpath\usersync\keyfile.key"
            
                #Create .env file with all variables
                $variables = "`$duo_installpath=`"$duo_installpath`"`n"
                $variables += "`$hostname=`"$hostname`"`n"
                $variables += "`$admin_ikey=`"$(ConvertFrom-SecureString -SecureString $admin_ikey -Key $(Get-Content "$duo_installpath\usersync\keyfile.key"))`"`n"
                $variables += "`$admin_skey=`"$(ConvertFrom-SecureString -SecureString $admin_skey -Key $(Get-Content "$duo_installpath\usersync\keyfile.key"))`"`n"
                $variables += "`$directory_key=`"$(ConvertFrom-SecureString -SecureString $directory_key -Key $(Get-Content "$duo_installpath\usersync\keyfile.key"))`"`n"
                $variables += "`$ad_group=`"$ad_group`"`n"
                $variables += "`$username_format=`"$username_format`""
                $variables | Out-File -FilePath "$duo_installpath\usersync\variables.ps1"
                }
        }
        else {
            Write-Host "There is already a variable File declared in $duo_installpath\usersync\ please delete this file to re-install the Script or edit the file manually"
            Invoke-LoggingMessage -LogMessage "There is already a variable File declared in $duo_installpath\usersync\ please delete this file to re-install the Script or edit the file manually"

        }
    
    }    
}


function Invoke-DecryptString {
    #Convert encrypted string into secure string and convert it to plaintext afterwards
    param(
        [parameter(Mandatory=$true)]
        [String]$EncryptedString
    )
    $SecureString=ConvertTo-SecureString $EncryptedString -Key $(Get-Content "$duo_installpath\usersync\keyfile.key")
    $DecryptedString=[System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString))
    return $DecryptedString

}


function Invoke-GetInput {

    #Forces User to specify details unless a default value is suggested. If a defautl value is suggested, and no User input is provided, the default value is used.
    param (
        [parameter(Mandatory=$true)]
        [String]$Question,
        [String]$Suggestion,
        [Switch]$SecureString
    )
        $prompt=""
        while (-Not($prompt)) {
            if ($suggestion) {
                $prompt=Read-Host -Prompt "$Question, default value is [$Suggestion]"
                if (-Not($prompt)) {
                    return $Suggestion
                }
            }
            else {
                $prompt = Read-Host -Prompt $Question
            }
        }

        if ($SecureString) {
            
            $prompt = ConvertTo-SecureString $prompt -AsPlainText -Force
        }
        return $prompt
    }

    function Invoke-ResyncUsers {
        #In Case of multiple Groups which need to be synchronized to DUO, create a overlay (nested) group, add this DN to the Script and add the other groups as members
        param (
            [parameter(Mandatory=$true)]
            [string]$ADSyncGroupDN,
            [parameter(Mandatory=$true)]
            [string]$hostname,
            [parameter(Mandatory=$true)]
            [String]$admin_ikey,
            [parameter(Mandatory=$true)]
            [String]$admin_skey,
            [parameter(Mandatory=$true)]
            [String]$directory_key,
            [parameter(Mandatory=$true)]
            [String]$username_format
        )
        
        #Get All Account which are member of the MFA Group
        $all_ad_group_members=Get-ADGroupMember -Identity $ADSyncGroupDN -Recursive
        
        #Store all UPNs in List
        if ($username_format -eq "userPrincipalName") {
            #Get UPN instead from SAMAccountname and save it into the AD Object
            foreach ($user in $($all_ad_group_members)) {
                $user | Add-Member -MemberType NoteProperty -Name 'userPrincipalName' -Value "$(Get-AdUser $($user) | Select-Object -ExpandProperty "userPrincipalName")" -Force
            }
        }

        #Grab all Users in DUO Portal
        $req=Invoke-APICall -method 'GET' -hostname $hostname -path '/admin/v1/users' -params $(@{"limit"="100"}) -admin_ikey $admin_ikey -admin_skey $admin_skey

        #In Case there are more results than the limit paramater (default 100 - do pagination) - cant be done in the function because of parameter sining
        $all_duo_users=$($req)
        while (Get-Member -inputobject $($req.metadata) -name "next_offset" -Membertype Properties) {
            $req=Invoke-APICall -method 'GET' -hostname $hostname -path '/admin/v1/users' -admin_ikey $admin_ikey -admin_skey $admin_skey -params $(@{"limit"="100";"offset"=$($req.metadata.next_offset)})
            $all_duo_users.response+=$req.response
        }
        #Filter out Users which are pending for deletion in DUO Portal
        $all_duo_users.response=$($all_duo_users.response) | Where-Object {$_.status -ne "pending deletion"}
    
    
        Write-Host "ALL AD Group Members: $($all_ad_group_members.userPrincipalName)"
        Invoke-LoggingMessage -LogMessage "ALL AD Group Members: $($all_ad_group_members.userPrincipalName)"
        Write-Host "All Active Users in DUO Portal: $($all_duo_users.response.username)"
        Invoke-LoggingMessage -LogMessage "All Active Users in DUO Portal: $($all_duo_users.response.username)"
        

        #########################################################################################
        #Search for all Users which are in the local AD Group, but not in the userlist from duo #
        #########################################################################################

        foreach ($ad_user in $all_ad_group_members) {
            #For SamAccountName comparison
            if ($username_format -eq "SamAccountName") {
                if ($($all_duo_users.response.username) -NotContains ($ad_user.SamAccountName)) {
                    Write-Host "User: $($ad_user.SamAccountName) in AD Sync Group but not found in DUO, triggering Sync to add users to DUO now"
                    Invoke-LoggingMessage -LogMessage "User: $($ad_user.SamAccountName) in AD Sync Group but not found in DUO, triggering Sync to add user to DUO now"
                    Invoke-APICall -method 'POST' -hostname $hostname -path "/admin/v1/users/directorysync/$directory_key/syncuser" -params $(@{'username'=$($ad_user.SamAccountName)}) -admin_ikey $admin_ikey -admin_skey $admin_skey | Out-Null
                }
            }
    
            #For UPN comparison
            if ($username_format -eq "userPrincipalName") {
                if ($($all_duo_users.response.username) -NotContains ($ad_user.userPrincipalName)) {
                    Write-Host "User: $($ad_user.userPrincipalName) in AD Sync Group but not found in DUO, triggering Sync to add users to DUO now"
                    Invoke-LoggingMessage -LogMessage "User: $($ad_user.userPrincipalName) in AD Sync Group but not found in DUO, triggering Sync to add user to DUO now"
                    Invoke-APICall -method 'POST' -hostname $hostname -path "/admin/v1/users/directorysync/$directory_key/syncuser" -params $(@{'username'=$($ad_user.userPrincipalName)}) -admin_ikey $admin_ikey -admin_skey $admin_skey | Out-Null
                }
            }
        }
   
        #############################################################################################################################
        #Search for all Users which are in DUO but not in the local AD Group (for example, if they got removed from the sync group) #
        #############################################################################################################################


        foreach ($duo_user in $($all_duo_users.response.username)) {
            if ($username_format -eq "SamAccountName") {
                if ($($all_ad_group_members.SamAccountName) -NotContains ($duo_user)) {
                    Write-Host "User: $duo_user present in DUO but not found in AD Sync Group anymore, triggering Sync to remove user from DUO now"
                    Invoke-LoggingMessage -LogMessage "User: $duo_user present in DUO but not found in AD Sync Group anymore, triggering Sync to remove user from DUO now"
                    Invoke-APICall -method 'POST' -hostname $hostname -path "/admin/v1/users/directorysync/$directory_key/syncuser" -params $(@{'username'=$duo_user}) -admin_ikey $admin_ikey -admin_skey $admin_skey | Out-Null
                }
            }

            if ($username_format -eq "userPrincipalName") {

                if ($($all_ad_group_members.userPrincipalName) -NotContains ($duo_user)) {
                    Write-Host "User: $duo_user present in DUO but not found in AD Sync Group anymore, triggering Sync to remove user from DUO now"
                    Invoke-LoggingMessage -LogMessage "User: $duo_user present in DUO but not found in AD Sync Group anymore, triggering Sync to remove user from DUO now"
                    Invoke-APICall -method 'POST' -hostname $hostname -path "/admin/v1/users/directorysync/$directory_key/syncuser" -params @{'username'=$duo_user} -admin_ikey $admin_ikey -admin_skey $admin_skey | Out-Null
                }
            }
        }
    }


    function Invoke-APICall {
        param (
            [parameter(Mandatory=$true)]
            [String]$method,
            [parameter(Mandatory=$true)]
            [string]$hostname,
            [parameter(Mandatory=$true)]
            [String]$path,
            [parameter(Mandatory=$false)]
            [Hashtable]$params,
            [parameter(Mandatory=$true)]
            [String]$admin_ikey,
            [parameter(Mandatory=$true)]
            [String]$admin_skey
        )
        

        #Switch Culture / Language to english to get english names of months for Date
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US"; 
        #Creates a RFC2822 Timestamp for DUO (for example: Thu, 27 Jan 2022 10:24:51 +01) 
        [String]$date=Get-Date -UFormat "%a, %d %b %Y %T %Z00";
    
        #If parameters are supplied (mandatory as hashtable) is supplied, sort it and concat it to string for signing
        if ($params -is [Hashtable]) {
    
            #DUO requires parametes sorted/signed alphabetically - so sort the hashtable of parameters
            $params_sorted=$params.GetEnumerator() | Sort-Object Value
            
            #Concat all paramaters into one long string, 
    
            foreach ($param in $params_sorted) {
                $concated_params += "$($param.Name)=$($param.Value)&"
            }
    
            #Replace @ sign with URL Encoding for @ in UPN - DUO needs this.
            $concated_params=$concated_params.Replace('@','%40')
            #Remove the last '&' character from parameters
            $concated_params=$concated_params.Substring(0,$concated_params.Length-1)
        }
        
        #If no paramaters are supplied, just create the concat variable with empty string
        else {
            $concated_params=""
    
        }
    
        $headers = @{
            "X-Duo-Date" = "$date"
            "Authorization" = "Basic $(Invoke-GetSignature -method $method -hostname $hostname -path $path -params $concated_params -admin_skey $admin_skey -admin_ikey $admin_ikey -date $date)"
            "Content-Type" = "application/x-www-form-urlencoded"
        }
        
    
        if ($method -eq 'GET') {

            $req=Invoke-RestMethod -Method $method -Headers $headers -Uri "https://$hostname$path`?$concated_params" 
            return $req
        }
        
        if ($method -eq 'POST') {

            $req=Invoke-RestMethod -Method $method -Headers $headers -Uri "https://$hostname$path`?$concated_params" 
            return $req
        }
    }

function Invoke-GetSignature {
    param (
        [parameter(Mandatory=$true)]
        [String]$method,
        [parameter(Mandatory=$true)]
        [string]$hostname,
        [parameter(Mandatory=$true)]
        [String]$path,
        [parameter(Mandatory=$false)]
        [String]$params,
        [parameter(Mandatory=$true)]
        [String]$admin_skey,
        [parameter(Mandatory=$true)]
        [String]$admin_ikey,
        [parameter(Mandatory=$true)]
        [String]$date
    )

    $concatpayload="$date`n$method`n$hostname`n$path`n$params"
    #Write-Host "Concated Payload: $concatpayload"
    $hmacsha = New-Object System.Security.Cryptography.HMACSHA1
    $hmacsha.key = [Text.Encoding]::ASCII.GetBytes($admin_skey)
    $signature = $hmacsha.ComputeHash([Text.Encoding]::ASCII.GetBytes($concatpayload))
   
    #Convert Signature from Bytes to Hexadecimal
    $signature=[System.BitConverter]::ToString($signature)
    #Filter out dashes of HEX Representation
    $signature=($signature -replace '[-]').ToLower()
    #Write-Host $signature

    #Create Basic Auth Payload with ikey & skey and convert to base64
    $basicauth="$admin_ikey`:$signature"
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($basicauth)
    $basicauth =[Convert]::ToBase64String($Bytes)

    #Write-Host $basicauth
    return $basicauth
}



function Invoke-ScheduledTask {  
    param(
        [parameter(Mandatory=$true)]
        [String]$TaskName,
        [parameter(Mandatory=$true)]
        [String]$ScriptPath,
        [parameter(Mandatory=$true)]
        [String]$WorkDir,
        [parameter(Mandatory=$true)]
        [String]$Arguments,
        [parameter(Mandatory=$true)]
        [Int]$Interval        
    )

    $taskExists = Get-ScheduledTask | Where-Object {$_.TaskName -like $TaskName }

    if ($taskExists) {
        Write-Host "A Scheduled Task named `"$TaskName`" already exists"
    }
    else {

        $action=New-ScheduledTaskAction `
        -WorkingDirectory $WorkDir `
        -Execute 'powershell.exe' `
        -Argument "-File $ScriptPath $Arguments"
    
        $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $Interval) `
        -RepetitionDuration (New-TimeSpan -Days (365 * 20))

        #Run as NT/SYSTEM to be able to run without User Logon / cached creds
        $principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\System" -RunLevel Highest -LogonType ServiceAccount

        Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName $TaskName -Description "Scheduled Task for DUO Usersync" 
        
        Write-Host "New Scheduled Task named `"$TaskName`" created"
        Invoke-LoggingMessage -LogMessage "New Scheduled Task named `"$TaskName`" created"

    }
}