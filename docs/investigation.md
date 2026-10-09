# Investigation notes

How each piece of evidence in the README was obtained, so it can be checked or repeated.

## 1. Event logs

- `System`: 33 `Kernel-Power 41` (unexpected shutdown) between 28 July and 9 October 2026,
  all with `BugcheckCode 0`. No WHEA hardware errors, no bluescreens. On this board the
  PCIe root port reports no AER (`DEVPKEY_PciDevice_Error_Reporting = 0`), so a missing
  WHEA event clears the CPU, not the PCIe link.
- `Application`, `Windows Error Reporting` 1001, event name `LiveKernelEvent`: 157 reports
  from 12 June. Each names the dump it attached. Windows re-files the previous crash's dump
  after the next boot, so reports must be grouped by dump file name, not counted.
- Fault buckets seen: `LKD_0x141_Tdr:6_IMAGE_amdkmdag.sys-PF:1-HWS:1-GRE=3202c`,
  `LKD_0xA1000001_amdfendr!…ReportLiveKernelDump`, `LKD_0xA2000002_amdfendr!…`,
  `LKD_0x117_Tdr:9_…-V-GRE=3202c`, `LKD_0x193_DxgkrnlLiveDump:801_Status_0xC0000001_Driver_amdkmdag_…_failed_DdiAddDevice`.
  `amdfendr` is AMD Crash Defender. `HWS:1` = hardware-accelerated GPU scheduling on.

## 2. Which engine hung, and whose work was on it

Copy the dumps (admin): `Copy-Item C:\Windows\LiveKernelReports\* <dir> -Recurse`.

`WinDbg !analyze -v` on a `WATCHDOG-*.dmp` gives `VIDEO_ENGINE_TIMEOUT_DETECTED (141)` with
Arg4 = the EPROCESS of the process whose work timed out (sample outputs in
[results/windbg](../results/windbg)). The dumps are "mini kernel dumps"; the
`dxgkrnl!_TDR_RECOVERY_CONTEXT` type is not in public symbols, so the record was read
directly from the file:

- search the dump for the 8 bytes of Arg4;
- the 15-character process image name follows it (after zero padding);
- the 24 bytes before it are six 32-bit values; on these dumps they were always
  `3 2 5 0 <mask> 0`, and the fifth value is the bitmask of engines that timed out.

The masks seen were only `1` and `128`. Mapping them to engines uses the node ordinals
Windows exposes in the `GPU Engine` performance counters (what Task Manager shows). On this
RX 9070 XT: engine 0 = `3D`, engine 7 = `Video Codec`. A cross-check: in the stress-test hang
of 9 October 03:58 the only program using the video engine was `ffmpeg.exe` (90% video,
1% 3D in the logger), and the dump records `ffmpeg.exe` with mask `128`.

Tool: [tools/analysis/Get-HangSnapshots.ps1](../tools/analysis/Get-HangSnapshots.ps1).

## 3. Which driver build was loaded at each hang

`kd -z <dump> -c "lmvm amdkmdag"` lists the module. AMD stamps a fixed fake timestamp
(1975), so builds are told apart by `CheckSum` and `ImageSize`:

| Build (checksum / size) | Seen | Matches | `0x141` hangs | of which fatal video-engine |
|---|---|---|---|---|
| `06B43DF3` / `06BC4000` | 23 Mar – 11 Apr | 26.2.x (26.2.2 installer downloaded 8 Mar) | 15 | **0** (all 15 are 3D) |
| `05026E89` / `050B5000` | 17 May – 3 Jun | 26.5.2 (installer downloaded 17 May) | 8 | 8 |
| `05048837` / `050D7000` | 12 – 22 Jun | unnamed (no installer kept; likely 26.6.x via AMD Software update) | 8 | 8 |
| `0504390C` / `050D8000` | 29 Jun | unnamed | 1 | 1 |
| `0504B0AC` / `050D9000` | 8 – 29 Jul | unnamed | 6 | 5 |
| `0509722E` / `05127000` | 30 Jul – Aug | 26.7.1 (downloaded 29 Jul) | 11 | 9 |
| `0508CC9B` / `05126000` | 30 Aug – 9 Oct | 26.8.1 = `32.0.31041.1004` (verified on disk) | 17 | 12 |
| `06B49EE8` / `06BCF000` | 9 Oct tests | 26.2.2 = `32.0.23027.2005` (verified on disk) | | |

The follow-up dumps written at boot after a failed recovery (`0x193`, `0x1B0`, `0x1A8`) show
other `amdkmdag` builds around `0x061F7000`–`0x0627F000` in size. Those are the CPU's
integrated Radeon graphics driver (`32.0.21045.5002` on disk has `06207FBA` / `0627F000`):
at those boots the RX 9070 XT's driver had not loaded. Full table:
[results/hang-snapshots.csv](../results/hang-snapshots.csv).

The 26.2.2 installed for testing is the same family as the March build but not
byte-identical, so it may be a different 26.2.x point release.

## 4. What the card was doing when it hung

[tools/windows/gpu-watch](../tools/windows/gpu-watch) logs every 2 s with forced writes.
It reads temperature and fan through `D3DKMTQueryAdapterInfo` (no admin needed), hotspot,
memory temperature, voltage, clock and PCIe link through AMD's ADL (`ADL2_New_QueryPMLogData_Get`),
and per-engine utilisation with the owning process from the `GPU Engine` counters. A sampler
thread talks to the driver while a separate writer thread never does, so a hung driver shows
up as a growing `gpu_age_s` while the heartbeat continues.

Two traps found on the way:
- After a hang that Windows "recovers", the `GPU Engine` 3D counters read zero for the rest of
  the session.
- ADL's PMLog sensor 40 (`bus_speed`) is an index: `3` means PCIe 4.0 here, not 3.0.
  `ADL2_Adapter_ChipSetInfo_Get` reports the generation directly (`busSpeedType` 5 = Gen 4).

The four excerpts in [results/logger-excerpts](../results/logger-excerpts) all show the same
shape for a video-engine hang: video load collapses, two operating-system stalls of 2–6 s
while Windows tries to recover, AMD's own load sensor frozen at 100%, then the card
disappears from the driver (VRAM in use drops to ~16 MB) about 25 s later. The heartbeat
keeps going until the user powers off.

## 5. Why the card is disabled after the reboot

The card's key under `HKLM\SYSTEM\CurrentControlSet\Enum\PCI\VEN_1002&DEV_7550…` gets
`ConfigFlags = 1` (disabled). Its last-write time was the second the card vanished from the
logger, during the failed recovery, with Windows still running, not during the next boot.
A plain failed TDR leaves code 43, not a persistent disable, so this is presumably AMD Crash
Defender switching the card off so the next boot comes up on the basic display driver.

## 6. Stress test design

[tools/windows/vcn-stress.ps1](../tools/windows/vcn-stress.ps1) runs three ffmpeg jobs on the
card (selected by DXGI adapter index; frames stay on the GPU as D3D11 textures):

- steady: H.264 AMF encode of a 1080p60 clip, flat out (about 8× real time);
- decode: HEVC 1440p60 D3D11VA decode, flat out;
- churn: a new real-time (`-re`) session every 15–90 s, random codec (H.264/HEVC/AV1), AMF
  usage (`lowlatency`, `transcoding`, `ultralowlatency`) and bitrate (3–20 Mbit/s).

Together they hold the video engine at about 90–97%. The test stops at the first
`LiveKernelEvent` whose dump time falls inside the run. The card stays near idle power and
51–54 °C throughout, which rules out heat and power delivery as the trigger.

## 7. Timeline

| Date (2026) | Event |
|---|---|
| 8 Mar | card installed; Adrenalin 26.2.2 |
| 23 Mar – 11 Apr | 16 engine hangs: 3D engine in games or their follow-ups, all recovered; plus one `0x1A8` dxgkrnl black-screen live dump (2 Apr, during that evening's game hangs) |
| 20 Apr | 26.3.1 installed; no engine hangs recorded until 17 May, but one `0x1A8` black-screen live dump on 23 Apr (no TDR, so no engine or process is recorded) |
| 17 May | 26.5.2 installed; first video-engine black screen that night (`0x141` at 23:11, `0x1A8` at 23:12 and 23:15, `0x193` "driver could not start the card" at 23:24) |
| May – Oct | 42 video-engine black screens on 26.5.2, 26.7.1, 26.8.1 |
| 9 Oct | stress test reproduces it on 26.8.1 (12, 16 min); see README for the driver A/B |
