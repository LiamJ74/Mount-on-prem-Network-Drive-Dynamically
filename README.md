# Mount-on-prem-Network-Drive-Dynamically
Abillity to mount on-prem network drive dynamically through powershell and Intune


## Summary
This solution provides automated mapping of network drives based on the logged-in user's Azure AD group membership. It is designed to be deployed via Microsoft Intune using the Win32 app model and includes:

A detection script: Verifies if the correct drives are already mapped.

A remediation script: Automatically maps the required network drives.

## 🧰 Package Contents

Detect-Drives.ps1 – PowerShell script to detect missing or misconfigured mapped drives.

Map-Drives.ps1 – PowerShell script that maps drives based on group membership.

## 🔐 Prerequisite: App Registration in Azure AD
If the remediation script queries Microsoft Graph API, you must create an App Registration to authenticate and authorize API access.

🔧 Steps to create the App Registration
Go to Azure Portal > Azure Active Directory > App registrations > + New registration.

Fill in:

Name: IntuneDriveMapper (or any name)

Supported account types: Accounts in this organizational directory only (Single tenant)

Click Register.

Once created:

Go to Certificates & secrets > + New client secret

Note down the secret value (you won’t see it again).

Go to API Permissions > + Add a permission > Microsoft Graph > Delegated permissions:

GroupMember.Read.All

User.Read

Click Grant admin consent.

Copy the following values for your script:

Tenant ID

Client ID

Client Secret

These will be injected securely (e.g., via Intune script parameters or encrypted storage) and used in the remediation script to call Microsoft Graph.




## 🔁 Logic Overview
Detection script:

Identifies the current user's Azure AD groups.

Checks if corresponding network drives are correctly mapped.

Returns exit code 0 if everything is correct; 1 otherwise.

Remediation script:

Uses Microsoft Graph API or group translation logic to determine user group membership.

Maps network drives accordingly.

## 📦 Intune Deployment Instructions
Step 1 – Prepare the Intune Win32 App Package
Use the Microsoft Win32 Content Prep Tool to bundle the scripts:


Step 2 – Create the Intune App
In the Microsoft Endpoint Manager Admin Center, go to:
Apps > Windows > + Add > Windows app (Win32).

Upload the .intunewin package you created.

Under Program, configure:

Install command:

powershell

```
powershell.exe -ExecutionPolicy Bypass -File ".\Map-Drives.ps1"
```
Uninstall command: (optional, if you support unmapping)

Under Detection rules, select:

Use a custom script

Upload Detect-Drives.ps1

Configure Requirements, Dependencies, and Assignments as needed.

Don't forget to use "as User" and not as system context

## ⚙️ Customization
The mapping logic is stored in Map-Drives.ps1 and may look like:

powershell

```
$GroupDriveMap = @{
    "GROUP-FINANCE" = @{ Drive = "Z:"; Path = "\\server\finance" }
    "GROUP-HR"      = @{ Drive = "Y:"; Path = "\\server\hr" }
}
```
🧪 Testing
Manually run Detect-Drives.ps1 on a test machine to confirm proper detection logic.

Ensure Intune logs reflect correct remediation if a drive is missing.

Use IntuneManagementExtension.log and AgentExecutor.log for troubleshooting.

✅ Result
Fully automated network drive mapping based on Azure AD groups.

Self-healing: if drives are deleted or changed, the detection/remediation cycle will correct it automatically.

Works seamlessly on Hybrid or Azure AD-joined devices.
