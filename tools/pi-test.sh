#!/bin/bash
#
# One-command check on real hardware: a Raspberry Pi (or any Linux machine)
# with an RTL-SDR dongle and antenna.
#
#   1. Records a short raw capture at 1090 MHz. If dump1090-fa is running, it
#      is paused for the recording only and restarted straight afterwards.
#   2. Builds this branch and the official code (origin/master).
#   3. Decodes the same recording with both and checks that every output is
#      byte-for-byte identical (tools/compare-builds.sh).
#   4. Times both on the recording, on this machine.
#   5. Writes a short report to send back: <workdir>/pi-test-result.md
#
#   tools/pi-test.sh [options]
#
#   --seconds N        length of the recording (default 120; about 4.8 MB per second)
#   --gain DB          tuner gain for the recording (default: dump1090-fa's current
#                      gain, else RECEIVER_GAIN from /etc/default/dump1090-fa, else 40)
#   --device ID        rtl_sdr device index or serial (default: RECEIVER_SERIAL, else 0)
#   --recording FILE   skip recording and use an existing 2.4 MS/s UC8 capture
#   --rounds N         timing runs per build (default 5; 3 on ARMv6 such as Pi Zero/Pi 1)
#   --pause-feeder     keep dump1090-fa stopped until the timing is done (cleaner
#                      numbers, but your feeder is off for the whole run)
#   --install-deps     install missing packages with apt-get first (asks for sudo)
#   --workdir DIR      where to put the recording, builds and report
#                      (default: ~/dump1090-pi-test)
#
# Exit status: 0 if the outputs match (apart from the intended Mode A/C
# altitude fix), 1 if they differ, 2 for a setup problem.

set -u

TOP=$(cd "$(dirname "$0")/.." && pwd)
SECONDS_TO_RECORD=120
GAIN=
DEVICE=
RECORDING=
ROUNDS=
PAUSE_FEEDER=0
INSTALL_DEPS=0
WORK=$HOME/dump1090-pi-test
SERVICE=dump1090-fa

usage() { sed -n '2,32p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_RECORD=$2; shift 2 ;;
        --gain) GAIN=$2; shift 2 ;;
        --device) DEVICE=$2; shift 2 ;;
        --recording) RECORDING=$(realpath "$2"); shift 2 ;;
        --rounds) ROUNDS=$2; shift 2 ;;
        --pause-feeder) PAUSE_FEEDER=1; shift ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --workdir) WORK=$2; shift 2 ;;
        -h|--help|*) usage ;;
    esac
done

say() { echo "=== $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 2; }

# --- prerequisites ---------------------------------------------------------

missing=()
command -v git >/dev/null || missing+=(git)
{ command -v cc >/dev/null && command -v make >/dev/null; } || missing+=(build-essential)
command -v pkg-config >/dev/null || missing+=(pkg-config)
pkg-config --exists ncurses 2>/dev/null || missing+=(libncurses-dev)
python3 -c 'import numpy' 2>/dev/null || missing+=(python3-numpy)
[ -n "$RECORDING" ] || command -v rtl_sdr >/dev/null || missing+=(rtl-sdr)
if [ ${#missing[@]} -gt 0 ]; then
    if [ $INSTALL_DEPS = 1 ]; then
        say "installing ${missing[*]}"
        sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends "${missing[@]}" || die "package install failed"
    else
        echo "Missing packages. Install them with:" >&2
        echo >&2
        echo "  sudo apt-get install -y ${missing[*]}" >&2
        echo >&2
        echo "or run this script again with --install-deps." >&2
        exit 2
    fi
fi

cd "$TOP"
git rev-parse --git-dir >/dev/null 2>&1 || die "run this from a git clone of the branch"
if ! git rev-parse -q --verify origin/master >/dev/null; then
    say "fetching origin/master (the official code to compare against)"
    git fetch -q origin master:refs/remotes/origin/master || die "could not fetch origin/master"
fi

mkdir -p "$WORK" || die "cannot create $WORK"
WORK=$(realpath "$WORK")
REPORT=$WORK/pi-test-result.md

ARCH=$(uname -m)
if [ -z "$ROUNDS" ]; then
    case "$ARCH" in armv6*) ROUNDS=3 ;; *) ROUNDS=5 ;; esac
fi
SMALL=
case "$ARCH" in armv6*) SMALL=--small ;; esac

# --- recording -------------------------------------------------------------

feeder_was_running=0
feeder_stopped=0
restart_feeder() {
    if [ $feeder_stopped = 1 ]; then
        say "restarting $SERVICE"
        sudo systemctl start "$SERVICE" && feeder_stopped=0
    fi
}
trap 'restart_feeder' EXIT
trap 'restart_feeder; exit 130' INT TERM

RECORD_LOG=$WORK/rtl_sdr.log
recorded_here=0
if [ -z "$RECORDING" ]; then
    recorded_here=1
    RECORDING=$WORK/capture-$(date +%Y%m%d-%H%M%S).iq
    SAMPLES=$((SECONDS_TO_RECORD * 2400000))
    need_kb=$((SAMPLES * 2 / 1024 + 400 * 1024))
    free_kb=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
    [ "$free_kb" -ge "$need_kb" ] || die "not enough free space in $WORK: need about $((need_kb / 1024)) MB, have $((free_kb / 1024)) MB (try --seconds 60)"

    defaults=/etc/default/dump1090-fa
    if [ -z "$GAIN" ] && [ -r /run/dump1090-fa/stats.json ]; then
        GAIN=$(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
for period in ("last1min", "latest", "total"):
    g = s.get(period, {}).get("local", {}).get("gain_db")
    if g is not None:
        print(g); break
' /run/dump1090-fa/stats.json 2>/dev/null)
        [ -n "$GAIN" ] && say "using dump1090-fa's current gain: $GAIN dB"
    fi
    if [ -z "$GAIN" ] && [ -r "$defaults" ]; then
        GAIN=$(. "$defaults" 2>/dev/null; echo "${RECEIVER_GAIN:-}")
        [ -n "$GAIN" ] && say "using RECEIVER_GAIN from $defaults: $GAIN dB"
    fi
    [ -n "$GAIN" ] || GAIN=40
    # rtl_sdr picks the nearest supported gain; the R820T maximum is 49.6 dB.
    # A negative gain means the tuner's automatic gain, which rtl_sdr calls 0.
    GAIN=$(python3 -c 'import sys; g = float(sys.argv[1]); print(0 if g < 0 else min(g, 49.6))' "$GAIN") || die "bad gain '$GAIN'"
    [ "$GAIN" = 0 ] && say "recording with the tuner's automatic gain"
    if [ -z "$DEVICE" ] && [ -r "$defaults" ]; then
        DEVICE=$(. "$defaults" 2>/dev/null; echo "${RECEIVER_SERIAL:-}")
    fi
    [ -n "$DEVICE" ] || DEVICE=0

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        feeder_was_running=1
        say "pausing $SERVICE so the dongle is free (it restarts after the recording)"
        sudo systemctl stop "$SERVICE" || die "could not stop $SERVICE"
        feeder_stopped=1
        sleep 2
    fi

    say "recording $SECONDS_TO_RECORD s at 1090 MHz, 2.4 MS/s, gain $GAIN dB, device $DEVICE"
    rtl_sdr -d "$DEVICE" -f 1090000000 -s 2400000 -g "$GAIN" -n "$SAMPLES" "$RECORDING" > "$RECORD_LOG" 2>&1
    rc=$?
    [ $PAUSE_FEEDER = 1 ] || restart_feeder
    if [ $rc != 0 ] || [ ! -s "$RECORDING" ]; then
        cat "$RECORD_LOG" >&2
        rm -f "$RECORDING"
        die "rtl_sdr failed (is another program using the dongle?)"
    fi
else
    [ -s "$RECORDING" ] || die "$RECORDING is missing or empty"
    : > "$RECORD_LOG"
    if [ $PAUSE_FEEDER = 1 ] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        feeder_was_running=1
        sudo systemctl stop "$SERVICE" && feeder_stopped=1
    fi
fi

# --- compare and time ------------------------------------------------------

say "building both versions and comparing (this takes a while on a Pi; your feeder is $( [ $feeder_stopped = 1 ] && echo paused || echo running ))"
# shellcheck disable=SC2086
tools/compare-builds.sh --base origin/master --iq "$RECORDING" --timing "$ROUNDS" $SMALL --workdir "$WORK/compare" > "$WORK/compare.log" 2>&1
STATUS=$?
restart_feeder

# --- report ----------------------------------------------------------------

model=
[ -r /proc/device-tree/model ] && model=$(tr -d '\0' < /proc/device-tree/model)
[ -n "$model" ] || model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
throttled=$(vcgencmd get_throttled 2>/dev/null || true)
dongle=$(grep -E '^ *[0-9]+: |Found .* tuner' "$RECORD_LOG" 2>/dev/null | sed 's/^ *//' | paste -sd ';' - | sed 's/;/; /g' || true)
lost=$(grep -ci 'lost' "$RECORD_LOG" 2>/dev/null || true)

{
    echo "## dump1090-fa real-hardware check"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Result | $( [ $STATUS = 0 ] && echo 'PASS: outputs match' || echo '**FAIL: outputs differ or the build failed**' ) |"
    echo "| Machine | ${model:-unknown} ($ARCH, $(nproc) CPUs) |"
    echo "| OS | $os, kernel $(uname -r) |"
    [ -n "$throttled" ] && echo "| Throttling | $throttled (0x0 means none) |"
    echo "| Branch | $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD) |"
    echo "| Feeder during timing | $( [ $PAUSE_FEEDER = 1 ] && echo paused || { [ $feeder_was_running = 1 ] && echo 'running (timings include its load on both builds)' || echo 'not running'; } ) |"
    [ -n "$dongle" ] && echo "| Dongle | $dongle |"
    echo
    python3 - "$RECORDING" "$WORK/compare/head/out/recording_fix2_modeac/messages.txt" "${GAIN:-}" "$lost" <<'EOF'
import os, re, sys
import numpy as np
path, msgs, gain, lost = sys.argv[1:5]
size = os.path.getsize(path)
print('### Recording\n')
print('| | |')
print('|---|---|')
print(f'| Length | {size / 2 / 2.4e6:.1f} s ({size / 1e6:.0f} MB) |')
if gain:
    print(f'| Gain | {gain} dB |')
if lost and lost != '0':
    print(f'| Dropped samples | rtl_sdr reported losses {lost} times (the comparison is still valid) |')
x = np.memmap(path, dtype=np.uint8, mode='r')
step = max(1, len(x) // 2 // 4000000)  # look at up to ~4M samples
iq = np.asarray(x[: len(x) // 2 * 2]).reshape(-1, 2)[::step].astype(np.float32) - 127.4
mag = np.hypot(iq[:, 0], iq[:, 1])
clip = np.mean((iq <= -127.4) | (iq >= 127.6)) * 100
print(f'| Signal | median magnitude {np.median(mag):.1f} counts, 99.9th percentile {np.percentile(mag, 99.9):.0f}, {clip:.3f}% of values at the limits |')
try:
    text = open(msgs).read()
    blocks = text.split('\n\n')
    modes = [b for b in blocks if re.search(r'^DF:(\d+)', b, re.M) and not re.search(r'^DF:32 ', b, re.M)]
    modeac = sum(1 for b in blocks if re.search(r'^DF:32 ', b, re.M))
    addrs = set(re.findall(r'ICAO Address:\s+([0-9A-F]{6}) \(Mode S', text))
    print(f'| Decoded (new build) | {len(modes)} Mode S messages from {len(addrs)} aircraft, {modeac} Mode A/C replies |')
except OSError:
    pass
print()
EOF
    if [ -s "$WORK/compare/result.md" ]; then
        cat "$WORK/compare/result.md"
    else
        echo '### Comparison log (last 40 lines)'
        echo
        echo '```'
        tail -40 "$WORK/compare.log"
        echo '```'
    fi
} > "$REPORT"

echo >&2
cat "$REPORT"
echo >&2
say "report written to $REPORT"
if [ $recorded_here = 1 ]; then
    say "the recording is $RECORDING ($(du -h "$RECORDING" | cut -f1)); rerun with --recording to reuse it, and delete it when you no longer need it"
fi
exit $STATUS
