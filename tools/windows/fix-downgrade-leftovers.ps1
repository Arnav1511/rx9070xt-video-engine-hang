# Finds and replaces the AMD driver files that a driver downgrade leaves behind in
# C:\Windows\System32 and C:\Windows\SysWOW64.
#
# AMD's driver INF copies its user-mode files "overwrite older only" (copy flag 0x4040), so
# installing an older Adrenalin over a newer one keeps the newer copies, even with Factory
# Reset. Among them are amfrt64.dll / amfrt32.dll (the AMF runtime every hardware-encoding
# app loads) and atiadlxx.dll / atiadlxy.dll (the ADL sensor library). Apps then run the
# newer AMF runtime against the older driver, and monitoring tools lose the card's sensors.
#
# For every AMD file in the two system folders that the card's installed driver package also
# ships, this compares the bytes. A file that matches neither that package nor the package
# of another AMD adapter in use (integrated graphics, say) is a leftover: it is renamed to
# <name>.bak-leftover and replaced with the package's copy, with owner and permissions
# restored. Undo a file by renaming its .bak-leftover back (take ownership first).
#
# Preview in a normal PowerShell (changes nothing):
#   powershell -ExecutionPolicy Bypass -File fix-downgrade-leftovers.ps1 -Check
# Fix in an administrator PowerShell, then reboot:
#   powershell -ExecutionPolicy Bypass -File fix-downgrade-leftovers.ps1
# -Card is part of the adapter's name; the script prints the adapter and package it found.
# -BlockDriverUpdates also stops Windows Update delivering drivers (for every device), so it
# cannot put a newer AMD driver back. Undo:
#   reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /f
#   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" /v SearchOrderConfig /t REG_DWORD /d 1 /f
#
# This replaces files in Windows' system folders. It was used on the system in the README
# after the 26.9.2 -> 26.2.2 downgrade (7 files). Read the preview before running the fix.
param([switch]$Check, [switch]$BlockDriverUpdates, [string]$Card = 'Radeon RX')
$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Check -and -not $admin) { Write-Host 'Run this from an administrator PowerShell (or add -Check to preview).' -ForegroundColor Red; exit 1 }
if (-not [Environment]::Is64BitProcess) { Write-Host 'Run this from the normal (64-bit) PowerShell.' -ForegroundColor Red; exit 1 }

function Get-Machine([string]$path) {                     # 0x8664 = 64-bit, 0x14c = 32-bit
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
    try { $br = New-Object IO.BinaryReader($fs); $fs.Position = 0x3C; $pe = $br.ReadInt32(); $fs.Position = $pe + 4; return $br.ReadUInt16() }
    catch { return 0 } finally { $fs.Close() }
}
function Get-Hash([string]$path) { (Get-FileHash -LiteralPath $path).Hash }
# Windows lists each adapter's driver files with their driver-store path; the package is the
# folder directly under FileRepository.
function Get-Package($adapter) { if ("$($adapter.InstalledDisplayDrivers)" -match '^(.+?\\FileRepository\\[^\\,]+)\\') { $matches[1] } }

$adapters = @(Get-CimInstance Win32_VideoController)
$cardAdapter = $adapters | Where-Object Name -match ([regex]::Escape($Card)) | Select-Object -First 1
if (-not $cardAdapter) { Write-Host "No display adapter with '$Card' in its name. Adapters: $($adapters.Name -join '; '). Pass -Card." -ForegroundColor Red; exit 1 }
$main = Get-Package $cardAdapter
if (-not $main -or -not (Test-Path $main)) { Write-Host "Could not find the driver-store package of $($cardAdapter.Name) (is the card disabled?); nothing changed." -ForegroundColor Red; exit 1 }
$inf = Get-ChildItem $main -Filter '*.inf' | Select-Object -First 1
$others = @($adapters | Where-Object { $_.AdapterCompatibility -match 'Advanced Micro|AMD|ATI' } | ForEach-Object { Get-Package $_ } | Where-Object { $_ -and $_ -ne $main -and (Test-Path $_) } | Select-Object -Unique)
Write-Host "$($cardAdapter.Name): driver $($cardAdapter.DriverVersion), package $(Split-Path $main -Leaf)"
foreach ($o in $others) { Write-Host "also in use: package $(Split-Path $o -Leaf)" }

# destination name -> source names, from the INF's "dest,source" copy lines
$ren = @{}
Get-Content $inf.FullName | ForEach-Object {
    if ($_ -match '^\s*([\w\.\-]+\.(?:dll|exe))\s*,\s*([\w\.\-]+\.(?:dll|exe))' -and $matches[1] -ne $matches[2]) {
        $d = $matches[1].ToLower(); if (-not $ren[$d]) { $ren[$d] = @() }; $ren[$d] += $matches[2].ToLower()
    }
}
function Get-Index($dir) { $ix = @{}; Get-ChildItem $dir -Recurse -File | Where-Object { $_.Extension -in '.dll', '.exe' } | ForEach-Object { $k = $_.Name.ToLower(); if (-not $ix[$k]) { $ix[$k] = @() }; $ix[$k] += $_.FullName }; $ix }
$mainIx = Get-Index $main
$otherIx = @($others | ForEach-Object { Get-Index $_ })

$replaced = 0; $stale = 0; $ok = 0
foreach ($t in @(@{ Dir = "$env:WINDIR\System32"; Machine = 0x8664 }, @{ Dir = "$env:WINDIR\SysWOW64"; Machine = 0x14c })) {
    Get-ChildItem $t.Dir -File | Where-Object { $_.Extension -in '.dll', '.exe' -and ($_.VersionInfo.CompanyName -match 'Advanced Micro|AMD|ATI' -or $_.Name -match '^(amd|ati|amf)') } | ForEach-Object {
        $dst = $_.FullName; $k = $_.Name.ToLower()
        $names = @(); if ($ren[$k]) { $names += $ren[$k] }; $names += $k          # the INF's source name first
        $cand = @(); foreach ($n in $names) { if ($mainIx[$n]) { $cand += @($mainIx[$n] | Where-Object { (Get-Machine $_) -eq $t.Machine }) } }
        if (-not $cand) { return }                                                # not a file this driver installs here
        $h = Get-Hash $dst
        if ($cand | Where-Object { (Get-Hash $_) -eq $h }) { $ok++; return }
        $name = $_.Name
        foreach ($ix in $otherIx) { foreach ($n in $names) { if ($ix[$n] -and (@($ix[$n]) | Where-Object { (Get-Hash $_) -eq $h })) { $ok++; Write-Host "$(Split-Path $t.Dir -Leaf)\$name : belongs to the other adapter's driver, left alone"; return } } }
        $src = $cand[0]; $stale++
        if ($Check) { Write-Host ("{0}\{1} : LEFTOVER ({2} bytes, {3}); would be replaced by {4} ({5} bytes)" -f (Split-Path $t.Dir -Leaf), $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd'), (Split-Path $src -Leaf), (Get-Item $src).Length) -ForegroundColor Yellow; return }
        $bak = "$dst.bak-leftover"
        takeown /f $dst /a | Out-Null
        icacls $dst /grant '*S-1-5-32-544:F' | Out-Null          # Administrators
        if (Test-Path $bak) { takeown /f $bak /a | Out-Null; icacls $bak /grant '*S-1-5-32-544:F' | Out-Null; Remove-Item $bak -Force }
        Rename-Item $dst (Split-Path $bak -Leaf)                  # works even while the DLL is loaded
        Copy-Item $src $dst
        icacls $dst /setowner 'NT SERVICE\TrustedInstaller' | Out-Null
        icacls $dst /reset | Out-Null                             # back to the folder's normal permissions
        $good = (Get-Hash $dst) -eq (Get-Hash $src)
        if ($good) { $replaced++ }
        Write-Host ("{0}\{1} : replaced ({2} -> {3} bytes), verified={4}" -f (Split-Path $t.Dir -Leaf), $_.Name, (Get-Item $bak).Length, (Get-Item $dst).Length, $good) -ForegroundColor $(if ($good) { 'Green' } else { 'Red' })
    }
}
Write-Host "`n$ok files already match, $stale leftover$(if ($Check) { ' (preview only, nothing changed)' } else { ", $replaced replaced" })."

if ($BlockDriverUpdates -and -not $Check) {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
    Set-ItemProperty -Path $pol -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name SearchOrderConfig -Value 0 -Type DWord
    Write-Host 'Windows Update will no longer deliver drivers.' -ForegroundColor Green
}
if (-not $Check -and $stale) { Write-Host 'Reboot so every program loads the matching files.' -ForegroundColor Cyan }
