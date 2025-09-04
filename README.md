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

The script supports three methods for providing the App Registration credentials.

### 1. Direct Parameters (Standard Method)
You can provide the `ClientId` and `ClientSecret` directly as command-line parameters. This is the standard and simplest way to use the script with Intune.

### 2. Azure Key Vault (Advanced Method)
The script can fetch the credentials from an Azure Key Vault. This is recommended for environments where secrets are centrally managed.

### 3. Hardcoded in Script (Remediation Method)
You can hardcode all necessary configuration directly into the `Map-Drive.ps1` script. This method is intended for simple, standalone execution, such as for remediation or testing, where providing parameters is inconvenient. This allows for a zero-parameter execution of the script.

**How to use:**
1.  Open the `Map-Drive.ps1` script.
2.  Locate the `Hardcoded Configuration` section at the top.
3.  Fill in the values for `$HardcodedTenantId`, `$HardcodedDomain`, `$HardcodedClientId`, and `$HardcodedClientSecret`.
> **Security Note:** This method is the least secure and should not be used for general production deployments in Intune, as the secret is stored in plain text within the script package.

**Prerequisites for Key Vault:**
*   The **user** running the script (or the **device**, if using a system identity) must have an Azure AD identity that is granted `Get` access to the secrets in your Key Vault.
*   The `Az.Accounts` and `Az.KeyVault` PowerShell modules must be available. The script will attempt to install them for the current user if they are missing.
*   Your Key Vault must contain two secrets with the following **exact names**:
    *   `IntuneDriveMapper-ClientId` (containing the Application Client ID)
    *   `IntuneDriveMapper-ClientSecret` (containing the Client Secret value)

## 🔁 Logic Overview

*   **Remediation Script (`Map-Drive.ps1`)**:
    1.  Uses the Microsoft Graph API to retrieve the user's Azure AD groups.
    2.  Calculates the definitive list of required network drives based on the `DriveMappings` and `NetworkShares` configuration.
    3.  **Safely removes drives**: It removes any drives that are defined in `$NetworkShares` but are no longer required for the user. It will **never** touch any other mapped drives that are not defined in its configuration.
    4.  **Maps missing drives**: It maps all required drives that are not already present.
    5.  Creates a status file (`status.json`) in a subfolder of the user's local app data (`$env:LOCALAPPDATA`) with the list of drives that were just configured.

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
    powershell.exe -ExecutionPolicy Bypass -File .\\Map-Drive.ps1 -Domain "YOUR_DOMAIN.com" -TenantId "YOUR_TENANT_ID" -ClientId "YOUR_CLIENT_ID" -ClientSecret "YOUR_SECRET"
    ```
    *Replace the placeholders with your actual values.*

    **Method B: Using Azure Key Vault**
    ```powershell
    powershell.exe -ExecutionPolicy Bypass -File .\\Map-Drive.ps1 -Domain "YOUR_DOMAIN.com" -TenantId "YOUR_TENANT_ID" -KeyVaultName "YOUR_KEY_VAULT_NAME"
    ```
    *Replace `YOUR_KEY_VAULT_NAME` with the name of your vault.*

    **Method C: Using Hardcoded Credentials**

    If you have filled in all the variables in the `Hardcoded Configuration` section of the script, it can be run with no parameters.
    ```powershell
    powershell.exe -ExecutionPolicy Bypass -File .\\Map-Drive.ps1
    ```
    *This method is generally not recommended for Intune deployment but is included for completeness.*

4.  Configure the uninstall command (optional).
5.  Under **Detection rules**, select **Use a custom script** and upload `Detect-Drives.ps1`.
6.  Ensure the application is deployed in the **user context**.

## ⚙️ Customization

The mapping logic is located in `Map-Drive.ps1`. You can customize it by modifying the configuration variables at the top of the script.

### Drive Mappings
You can define which Azure AD groups map to which network shares by modifying these two hash tables:

```powershell
# Maps a group name (with wildcard *) to a logical share name
$DriveMappings = @{
    "ALPESCN_ORDONNANCEMENT_R"  = "ORDONNANCEMENT"
    "ALPESCN_LOGISTIQUE_R"      = "LOGISTIQUE"
    "ALPESCN_FINANCE_RW"        = "FINANCE"
    "R&D"                       = "R&D"
    # ... etc.
}

# Maps a logical share name to one or more actual UNC paths
$NetworkShares = @{
    "ORDONNANCEMENT" = "\\10.80.2.20\ORDONNANCEMENT"
    "LOGISTIQUE"     = "\\10.80.2.20\LOGISTIQUE"
    "FINANCE"        = "\\10.80.2.20\FINANCE"
    "R&D" = @(
        "\\vm-data\RDM",
        "\\vm-data\TLC"
        # ... etc.
    )
}
```

### Excluding Drives from Unmapping
The script is designed to remove any mapped drives that are not explicitly assigned via the group mappings. If you have drives that users map manually (or that are mapped by other systems) that you want this script to ignore, you can add them to the `$ExcludedUncPaths` list.

The script will never attempt to unmap a drive whose UNC path is in this list.

```powershell
# Add any UNC paths here that should NEVER be unmapped by this script.
$ExcludedUncPaths = @(
    "\\SERVER\COMMON-SHARE",
    "\\CORP\DEPT-SHARE"
)
```
This feature replaces the previous, less flexible behavior of always adding a "Public" drive.

### Conditional Public Share Mapping
You can control access to the "Public" logical share based on a user's membership in other logical shares. This is useful for scenarios like preventing users with access to sensitive "R&D" drives from also getting the general "Public" drive.

This is controlled by two arrays:
*   `$allowedSharesForPublic`: If this list has any entries, a user **must** have at least one of these logical shares to be considered for "Public" drive access. If this list is empty, all users are considered "allowed" by default.
*   `$deniedSharesForPublic`: If a user has **any** logical share that is in this list, they will be **denied** access to the "Public" drive, even if they were allowed by the first list.

**Example:** Deny the "Public" drive to anyone who is a member of the "R&D" or "SCIENTIFIC" shares.
```powershell
$allowedSharesForPublic = @() # Allow all by default
$deniedSharesForPublic  = @(
	"R&D",
	"SCIENTIFIC"
)
```

## 🧪 Testing & Troubleshooting

To test the script or troubleshoot issues, you can run it manually from a PowerShell terminal. This is the best way to diagnose problems.

### How to Run for Local Testing

1.  **Open PowerShell**: Launch a PowerShell terminal on a test machine.
2.  **Navigate to the script directory**: Use `cd` to go to the folder containing the scripts.
3.  **Unblock the Script**: If you downloaded the scripts as a ZIP file, Windows will likely "block" them. Run this command first to unblock the mapping script:
    ```powershell
    Unblock-File -Path .\\Map-Drive.ps1
    ```
4.  **Run the Script**: Use the following command template. This method uses an environment variable to handle the client secret, which is more secure for interactive testing than passing it as a parameter.

    **Example Command:**
    ```powershell
    # First, set your secret as an environment variable for the current PowerShell session
    $env:INTUNE_CLIENT_SECRET = "YOUR_CLIENT_SECRET_VALUE"

    # Next, run the script with your other details
    .\\Map-Drive.ps1 -Domain "YOUR_DOMAIN.com" -ClientId "YOUR_CLIENT_ID" -TenantId "YOUR_TENANT_ID"
    ```
    *Replace `YOUR_DOMAIN.com`, `YOUR_CLIENT_SECRET_VALUE`, `YOUR_CLIENT_ID`, and `YOUR_TENANT_ID` with the actual values from your Azure App Registration.*

    > **Note:** The script will automatically use the `INTUNE_CLIENT_SECRET` environment variable if the `-ClientSecret` parameter is omitted.

### Interpreting the Debug Output

The script will print messages with timestamps. Look at the last message printed before the script hangs or fails. This will tell you which step is causing the problem.

*   **`DEBUG: Attempting to get Graph API token...`**: The script is trying to authenticate. If it hangs here, check for firewall or proxy issues that might be blocking the connection to `login.microsoftonline.com`.
*   **`DEBUG: Getting user object ID from Graph API...`**: The script is trying to find the user in Azure AD. If it hangs here, the Graph API call to get the user might be failing.
*   **`DEBUG: Getting all groups for user ID...`**: The script is trying to retrieve the user's group memberships. This can take time if the user is in many groups.

If the script fails with a `401 Unauthorized` error, refer to the "Prerequisite: App Registration in Azure AD" section to ensure your API permissions are correct.

## ✅ Result

*   Fully automated network drive mapping based on Azure AD groups.
*   Safe, self-healing solution: corrects mappings for configured corporate drives while ignoring users' personal mapped drives.
*   Flexible: Supports multiple authentication methods and allows for drive-level exclusions.
*   Works on both Azure AD joined and Hybrid joined devices.
