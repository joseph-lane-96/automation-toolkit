# =================== 📦 MODULE IMPORT ===================
Import# ------------------ MODULE IMPORTS ------------------
Import-Module ActiveDirectory
Import-Module MSOnline

# ------------------ CONFIGURATION ------------------
$AllStaffGroup     = "AllStaff"
$UnlicensedGroup   = "Unlicensed"
$PrimaryAdmins     = "admin1@yourdomain.com","admin2@yourdomain.com"
$DomainName        = "yourdomain.com"
$OU                = "OU=Users,DC=yourdomain,DC=com"
$SMTPServer        = "smtp.yourdomain.com"
$EmailFrom         = "noreply@$DomainName"

# License SKU to friendly name mapping
$LicenseLabels = @{
    "BUSINESS_PREMIUM"     = "Microsoft 365 Business Premium"
    "BUSINESS_STANDARD"    = "Microsoft 365 Business Standard"
    "ENTERPRISEPACK"       = "Microsoft 365 Enterprise E3"
    "MICROSOFT365_APPS"    = "Microsoft 365 Apps for Business"
    "VISIO_PLAN2"          = "Visio Plan 2"
}

# ------------------ UTILITY FUNCTIONS ------------------
# Generates a secure random password for new users
function Generate-RandomPassword {
    $length = 12
    $chars  = @()
    $chars += [char[]](65..90)        # Uppercase letters
    $chars += [char[]](97..122)       # Lowercase letters
    $chars += [char[]](48..57)        # Numbers
    $chars += "!@#$%^&*()-_=+[]{}<>"  # Symbols
    -join (1..$length | ForEach-Object { $chars | Get-Random })
}

# ------------------ AUTHENTICATION ------------------
Write-Host "`n🔐 Sign in with your Microsoft 365 admin account..."
$M365Cred = Get-Credential
Connect-MsolService -Credential $M365Cred

Write-Host "`n🔐 Sign in with your Active Directory admin account..."
$ADCred = Get-Credential

# ------------------ PROVISIONING LOOP ------------------
do {
    Write-Host "`n🆕 Start provisioning a new user..."

    # -- Input user details --
    $FirstName = Read-Host "Enter First Name"
    $LastName  = Read-Host "Enter Last Name"
    $Username  = ("$FirstName.$LastName").ToLower()
    $Password  = Generate-RandomPassword
    $UPN       = "$Username@$DomainName"
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $GroupsAssigned = "$AllStaffGroup"
    $LicenseStatus = ""

    # -- Create user in Active Directory --
    New-ADUser -Name "$FirstName $LastName" `
               -GivenName $FirstName `
               -Surname $LastName `
               -SamAccountName $Username `
               -UserPrincipalName $UPN `
               -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -Force) `
               -Path $OU `
               -Enabled $true `
               -Credential $ADCred

    Write-Host "✅ AD user '$Username' created."
    Write-Host "🔑 Assigned password: $Password"

    # -- Add to AllStaff group --
    Add-ADGroupMember -Identity $AllStaffGroup -Members $Username -Credential $ADCred
    Write-Host "✅ User added to group '$AllStaffGroup'"

    # -- License assignment decision --
    $AssignBP = Read-Host "Assign Business Premium license? (y/n)"
    if ($AssignBP -eq "y") {
        $LicenseSku = "BUSINESS_PREMIUM"
    } else {
        Write-Host "`n📋 Available alternate licenses:"
        foreach ($Key in $LicenseLabels.Keys) {
            Write-Host "- $LicenseLabels[$Key] (`$Key`)"
        }
        $LicenseSku = Read-Host "Enter alternate SKU or press Enter to skip"
    }

    # -- Assign license if provided --
    if (![string]::IsNullOrWhiteSpace($LicenseSku)) {
        $LicenseDisplayName = $LicenseLabels[$LicenseSku]
        $TargetLicenseSku = Get-MsolAccountSku | Where-Object {
            $_.AccountSkuId -match $LicenseSku -and $_.ActiveUnits -gt $_.ConsumedUnits
        }

        if ($TargetLicenseSku) {
            try {
                Set-MsolUserLicense -UserPrincipalName $UPN -AddLicenses $TargetLicenseSku.AccountSkuId
                Write-Host "✅ License '$LicenseDisplayName' assigned."
                $LicenseStatus = "Licensed: $LicenseDisplayName"
            } catch {
                Write-Host "❌ License assignment failed. User added to '$UnlicensedGroup'"
                Add-ADGroupMember -Identity $UnlicensedGroup -Members $Username -Credential $ADCred
                $GroupsAssigned += ",$UnlicensedGroup"
                $LicenseStatus = "License Error"
            }
        } else {
            Write-Host "🚫 No licenses available for '$LicenseDisplayName'."
            Add-ADGroupMember -Identity $UnlicensedGroup -Members $Username -Credential $ADCred
            $GroupsAssigned += ",$UnlicensedGroup"
            $LicenseStatus = "Unlicensed"
        }
    } else {
        Write-Host "🚫 License assignment skipped. User added to '$UnlicensedGroup'"
        Add-ADGroupMember -Identity $UnlicensedGroup -Members $Username -Credential $ADCred
        $GroupsAssigned += ",$UnlicensedGroup"
        $LicenseStatus = "Unlicensed"
    }

    # ------------------ EMAIL NOTIFICATION ------------------
    $EmailBody = @"
<h2>🧍 New User Provisioned</h2>
<ul>
  <li><strong>Name:</strong> $FirstName $LastName</li>
  <li><strong>Username:</strong> $Username</li>
  <li><strong>UPN:</strong> $UPN</li>
  <li><strong>Password:</strong> $Password</li>
  <li><strong>Groups:</strong> $GroupsAssigned</li>
  <li><strong>License:</strong> $LicenseStatus</li>
  <li><strong>Created:</strong> $TimeStamp</li>
</ul>
"@

    Send-MailMessage -To $PrimaryAdmins `
                     -From $EmailFrom `
                     -Subject "🆕 User Provisioned: $Username" `
                     -Body $EmailBody `
                     -BodyAsHtml `
                     -SmtpServer $SMTPServer

    Write-Host "`n📧 Email sent to primary admins with full user details."

    # ------------------ SUMMARY OUTPUT ------------------
    Write-Host "`n🗂️ Summary:"
    Write-Host "Name      : $FirstName $LastName"
    Write-Host "Username  : $Username"
    Write-Host "UPN       : $UPN"
    Write-Host "Password  : $Password"
    Write-Host "Groups    : $GroupsAssigned"
    Write-Host "License   : $LicenseStatus"
    Write-Host "Created   : $TimeStamp"

    # ------------------ LOOP AGAIN? ------------------
    $Another = Read-Host "`nWould you like to provision another user? (y/n)"
}
while ($Another -eq "y")
