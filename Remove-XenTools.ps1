#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Audyt i etapowe usuwanie XenServer Tools po migracji do Hyper-V.
.DESCRIPTION
Windows PowerShell 5.1 x64, Windows Server 2016 lub nowszy.
Domyslnie tylko audyt. Zmiany wymagaja -Execute -BackupConfirmed.
Cleanup dziala tylko w gosciu Hyper-V bez obecnych urzadzen Xen.
Nie usuwa wszystkich produktow Citrix ani wszystkich ghost devices.
Szczegoly, ograniczenia i procedura: README-XenCleanup.md.
.PARAMETER Phase
Audit: raport; Uninstall: zatwierdzone produkty MSI; Cleanup: pozostalosci.
.PARAMETER ProductCode
Jawna lista GUID produktow MSI, skopiowana z raportu audytu.
.PARAMETER AllowSourceUninstall
Pozwala na standardowa deinstalacje MSI jeszcze na XenServer.
Nie odblokowuje Cleanup na XenServer.
.PARAMETER Execute
Wlacza zmiany. Bez tego kazda faza jest tylko audytem.
.PARAMETER BackupConfirmed
Potwierdzenie sprawdzonej kopii calej VM i dostepu do konsoli.
.EXAMPLE
.\Remove-XenTools.ps1
.EXAMPLE
.\Remove-XenTools.ps1 -Phase Cleanup -Execute -BackupConfirmed -WhatIf
.NOTES
Autorska implementacja, nie kopia skryptow z GitHub. Bez gwarancji.
Nieprzetestowana na Windows w srodowisku wykonania autora odpowiedzi.
Exit: 0 audyt/sukces, 1 blad/blokada, 3010 wymagany restart i ponowienie.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [ValidateSet('Audit','Uninstall','Cleanup')][string]$Phase = 'Audit',
    [string[]]$ProductCode = @(),
    [switch]$Execute,
    [switch]$BackupConfirmed,
    [switch]$AllowSourceUninstall,
    [string]$WorkRoot = "$env:ProgramData\XenCleanup"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Cmdlet = $PSCmdlet
$script:ExitCode = 0
$script:TranscriptStarted = $false
$script:PendingReboot = $false
# Exact names only. Unknown versions remain visible in the report for review.
$script:DriverNames = @('xenbus','xenfilt','xeniface','xenvif','xennet',
    'xenvbd','xendisk','xenhid','xenvkbd','xenvusb','xencons','xenpci')
$script:AgentNames = @('xenagent','xensvc','xenbus_monitor','xeninstall')
$script:InfNames = @($script:DriverNames | ForEach-Object { "$_.inf" })
$script:SysNames = @($script:DriverNames | ForEach-Object { "$_.sys" })
$script:Events = New-Object 'System.Collections.Generic.List[object]'
function Log([string]$Message) {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format s), $Message)
    $script:Events.Add([pscustomobject]@{Time=(Get-Date -Format o);Message=$Message})
}
function Run-Native([string]$File, [string[]]$Arguments, [int[]]$Allowed=@(0)) {
    Log ("NATIVE: $File " + ($Arguments -join ' '))
    $output = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    Log "ExitCode=$code"
    if ($Allowed -notcontains $code) { throw "$File zakonczyl sie kodem $code" }
    return [int]$code
}
function Require-Reboot([string]$Reason) {
    $script:PendingReboot = $true
    [pscustomobject]@{BootTime=$script:BootTime.ToString('o');Reason=$Reason} |
        ConvertTo-Json | Set-Content -LiteralPath $script:Marker -Encoding UTF8
    Log "RESTART WYMAGANY: $Reason. Uruchom ponownie system i powtorz faze."
    $script:ExitCode = 3010
}
function Get-Products {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root) {
            $name = [string]$key.GetValue('DisplayName')
            if ($name -notmatch '(?i)(xenserver|xen tools|xentools|citrix.*(tools|management agent)|xcp-ng)') { continue }
            [pscustomobject]@{Name=$name;Version=$key.GetValue('DisplayVersion');
                Publisher=$key.GetValue('Publisher');ProductCode=$key.PSChildName;
                WindowsInstaller=$key.GetValue('WindowsInstaller');
                UninstallString=$key.GetValue('UninstallString');RegistryPath=$key.Name}
        }
    }
}
function Get-Devices {
    # A disabled device is still present. Status=Unknown is NOT used as a ghost test.
    $present = @{}
    Get-PnpDevice -PresentOnly -ErrorAction Stop | ForEach-Object { $present[$_.InstanceId]=$true }
    foreach ($d in Get-PnpDevice -ErrorAction Stop) {
        $enum = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $d.InstanceId
        $svc = ''
        if (Test-Path -LiteralPath $enum) {
            $svc = [string](Get-Item -LiteralPath $enum).GetValue('Service')
        }
        $xen = ($d.InstanceId -match '^(?i:XEN|XENBUS|XENVIF|XENVBD)\\') -or
            ($d.InstanceId -match '^(?i:PCI)\\VEN_5853&') -or
            ($script:DriverNames -contains $svc)
        [pscustomobject]@{InstanceId=$d.InstanceId;Name=$d.FriendlyName;
            Class=$d.Class;Status=[string]$d.Status;Present=$present.ContainsKey($d.InstanceId);
            Service=$svc;IsXen=[bool]$xen}
    }
}
function Get-Packages {
    @(Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object {
        $script:InfNames -contains [IO.Path]::GetFileName($_.OriginalFileName)
    } | Select-Object Driver,OriginalFileName,ProviderName,ClassName,Version,BootCritical,Inbox)
}
function Get-XenServices {
    foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services') {
        $image = [string]$key.GetValue('ImagePath')
        if (($script:DriverNames -contains $key.PSChildName) -or
            ($script:AgentNames -contains $key.PSChildName) -or
            ($key.PSChildName -match '(?i)xen') -or ($image -match '(?i)xen')) {
            [pscustomobject]@{Name=$key.PSChildName;ImagePath=$image;
                Type=$key.GetValue('Type');Start=$key.GetValue('Start')}
        }
    }
}
function Get-Filters {
    # Enumerate real control sets once; CurrentControlSet is an alias.
    foreach ($cs in Get-ChildItem 'HKLM:\SYSTEM' | Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }) {
        $root = Join-Path $cs.PSPath 'Control\Class'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -Recurse -ErrorAction Stop) {
            foreach ($valueName in @('UpperFilters','LowerFilters')) {
                $values = @($key.GetValue($valueName))
                if ($values -contains 'xenfilt') {
                    [pscustomobject]@{Path=$key.PSPath;NativePath=$key.Name;
                        ValueName=$valueName;Values=[string[]]$values}
                }
            }
        }
    }
}
function Get-Inventory {
    $devices = @(Get-Devices)
    [pscustomobject]@{Computer=$env:COMPUTERNAME;Time=(Get-Date -Format o);
        ComputerSystem=$script:ComputerSystem | Select-Object Manufacturer,Model;
        OS=$script:OS | Select-Object Caption,Version,BuildNumber,LastBootUpTime;
        Products=@(Get-Products);XenDevices=@($devices | Where-Object IsXen);
        AllGhostDevices=@($devices | Where-Object { -not $_.Present });
        DriverPackages=@(Get-Packages);Services=@(Get-XenServices);Filters=@(Get-Filters);
        DriverFiles=@(Get-ChildItem "$env:windir\System32\drivers" -File |
            Where-Object { $_.Name -match '^(?i)xen.*\.sys$' } |
            Select-Object Name,FullName,Length,LastWriteTime)}
}
function Save-Inventory([string]$Name) {
    $inventory = Get-Inventory
    $inventory | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath (Join-Path $script:RunDir "$Name.json") -Encoding UTF8 -WhatIf:$false
    return $inventory
}
function Assert-CleanupSafe {
    if ($script:ComputerSystem.Manufacturer -ne 'Microsoft Corporation' -or
        $script:ComputerSystem.Model -ne 'Virtual Machine') {
        throw 'Cleanup dozwolony tylko wewnatrz goscia Hyper-V. Brak obejscia tej blokady.'
    }
    if (@(Get-Devices | Where-Object { $_.IsXen -and $_.Present }).Count -gt 0) {
        throw 'Wykryto obecne urzadzenie Xen. Nie wolno usuwac sterownikow.'
    }
}
# SetupAPI is used instead of pnputil /remove-device, absent on Server 2016/2019.
function Initialize-SetupApi {
    if ('XenCleanup.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace XenCleanup {
 public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct DevInfo {
   public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct InstallParams {
   public uint cbSize, Flags, FlagsEx;
   public IntPtr hwndParent, InstallMsgHandler, InstallMsgHandlerContext, FileQueue;
   public UIntPtr ClassInstallReserved;
   public uint Reserved;
   [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string DriverPath;
  }
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr guid, IntPtr parent);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string id, IntPtr parent, uint flags, ref DevInfo data);
  [DllImport("setupapi.dll", SetLastError=true)]
  static extern bool SetupDiCallClassInstaller(uint code, IntPtr set, ref DevInfo data);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool SetupDiGetDeviceInstallParamsW(IntPtr set, ref DevInfo data, ref InstallParams p);
  [DllImport("setupapi.dll", SetLastError=true)]
  static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  public static bool Remove(string id) {
   IntPtr set=SetupDiCreateDeviceInfoList(IntPtr.Zero,IntPtr.Zero);
   if(set==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    DevInfo d=new DevInfo(); d.cbSize=(uint)Marshal.SizeOf(typeof(DevInfo));
    Check(SetupDiOpenDeviceInfoW(set,id,IntPtr.Zero,0,ref d));
    // No class install params: DIF_REMOVE applies globally, not to one profile.
    Check(SetupDiCallClassInstaller(0x05,set,ref d));
    InstallParams p=new InstallParams(); p.cbSize=(uint)Marshal.SizeOf(typeof(InstallParams));
    Check(SetupDiGetDeviceInstallParamsW(set,ref d,ref p));
    return (p.Flags & (0x80u | 0x100u))!=0;
   } finally { SetupDiDestroyDeviceInfoList(set); }
  }
 }
}
'@
}
function Invoke-XenCleanup {
try {
    if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Uruchom Windows PowerShell 5.1 x64, nie PowerShell 7 ani proces x86.'
    }
    $script:OS = Get-CimInstance Win32_OperatingSystem
    if ([int]$script:OS.BuildNumber -lt 14393) { throw 'Wymagany Windows build 14393 lub nowszy.' }
    $script:ComputerSystem = Get-CimInstance Win32_ComputerSystem
    $script:BootTime = [datetime]$script:OS.LastBootUpTime
    # Report files are intentionally written even in Audit and WhatIf.
    $null = New-Item -ItemType Directory -Path $WorkRoot -Force -WhatIf:$false -Confirm:$false
    $script:RunDir = Join-Path $WorkRoot ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null = New-Item -ItemType Directory -Path $script:RunDir -WhatIf:$false -Confirm:$false
    $script:Marker = Join-Path $WorkRoot 'restart-required.json'
    Start-Transcript -LiteralPath (Join-Path $script:RunDir 'transcript.txt') -WhatIf:$false | Out-Null
    $script:TranscriptStarted = $true
    Log "Phase=$Phase Execute=$Execute WhatIf=$WhatIfPreference"
    $before = Save-Inventory 'before'
    Log ('Produkty={0}, urzadzenia Xen={1}, pakiety={2}, filtry={3}' -f
        $before.Products.Count,$before.XenDevices.Count,$before.DriverPackages.Count,$before.Filters.Count)
    $before.Products | Format-Table Name,ProductCode,WindowsInstaller -AutoSize | Out-Host
    if ($Phase -eq 'Audit' -or -not $Execute) { Log 'AUDYT: brak zmian systemowych.'; return }
    if (-not $BackupConfirmed) { throw 'Wymagane -BackupConfirmed: kopia calej VM i dostep do konsoli.' }
    if (Test-Path -LiteralPath $script:Marker) {
        $marker = Get-Content -LiteralPath $script:Marker -Raw | ConvertFrom-Json
        if ($script:BootTime -le [datetime]$marker.BootTime) {
            $script:PendingReboot=$true; $script:ExitCode=3010; Log 'Najpierw wykonaj restart wymagany przez poprzedni przebieg.'; return
        }
        if (-not $WhatIfPreference) { Remove-Item -LiteralPath $script:Marker -Confirm:$false }
    }
    # Conservative pending-reboot checks, not a universal reboot detector.
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $session = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if ($pending -or $null -ne $session.GetValue('PendingFileRenameOperations')) {
        $script:PendingReboot=$true; $script:ExitCode=3010; Log 'Windows sygnalizuje oczekujacy restart. Najpierw wyjasnij i wykonaj restart.'; return
    }
    if ($Phase -eq 'Uninstall') {
        if (-not $AllowSourceUninstall) { Assert-CleanupSafe }
        if ($ProductCode.Count -eq 0) { throw 'Podaj -ProductCode z raportu; brak automatycznego wyboru MSI.' }
        $products = @(Get-Products)
        $selected = @()
        foreach ($code in ($ProductCode | Select-Object -Unique)) {
            if ($code -notmatch '^\{[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}$') { throw "Niepoprawny GUID: $code" }
            $matches = @($products | Where-Object { $_.ProductCode -eq $code -and $_.WindowsInstaller -eq 1 })
            if ($matches.Count -eq 0) { throw "Nie znaleziono zatwierdzonego produktu Xen MSI: $code" }
            $selected += $matches[0]
        }
        foreach ($product in $selected) {
            if ($script:Cmdlet.ShouldProcess($product.Name, 'MSI uninstall /x /qn /norestart')) {
                $msilog = Join-Path $script:RunDir ('msi-'+$product.ProductCode.Trim('{}')+'.log')
                $args = '/x {0} /qn /norestart REBOOT=ReallySuppress /L*v "{1}"' -f $product.ProductCode,$msilog
                $process = Start-Process "$env:windir\System32\msiexec.exe" -ArgumentList $args -Wait -PassThru
                Log "MSI $($product.Name): $($process.ExitCode)"
                if ($process.ExitCode -notin @(0,3010,1641)) { throw "Blad MSI: $($process.ExitCode)" }
                Require-Reboot 'Zakonczono deinstalacje jednego produktu MSI; ponow audyt po restarcie.'
                return # One product per run: avoid continuing through an unknown installer state.
            }
        }
        return
    }
    Assert-CleanupSafe
    if (@(Get-Products).Count -gt 0) { throw 'Pozostaly produkty Tools. Najpierw standardowa deinstalacja i restart.' }
    # 1. Remove only absent Xen devices. Recheck presence immediately before removal.
    Initialize-SetupApi
    foreach ($device in @(Get-Devices | Where-Object { $_.IsXen -and -not $_.Present })) {
        if ($script:Cmdlet.ShouldProcess($device.InstanceId, 'Remove absent Xen PnP device')) {
            Assert-CleanupSafe
            $now = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object InstanceId -eq $device.InstanceId)
            if ($now.Count -gt 0) { throw 'Urzadzenie stalo sie obecne. Przerwano.' }
            $needsRestart = [XenCleanup.Native]::Remove($device.InstanceId)
            Log "Usunieto ghost device: $($device.InstanceId)"
            if ($needsRestart) { Require-Reboot 'SetupAPI wymaga restartu.'; return }
        }
    }
    # Do not delete packages if any Xen devnode remains (including declined removals).
    if (@(Get-Devices | Where-Object IsXen).Count -gt 0 -and -not $WhatIfPreference) {
        throw 'Pozostaly urzadzenia Xen. Pakiety i pliki nie beda usuwane.'
    }
    # 2. Export each package, then delete without /force or /uninstall.
    foreach ($package in @(Get-Packages)) {
        if ($package.ProviderName -notmatch '(?i)(Citrix|XenServer|Xen Project|XCP-ng)') { throw "Nieznany dostawca pakietu $($package.Driver): $($package.ProviderName). Wymagana analiza." }
        if ($package.Inbox -or $package.Driver -notmatch '^oem\d+\.inf$') { throw 'Nieoczekiwany pakiet systemowy.' }
        if ($script:Cmdlet.ShouldProcess($package.Driver, 'Export and delete Xen driver package (no force)')) {
            Assert-CleanupSafe
            $dest = Join-Path $script:RunDir $package.Driver
            $null = New-Item -ItemType Directory -Path $dest -Confirm:$false
            $null = Run-Native "$env:windir\System32\pnputil.exe" @('/export-driver',$package.Driver,$dest)
            $code = Run-Native "$env:windir\System32\pnputil.exe" @('/delete-driver',$package.Driver) @(0,3010)
            if ($code -eq 3010) { Require-Reboot 'PnPUtil wymaga restartu.'; return }
        }
    }
    if (@(Get-Packages).Count -gt 0 -and -not $WhatIfPreference) { throw 'Pozostaly pakiety Xen. Przerwano.' }
    # 3. Remove only xenfilt from multi-string values, preserving other filters.
    $filterChanged = $false
    foreach ($filter in @(Get-Filters)) {
        if ($script:Cmdlet.ShouldProcess($filter.NativePath+'\'+$filter.ValueName, 'Remove only xenfilt filter entry')) {
            $backup = Join-Path $script:RunDir ('filter-'+[guid]::NewGuid().ToString('N')+'.reg')
            $null = Run-Native "$env:windir\System32\reg.exe" @('export',$filter.NativePath,$backup,'/y')
            $keep = [string[]]@($filter.Values | Where-Object { $_ -ine 'xenfilt' })
            if ($keep.Count -gt 0) {
                Set-ItemProperty -LiteralPath $filter.Path -Name $filter.ValueName -Value $keep -Type MultiString -Confirm:$false
            } else { Remove-ItemProperty -LiteralPath $filter.Path -Name $filter.ValueName -Confirm:$false }
            $filterChanged = $true
        }
    }
    if ($filterChanged) { Require-Reboot 'Zmieniono filtry klas urzadzen; pliki pozostawiono do kolejnego przebiegu.'; return }
    if (@(Get-Filters).Count -gt 0 -and -not $WhatIfPreference) { throw 'Pozostaly filtry xenfilt. Nie wolno usuwac uslug ani plikow.' }
    # 4. Never stop a running kernel driver. Delete only exact, stopped services.
    $serviceChanged = $false
    foreach ($svc in @(Get-XenServices)) {
        if (($script:DriverNames + $script:AgentNames) -notcontains $svc.Name) {
            throw "Nierozpoznana usluga Xen: $($svc.Name). Wymagana reczna analiza; pliki pozostaja."
        }
        $driver = Get-CimInstance Win32_SystemDriver -Filter ("Name='{0}'" -f $svc.Name)
        if ($null -ne $driver -and $driver.State -ne 'Stopped') {
            throw "Sterownik $($svc.Name) nie jest zatrzymany. Brak wymuszonego zatrzymania/usuniecia."
        }
        if ($script:Cmdlet.ShouldProcess($svc.Name, 'Backup and delete stopped Xen service')) {
            $backup = Join-Path $script:RunDir ('service-'+$svc.Name+'.reg')
            $null = Run-Native "$env:windir\System32\reg.exe" @('export',('HKLM\SYSTEM\CurrentControlSet\Services\'+$svc.Name),$backup,'/y')
            $normal = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if ($null -ne $normal -and $normal.Status -ne 'Stopped' -and $null -eq $driver) {
                Stop-Service -Name $svc.Name -ErrorAction Stop -Confirm:$false
                $normal.WaitForStatus('Stopped',[timespan]::FromSeconds(30))
            }
            $null = Run-Native "$env:windir\System32\sc.exe" @('delete',$svc.Name)
            $serviceChanged = $true
        }
    }
    if ($serviceChanged) { Require-Reboot 'Usunieto wpisy uslug. Pliki zostana sprawdzone po restarcie.'; return }
    if (@(Get-XenServices).Count -gt 0 -and -not $WhatIfPreference) { throw 'Pozostaly uslugi Xen. Pliki nie beda usuwane.' }
    # 5. Final file deletion, exact allowlist, only after all references above are gone.
    foreach ($file in @(Get-ChildItem "$env:windir\System32\drivers" -File | Where-Object { $script:SysNames -contains $_.Name })) {
        if ($script:Cmdlet.ShouldProcess($file.FullName, 'Backup, hash and delete residual Xen SYS file')) {
            Assert-CleanupSafe
            if ($file.VersionInfo.CompanyName -notmatch '(?i)(Citrix|Xen|XCP-ng)') {
                throw "Niepotwierdzony dostawca pliku $($file.Name). Plik pozostaje do recznej analizy."
            }
            $references = @(foreach ($cs in Get-ChildItem 'HKLM:\SYSTEM' | Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }) {
                $serviceRoot = Join-Path $cs.PSPath 'Services'
                Get-ChildItem -LiteralPath $serviceRoot | Where-Object {
                    ([string]$_.GetValue('ImagePath')) -match [regex]::Escape($file.Name) -or
                    ($_.PSChildName + '.sys') -ieq $file.Name
                }
            })
            if ($references.Count -gt 0) { throw "Plik $($file.Name) ma odwolanie w usludze. Przerwano." }
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            $hash | Export-Csv (Join-Path $script:RunDir 'deleted-file-hashes.csv') -Append -NoTypeInformation -Encoding UTF8
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $script:RunDir $file.Name) -Confirm:$false
            Remove-Item -LiteralPath $file.FullName -ErrorAction Stop -Confirm:$false
            Log "Usunieto plik $($file.FullName) SHA256=$($hash.Hash)"
        }
    }
    $after = Save-Inventory 'after'
    if ($WhatIfPreference) { Log 'WHATIF: tylko plan, raporty zapisane; nie wykonano czyszczenia.'; return }
    $remaining = $after.Products.Count + $after.XenDevices.Count + $after.DriverPackages.Count +
        $after.Services.Count + $after.Filters.Count + $after.DriverFiles.Count
    if ($remaining -gt 0) { throw 'Pozostaly elementy Xen, w tym mozliwe nazwy spoza listy. Sprawdz after.json.' }
    Log 'Nie wykryto pozostalosci w kontrolowanym zakresie. Wykonaj restart i testy aplikacji.'
} catch {
    $script:ExitCode = 1
    Write-Warning $_.Exception.Message
    if ($script:TranscriptStarted) { Log ('BLAD: '+$_.Exception.Message) }
} finally {
    if ($script:TranscriptStarted) {
        try {
            [pscustomobject]@{ExitCode=$script:ExitCode;PendingReboot=$script:PendingReboot;
                Phase=$Phase;Execute=[bool]$Execute;WhatIf=[bool]$WhatIfPreference;Events=$script:Events} |
                ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:RunDir 'result.json') -Encoding UTF8 -WhatIf:$false
            Log "Raporty: $script:RunDir"
        } finally { Stop-Transcript -WhatIf:$false | Out-Null }
    }
}
}
Invoke-XenCleanup
exit $script:ExitCode
