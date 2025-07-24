# ------------------ REQUIRED MODULES ------------------
$requiredModules = @(
    @{Name="MSOnline"; MinimumVersion="1.1.183.57"},
    @{Name="AzureAD"; MinimumVersion="2.0.2.138"},
    @{Name="Microsoft.Graph"; MinimumVersion="1.9.6"},
    @{Name="ExchangeOnlineManagement"; MinimumVersion="3.0.0"}
)

function Install-And-ImportModules {
    foreach ($mod in $requiredModules) {
        $installed = Get-Module -ListAvailable -Name $mod.Name | Where-Object {
            [version]$_.Version -ge [version]$mod.MinimumVersion
        }

        if (-not $installed) {
            Write-Host "Module '$($mod.Name)' not found or outdated. Installing..."
            try {
                Install-Module -Name $mod.Name -MinimumVersion $mod.MinimumVersion -Scope CurrentUser -Force -AllowClobber
                Write-Host "Installed module $($mod.Name) successfully."
            } catch {
                Write-Warning "Failed to install $($mod.Name): $_"
                exit 1
            }
        } else {
            Write-Host "Module '$($mod.Name)' is already installed."
        }

        try {
            Import-Module $mod.Name -ErrorAction Stop
            Write-Host "Imported $($mod.Name) module."
        } catch {
            Write-Warning "Failed to import $($mod.Name): $_"
            exit 1
        }
    }
}

function Authenticate-All {
    Write-Host "`nPlease enter credentials for Azure AD and MSOnline modules."
    $cred = Get-Credential

    Write-Host "Connecting to MSOnline and AzureAD..."
    try {
        Connect-MsolService -Credential $cred
        Connect-AzureAD -Credential $cred
        Write-Host "Connected to MSOnline and AzureAD."
    } catch {
        Write-Warning "Failed MSOnline/AzureAD connection: $_"
        exit 1
    }

    Write-Host "Connecting to Microsoft Graph..."
    try {
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All", "User.Read.All", "Group.ReadWrite.All"
        Write-Host "Microsoft Graph connected successfully."
    } catch {
        Write-Warning "Failed to connect to Microsoft Graph: $_"
        exit 1
    }

    Write-Host "Please enter credentials for Exchange Online (can be the same as above)."
    $exCred = Get-Credential
    Write-Host "Connecting to Exchange Online..."
    try {
        Connect-ExchangeOnline -Credential $exCred -ShowProgress $false
        Write-Host "Exchange Online connected successfully."
    } catch {
        Write-Warning "Failed to connect to Exchange Online: $_"
        exit 1
    }

    return $cred
}

# Main Offboarding workflow
function Offboard-User {
    param (
        [string]$DomainName,
        [string]$EmailSender,
        [string]$SMTPServer,
        [string]$RecipientAdmins,
        [pscredential]$Credential
    )

    # Helper functions
    function Get-UserObject {
        param([string]$UPN)
        try {
            return Get-AzureADUser -ObjectId $UPN
        } catch {
            return $null
        }
    }

    function Remove-UserLicenses {
        param([string]$UPN)
        $user = Get-MsolUser -UserPrincipalName $UPN
        if (-not $user) { Write-Warning "User not found in MSOnline."; return }

        $skuIds = $user.Licenses | ForEach-Object { $_.AccountSkuId }
        if ($skuIds.Count -eq 0) {
            Write-Host "No licenses to remove."
            return
        }

        try {
            Set-MsolUserLicense -UserPrincipalName $UPN -RemoveLicenses $skuIds
            Write-Host "✅ Licenses revoked"
        } catch {
            Write-Warning "Failed to revoke licenses: $_"
        }
    }

    function Remove-GroupMemberships {
        param([string]$UserObjectId)
        try {
            $groups = Get-AzureADUserMembership -ObjectId $UserObjectId
            foreach ($group in $groups) {
                try {
                    Remove-AzureADGroupMember -ObjectId $group.ObjectId -MemberId $UserObjectId
                    Write-Host "Removed from group: $($group.DisplayName)"
                } catch {
                    Write-Warning "Failed to remove from group $($group.DisplayName): $_"
                }
            }
            Write-Host "✅ Group memberships removed"
        } catch {
            Write-Warning "Failed to retrieve user group memberships: $_"
        }
    }

    # Start offboarding
    $UPN = Read-Host "Enter UPN of user to offboard"
    $UserObj = Get-UserObject -UPN $UPN

    if (-not $UserObj) {
        Write-Host "❌ User not found in Azure AD"
        return
    }

    Write-Host "`n⚠️ Please confirm offboarding for:"
    Write-Host "Display Name : $($UserObj.DisplayName)"
    Write-Host "UPN          : $UPN"
    $ConfirmUser = Read-Host "Proceed with offboarding this user? (y/n)"
    if ($ConfirmUser.ToLower() -ne "y") {
        Write-Host "⏹️ Offboarding cancelled."
        return
    }

    Write-Host "`nRetrieving Intune devices for user..."
    $Devices = Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '$UPN'"
    $RecoveryInfo = @()

    if ($Devices.Count -gt 0) {
        Write-Host "`n📋 Devices registered to this user:"
        $i = 1
        foreach ($Device in $Devices) {
            Write-Host "$i. $($Device.DeviceName) ($($Device.OperatingSystem)) - $($Device.Manufacturer)"
            $i++
        }

        $ConfirmDevices = Read-Host "Proceed with retrieving BitLocker keys and wiping these devices? (y/n)"
        if ($ConfirmDevices.ToLower() -ne "y") {
            Write-Host "⏹️ Device actions skipped."
            $Devices = @()
        }
    } else {
        Write-Host "`nℹ️ No Intune devices found for this user."
    }

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Disable Azure AD account
    try {
        Set-AzureADUser -ObjectId $UPN -AccountEnabled $false
        Write-Host "✅ User account disabled"
    } catch {
        Write-Warning "Failed to disable user account: $_"
    }

    # Revoke Microsoft 365 licenses
    Remove-UserLicenses -UPN $UPN

    # Remove group memberships
    Remove-GroupMemberships -UserObjectId $UserObj.ObjectId

    # Optional mailbox conversion
    $ConvertMailbox = Read-Host "Convert mailbox to shared? (y/n)"
    if ($ConvertMailbox.ToLower() -eq "y") {
        try {
            Set-Mailbox -Identity $UPN -Type Shared
            Write-Host "✅ Mailbox converted to shared"
        } catch {
            Write-Warning "Failed to convert mailbox. Ensure Exchange Online module is connected and mailbox exists."
        }
    }

    # Device BitLocker key retrieval and wipe
    foreach ($Device in $Devices) {
        try {
            $BitlockerKeys = Get-MgDeviceManagementManagedDeviceRecoveryKey -ManagedDeviceId $Device.Id
            if ($BitlockerKeys) {
                foreach ($Key in $BitlockerKeys) {
                    $RecoveryInfo += "<li><strong>$($Device.DeviceName)</strong>: $($Key.RecoveryKey)</li>"
                }
                Write-Host "🔑 Retrieved BitLocker key(s) for $($Device.DeviceName)"
            } else {
                Write-Host "⚠️ No BitLocker keys found for $($Device.DeviceName)"
            }
        } catch {
            Write-Warning "Could not retrieve BitLocker key for $($Device.DeviceName): $_"
        }

        try {
            Invoke-MgDeviceManagementManagedDeviceWipe -ManagedDeviceId $Device.Id
            Write-Host "✅ Wipe triggered for $($Device.DeviceName)"
        } catch {
            Write-Warning "Failed to wipe $($Device.DeviceName): $_"
        }
    }

    # Email notification
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

    Write-Host "Sending summary email to IT team..."
    try {
        $smtpParams = @{
            To         = $RecipientAdmins
            From       = $EmailSender
            Subject    = "🧍 User Offboarding Complete: $UPN"
            Body       = $EmailBody
            BodyAsHtml = $true
            SmtpServer = $SMTPServer
            Port       = 587
            UseSsl     = $true
            Credential = $Credential
        }
        Send-MailMessage @smtpParams
        Write-Host "`n📧 Summary email sent to IT team."
    } catch {
        Write-Warning "Failed to send summary email: $_"
    }
}

# ------------------ MAIN SCRIPT ------------------

# Config
$DomainName = "alphaplus.co.uk"
$EmailSender = "admin@$DomainName"
$SMTPServer = "smtp.office365.com"
$RecipientAdmins = "zak.horrocks@$DomainName","jack.hughes@$DomainName","joe.lane@$DomainName","dan.creighton@$DomainName","ziyan.amjid@$DomainName"

# Step 1: Install and import modules
Install-And-ImportModules

# Step 2: Authenticate and get credentials
$cred = Authenticate-All

# Step 3: Run offboarding
Offboard-User -DomainName $DomainName -EmailSender $EmailSender -SMTPServer $SMTPServer -RecipientAdmins $RecipientAdmins -Credential $cred

# Step 4: Disconnect sessions
Write-Host "Cleaning up sessions..."
Disconnect-ExchangeOnline -Confirm:$false
Disconnect-MgGraph
Write-Host "Done."
