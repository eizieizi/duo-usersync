#Source Functions
. .\functions.ps1
#. .\sync.ps1
$duo_installpath="C:\Program Files\Duo Security Authentication Proxy"
. "$duo_installpath\usersync\variables.ps1"

#Decrypt encrypted fields
$admin_ikey=Invoke-DecryptString -EncryptedString $admin_ikey
$admin_skey=Invoke-DecryptString -EncryptedString $admin_skey
$directory_key=Invoke-DecryptString -EncryptedString $directory_key



#Finished PAGING CODE
$response=Invoke-APICall -method 'GET' -hostname $hostname -path '/admin/v1/users' -admin_ikey $admin_ikey -admin_skey $admin_skey -params $(@{"limit"="2"})
$sum_objects=$($response)

#Paging, as long as the next offset propertie is sent from the API, do further requests with the offset value from the last request
while (Get-Member -inputobject $($response.metadata) -name "next_offset" -Membertype Properties) {
    $response=Invoke-APICall -method 'GET' -hostname $hostname -path '/admin/v1/users' -admin_ikey $admin_ikey -admin_skey $admin_skey -params $(@{"limit"="2";"offset"=$($response.metadata.next_offset)})
    $response.response+=$response.response
    $sum_objects.response+=$response.response
}

Write-Host "Response Objekt: $($response.response.username)"
Write-Host "Sum Objekt: $($sum_objects.response.username)"