# ------------------ PREREQUISITES ------------------
# Modules required:
#   Install-Module MSOnline -Scope CurrentUser
#   Install-Module AzureAD -Scope CurrentUser
#   Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser

Import-Module MSOnline
Import-Module AzureAD
Import-Module Microsoft.Graph.DeviceManagement

# ------------------ CONFIGURATION ------------------
$DomainName         = "yourdomain.com"
$EmailSender        = "itadmin@$DomainName"
$SMTPServer         = "smtp.office365.com"
$RecipientAdmins    = "support@$DomainName"  # comma-separated list

# ------------------ AUTHENTICATION ------------------
Write-Host "`n🔐 Signing in..."
$Cred = Get-Credential
Connect-MsolService -Credential $Cred
Connect-AzureAD -Credential $Cred
Connect-MgDeviceManagement -Credential $Cred

# ------------------ INPUT USER ------------------
$UPN = Read-Host "Enter UPN of user to offboard"
$UserObj = Get-AzureADUser -ObjectId $UPN

if (-not $UserObj) {
    Write-Host "❌ User not found in Azure AD"
    exit
}

Write-Host "`n⚠️ Please confirm offboarding for:"
Write-Host "Display Name : $($UserObj.DisplayName)"
Write-Host "UPN          : $UPN"
$ConfirmUser = Read-Host "Proceed with offboarding this user? (y/n)"
if ($ConfirmUser -ne "y") {
    Write-Host "⏹️ Offboarding cancelled."
    exit
}

# ------------------ DEVICE REVIEW ------------------
$Devices = Get-MgDeviceManagementManagedDevice | Where-Object { $_.UserPrincipalName -eq $UPN }
$RecoveryInfo = @()

if ($Devices.Count -gt 0) {
    Write-Host "`n📋 Devices registered to this user:"
    $i = 1
    foreach ($Device in $Devices) {
        Write-Host "$i. $($Device.DeviceName) ($($Device.OperatingSystem)) - $($Device.Manufacturer)"
        $i++
    }

    $ConfirmDevices = Read-Host "Proceed with retrieving BitLocker keys and wiping these devices? (y/n)"
    if ($ConfirmDevices -ne "y") {
        Write-Host "⏹️ Device actions skipped."
        $Devices = @()
    }
} else {
    Write-Host "`nℹ️ No Intune devices found for this user."
}

# ------------------ OFFBOARDING ACTIONS ------------------
$TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Disable Azure AD account
Set-AzureADUser -ObjectId $UPN -AccountEnabled $false
Write-Host "✅ User account disabled"

# Revoke Microsoft 365 licenses
$Licenses = Get-MsolUser -UserPrincipalName $UPN | Select-Object -ExpandProperty Licenses
Set-MsolUserLicense -UserPrincipalName $UPN -RemoveLicenses $Licenses.AccountSkuId
Write-Host "✅ Licenses revoked"

# Remove group memberships
$Groups = Get-AzureADUserMembership -ObjectId $UPN
foreach ($Group in $Groups) {
    Remove-AzureADGroupMember -ObjectId $Group.ObjectId -MemberId $UPN
}
Write-Host "✅ Group memberships removed"

# Optional mailbox conversion
$ConvertMailbox = Read-Host "Convert mailbox to shared? (y/n)"
if ($ConvertMailbox -eq "y") {
    try {
        Set-Mailbox -Identity $UPN -Type Shared
        Write-Host "✅ Mailbox converted to shared"
    } catch {
        Write-Host "⚠️ Failed to convert mailbox. Mailbox may not exist or require Exchange module."
    }
}

# Device BitLocker key retrieval and wipe
foreach ($Device in $Devices) {
    try {
        $Bitlocker = Get-MgDeviceManagementManagedDeviceRecoveryKey -ManagedDeviceId $Device.Id
        $Key = $Bitlocker.RecoveryKey
        $RecoveryInfo += "<li><strong>$($Device.DeviceName)</strong>: $Key</li>"
        Write-Host "🔑 Retrieved BitLocker key for $($Device.DeviceName)"
    } catch {
        Write-Host "⚠️ Could not retrieve BitLocker key for $($Device.DeviceName)"
    }

    try {
        Invoke-MgDeviceManagementManagedDeviceWipe -ManagedDeviceId $Device.Id
        Write-Host "✅ Wipe triggered for $($Device.DeviceName)"
    } catch {
        Write-Host "⚠️ Failed to wipe $($Device.DeviceName)"
    }
}

# ------------------ EMAIL NOTIFICATION ------------------
$EmailBody = @"
<h2>📤 Offboarding Summary</h2>
<ul>
  <li><strong>User:</strong> $UPN</li>
  <li><strong>Time:</strong> $TimeStamp</li>
  <li><strong>Mailbox Shared:</strong> $ConvertMailbox</li>
  <li><strong>Devices Wiped:</strong> $($Devices.Count)</li>
</ul>
<h3>🔐 BitLocker Recovery Keys:</h3>
<ul>
  $($RecoveryInfo -join "`n")
</ul>
<hr />
<p><strong>📝 IT Admin Note:</strong></p>
<ul>
  <li>🧳 Please arrange collection of all assigned equipment</li>
  <li>🔍 Inspect devices for physical damage or missing components</li>
  <li>🔓 Remove BitLocker encryption manually using recovery keys if applicable</li>
</ul>
"@

Send-MailMessage -To $RecipientAdmins `
                 -From $EmailSender `
                 -Subject "🧍 User Offboarding Complete: $UPN" `
                 -Body $EmailBody `
                 -BodyAsHtml `
                 -SmtpServer $SMTPServer `
                 -Port 587 `
                 -UseSsl `
                 -Credential $Cred

Write-Host "`n📧 Summary email sent to IT team."
