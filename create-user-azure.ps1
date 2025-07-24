# ------------------ PREREQUISITES ------------------
# Required modules:
#   - Microsoft Graph SDK:      Install-Module Microsoft.Graph -Scope CurrentUser -Force
#   - Exchange Online Mgmt:     Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
#
# Required permissions:
#   - Microsoft Graph: Directory.ReadWrite.All, User.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All
#   - Exchange Online: Mailbox access via admin role

# ------------------ MODULE IMPORT ------------------
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Groups
Import-Module Microsoft.Graph.Identity.DirectoryManagement
Import-Module ExchangeOnlineManagement

# ------------------ CONFIGURATION ------------------
$PrimaryAdmins        = "admin1@yourdomain.com","admin2@yourdomain.com"
$DomainName           = "yourdomain.com"
$EmailSender          = "itadmin@$DomainName"
$SMTPServer           = "smtp.office365.com"
$DefaultGroupName     = "AllStaff"
$UnlicensedGroupName  = "Unlicensed"
$UserTimeZone         = "GMT Standard Time"

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
    $chars += [char[]](65..90)
    $chars += [char[]](97..122)
    $chars += [char[]](48..57)
    $chars += "!@#$%^&*()-_=+[]{}<>"
    -join (1..$length | ForEach-Object { $chars | Get-Random })
}

function Get-GroupIdByName($DisplayName) {
    $group = Get-MgGroup -Filter "displayName eq '$DisplayName'"
    if (-not $group) { throw "❌ Group '$DisplayName' not found." }
    return $group.Id
}

# ------------------ SIGN-IN ------------------
Write-Host "`n🔐 Signing in to Microsoft Graph..."
Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "Directory.ReadWrite.All", "Organization.Read.All"

# ------------------ USER PROVISIONING LOOP ------------------
do {
    Write-Host "`n🆕 Start provisioning a new user..."

    # -- Collect user input --
    $FirstName = Read-Host "First Name"
    $LastName  = Read-Host "Last Name"
    $JobTitle  = Read-Host "Job Title"
    $Username  = ("$FirstName.$LastName").ToLower()
    $UPN       = "$Username@$DomainName"
    $Password  = Generate-RandomPassword
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $GroupsAssigned = @()
    $LicenseStatus  = ""

    # -- Check for existing user --
    $ExistingUser = Get-MgUser -Filter "userPrincipalName eq '$UPN'"
    if ($ExistingUser) {
        Write-Warning "⚠️ User '$UPN' already exists. Skipping..."
        $Another = Read-Host "`nProvision another user? (y/n)"
        continue
    }

    # -- Create user --
    try {
        $User = New-MgUser -AccountEnabled $true `
            -DisplayName "$FirstName $LastName" `
            -UserPrincipalName $UPN `
            -MailNickname $Username `
            -PasswordProfile @{ 
                Password = $Password
                ForceChangePasswordNextSignIn = $true 
            } `
            -GivenName $FirstName `
            -Surname $LastName `
            -JobTitle $JobTitle `
            -UsageLocation "GB" `
            -Mail @{} # Avoids mail sync issues

        Write-Host "✅ Created user: $UPN"
        Write-Host "🔑 Assigned password: $Password"
    } catch {
        Write-Error "❌ Failed to create user: $_"
        $Another = Read-Host "`nTry another user? (y/n)"
        continue
    }

    # -- Add to AllStaff group --
    try {
        $AllStaffId = Get-GroupIdByName $DefaultGroupName
        Add-MgGroupMember -GroupId $AllStaffId -DirectoryObjectId $User.Id
        $GroupsAssigned += $DefaultGroupName
        Write-Host "✅ Added to group: $DefaultGroupName"
    } catch {
        Write-Warning "⚠️ Could not add to default group: $_"
    }

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
        try {
            $AllSkus = Get-MgSubscribedSku
            $Sku = $AllSkus | Where-Object {
                $_.SkuPartNumber -eq $LicenseSku -and $_.PrepaidUnits.Enabled -gt $_.ConsumedUnits
            }

            if ($Sku) {
                Set-MgUserLicense -UserId $User.Id -AddLicenses @{SkuId = $Sku.SkuId} -RemoveLicenses @()
                $LicenseStatus = "Licensed: $($LicenseLabels[$LicenseSku])"
                Write-Host "✅ Assigned license: $LicenseLabels[$LicenseSku]"
            } else {
                throw "License not available or no units remaining"
            }
        } catch {
            Write-Warning "⚠️ Failed to assign license: $_"
            $LicenseStatus = "Unlicensed"
        }
    } else {
        $LicenseStatus = "Unlicensed"
    }

    # -- Add to Unlicensed group if needed --
    if ($LicenseStatus -eq "Unlicensed") {
        try {
            $UnlicensedId = Get-GroupIdByName $UnlicensedGroupName
            Add-MgGroupMember -GroupId $UnlicensedId -DirectoryObjectId $User.Id
            $GroupsAssigned += $UnlicensedGroupName
            Write-Host "🚫 Added to '$UnlicensedGroupName'"
        } catch {
            Write-Warning "⚠️ Failed to add to Unlicensed group: $_"
        }
    }

    # ------------------ WAIT FOR MAILBOX ------------------
    $Mailbox = $null
    $MaxWaitTime = 120   # seconds
    $Interval     = 10
    $Waited       = 0

    Write-Host "`n⏳ Waiting for mailbox to be provisioned for $UPN..."

    try {
        Connect-ExchangeOnline -ShowProgress:$false -ErrorAction Stop
    } catch {
        Write-Warning "⚠️ Could not connect to Exchange Online: $_"
    }

    while (-not $Mailbox -and $Waited -lt $MaxWaitTime) {
        try {
            $Mailbox = Get-Mailbox -Identity $UPN -ErrorAction Stop
        } catch {
            Start-Sleep -Seconds $Interval
            $Waited += $Interval
        }
    }

    if (-not $Mailbox) {
        Write-Warning "⚠️ Mailbox for $UPN was not ready after $MaxWaitTime seconds. Skipping calendar permissions."
        Disconnect-ExchangeOnline -Confirm:$false
    } else {
        # -- Set Time Zone --
        try {
            Set-MailboxRegionalConfiguration -Identity $UPN -TimeZone $UserTimeZone -LocalizeDefaultFolderName
            Write-Host "🌍 Set mailbox time zone to: $UserTimeZone"
        } catch {
            Write-Warning "⚠️ Failed to set mailbox time zone: $_"
        }

        # -- Calendar Sharing --
        try {
            $AllStaffUsers = Get-MgGroupMember -GroupId $AllStaffId -All | Where-Object {
                $_.AdditionalProperties.userPrincipalName -ne $null
            }

            foreach ($Member in $AllStaffUsers) {
                $OtherUPN = $Member.AdditionalProperties.userPrincipalName
                if ($OtherUPN -ne $UPN) {
                    Add-MailboxFolderPermission -Identity "$OtherUPN:\Calendar" `
                                                -User $UPN `
                                                -AccessRights Reviewer -ErrorAction SilentlyContinue

                    Add-MailboxFolderPermission -Identity "$UPN:\Calendar" `
                                                -User $OtherUPN `
                                                -AccessRights Reviewer -ErrorAction SilentlyContinue
                }
            }

            Write-Host "📅 Calendar sharing permissions set between $UPN and AllStaff."
        } catch {
            Write-Warning "⚠️ Calendar sharing failed: $_"
        }

        Disconnect-ExchangeOnline -Confirm:$false
    }

    # ------------------ EMAIL NOTIFICATION ------------------
    try {
        $EmailBody = @"
<h2>🧍 New Azure User Provisioned</h2>
<ul>
  <li><strong>Name:</strong> $FirstName $LastName</li>
  <li><strong>Username:</strong> $Username</li>
  <li><strong>UPN:</strong> $UPN</li>
  <li><strong>Job Title:</strong> $JobTitle</li>
  <li><strong>Password:</strong> $Password</li>
  <li><strong>Groups:</strong> $($GroupsAssigned -join ", ")</li>
  <li><strong>License:</strong> $LicenseStatus</li>
  <li><strong>Time Zone:</strong> $UserTimeZone</li>
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
                         -Credential (Get-Credential)

        Write-Host "`n📧 Email sent with user details."
    } catch {
        Write-Warning "⚠️ Failed to send admin email: $_"
    }

    # ------------------ SUMMARY ------------------
    Write-Host "`n🗂️ Summary:"
    Write-Host "Name      : $FirstName $LastName"
    Write-Host "Job Title : $JobTitle"
    Write-Host "Username  : $Username"
    Write-Host "UPN       : $UPN"
    Write-Host "Password  : $Password"
    Write-Host "Groups    : $($GroupsAssigned -join ", ")"
    Write-Host "License   : $LicenseStatus"
    Write-Host "Time Zone : $UserTimeZone"
    Write-Host "Created   : $TimeStamp"

    $Another = Read-Host "`nProvision another user? (y/n)"
}
while ($Another -eq "y")
