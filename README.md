# OneDrive Remove

![Windows 11](https://img.shields.io/badge/Windows-11-0078D4?logo=windows&logoColor=white)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Run as admin](https://img.shields.io/badge/run%20as-Administrator-orange)

One PowerShell script that fully removes OneDrive from Windows 11 and stops it coming back.
Your files are left alone.

Uninstalling OneDrive from Settings leaves the Explorer sidebar entry, the startup entry, scheduled tasks,
and the package that reinstalls it for every new user. This script cleans all of that up in one go.

## What it does

| Step | Detail |
|---|---|
| Stops OneDrive | Ends `OneDrive`, `OneDriveStandaloneUpdater` and `FileSyncConfig` |
| Uninstalls it | Store (AppX) package for all users, the provisioned package for new users, and the classic `OneDriveSetup.exe /uninstall` |
| Cleans Explorer | Removes OneDrive from the navigation pane |
| Stops it starting | Removes the Run entries and the OneDrive scheduled tasks |
| Removes leftovers | Program Files, ProgramData and each signed-in user's local OneDrive settings |
| Keeps it gone | Sets the "Prevent the usage of OneDrive for file storage" policy in the registry |
| Refreshes the desktop | Restarts Explorer so the changes show straight away |

**Your synced files stay put.** Local `OneDrive` folders are not touched unless you add `-RemoveUserData`.

## Use it

1. Open PowerShell **as Administrator**.
2. Run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Remove-OneDrive.ps1
```

3. Reboot when it finishes.

To also delete the current user's local OneDrive folders (make sure anything you need is backed up first):

```powershell
.\Remove-OneDrive.ps1 -RemoveUserData
```

The script checks it's running as admin on Windows 11 (build 22000 or later). On anything else, it exits
without changing anything. `-WhatIf` is **not** supported yet: running the script makes the changes.

Everything it does is logged to `C:\Logs\RemoveOneDrive.log`.

## Good to know

- User settings are cleaned for accounts that are **signed in** when it runs. On a shared PC, run it before
  other people sign in, or again later.
- Best run on a fresh install or before handing a machine over.

## Changed your mind?

1. Delete the registry key `HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive`.
2. Reinstall OneDrive from Microsoft (download page or `winget install Microsoft.OneDrive`).
3. Sign in again.
