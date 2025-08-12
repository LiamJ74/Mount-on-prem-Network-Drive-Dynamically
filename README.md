# 🗺️ Dynamic Network Drive Mapping with Intune

This project provides a solution to dynamically map on-premises network drives based on a user's Azure AD group membership. The deployment is designed to be managed via Microsoft Intune as a Win32 application.

## ✨ Summary

The solution automates the mapping of network drives for users. It includes:

*   **A detection script**: Verifies if the correct network drives are already mapped.
*   **A remediation script**: Maps the necessary network drives based on the user's Azure AD groups.

## 🧰 Package Contents

*   `Detect-Drives.ps1` – The PowerShell script that detects missing or misconfigured drives.
*   `Map-Drive.ps1` – The PowerShell script that performs the drive mapping.

## 🔐 Prerequisite: App Registration in Azure AD

For the script to query the Microsoft Graph API, an App Registration is required to authenticate and authorize access.

### 🔧 Steps to Create the App Registration

1.  Go to the **Azure Portal > Azure Active Directory > App registrations > + New registration**.
2.  Fill in the information:
    *   **Name**: `IntuneDriveMapper` (or a name of your choice).
    *   **Supported account types**: Accounts in this organizational directory only (Single tenant).
3.  Click **Register**.

Once the application is created:

4.  Go to **Certificates & secrets > + New client secret**.
    *   Make a note of the secret's **Value**. It will not be visible again after you leave the page.
5.  Go to **API Permissions > + Add a permission > Microsoft Graph > Application permissions**:
    *   `GroupMember.Read.All` – Allows the app to read group memberships.
    *   `User.Read.All` – Allows the app to read basic properties of all users.
    > **Note:** The script uses application permissions (app-only context) and not delegated permissions. Ensure you are adding the correct type.

6.  Click **Grant admin consent for [Your Tenant]**. This step is crucial and must be performed by an administrator.

### 🔑 Information to Collect

Copy the following values to use in the script:
*   **Tenant ID**
*   **Application (client) ID**
*   **Client secret Value**

## 🔒 Authentication Methods

The script supports two methods for providing the App Registration credentials.

### 1. Direct Parameters (Standard Method)
You can provide the `ClientId` and `ClientSecret` directly as command-line parameters. This is the standard and simplest way to use the script with Intune.

### 2. Azure Key Vault (Advanced Method)
The script can fetch the credentials from an Azure Key Vault. This is recommended for environments where secrets are centrally managed.

**Prerequisites for Key Vault:**
*   The **user** running the script (or the **device**, if using a system identity) must have an Azure AD identity that is granted `Get` access to the secrets in your Key Vault.
*   The `Az.Accounts` and `Az.KeyVault` PowerShell modules must be available. The script will attempt to install them for the current user if they are missing.
*   Your Key Vault must contain two secrets with the following **exact names**:
    *   `IntuneDriveMapper-ClientId` (containing the Application Client ID)
    *   `IntuneDriveMapper-ClientSecret` (containing the Client Secret value)

## 🔁 Logic Overview

*   **Remediation Script (`Map-Drive.ps1`)**:
    1.  Uses the Microsoft Graph API to retrieve the user's groups.
    2.  Determines the exact list of required network drives.
    3.  Maps any missing drives and removes any that are no longer needed.
    4.  Creates a status file (`status.json`) in a subfolder of the user's local app data (`$env:LOCALAPPDATA`) with the list of drives that were just configured.

*   **Detection Script (`Detect-Drives.ps1`)**:
    1.  Reads the `status.json` file to know which drives should be mapped.
    2.  Checks if the file is recent (less than 24 hours old by default).
    3.  Verifies that the drives listed in the file match the currently mapped drives.
    4.  Exits with code `0` (success) if everything matches, otherwise `1` (failure), which triggers the remediation.

## 📦 Intune Deployment Instructions

**Step 1 – Prepare the Win32 Package**

*   Use the `Microsoft Win32 Content Prep Tool` to package the two PowerShell scripts into an `.intunewin` file.

**Step 2 – Create the Application in Intune**

1.  In the Microsoft Endpoint Manager admin center, go to:
    **Apps > Windows > + Add > Windows app (Win32)**.
2.  Upload the `.intunewin` package you created.
3.  On the **Program** tab, configure the install command. Choose one of the two methods below.

    **Method A: Using Direct Parameters**
    ```powershell
    powershell.exe -ExecutionPolicy Bypass -File .\\Map-Drive.ps1 -TenantId "YOUR_TENANT_ID" -ClientId "YOUR_CLIENT_ID" -ClientSecret "YOUR_SECRET"
    ```
    *Replace the placeholders with your actual values.*

    **Method B: Using Azure Key Vault**
    ```powershell
    powershell.exe -ExecutionPolicy Bypass -File .\\Map-Drive.ps1 -TenantId "YOUR_TENANT_ID" -KeyVaultName "YOUR_KEY_VAULT_NAME"
    ```
    *Replace `YOUR_KEY_VAULT_NAME` with the name of your vault.*

4.  Configure the uninstall command (optional).
5.  Under **Detection rules**, select **Use a custom script** and upload `Detect-Drives.ps1`.
6.  Ensure the application is deployed in the **user context**.

## ⚙️ Customization

The mapping logic is located in `Map-Drive.ps1`. You can customize it by modifying the hash tables:

```powershell
# Maps a group name (with wildcard *) to a logical share name
$DriveMappings = @{
    "AZURE/AD_GROUPS*_R1"  = "Finance"
    "AZURE/AD_GROUPS*_RW1" = "Finance"
    "AZURE/AD_GROUPS*_R2"  = "HR"
}

# Maps a logical share name to one or more actual UNC paths
$NetworkShares = @{
    "Finance" = "\\SERVER\FINANCE"
    "HR"      = @(
        "\\SERVER\HR-DOCS",
        "\\SERVER\HR-ARCHIVES"
    )
}
```

## 🧪 Testing

*   Manually run `Detect-Drives.ps1` on a test machine to validate the detection logic.
*   Use the Intune logs (`IntuneManagementExtension.log`, `AgentExecutor.log`) for troubleshooting.

## 🩺 Troubleshooting

If the script fails or appears to hang, you can run it manually from a PowerShell terminal to diagnose the issue. The script now includes detailed debugging messages to help pinpoint the problem.

### How to Run for Debugging

1.  Open a PowerShell terminal on a test machine.
2.  Navigate to the directory containing the `Map-Drive.ps1` script.
3.  Run the script using the same command line you configured in Intune. For example:
    ```powershell
    powershell.exe -ExecutionPolicy Bypass -File .\\Map-Drive.ps1 -TenantId "YOUR_TENANT_ID" -ClientId "YOUR_CLIENT_ID" -ClientSecret "YOUR_SECRET"
    ```

### Interpreting the Debug Output

The script will print messages with timestamps. Look at the last message printed before the script hangs. This will tell you which step is failing.

*   **`DEBUG: Attempting to get Graph API token...`**: The script is trying to authenticate. If it hangs here, check for firewall or proxy issues that might be blocking the connection to `login.microsoftonline.com`.
*   **`DEBUG: Getting user object ID from Graph API...`**: The script is trying to find the user in Azure AD. If it hangs here, the Graph API call to get the user might be failing.
*   **`DEBUG: Getting all groups for user ID...`**: The script is trying to retrieve the user's group memberships. This can take time if the user is in many groups. If it hangs here for a very long time, there might be an issue with the Graph API service.

If the script fails with a `401 Unauthorized` error, refer to the "Prerequisite: App Registration in Azure AD" section to ensure your API permissions are correct.

## ✅ Result

*   Fully automated network drive mapping based on Azure AD groups.
*   Self-healing solution: deleted or modified drives are automatically corrected.
*   Works on both Azure AD joined and Hybrid joined devices.
