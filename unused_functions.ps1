function Invoke-NoCertValidation {
    
    #Disable Certificate Validation of remote Servers to allow BURP Proxy HTTP/S interception
    #NEVER activate in production. 

    add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
        }
    }
"@

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
Write-Host "Disabled Certificate Validation"
}