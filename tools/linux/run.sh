#!/usr/bin/env bash
# Video-engine stress test for the RX 9070 XT, Linux edition.
# Same load as vcn-stress.ps1 on Windows, but through a completely different stack:
# the open-source amdgpu kernel driver, Mesa's VA-API encoder and Linux's own copy
# of the card's video firmware. The only thing shared with Windows is the card.
#   hangs here too   -> the card's video engine (hardware)
#   clean for 60 min -> AMD's Windows driver
# Run from the folder it lives in:  bash run.sh        (optional: bash run.sh 30  for 30 minutes)
set -u
MINUTES="${1:-60}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SRC_DIR:-$HERE/../windows}"   # clips made by the Windows test, if present
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$HERE/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
if ! touch "$LOG_DIR/.write-test" 2>/dev/null; then
  LOG_DIR="$HOME/vcn-logs"; mkdir -p "$LOG_DIR"
  echo "!! The Windows drive is read-only here, so the log goes to $LOG_DIR (lost at reboot)."
  echo "!! Take a phone photo of the final RESULT lines."
fi
rm -f "$LOG_DIR/.write-test"
LOG="$LOG_DIR/linux_stress_$STAMP.log"
KLOG="$LOG_DIR/linux_kernel_$STAMP.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; sync -f "$LOG" 2>/dev/null; }
banner() { echo; echo "=================================================================="; echo "  $*"; echo "=================================================================="; echo; }

banner "Radeon video engine test (Linux) - ${MINUTES} minutes"
log "START minutes=$MINUTES kernel=$(uname -r)"

# --- tools -------------------------------------------------------------------
if ! command -v ffmpeg >/dev/null || ! command -v vainfo >/dev/null; then
  log "installing ffmpeg + vainfo (needs internet)..."
  sudo apt-get update -qq >/dev/null 2>&1
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg vainfo mesa-va-drivers >/dev/null 2>&1; then
    log "FAILED to install ffmpeg. Is the network cable plugged in? Then run: bash run.sh"; exit 1
  fi
fi
log "ffmpeg: $(ffmpeg -hide_banner -version | head -n1)"
log "mesa: $(dpkg-query -W -f='${Version}' mesa-va-drivers 2>/dev/null)"

# --- find the card to test by PCI device id, not the CPU's built-in graphics ----
# 0x7550 = Navi 48 (RX 9070 / 9070 XT). Other cards: PCI_ID=0x.... bash run.sh
PCI_ID="${PCI_ID:-0x7550}"
NODE=""; DEV=""
for r in /sys/class/drm/renderD*; do
  if grep -qi "$PCI_ID" "$r/device/device" 2>/dev/null; then NODE="/dev/dri/$(basename "$r")"; DEV="$r/device"; fi
done
if [ -z "$NODE" ]; then log "RX 9070 XT render node not found:"; ls -l /sys/class/drm/ | tee -a "$LOG"; exit 1; fi
HWMON="$(ls -d "$DEV"/hwmon/hwmon* 2>/dev/null | head -n1)"
log "card: $(cat "$DEV/vendor") $(cat "$DEV/device") node=$NODE vbios=$(cat "$DEV/vbios_version" 2>/dev/null)"
sudo dmesg 2>/dev/null | grep -i -E 'amdgpu.*(vcn|firmware|fw version)' | tail -n 8 >> "$LOG"
vainfo --display drm --device "$NODE" 2>/dev/null | grep -E 'Driver version|VAEntrypointEncSlice' | tee -a "$LOG"

# --- source clips in RAM: reuse the Windows ones if present, else make them here --
S1080=/tmp/src_1080p60_h264.mp4; S1440=/tmp/src_1440p60_hevc.mp4
HW="-hide_banner -nostats -loglevel error -init_hw_device vaapi=va:$NODE -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi"
for spec in "src_1080p60_h264.mp4 1920x1080 h264_vaapi 12M" "src_1440p60_hevc.mp4 2560x1440 hevc_vaapi 20M"; do
  set -- $spec
  if [ -f "$SRC_DIR/$1" ]; then cp "$SRC_DIR/$1" "/tmp/$1"; continue; fi
  ffmpeg -hide_banner -loglevel error -y -init_hw_device vaapi=va:"$NODE" -f lavfi -i "testsrc2=size=$2:rate=60,noise=alls=10:allf=t" \
    -t 20 -filter_hw_device va -vf 'format=nv12,hwupload' -c:v "$3" -b:v "$4" "/tmp/$1" || { log "could not make $1 with $3"; exit 1; }
  log "made $1 with $3"
done

# --- quick check of each encoder; drop any this card/driver cannot do -----------
CODECS=()
for c in h264_vaapi hevc_vaapi av1_vaapi; do
  start=$(date +%s%3N)
  if ffmpeg $HW -i "$S1080" -t 5 -c:v "$c" -rc_mode CBR -b:v 8M -f null - >/tmp/chk.txt 2>&1; then
    log "check $c ok: 300 frames in $(( $(date +%s%3N) - start )) ms"; CODECS+=("$c")
  else
    log "check $c FAILED: $(tr '\n' ' ' </tmp/chk.txt | cut -c1-200)"
  fi
done
[ ${#CODECS[@]} -gt 0 ] || { log "no hardware encoder works, cannot test"; exit 1; }

# --- kernel watcher: any amdgpu timeout or reset ends the test ------------------
sudo dmesg -W > "$KLOG" 2>&1 &
KPID=$!
hang_lines() { grep -i -E 'amdgpu.*(timeout|timed out|reset|hang|ring .*fail|page fault|vcn.*err)|drm.*(timeout|reset)' "$KLOG" 2>/dev/null; }

PIDS=()
cleanup() { for p in "${PIDS[@]}" ${STEADY:-} ${DECODE:-} ${CHURN:-}; do kill "$p" 2>/dev/null; done; sudo kill "$KPID" 2>/dev/null; }
trap 'cleanup; log "stopped by user"; exit 130' INT TERM

start_steady() { ffmpeg $HW -stream_loop -1 -i "$S1080" -t 360000 -c:v h264_vaapi -rc_mode CBR -b:v 8M -progress /tmp/steady.progress -f null - 2>>"$LOG_DIR/ffmpeg_$STAMP.err" & STEADY=$!; }
start_decode() { ffmpeg $HW -stream_loop -1 -i "$S1440" -t 360000 -f null - 2>>"$LOG_DIR/ffmpeg_$STAMP.err" & DECODE=$!; }
start_steady; log "steady started pid=$STEADY (h264, flat out)"
start_decode; log "decode started pid=$DECODE (1440p hevc, flat out)"

END=$(( $(date +%s) + MINUTES * 60 ))
CHURN=""; CHURN_END=0; N=0; HANG=0; LAST_STATUS=0
while [ "$(date +%s)" -lt "$END" ]; do
  now=$(date +%s)
  # churn: a new real-time session every 15-90 s with random codec/bitrate/source
  if [ -z "$CHURN" ] || ! kill -0 "$CHURN" 2>/dev/null || [ "$now" -ge "$CHURN_END" ]; then
    [ -n "$CHURN" ] && kill "$CHURN" 2>/dev/null
    c=${CODECS[$((RANDOM % ${#CODECS[@]}))]}; rate=$((3 + RANDOM % 18)); dur=$((15 + RANDOM % 76))
    if [ $((RANDOM % 2)) -eq 0 ]; then src=$S1080; else src=$S1440; fi
    ffmpeg $HW -re -stream_loop -1 -i "$src" -t "$dur" -c:v "$c" -rc_mode CBR -b:v "${rate}M" -f null - 2>>"$LOG_DIR/ffmpeg_$STAMP.err" &
    CHURN=$!; CHURN_END=$((now + dur + 15)); N=$((N + 1))
    log "churn #$N $c ${rate}M ${dur}s $(basename "$src")"
  fi
  kill -0 "$STEADY" 2>/dev/null || { log "steady EXITED, restarting"; start_steady; }
  kill -0 "$DECODE" 2>/dev/null || { log "decode EXITED, restarting"; start_decode; }
  # status line every 30 s
  if [ $((now - LAST_STATUS)) -ge 30 ]; then
    LAST_STATUS=$now
    t() { [ -n "$HWMON" ] && for i in 1 2 3; do l=$(cat "$HWMON/temp${i}_label" 2>/dev/null); v=$(cat "$HWMON/temp${i}_input" 2>/dev/null); [ -n "$v" ] && printf '%s=%sC ' "$l" $((v / 1000)); done; }
    fps=$(grep '^fps=' /tmp/steady.progress 2>/dev/null | tail -n1 | cut -d= -f2)
    log "status: $(t)busy=$(cat "$DEV/gpu_busy_percent" 2>/dev/null)% steady_fps=$fps elapsed=$(( (now - (END - MINUTES * 60)) / 60 ))min"
  fi
  if hang_lines >/dev/null; then HANG=1; break; fi
  sleep 1
done

cleanup
sleep 2
ELAPSED=$(( ( $(date +%s) - (END - MINUTES * 60) ) / 60 ))
if [ "$HANG" -eq 1 ]; then
  log "KERNEL REPORTED A GPU PROBLEM after ${ELAPSED} min:"
  hang_lines | head -n 30 | tee -a "$LOG"
  sudo dmesg | tail -n 80 >> "$LOG"
  banner "RESULT: VIDEO ENGINE HANG ON LINUX after ${ELAPSED} min ($N sessions). Log: $LOG"
else
  log "no GPU timeouts or resets in ${MINUTES} min ($N churn sessions)"
  banner "RESULT: PASSED ${MINUTES} min on Linux, no hang ($N sessions). Log: $LOG"
fi
log "END hang=$HANG"
sync
