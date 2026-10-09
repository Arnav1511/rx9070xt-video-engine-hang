# Turns Windows' GPU hang snapshots into a table: one row per hang with the stop code,
# whether AMD's own watchdog fired too, which program's work was on the stuck engine,
# which engine it was, and (with WinDbg installed) which amdkmdag.sys build was loaded.
#
# 1. Copy the snapshots out of the protected folder (admin PowerShell, once):
#      Copy-Item C:\Windows\LiveKernelReports\* .\dumps -Recurse -Force
# 2. Run (normal PowerShell):
#      powershell -ExecutionPolicy Bypass -File Get-HangSnapshots.ps1 -Dumps .\dumps
#    Optional, for the driver build column: winget install Microsoft.WinDbg
#
# How the program/engine columns are read: every WATCHDOG-*.dmp (stop code 0x141
# VIDEO_ENGINE_TIMEOUT_DETECTED, or 0x117) carries the TDR record that dxgkrnl wrote.
# Bugcheck parameter 4 is the EPROCESS of the process whose work timed out. In the
# record, that pointer is preceded by six 32-bit values; the fifth is the bitmask of the
# engines that timed out, and the pointer is followed by the process's 15-character
# image name. Engine bits are the node ordinals Task Manager shows ("GPU Engine"
# counters): on the RX 9070 XT, bit 0 (value 1) = 3D and bit 7 (value 128) = Video Codec.
# The layout was read from these dumps, not from Microsoft documentation, so check it
# against Task Manager's engine list on your own card.
param(
    [string]$Dumps = (Join-Path $PSScriptRoot 'dumps'),
    [string]$Out = (Join-Path $PSScriptRoot 'hang-snapshots.csv')
)

Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text;
public static class TdrRecord {
  public static string[] Read(string path) {
    byte[] b = File.ReadAllBytes(path);
    if (Encoding.ASCII.GetString(b, 0, 8) != "PAGEDU64") return new string[] { "not a kernel dump", "", "" };
    uint code = BitConverter.ToUInt32(b, 0x38); ulong p4 = BitConverter.ToUInt64(b, 0x58);
    string proc = "", mask = "";
    if (p4 != 0) {
      byte[] pat = BitConverter.GetBytes(p4);
      for (int i = 0x2000; i + 40 < b.Length && proc == ""; i++) {
        bool m = true; for (int k = 0; k < 8; k++) if (b[i + k] != pat[k]) { m = false; break; }
        if (!m) continue;
        int j = i + 8, z = 0; while (z < 8 && b[j] == 0) { j++; z++; }
        var sb = new StringBuilder(); while (sb.Length < 16 && b[j] >= 0x20 && b[j] < 0x7F) { sb.Append((char)b[j]); j++; }
        if (sb.Length >= 3 && b[j] == 0 && i >= 24) { proc = sb.ToString(); mask = BitConverter.ToUInt32(b, i - 24 + 16).ToString(); }
      }
    }
    return new string[] { "0x" + code.ToString("X"), proc, mask };
  }
}
'@

$kd = $null
$pkg = Get-AppxPackage -Name 'Microsoft.WinDbg' -ErrorAction SilentlyContinue
if ($pkg) { $kd = Join-Path $pkg.InstallLocation 'amd64\kd.exe' }
$sym = Join-Path $env:TEMP 'symbols'

$watchdog = Get-ChildItem $Dumps -Recurse -Filter 'WATCHDOG-*.dmp' | Sort-Object Name
if (-not $watchdog) { throw "no WATCHDOG-*.dmp under $Dumps" }
$rows = foreach ($f in $watchdog) {
    if ($f.BaseName -notmatch '(\d{8})-(\d{4})$') { continue }
    $stamp = "$($Matches[1])-$($Matches[2])"
    $t = [TdrRecord]::Read($f.FullName)
    $cs = ''; $sz = ''
    if ($kd) {
        $log = Join-Path $env:TEMP "lm_$stamp.txt"
        & $kd -z $f.FullName -y "srv*$sym*https://msdl.microsoft.com/download/symbols" -logo $log -c 'lmvm amdkmdag; q' | Out-Null
        $txt = (Get-Content $log -ErrorAction SilentlyContinue) -join "`n"
        if ($txt -match 'CheckSum:\s+(\S+)') { $cs = $Matches[1] }
        if ($txt -match 'ImageSize:\s+(\S+)') { $sz = $Matches[1] }
        Remove-Item $log -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{
        time               = [datetime]::ParseExact($stamp, 'yyyyMMdd-HHmm', $null).ToString('yyyy-MM-dd HH:mm')
        stop_code          = $t[0]
        amd_watchdog_fired = [bool](Get-ChildItem $Dumps -Recurse -Filter "AMD_WATCHDOG-$stamp.dmp")
        program_on_engine  = $t[1]
        engine_mask        = $t[2]
        amdkmdag_checksum  = $cs
        amdkmdag_size      = $sz
    }
}
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 $Out
$rows | Format-Table -AutoSize
"$(@($rows).Count) hangs -> $Out"
