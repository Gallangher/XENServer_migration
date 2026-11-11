#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Remove XenServer / Citrix VM Tools, absent Xen devices and leftover drivers.
Run in Windows PowerShell 5.1 x64 on the migrated Hyper-V VM.
Back up the VM first. This script has NOT been tested on Windows.
No phases or command-line switches. MSI removal is automatic.
Only ghost-device and driver cleanup ask for Y/N confirmation.
If an MSI requests a restart, restart Windows and run this script again.
Unknown EXE uninstallers and drivers still in use are not forced.
#>
$ErrorActionPreference = 'Stop'

function Confirm-Removal([string]$Question) {
    return ((Read-Host "$Question Y/N") -match '^(?i)y$')
}

# Exact driver names prevent removal of unrelated Citrix products.
$driverNames = @('xenbus','xenfilt','xeniface','xenvif','xennet',
    'xenvbd','xendisk','xenhid','xenvkbd','xenvusb','xencons','xenpci')
$infNames = @($driverNames | ForEach-Object { "$_.inf" })
$sysNames = @($driverNames | ForEach-Object { "$_.sys" })

function Get-XenDevices {
    $present = @{}
    Get-PnpDevice -PresentOnly | ForEach-Object { $present[$_.InstanceId] = $true }
    foreach ($device in Get-PnpDevice) {
        $key = Get-Item -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $device.InstanceId) -ErrorAction SilentlyContinue
        $service = if ($key) { [string]$key.GetValue('Service') } else { '' }
        if ($device.InstanceId -match '^(?i:XEN|XENBUS|XENVIF|XENVBD)\\' -or
            $device.InstanceId -match '^(?i:PCI)\\VEN_5853&' -or
            $driverNames -contains $service) {
            [pscustomobject]@{Name=$device.FriendlyName;InstanceId=$device.InstanceId;
                Present=$present.ContainsKey($device.InstanceId)}
        }
    }
}

try {
    # Never remove the source VM's active Xen storage or network drivers.
    $vm = Get-CimInstance Win32_ComputerSystem
    if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1 x64.'
    }
    if ($vm.Manufacturer -ne 'Microsoft Corporation' -or $vm.Model -ne 'Virtual Machine') {
        throw 'Run this script inside the migrated Hyper-V VM, not on XenServer.'
    }
    if (@(Get-XenDevices | Where-Object Present).Count) {
        throw 'Present Xen devices found. Active Xen drivers will not be removed.'
    }

    # Find VM Tools in both uninstall registry locations. Do not use Win32_Product.
    $products = @(foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem $root) {
            $name = [string]$key.GetValue('DisplayName')
            if ($name -match '^(?i)(Citrix (XenServer (Tools|Windows Management Agent)|Tools for Virtual Machines)|XenServer (Tools|Windows Management Agent)|Xen Tools|XenTools|XCP-ng (Tools|Windows Management Agent))(\s.*)?$') {
                [pscustomobject]@{Name=$name;Code=$key.PSChildName;MSI=$key.GetValue('WindowsInstaller')}
            }
        }
    })
    if ($products.Count) {
        Write-Host 'Found the following VM Tools. Uninstalling automatically:'
        $products | Format-Table Name,Code -AutoSize
        # Do not guess silent switches for EXE uninstallers.
        if (@($products | Where-Object { $_.MSI -ne 1 -or $_.Code -notmatch '^\{[0-9a-fA-F-]{36}\}$' }).Count) {
            throw 'A non-MSI Tools entry was found. Uninstall it using the vendor uninstaller, then run this script again.'
        }
        foreach ($product in ($products | Sort-Object Code -Unique)) {
            $process = Start-Process msiexec.exe -ArgumentList "/x $($product.Code) /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru
            if ($process.ExitCode -in @(3010,1641)) {
                Write-Warning 'Restart Windows, then run this script again. Cleanup has not continued.'
                exit 3010
            }
            if ($process.ExitCode -ne 0) { throw "MSI uninstall failed: $($product.Name), code $($process.ExitCode)." }
        }
    } else { Write-Host 'No matching VM Tools found.' }

    # Remove only absent Xen devices. Unknown status alone does not mean absent.
    $ghosts = @(Get-XenDevices | Where-Object { -not $_.Present })
    if ($ghosts.Count) {
        Write-Host 'Found the following ghost devices:'
        $ghosts | Format-Table Name,InstanceId -AutoSize
        if (-not (Confirm-Removal 'Remove these ghost devices?')) {
            Write-Host 'Cancelled. Driver files were not removed.'
            exit 0
        }
        # SetupAPI supports systems without pnputil /remove-device (Server 2016/2019).
        if (-not ('SimpleXenCleanup.Native' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace SimpleXenCleanup {
 public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct DeviceInfo {
   public uint Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
  }
  [DllImport("setupapi.dll", SetLastError=true)]
  static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr guid, IntPtr parent);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string id, IntPtr parent, uint flags, ref DeviceInfo info);
  [DllImport("setupapi.dll", SetLastError=true)]
  static extern bool SetupDiCallClassInstaller(uint code, IntPtr set, ref DeviceInfo info);
  [DllImport("setupapi.dll", SetLastError=true)]
  static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  public static void Remove(string id) {
   IntPtr set=SetupDiCreateDeviceInfoList(IntPtr.Zero,IntPtr.Zero);
   if(set==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    DeviceInfo info=new DeviceInfo(); info.Size=(uint)Marshal.SizeOf(typeof(DeviceInfo));
    if(!SetupDiOpenDeviceInfoW(set,id,IntPtr.Zero,0,ref info))
     throw new Win32Exception(Marshal.GetLastWin32Error());
    if(!SetupDiCallClassInstaller(5,set,ref info))
     throw new Win32Exception(Marshal.GetLastWin32Error());
   } finally { SetupDiDestroyDeviceInfoList(set); }
  }
 }
}
'@
        }
        foreach ($ghost in $ghosts) {
            if (@(Get-PnpDevice -PresentOnly | Where-Object InstanceId -eq $ghost.InstanceId).Count) {
                throw 'A selected device is now present. Cleanup stopped.'
            }
            [SimpleXenCleanup.Native]::Remove($ghost.InstanceId)
            Write-Host "Removed: $($ghost.InstanceId)"
        }
    } else { Write-Host 'No Xen ghost devices found.' }
    if (@(Get-XenDevices).Count) { throw 'Xen devices remain. Restart Windows and run this script again.' }

    # Show packages and loose files together, then ask once before driver cleanup.
    $packages = @(Get-WindowsDriver -Online -All | Where-Object {
        $infNames -contains [IO.Path]::GetFileName($_.OriginalFileName)
    })
    $files = @(Get-ChildItem "$env:windir\System32\drivers" -File | Where-Object { $sysNames -contains $_.Name })
    if (-not $packages.Count -and -not $files.Count) {
        Write-Host 'No matching driver packages or files found.'
        exit 0
    }
    Write-Host 'Found the following driver packages and files:'
    $packages | Format-Table Driver,OriginalFileName,ProviderName -AutoSize
    $files | Format-Table FullName -AutoSize
    if (-not (Confirm-Removal 'Remove these driver packages and files?')) { exit 0 }

    # Use the Windows package manager. Never delete DriverStore folders manually.
    foreach ($package in $packages) {
        if ($package.Inbox -or $package.Driver -notmatch '^oem\d+\.inf$' -or
            $package.ProviderName -notmatch '(?i)(Citrix|Xen|XCP-ng)') {
            throw "Unrecognised driver package: $($package.Driver)."
        }
        & "$env:windir\System32\pnputil.exe" /delete-driver $package.Driver
        if ($LASTEXITCODE -eq 3010) {
            Write-Warning 'Restart Windows, then run this script again.'
            exit 3010
        }
        if ($LASTEXITCODE -ne 0) { throw "Driver package removal failed: $($package.Driver). No forced deletion." }
    }
    # Only remove loose SYS files without service references in any control set.
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.FullName)) { continue }
        $references = @(foreach ($cs in Get-ChildItem 'HKLM:\SYSTEM' | Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }) {
            Get-ChildItem (Join-Path $cs.PSPath 'Services') | Where-Object {
                ([string]$_.GetValue('ImagePath')) -match [regex]::Escape($file.Name) -or
                ($_.PSChildName + '.sys') -ieq $file.Name
            }
        })
        if ($references.Count) {
            Write-Warning "Skipped $($file.Name): a service still references it."
            continue
        }
        if ($file.VersionInfo.CompanyName -notmatch '(?i)(Citrix|Xen|XCP-ng)') {
            Write-Warning "Skipped $($file.Name): unknown file vendor."
            continue
        }
        Remove-Item -LiteralPath $file.FullName -ErrorAction Stop
        Write-Host "Deleted: $($file.FullName)"
    }
    Write-Host 'Cleanup pass finished. Review warnings and restart Windows. Skipped files remain.'
} catch {
    Write-Warning $_.Exception.Message
    exit 1
}
