# ------------------ PREREQUISITES ------------------
# This script requires the following modules:
#   - MSOnline: For license assignment in Microsoft 365
#   - AzureAD: For user creation and group membership in Entra ID (Azure AD)
# To install, run these once:
#   Install-Module MSOnline -Scope CurrentUser
#   Install-Module AzureAD -Scope CurrentUser

# ------------------ MODULE IMPORT ------------------
Import-Module MSOnline
Import-Module AzureAD

# ------------------ CONFIGURATION ------------------
$PrimaryAdmins        = "admin1@yourdomain.com","admin2@yourdomain.com"
$DomainName           = "yourdomain.com"
$EmailSender          = "itadmin@$DomainName"      # Must be a valid mailbox
$SMTPServer           = "smtp.office365.com"
$DefaultGroupName     = "AllStaff"                # Name of default Entra ID group
$UnlicensedGroupName  = "Unlicensed"              # Name of fallback group

# Map license SKUs to friendly names
$LicenseLabels = @{
    "BUSINESS_PREMIUM"     = "Microsoft 365 Business Premium"
    "BUSINESS_STANDARD"    = "Microsoft 365 Business Standard"
    "ENTERPRISEPACK"       = "Microsoft 365 Enterprise E3"
}

# ------------------ UTILITY FUNCTIONS ------------------
function Generate-RandomPassword {
    $length = 12
    $chars  = @()
    $chars += [char[]](65..90)        # Uppercase letters
    $chars += [char[]](97..122)       # Lowercase letters
    $chars += [char[]](48..57)        # Digits
    $chars += "!@#$%^&*()-_=+[]{}<>"  # Symbols
    -join (1..$length | ForEach-Object { $chars | Get-Random })
}

function Get-AzureADGroupId($GroupName) {
    $Group = Get-AzureADGroup -Filter "DisplayName eq '$GroupName'"
    return $Group.ObjectId
}

# ------------------ SIGN-IN ------------------
Write-Host "`n🔐 Signing in to Microsoft 365 and Azure AD..."
$M365Cred = Get-Credential
Connect-MsolService -Credential $M365Cred
Connect-AzureAD     -Credential $M365Cred

# ------------------ USER PROVISIONING LOOP ------------------
do {
    Write-Host "`n🆕 Start provisioning a new user..."

    # -- Collect user details --
    $FirstName = Read-Host "First Name"
    $LastName  = Read-Host "Last Name"
    $Username  = ("$FirstName.$LastName").ToLower()
    $UPN       = "$Username@$DomainName"
    $Password  = Generate-RandomPassword
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $GroupsAssigned = @()
    $LicenseStatus  = ""

    # -- Create Azure AD user --
    $User = New-AzureADUser -DisplayName "$FirstName $LastName" `
        -UserPrincipalName $UPN `
        -MailNickname $Username `
        -AccountEnabled $true `
        -PasswordProfile @{ Password = $Password; ForceChangePasswordNextLogin = $true } `
        -GivenName $FirstName `
        -Surname $LastName

    Write-Host "✅ Created user: $UPN"
    Write-Host "🔑 Assigned password: $Password"

    # -- Add to default group --
    $AllStaffId = Get-AzureADGroupId $DefaultGroupName
    Add-AzureADGroupMember -ObjectId $AllStaffId -RefObjectId $User.ObjectId
    $GroupsAssigned += $DefaultGroupName
    Write-Host "✅ Added to group: $DefaultGroupName"

    # -- License assignment --
    $AssignBP = Read-Host "Assign Business Premium license? (y/n)"
    if ($AssignBP -eq "y") {
        $LicenseSku = "BUSINESS_PREMIUM"
    } else {
        Write-Host "`n📋 Available license SKUs:"
        foreach ($Key in $LicenseLabels.Keys) {
            Write-Host "- $LicenseLabels[$Key] (`$Key`)"
        }
        $LicenseSku = Read-Host "Enter alternate SKU or press Enter to skip"
    }

    if (![string]::IsNullOrWhiteSpace($LicenseSku)) {
        $Sku = Get-MsolAccountSku | Where-Object { $_.AccountSkuId -match $LicenseSku -and $_.ActiveUnits -gt $_.ConsumedUnits }
        if ($Sku) {
            Set-MsolUserLicense -UserPrincipalName $UPN -AddLicenses $Sku.AccountSkuId
            $LicenseStatus = "Licensed: $($LicenseLabels[$LicenseSku])"
            Write-Host "✅ Assigned license: $LicenseLabels[$LicenseSku]"
        } else {
            $UnlicensedId = Get-AzureADGroupId $UnlicensedGroupName
            Add-AzureADGroupMember -ObjectId $UnlicensedId -RefObjectId $User.ObjectId
            $GroupsAssigned += $UnlicensedGroupName
            $LicenseStatus = "Unlicensed"
            Write-Host "🚫 License unavailable. Added to '$UnlicensedGroupName'"
        }
    } else {
        $UnlicensedId = Get-AzureADGroupId $UnlicensedGroupName
        Add-AzureADGroupMember -ObjectId $UnlicensedId -RefObjectId $User.ObjectId
        $GroupsAssigned += $UnlicensedGroupName
        $LicenseStatus = "Unlicensed"
        Write-Host "🚫 License skipped. Added to '$UnlicensedGroupName'"
    }

    # -- Send admin email --
    $EmailBody = @"
<h2>🧍 New Azure User Provisioned</h2>
<ul>
  <li><strong>Name:</strong> $FirstName $LastName</li>
  <li><strong>Username:</strong> $Username</li>
  <li><strong>UPN:</strong> $UPN</li>
  <li><strong>Password:</strong> $Password</li>
  <li><strong>Groups:</strong> $($GroupsAssigned -join ", ")</li>
  <li><strong>License:</strong> $LicenseStatus</li>
  <li><strong>Created:</strong> $TimeStamp</li>
</ul>
"@

    Send-MailMessage -To $PrimaryAdmins `
                     -From $EmailSender `
                     -Subject "🆕 Azure User Provisioned: $Username" `
                     -Body $EmailBody `
                     -BodyAsHtml `
                     -SmtpServer $SMTPServer `
                     -Port 587 `
                     -UseSsl `
                     -Credential $M365Cred

    Write-Host "`n📧 Email sent with user details."

    # -- Output summary --
    Write-Host "`n🗂️ Summary:"
    Write-Host "Name      : $FirstName $LastName"
    Write-Host "Username  : $Username"
    Write-Host "UPN       : $UPN"
    Write-Host "Password  : $Password"
    Write-Host "Groups    : $($GroupsAssigned -join ", ")"
    Write-Host "License   : $LicenseStatus"
    Write-Host "Created   : $TimeStamp"

    $Another = Read-Host "`nProvision another user? (y/n)"
}
while ($Another -eq "y")
