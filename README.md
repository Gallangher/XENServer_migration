# Xen Tools Cleanup

Remove XenServer Tools and leftover Xen drivers after moving a Windows VM to Hyper-V.

## Before you start

- Use Windows PowerShell 5.1, 64-bit, as Administrator.
- Use Windows Server 2016 or later.
- Back up the whole VM and make sure you can restore it.
- Keep access to the VM console.
- Test on a copy first. This script has not been tested on Windows.
- Run commands from the folder containing Remove-XenTools.ps1.

## 1. Check syntax without running the script

```powershell
$tokens = $null
$parseErrors = $null
$path = (Resolve-Path .\Remove-XenTools.ps1).Path
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$parseErrors
)
$parseErrors | Format-List Message, Extent
```

If errors appear, stop. No parser errors does not mean the script is safe to run.

## 2. Check the VM

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 -Phase Audit
```

This saves a report. It does not change the system configuration.
Read before.json and check the product names and ProductCode values.

## 3. Uninstall Xen Tools

Replace {GUID-FROM-REPORT} with the real MSI ProductCode from the audit.
Do not use this example unchanged.

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 `
    -Phase Uninstall `
    -ProductCode '{GUID-FROM-REPORT}' `
    -Execute -BackupConfirmed -AllowSourceUninstall
```

- Use -AllowSourceUninstall only when uninstalling on the source XenServer VM.
- This runs the normal MSI uninstaller. It may affect network or disk access.
- One product is removed per run. Restart, run Audit again, then repeat if needed.
- For an EXE installer, use the vendor's uninstall instructions instead.

## 4. Start the migrated VM on Hyper-V

Check that Windows starts and that disks and networking work.
Do not run the source and its copy on the same network at the same time.

Cleanup only works inside a running Hyper-V VM with no present Xen devices.
It cannot repair a VM that does not boot.

## 5. Preview cleanup

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 `
    -Phase Cleanup -Execute -BackupConfirmed -WhatIf
```

This shows the planned changes and saves reports. It does not remove anything.
Installed Tools or other safety checks may block the preview.

## 6. Run cleanup

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 `
    -Phase Cleanup -Execute -BackupConfirmed

$LASTEXITCODE
```

Confirm each change when asked.
If a restart is required, restart Windows and run the same command again.
Do not bypass a safety block or force driver removal.

## What cleanup removes

- Recognised Xen ghost devices: old devices that are no longer present.
- Recognised Xen driver packages, after exporting a copy.
- Only the xenfilt entry from device-class filter lists.
- Recognised Xen services, when safe.
- Recognised leftover SYS files, after backup and reference checks.

It does not remove all ghost devices, other Citrix products or unknown drivers.
Some versions or leftovers may need manual review.

## Results

- 0: audit or preview finished, or cleanup finished within its checked scope.
- 1: error or safety block. Read the logs.
- 3010: restart required. Restart, then run Audit and the relevant phase again.

A successful Audit does not mean the VM is clean. Read the report.

Reports and backups are saved under:

```text
C:\ProgramData\XenCleanup\
```

Main files: before.json, after.json (when created), result.json and transcript.txt.
Keep the same report folder setting between runs. Do not delete restart-required.json
just to bypass a required restart.

## Final check

Restart the VM. Check disks, IP settings, DNS, applications and the Windows System log.
Run Audit again and create a new backup.

If something fails, restore the whole VM from your backup.
The script's file and registry copies are not a full rollback.

## Source

This short guide is based on the supplied Remove-XenTools.ps1 script and its
README-XenCleanup.md documentation. No new Windows testing was performed.
