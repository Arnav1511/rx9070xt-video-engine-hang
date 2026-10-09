# RX 9070 XT: video engine (VCN) hang → black screen → card disabled after reboot

**Summary (October 2026, reported to AMD via the Bug Report Tool):** on Adrenalin **26.5.2 through 26.9.2** (every driver newer than 26.3.1 this card has run, including the newest release as of 9 October 2026), the RX 9070 XT's **video codec
engine** hangs under encode/decode load, AMD's recovery fails, the screen goes black and Crash
Defender disables the card. A stress test reproduces it in **6–16 minutes**. On
**Adrenalin 26.2.2** the same test ran **90 minutes across two runs (30 + 60) without a hang**, and the
crash history agrees (26.2.x: 0 video-engine hangs out of 15; 26.5.2–26.8.1: 43 out of 51). Suspected
component: the AMF runtime shipped with the newer packages (one run so far, A/B pending).
Hardware is not fully excluded; see [Open questions](#open-questions). **Workaround:** use
26.2.2, or keep apps off the hardware encoder ([below](#workaround-until-the-cause-is-fixed)).

**Status (9 October 2026):** Adrenalin 26.9.2 (released 29 September, the newest driver) was
tested today and hung after 10.7 minutes, so no release so far fixes it. The test PC goes
back to 26.2.2 for everyday use, with hardware acceleration enabled in Discord, Chrome and
OBS; whether that stays free of hangs will be recorded here.

## Symptom

- Both screens go black, usually while streaming on Discord, watching video in a browser or
  recording with OBS. Games alone run for 12+ hours without a problem.
- Windows keeps running underneath; the PC needs a reset.
- The card's fans get noticeably louder while the screen is black (not full speed). The logger
  shows them at ~690 rpm right up to the hang; after that the driver can no longer read them,
  consistent with the card falling back to its own fan control.
- After the reboot the card is **disabled** (Device Manager, code 22). Enabling it and
  rebooting again brings it back.
- Started about two months after the PC was built, then recurred 5–12 times a month.

## System

| | |
|---|---|
| GPU | Radeon RX 9070 XT (Navi 48, PCI `1002:7550`, subsystem `1DA2:E490`), PCIe 4.0 x16 direct in the slot |
| CPU / board | Ryzen 7 9800X3D, ASUS TUF GAMING B650-PLUS (BIOS 3881) |
| RAM / PSU | 2×16 GB DDR5-6000, Corsair 850 W |
| OS | Windows 11 Pro 26200 (Mar–Sep 2026), 26300 (Oct 2026) |
| Drivers | Adrenalin 26.2.2, 26.3.1, 26.5.2, 26.7.1, 26.8.1 over the period; 26.9.2 for one stress run |

## Findings

**1. Every black screen is a video codec engine hang.** Windows saves a live kernel dump for
each GPU timeout (`C:\Windows\LiveKernelReports\WATCHDOG`). The TDR record inside each dump
names the engine that stopped and the process whose work was on it. The 67 hangs from
23 March to 9 October 2026 (before any stress testing) split cleanly:

| Hangs | Engine | Program on the engine | Outcome |
|---|---|---|---|
| 42 | **Video codec (engine 7)** | Discord 34, Chrome 4, OBS 2, Discord's encoder helper 1, Media Player 1 | AMD watchdog fires, reset fails, **black screen**, card disabled after reboot |
| 1 | Video codec (engine 7) | Discord | recovered (22 July) |
| 22 | 3D (engine 0) | games 20, a system process right after a game hang 2 | reset works, only the game closes (`DXGI_ERROR_DEVICE_HUNG`) |
| 2 | none recorded | `0x117` follow-ups to the hangs above | |

Every black screen was a video-engine hang; no 3D hang ever caused one.

**2. The fatal sequence is always the same.** `0x141 VIDEO_ENGINE_TIMEOUT_DETECTED`
(bucket `Tdr:6 … HWS:1-GRE=3202c`), AMD Crash Defender reports `0xA1000001` / `0xA2000002`
in the same second, the recovery fails (`0x117 … GRE=3202c`), and the card's device key is
marked disabled (`ConfigFlags=1`) while Windows is still running. On the next boot the
driver either cannot start the card (`0x193`, `DdiAddDevice` failed `0xC0000001`) or finds
it disabled (code 22). Details: [docs/investigation.md](docs/investigation.md).

**3. Not heat, power or the PCIe link.** At every captured video-engine hang the card was
at 51–54 °C, near idle power, on a stable PCIe 4.0 x16 link. Windows stays alive throughout
(the logger's heartbeat keeps writing), so it is not a whole-system freeze.

**4. It reproduces with plain ffmpeg, no Discord or browser.** A stress test that loads
only the video engine (AMF encode + D3D11 decode) triggers the identical fatal signature:

| # | Driver | `amfrt64.dll` (AMF runtime) loaded | Result |
|---|---|---|---|
| 1 | 26.8.1 | 26.8.1 | **hang at 12 min** |
| 2 | 26.8.1 | 26.8.1 | **hang at 16 min** |
| 3 | 26.2.2 (clean install) | 26.8.1 (left in System32 by the downgrade) | **hang at 6.4 min** |
| 4 | 26.2.2 | 26.2.2 | **passed 30 min** |
| 5 | 26.2.2 | 26.2.2 | **passed 60 min** (69 sessions, video engine 96% average, max 58 °C) |
| 6 | 26.9.2 (upgrade over 26.2.2; every driver file in System32 and SysWOW64 checked against the package) | 26.9.2 | **hang at 10.7 min** |
| 7 | 26.2.2 | 26.8.1 | planned (A/B) |
| 8 | Linux, amdgpu + Mesa VA-API | n/a | planned |

Run 6 used the newest driver available (released 29 September 2026, a new driver branch,
`32.0.32015.2008`). The video engine was at 92–94% under ffmpeg and the card at 52 °C when
it stopped. The TDR record in the dump names the video codec engine (7) and `ffmpeg.exe`,
as in run 1. Windows filed `0x141 … Tdr:6 … HWS:1-GRE=8094` (earlier builds: `GRE=3202c`) with
Crash Defender's `0xA1000001` / `0xA2000002` in the same second and `0x193` four seconds
later; after the reset the card was disabled (code 22), as before.

Logs: [results/stress-runs](results/stress-runs). Second-by-second logger data around each
hang: [results/logger-excerpts](results/logger-excerpts).

**5. The onset matches a driver update.** Reading the `amdkmdag.sys` build out of every dump
([results/hang-snapshots.csv](results/hang-snapshots.csv)): on 26.2.x, 15 hangs, all 3D and
none on the video engine; on every build from 26.5.2 to 26.8.1, fatal video-engine hangs
(43 of 51 `0x141` dumps, one of them from the first stress test). The first video-engine black screen happened the
night Adrenalin 26.5.2 was installed (17 May 2026). On 26.2.x and 26.3.1 (March to mid-May)
the recorded engine hangs were all recoverable 3D hangs in games. Windows did log two
black-screen detections then (`0x1A8`, 2 and 23 April), which carry no engine record, so
they cannot be classified. Windows stayed on the same build (26200) from March to September,
so the onset in May was not a Windows feature update.

## Open questions

- Runs 3 and 4 differ only in which `amfrt64.dll` was loaded; the kernel driver, firmware
  and every other driver library were 26.2.2 in both. That points at AMD's AMF runtime from
  the newer packages. Run 5 confirmed that clean 26.2.2 holds for a full hour; run 7 (26.2.2
  with only the newer `amfrt64.dll` swapped in) is the remaining test of the AMF runtime.
- Run 8 (Linux) uses a separate driver, encoder library and firmware build. A hang there
  would point at the card itself.
- AMD has acknowledged VCN engine hangs on RDNA3 with HAGS as a factor (see
  [Similar reports](#similar-reports)). A run of 26.8.1 with HAGS off would show whether the
  same workaround applies to RDNA4.
- Is any healthy RX 9070 XT affected? Results from other owners running the test below
  would settle the hardware question. Please [open a "Stress test result" issue](../../issues/new/choose) with your log.

## Reproduce it

> **Warning:** on an affected system this test causes the black screen it is looking for.
> Save your work. Afterwards, enable the card in Device Manager (or, in an admin
> PowerShell, `Get-PnpDevice -FriendlyName '*9070*' | Enable-PnpDevice -Confirm:$false`)
> and reboot.

**Windows**
```powershell
winget install Gyan.FFmpeg
powershell -ExecutionPolicy Bypass -File tools\windows\vcn-stress.ps1 -Minutes 30
```
It prints `RESULT: PASSED` or `RESULT: VIDEO ENGINE HANG after N min` and writes a log to
`tools\windows\logs`. Hangs here happened between 6 and 16 minutes. Close OBS, Discord
streams and browser video while it runs so only the test uses the engine.

**Linux** (live USB is enough, nothing is installed on the disk):
```bash
bash tools/linux/run.sh 60
```
It installs ffmpeg, checks the VA-API encoders and watches the kernel log for amdgpu
timeouts or resets.

## Workaround (until the cause is fixed)

**Option 1:** install Adrenalin **26.2.2** with *Factory Reset* (from AMD's previous-drivers
page; use the full offline installer, the small web installer only offers the current
version). Then check the system folders for files the newer package left behind. Here the
downgrade left eight files from 26.8.1 that matched no installed driver:

- `C:\Windows\System32`: `amfrt64.dll`, `atiadlxx.dll`, `amdadlx64.dll`, `amd_fidelityfx_dx12.dll`
- `C:\Windows\SysWOW64`: `amfrt32.dll`, `atiadlxx.dll`, `atiadlxy.dll`, `amdadlx32.dll`

`amfrt64.dll` / `amfrt32.dll` are the AMF runtime that every hardware-encoding app (Discord,
OBS, browsers) loads, which is how run 3 still hung on 26.2.2. The `atiadl*` files are AMD's
sensor library; with the mismatched copies, monitoring tools lost the card's temperature,
clock, power and fan readings. Replace each with the copy from the installed driver's folder
under `C:\Windows\System32\DriverStore\FileRepository` (the files belong to TrustedInstaller,
so it takes an admin shell and `takeown`; in SysWOW64, `atiadlxx.dll` is a copy of the
package's `atiadlxy.dll`), then reboot. Until that is done, combine this with option 2.
Windows Update and AMD Software will both offer newer drivers again; decline or block them.

**Option 2:** stay on the current driver and keep apps off the card's video engine, so the
CPU encodes and decodes instead:

- **Discord:** Settings → Voice & Video → Video Codec → *Hardware Acceleration* off.
  The general Advanced → Hardware Acceleration switch does **not** stop it.
- **Chrome:** Settings → System → *Use graphics acceleration when available* off.
- **OBS:** Settings → Output → Encoder: x264.
- **AMD Record / Instant Replay, Game Bar recording:** avoid.

Games, frame generation and FSR are unaffected; they use the 3D engine.

## Tools

| | |
|---|---|
| [tools/windows/vcn-stress.ps1](tools/windows/vcn-stress.ps1) | the video-engine stress test (Windows, AMF) |
| [tools/linux/run.sh](tools/linux/run.sh) | the same test on Linux (amdgpu, VA-API) |
| [tools/windows/gpu-watch](tools/windows/gpu-watch) | background logger: temperatures, clocks, per-engine load and the process on it, VRAM, memory commit and network probes every 2 s, written through to disk so the last lines survive a hard reset |
| [tools/analysis/Get-HangSnapshots.ps1](tools/analysis/Get-HangSnapshots.ps1) | reads Windows' GPU hang dumps: stop code, AMD watchdog, engine and program, driver build |

## Discussion

- [r/radeon thread](https://www.reddit.com/r/radeon/comments/1x17ic1/rx_9070_xt_black_screens_on_adrenalin_265_video/)

## Similar reports

- [AMD_Vik (AMD) on r/Amd](https://www.reddit.com/r/Amd/comments/1wtb115/comment/pcu0dvd/), as
  quoted in the r/radeon thread: *"This one (NV3X VCN engine hangs) is still in progress, and
  should be resolved in the next release. Assuming you're on Windows 11, you can disable HAGS
  as a temporary workaround."* That is about RDNA3 (NV3X). Every hang here carries `HWS:1`
  (hardware-accelerated GPU scheduling on), which fits, but 26.2.2 passes the stress test with
  HAGS on, so on RDNA4 HAGS alone is not the cause. Whether turning HAGS off avoids the hang on
  26.5.2–26.9.2 with RDNA4 is untested here.

- [LizardByte/Sunshine#5385](https://github.com/LizardByte/Sunshine/issues/5385): RX 9070 XT
  hangs during AMF encoder session start on Adrenalin 26.6.4, Crash Defender puts the GPU in
  reduced mode; the reporter says it did not happen on 25.9.1.
- [GameGPU, 22 Aug 2026](https://en.gamegpu.com/news/zhelezo/drajver-amd-software-adrenalin-26-8-1-vyzyvaet-sboi-na-radeon-rx-9070-xt):
  RX 9070 XT owners reporting random black screens on 26.8.1 (from Reddit; no AMD comment).

## Privacy

Logs are published with the Windows user name, PC name and paths replaced by placeholders.
The raw kernel dumps are not published because they contain fragments of system memory;
they are available to AMD on request.

## License

MIT, see [LICENSE](LICENSE).
