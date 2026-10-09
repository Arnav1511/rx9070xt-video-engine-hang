# Video-engine (VCN) stress test for AMD Radeon cards on Windows.
#
# Loads only the card's video codec engine, through AMD's AMF encoder and D3D11 decoder:
#   steady - one never-ending H.264 encode, flat out (a stream that never stops)
#   decode - continuous 1440p HEVC hardware decode, flat out (watching a stream)
#   churn  - real-time encoder sessions opened and closed every 15-90 s with a random
#            codec (H.264/HEVC/AV1), AMF usage mode and bitrate (streams starting,
#            stopping and changing quality)
# Stops at the time limit or as soon as Windows logs a GPU hang (LiveKernelEvent).
# The log is written through to disk, so it survives a hard reset.
#
# Needs ffmpeg with AMF support (winget install Gyan.FFmpeg). Run in a normal PowerShell:
#   powershell -ExecutionPolicy Bypass -File vcn-stress.ps1 -Minutes 30
# -Adapter is the DXGI adapter index of the card to test (0 is usually the card your
# main monitor is plugged into). The script prints the adapter list at start.
param([double]$Minutes = 30, [int]$Adapter = 0, [string]$LogDir = (Join-Path $PSScriptRoot 'logs'))

$ErrorActionPreference = 'Stop'
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ff) { $ff = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter 'ffmpeg.exe' -Recurse -Depth 6 -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
if (-not $ff) { throw 'ffmpeg not found. Install it with: winget install Gyan.FFmpeg' }

New-Item -ItemType Directory -Force $LogDir | Out-Null
$start = Get-Date
$end = $start.AddMinutes($Minutes)
$logStream = New-Object IO.FileStream((Join-Path $LogDir ("stress_{0:yyyyMMdd_HHmmss}.log" -f $start)), 'Append', 'Write', 'ReadWrite', 4096, 'WriteThrough')
function Log([string]$msg) {
    $b = [Text.Encoding]::UTF8.GetBytes(("{0:yyyy-MM-dd HH:mm:ss} {1}`r`n" -f (Get-Date), $msg))
    $logStream.Write($b, 0, $b.Length); $logStream.Flush($true)
    Write-Host $msg
}

$hw = "-hide_banner -nostats -loglevel error -init_hw_device d3d11va=dx:$Adapter -hwaccel d3d11va -hwaccel_device dx -hwaccel_output_format d3d11"

# Test clips are made once with the card's own encoder.
$src1080 = Join-Path $PSScriptRoot 'src_1080p60_h264.mp4'
$src1440 = Join-Path $PSScriptRoot 'src_1440p60_hevc.mp4'
foreach ($c in @(@($src1080, '1920x1080', 'h264_amf', '12M'), @($src1440, '2560x1440', 'hevc_amf', '20M'))) {
    if (Test-Path $c[0]) { continue }
    & $ff -hide_banner -loglevel error -y -init_hw_device "d3d11va=dx:$Adapter" -f lavfi -i "testsrc2=size=$($c[1]):rate=60,noise=alls=10:allf=t" -t 20 -filter_hw_device dx -vf 'format=nv12,hwupload' -c:v $c[2] -b:v $c[3] $c[0]
    if ($LASTEXITCODE -ne 0) { throw "could not create $($c[0]) with $($c[2]) on adapter $Adapter" }
}

function Start-Ff([string]$name, [string]$ffArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo $ff, $ffArgs
    $psi.UseShellExecute = $false; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Name = $name; Proc = $p; Err = $p.StandardError.ReadToEndAsync(); Args = $ffArgs; Started = Get-Date }
}
function Stop-All($workers) {
    foreach ($w in $workers) { if ($w -and -not $w.Proc.HasExited) { try { $w.Proc.Kill() } catch {} } }
    foreach ($w in $workers) { if ($w) { $w.Proc.WaitForExit(10000) | Out-Null } }
}

# steady and decode run flat out (about 8x real time), so ffmpeg's -t, which counts
# video time, is set far beyond the test; the loop below stops them. Churn sessions
# use -re to run in real time like a live stream, so their -t is wall time and each
# one closes its encoder cleanly.
$steadyArgs = "$hw -stream_loop -1 -i `"$src1080`" -t 360000 -c:v h264_amf -usage lowlatency -rc cbr -b:v 8M -f null -"
$decodeArgs = "$hw -stream_loop -1 -i `"$src1440`" -t 360000 -f null -"
$codecs = 'h264_amf', 'hevc_amf', 'av1_amf'
$usages = 'lowlatency', 'transcoding', 'ultralowlatency'
$rng = New-Object Random

Log "START minutes=$Minutes adapter=$Adapter ffmpeg=$((& $ff -version | Select-Object -First 1) -replace 'Copyright.*','')"
Get-CimInstance Win32_VideoController | ForEach-Object { Log "gpu: $($_.Name) driver=$($_.DriverVersion) ($($_.DriverDate.ToString('yyyy-MM-dd')))" }
$amf = Join-Path (Split-Path $ff) 'amfrt64.dll'
Log ("AMF runtime used: " + $(if (Test-Path $amf) { "$amf (next to ffmpeg)" } else { "$env:WINDIR\System32\amfrt64.dll, $((Get-Item "$env:WINDIR\System32\amfrt64.dll").Length) bytes, written $((Get-Item "$env:WINDIR\System32\amfrt64.dll").LastWriteTime.ToString('yyyy-MM-dd'))" }))

$steady = Start-Ff 'steady' $steadyArgs; Log "steady started pid=$($steady.Proc.Id)"
$decode = Start-Ff 'decode' $decodeArgs; Log "decode started pid=$($decode.Proc.Id)"
$churn = $null; $churnEnd = Get-Date
$sessions = 0; $failures = 0; $hang = $false
$lastCheck = $start.AddSeconds(-5)

while ((Get-Date) -lt $end) {
    if (-not $churn -or $churn.Proc.HasExited -or (Get-Date) -ge $churnEnd) {
        if ($churn -and -not $churn.Proc.HasExited) { Log "churn #$sessions did not finish on time, killed"; try { $churn.Proc.Kill() } catch {}; $churn.Proc.WaitForExit(5000) | Out-Null }
        elseif ($churn -and $churn.Proc.ExitCode -ne 0) { $failures++; Log "churn FAILED exit=$($churn.Proc.ExitCode) args=[$($churn.Args)] stderr=[$($churn.Err.Result.Trim() -replace '\s+',' ')]" }
        $codec = $codecs[$rng.Next($codecs.Count)]; $usage = $usages[$rng.Next($usages.Count)]
        $src = if ($rng.Next(2) -eq 0) { $src1080 } else { $src1440 }
        $rate = 3 + $rng.Next(18); $dur = 15 + $rng.Next(76)
        $churn = Start-Ff 'churn' "$hw -re -stream_loop -1 -i `"$src`" -t $dur -c:v $codec -usage $usage -rc cbr -b:v ${rate}M -f null -"
        $churnEnd = (Get-Date).AddSeconds($dur + 15); $sessions++
        Log ("churn #{0} {1} usage={2} {3}M {4}s src={5}" -f $sessions, $codec, $usage, $rate, $dur, (Split-Path $src -Leaf))
    }
    foreach ($n in 'steady', 'decode') {
        $w = Get-Variable -Name $n -ValueOnly
        if ($w.Proc.HasExited -and (Get-Date) -lt $end.AddSeconds(-10)) {
            $failures++
            Log "$n EXITED early exit=$($w.Proc.ExitCode) after $([int]((Get-Date) - $w.Started).TotalSeconds)s stderr=[$($w.Err.Result.Trim() -replace '\s+',' ')]"
            Set-Variable -Name $n -Value (Start-Ff $n $(if ($n -eq 'steady') { $steadyArgs } else { $decodeArgs }))
        }
    }
    if (((Get-Date) - $lastCheck).TotalSeconds -ge 10) {
        $since = $lastCheck; $lastCheck = Get-Date
        # Windows re-files the previous crash's dump after a reboot; only dumps named with
        # a time inside this run count.
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'LiveKernelEvent' -and $_.Message -match '-(\d{8})-(\d{4})\.dmp' -and
                [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmm', $null) -ge $start.AddSeconds(-$start.Second) }
        if ($ev) {
            foreach ($e in $ev) { $m = $e.Message -replace '\s+', ' '; Log ("GPU HANG REPORTED at {0:HH:mm:ss}: {1}" -f $e.TimeCreated, $m.Substring(0, [math]::Min(300, $m.Length))) }
            $hang = $true; break
        }
    }
    Start-Sleep -Milliseconds 1000
}

Stop-All @($steady, $decode, $churn)
$mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
Log "END after $mins min: churn sessions=$sessions failures=$failures hang=$hang"
Log $(if ($hang) { "RESULT: VIDEO ENGINE HANG after $mins min" } else { "RESULT: PASSED $Minutes min, no hang" })
$logStream.Close()
