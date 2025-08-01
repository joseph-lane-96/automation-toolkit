# Import the Active Directory module
Import-Module ActiveDirectory

# Configuration
$userSamAccountName = "username"                         # SAM Account Name
$newPassword = "NewP@ssword123"                          # New password if resetting
$domainController = "yourDC.domain.local"                # Your AD server
$forceChangeAtLogon = $true                              # Toggle: $true or $false
$userEmail = "user@example.com"                          # User's email
$adminEmail = "admin@example.com"                        # Admin's email
$smtpServer = "smtp.domain.local"                        # SMTP server

# Convert password to secure string
$securePassword = ConvertTo-SecureString $newPassword -AsPlainText -Force

try {
    # Reset password or force change
    if ($forceChangeAtLogon) {
        Set-ADAccountPassword -Identity $userSamAccountName -NewPassword $securePassword -Reset -Server $domainController
        Set-ADUser -Identity $userSamAccountName -ChangePasswordAtLogon $true -Server $domainController
    } else {
        Set-ADAccountPassword -Identity $userSamAccountName -NewPassword $securePassword -Reset -Server $domainController
        Set-ADUser -Identity $userSamAccountName -ChangePasswordAtLogon $false -Server $domainController
    }

    Write-Host "✅ Password reset for $userSamAccountName" # Icons for quick skimming

    # Send email notifications
    $subject = "Your Active Directory password has been reset"
    $body = "Hi, your password for account '$userSamAccountName' has been successfully reset. Please follow your IT instructions to log in securely."

    Send-MailMessage -To $userEmail -From $adminEmail -Subject $subject -Body $body -SmtpServer $smtpServer
    Send-MailMessage -To $adminEmail -From $adminEmail -Subject "Password Reset Completed" -Body "Password for user '$userSamAccountName' was reset." -SmtpServer $smtpServer
}
catch {
    Write-Error "❌ Error resetting password: $($_.Exception.Message)"
}
