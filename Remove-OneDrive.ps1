<#
.SYNOPSIS
    Completely disables and removes OneDrive on Windows 11.

.DESCRIPTION
    - Verifies OS is Windows 11
    - Stops OneDrive processes
    - Uninstalls OneDrive (Win32 + AppX/provisioned)
    - Removes File Explorer integration
    - Disables tray / startup
    - Cleans up leftover program files (but *not* user data by default)
    - Adds policies/registry to prevent OneDrive coming back

.NOTES
    Run as Administrator.
    Logging: C:\Logs\RemoveOneDrive.log
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # OPTIONAL: If specified, also delete local OneDrive sync folders
    # for the *current user* (e.g. C:\Users\<User>\OneDrive*).
    # By default, user data is NOT removed.
    [switch]$RemoveUserData
)

# -------------------------------
# Global configuration / logging
# -------------------------------

$Global:LogDirectory = 'C:\Logs'
$Global:LogFile      = Join-Path $Global:LogDirectory 'RemoveOneDrive.log'

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path $Global:LogDirectory)) {
            New-Item -Path $Global:LogDirectory -ItemType Directory -Force | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
        Add-Content -Path $Global:LogFile -Value $line
        Write-Host $line
    } catch {
        # If logging fails, at least write to console
        Write-Warning "Logging failed: $($_.Exception.Message)"
        Write-Host $Message
    }
}

# -------------------------------
# Basic checks (Admin / OS)
# -------------------------------

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsWindows11 {
    try {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $cv = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $build = [int]$cv.CurrentBuildNumber
        # Windows 11 began with build 22000
        if ($build -ge 22000) {
            return $true
        } else {
            return $false
        }
    } catch {
        Write-Log "Failed to detect Windows version: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# Ensure we are elevated
if (-not (Test-IsAdministrator)) {
    Write-Host "ERROR: This script must be run as Administrator. Right-click PowerShell and select 'Run as administrator'." -ForegroundColor Red
    exit 1
}

Write-Log "==== Starting OneDrive removal script ===="

# Ensure OS is Windows 11
if (-not (Test-IsWindows11)) {
    Write-Log "This script is intended for Windows 11 only. Exiting." 'WARN'
    Write-Host "This script detected that the OS is NOT Windows 11. No changes were made." -ForegroundColor Yellow
    exit 0
}

Write-Log "OS verification passed: Windows 11 detected."

# -------------------------------
# Helper: Get all user SIDs to modify registry for
# -------------------------------
function Get-UserRegistrySIDs {
    <#
        Returns SIDs for all loaded user profiles (HKU),
        excluding technical hives like *_Classes.
    #>
    $sids = @()
    try {
        $hku = Get-ChildItem -Path 'HKU:\' -ErrorAction Stop
        foreach ($item in $hku) {
            if ($item.Name -notlike '*_Classes') {
                $sids += $item.PSChildName
            }
        }
    } catch {
        Write-Log "Failed to enumerate HKU SIDs: $($_.Exception.Message)" 'ERROR'
    }
    return $sids
}

# -------------------------------
# 1. Stop OneDrive processes
# -------------------------------

function Stop-OneDriveProcesses {
    Write-Log "Stopping any running OneDrive processes..."
    $processNames = @(
        'OneDrive',
        'OneDriveStandaloneUpdater',
        'FileSyncConfig'
    )

    foreach ($name in $processNames) {
        try {
            $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
            if ($procs) {
                foreach ($p in $procs) {
                    Write-Log "Stopping process $($p.ProcessName) (PID $($p.Id))"
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Log "Process ${name} not running." 'INFO'
            }
        } catch {
            Write-Log "Error stopping ${name}: $($_.Exception.Message)" 'WARN'
        }
    }
}

# -------------------------------
# 2. Uninstall OneDrive (Win32 & AppX / Provisioned)
# -------------------------------

function Uninstall-OneDrive {
    Write-Log "Uninstalling OneDrive (Win32 + AppX/provisioned)..."

    # --- AppX for existing users ---
    try {
        $appx = Get-AppxPackage -AllUsers -Name '*OneDrive*' -ErrorAction SilentlyContinue
        if ($appx) {
            foreach ($pkg in $appx) {
                Write-Log "Removing AppX package: $($pkg.PackageFullName)"
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)" 'WARN'
                }
            }
        } else {
            Write-Log "No OneDrive AppX packages found for existing users."
        }
    } catch {
        Write-Log "Error querying OneDrive AppX packages: $($_.Exception.Message)" 'WARN'
    }

    # --- Provisioned AppX for new users ---
    try {
        $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*OneDrive*' }
        if ($prov) {
            foreach ($p in $prov) {
                Write-Log "Removing provisioned package: $($p.DisplayName)"
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null
                } catch {
                    Write-Log "Failed to remove provisioned package $($p.DisplayName): $($_.Exception.Message)" 'WARN'
                }
            }
        } else {
            Write-Log "No provisioned OneDrive AppX packages found."
        }
    } catch {
        Write-Log "Error querying provisioned OneDrive packages: $($_.Exception.Message)" 'WARN'
    }

    # --- Win32 OneDriveSetup uninstall (32/64-bit) ---
    $setupPaths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )

    foreach ($path in $setupPaths) {
        try {
            if (Test-Path $path) {
                Write-Log "Running OneDriveSetup uninstall: ${path} /uninstall"
                & $path /uninstall | Out-Null
            } else {
                Write-Log "OneDriveSetup not found at ${path} (this is fine)." 'INFO'
            }
        } catch {
            Write-Log "Error running OneDriveSetup from ${path}: $($_.Exception.Message)" 'WARN'
        }
    }
}

# -------------------------------
# 3. Remove OneDrive integration from File Explorer
# -------------------------------

function Remove-OneDriveExplorerIntegration {
    <#
        Removes OneDrive from Explorer navigation pane by:
        - Unpinning namespace tree CLSID
        - Removing NameSpace keys
        Applies to HKLM, HKCR, HKCU, and all HKU user hives.
    #>

    Write-Log "Removing OneDrive integration from File Explorer..."

    $oneDriveGuid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'

    # Helper: Safely remove a registry key
    function Safe-RemoveRegistryKey {
        param(
            [string]$Path
        )
        try {
            if (Test-Path $Path) {
                Write-Log "Removing registry key: ${Path}"
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log "Failed to remove registry key ${Path}: $($_.Exception.Message)" 'WARN'
        }
    }

    # Helper: Set System.IsPinnedToNameSpaceTree=0 on a CLSID key
    function Unpin-FromNameSpaceTree {
        param(
            [string]$BasePath
        )
        $fullPath = Join-Path $BasePath $oneDriveGuid
        try {
            if (-not (Test-Path $fullPath)) {
                New-Item -Path $fullPath -Force | Out-Null
            }
            New-ItemProperty -Path $fullPath -Name 'System.IsPinnedToNameSpaceTree' -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Log "Set System.IsPinnedToNameSpaceTree=0 at ${fullPath}"
        } catch {
            Write-Log "Failed to modify ${fullPath}: $($_.Exception.Message)" 'WARN'
        }
    }

    # HKCR CLSID (global classes)
    Unpin-FromNameSpaceTree -BasePath 'Registry::HKEY_CLASSES_ROOT\CLSID'

    # HKLM MyComputer & Desktop NameSpace entries
    Safe-RemoveRegistryKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$oneDriveGuid"
    Safe-RemoveRegistryKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$oneDriveGuid"

    # HKCU & all HKU hives - remove NameSpace keys & unpin CLSID
    $userSids = Get-UserRegistrySIDs
    foreach ($sid in $userSids) {
        # Some system accounts, skip if clearly machine-only
        if ($sid -eq 'S-1-5-18') { continue }

        $userRoot = "Registry::HKEY_USERS\$sid"
        $userNSDesktop = "$userRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$oneDriveGuid"
        $userNSMyComp  = "$userRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$oneDriveGuid"
        $userCLSIDBase = "$userRoot\Software\Classes\CLSID"

        Safe-RemoveRegistryKey $userNSDesktop
        Safe-RemoveRegistryKey $userNSMyComp
        Unpin-FromNameSpaceTree -BasePath $userCLSIDBase
    }

    Write-Log "Explorer integration cleanup completed."
}

# -------------------------------
# 4. Disable tray / startup (system tray / corner)
# -------------------------------

function Disable-OneDriveStartupAndTray {
    <#
        Prevents OneDrive from auto-starting at logon by:
        - Removing Run keys for all profiles
        - Removing OneDrive-related scheduled tasks
        - (Policy keys are set in Set-OneDrivePreventPolicies)
    #>

    Write-Log "Disabling OneDrive from starting at logon / appearing in tray..."

    # Remove Run entries (HKCU/HKU / HKLM)
    $userSids = Get-UserRegistrySIDs
    foreach ($sid in $userSids) {
        if ($sid -eq 'S-1-5-18') { continue }

        $runPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
        try {
            if (Test-Path $runPath) {
                $props = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
                if ($props -and ($props.PSObject.Properties.Name -contains 'OneDrive')) {
                    Write-Log "Removing Run value 'OneDrive' from ${runPath}"
                    Remove-ItemProperty -Path $runPath -Name 'OneDrive' -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Log "Failed to clean Run key for SID ${sid}: $($_.Exception.Message)" 'WARN'
        }
    }

    # HKLM Run
    $runHKLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    try {
        if (Test-Path $runHKLM) {
            $props = Get-ItemProperty -Path $runHKLM -ErrorAction SilentlyContinue
            if ($props -and ($props.PSObject.Properties.Name -contains 'OneDrive')) {
                Write-Log "Removing Run value 'OneDrive' from HKLM Run"
                Remove-ItemProperty -Path $runHKLM -Name 'OneDrive' -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "Failed to clean HKLM Run key: $($_.Exception.Message)" 'WARN'
    }

    # Remove scheduled tasks
    try {
        $tasks = Get-ScheduledTask -TaskName '*OneDrive*' -ErrorAction SilentlyContinue
        if ($tasks) {
            foreach ($task in $tasks) {
                Write-Log "Unregistering scheduled task: $($task.TaskName)"
                try {
                    Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "Failed to unregister task $($task.TaskName): $($_.Exception.Message)" 'WARN'
                }
            }
        } else {
            Write-Log "No OneDrive-related scheduled tasks found."
        }
    } catch {
        Write-Log "Error querying OneDrive scheduled tasks: $($_.Exception.Message)" 'WARN'
    }
}

# -------------------------------
# 5. Clean up leftover program files (NOT user data by default)
# -------------------------------

function Clean-OneDriveLeftovers {
    <#
        Removes OneDrive binaries and configuration directories that are safe:
        - Program Files / Program Files (x86)
        - ProgramData
        - LocalAppData for all user profiles (if accessible)
        By default, user OneDrive folders containing sync'd files are NOT removed.
        Optional: remove user data for current user if -RemoveUserData is specified.
    #>

    Write-Log "Cleaning up OneDrive program files and configuration directories..."

    $pathsToRemove = @(
        'C:\Program Files\Microsoft OneDrive',
        'C:\Program Files (x86)\Microsoft OneDrive',
        'C:\ProgramData\Microsoft OneDrive'
    )

    foreach ($path in $pathsToRemove) {
        try {
            if (Test-Path $path) {
                Write-Log "Removing directory: ${path}"
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Write-Log "Directory not found (this is fine): ${path}" 'INFO'
            }
        } catch {
            Write-Log "Failed to remove directory ${path}: $($_.Exception.Message)" 'WARN'
        }
    }

    # LocalAppData for all users (where possible)
    try {
        $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalPath -like 'C:\Users\*' -and $_.Loaded -eq $true }

        foreach ($profile in $profiles) {
            $userLocalAppData = Join-Path $profile.LocalPath 'AppData\Local\Microsoft\OneDrive'
            if (Test-Path $userLocalAppData) {
                Write-Log "Removing user-local OneDrive config: ${userLocalAppData}"
                try {
                    Remove-Item -Path $userLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "Failed to remove ${userLocalAppData}: $($_.Exception.Message)" 'WARN'
                }
            }
        }
    } catch {
        Write-Log "Failed to enumerate user profiles for LocalAppData cleanup: $($_.Exception.Message)" 'WARN'
    }

    # User data (sync folders) for current user - optional and explicit
    $currentUserProfile = $env:UserProfile
    $userDataGlobs = @(
        (Join-Path $currentUserProfile 'OneDrive*')
    )

    if ($RemoveUserData.IsPresent) {
        foreach ($glob in $userDataGlobs) {
            $items = Get-Item $glob -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                Write-Log "User requested removal of local OneDrive data at: $($item.FullName)" 'WARN'
                try {
                    Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "Failed to delete user data at $($item.FullName): $($_.Exception.Message)" 'WARN'
                }
            }
        }
    } else {
        foreach ($glob in $userDataGlobs) {
            $items = Get-Item $glob -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                Write-Log "Leaving user OneDrive data in place at: $($item.FullName)" 'INFO'
            }
        }
    }
}

# -------------------------------
# 6. Policies / registry to prevent OneDrive returning
# -------------------------------

function Set-OneDrivePreventPolicies {
    <#
        Applies Group Policy equivalent registry settings to:
        - Prevent usage of OneDrive for file storage
        - Block consumer sync, legacy NGSC, etc.
        Also ensure OneDrive is not provisioned for new users (already handled in Uninstall-OneDrive).
    #>

    Write-Log "Applying policies/registry to prevent OneDrive from returning..."

    $policyBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
    try {
        if (-not (Test-Path $policyBase)) {
            New-Item -Path $policyBase -Force | Out-Null
        }

        # Prevent the usage of OneDrive for file storage
        New-ItemProperty -Path $policyBase -Name 'DisableFileSync' -PropertyType DWord -Value 1 -Force | Out-Null

        # Older / alternate policy names for compatibility
        New-ItemProperty -Path $policyBase -Name 'DisableFileSyncNGSC' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $policyBase -Name 'DisablePersonalSync' -PropertyType DWord -Value 1 -Force | Out-Null

        Write-Log "Policy keys set under ${policyBase}"
    } catch {
        Write-Log "Failed to set OneDrive policy keys: $($_.Exception.Message)" 'ERROR'
    }
}

# -------------------------------
# 7. Restart Explorer for UI changes
# -------------------------------

function Restart-ExplorerShell {
    <#
        Cleanly restarts Explorer so File Explorer navigation / tray changes apply.
    #>
    Write-Log "Restarting Explorer shell to apply UI changes..."

    try {
        $explorer = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue
        if ($explorer) {
            Write-Log "Stopping explorer.exe"
            Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Error stopping explorer.exe: $($_.Exception.Message)" 'WARN'
    }

    Start-Sleep -Seconds 2

    try {
        Write-Log "Starting explorer.exe"
        Start-Process -FilePath 'explorer.exe' -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Error starting explorer.exe: $($_.Exception.Message)" 'WARN'
    }
}

# -------------------------------
# MAIN EXECUTION
# -------------------------------

try {
    Stop-OneDriveProcesses
    Uninstall-OneDrive
    Remove-OneDriveExplorerIntegration
    Disable-OneDriveStartupAndTray
    Clean-OneDriveLeftovers
    Set-OneDrivePreventPolicies
    Restart-ExplorerShell

    Write-Log "OneDrive removal and disablement sequence completed successfully."
    Write-Host ""
    Write-Host "OneDrive has been disabled and removed as far as is supported via script." -ForegroundColor Green
    Write-Host "A reboot is recommended to ensure all changes fully take effect." -ForegroundColor Yellow
    if ($RemoveUserData.IsPresent) {
        Write-Host "Note: Local OneDrive *data* for the current user was removed because -RemoveUserData was specified." -ForegroundColor Yellow
    } else {
        Write-Host "Note: Local OneDrive *data* folders (e.g. synced user files) were left in place by default." -ForegroundColor Yellow
    }
    Write-Host "Log file: $Global:LogFile"
} catch {
    Write-Log "A fatal error occurred in the main execution block: $($_.Exception.Message)" 'ERROR'
    Write-Host "A fatal error occurred. See log for details: $Global:LogFile" -ForegroundColor Red
    exit 1
}

Write-Log "==== OneDrive removal script finished ===="
