#!/usr/bin/env bash
#============================================================================================================
#
#                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
#                               SPDX-License-Identifier: BSD-3-Clause
#
#============================================================================================================
# ==============================================================================
# QDC SDP one-click connection launcher - C++ tunnel (Linux / macOS)
#
# Starts the SSH, ADB/SCP, target tunnel, and host tunnel steps needed for
# Snapdragon Profiler device discovery through SDP, using the native C++ tunnel
# binaries (qdc-tunnel-target / qdc-tunnel-host) instead of the Java JARs.
#
# Why C++: the device-side binary is a single small static ELF (~200 KB) that runs
# on both QDC Android and QDC Qualcomm Linux (IoT). Deploying it is one quick push
# with no JVM/JRE/DEX bundle, so target setup is dramatically faster than the Java
# path (which had to ship a whole JRE to IoT devices).
#
# Supports two target types based on QDC_CHIPSET_CATEGORY:
#   Mobile  - Android target: adb push qdc-tunnel-target + adb shell
#   IOT     - Qualcomm Linux target: scp qdc-tunnel-target + ssh
#
# REQUIRED environment variables (or set them in config.local.sh):
#   QDC_API_KEY       - Your QDC API key
#   SSH_KEY           - Path to your SSH private key (e.g. ~/.ssh/id_ed25519)
#
# OPTIONAL environment variables:
#   SSH_USER_HOST        - SSH user@host (auto-detected from DNS servers if not set)
#   QDC_SESSIONS_URL     - QDC sessions API endpoint (has a default)
#   QDC_CHIPSET_CATEGORY - Mobile or IOT; used when passing device ID manually
#   HOST_BIN             - Explicit path to qdc-tunnel-host (host binary)
#   TARGET_BIN           - Explicit path to qdc-tunnel-target (device binary, aarch64)
#   ADB_PATH             - Full path to the adb binary (Mobile only). Set this when adb is
#                          not on PATH; otherwise the launcher uses "adb" from PATH.
#
# IOT-specific environment variables (required when QDC_CHIPSET_CATEGORY=IOT):
#   IOT_TARGET_SSH       - SSH user@host for the IoT target device
#   IOT_REMOTE_DIR       - Remote deployment directory on IoT target (default: /tmp/qdc-sdp)
#   IOT_TARGET_ARCH      - Override target architecture auto-detection: x64 or aarch64
#   IOT_TARGET_PASSWORD  - Device root password; when set, device ssh/scp use password auth
#                          (via sshpass if installed, else SSH_ASKPASS) so no prompts appear.
#   IOT_TARGET_USER      - Device login user (default: root)
# ==============================================================================

set -euo pipefail

CONNECTION_CATEGORY="QDC Cloud device"
STARTUP_DELAY_SECONDS=5

# --- Determine script directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Detect OS ---
OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="mac" ;;
    *)       echo "ERROR: Unsupported OS: $OS_TYPE"; exit 1 ;;
esac

# --- Load local config overrides if present (git-ignored) ---
if [[ -f "$SCRIPT_DIR/config.local.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/config.local.sh"
fi

# ==============================================================================
# Helper functions
# ==============================================================================

fail() {
    echo
    echo "============================================================"
    echo "Failed to start QDC SDP connection workflow."
    echo "Review the error above, fix it, then run this script again."
    echo "============================================================"
    echo
    exit 1
}

require_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: Required tool \"$1\" was not found in PATH."
        return 1
    fi
}

kill_port() {
    local port="$1"
    local pids

    if [[ "$PLATFORM" == "mac" ]]; then
        pids=$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true)
    else
        pids=$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || \
               ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
    fi

    if [[ -z "$pids" ]]; then
        echo "No process found listening on TCP port $port."
        return 0
    fi

    for pid in $pids; do
        echo "Killing process $pid listening on TCP port $port..."
        kill -9 "$pid" 2>/dev/null || true
    done
}

check_port_listening() {
    local port="$1"
    if [[ "$PLATFORM" == "mac" ]]; then
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null
    else
        ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port" || \
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null 2>&1
    fi
}

# Locate an executable from a list of candidate paths, or PATH as a last resort.
# Usage: resolve_bin <var_name> <friendly-name> <candidate> [candidate...]
resolve_bin() {
    local var_name="$1"; shift
    local friendly="$1"; shift
    local existing="${!var_name:-}"
    if [[ -n "$existing" ]]; then
        if [[ -x "$existing" ]]; then return 0; fi
        echo "ERROR: $var_name is set but not executable: \"$existing\""
        return 1
    fi
    local c
    for c in "$@"; do
        if [[ -x "$c" ]]; then
            eval "$var_name=\"$c\""
            return 0
        fi
    done
    # PATH fallback (by friendly name)
    if command -v "$friendly" &>/dev/null; then
        eval "$var_name=\"$(command -v "$friendly")\""
        return 0
    fi
    echo "ERROR: Could not find the $friendly binary. Looked in:"
    for c in "$@"; do echo "  $c"; done
    echo
    echo "Build the C++ tunnel binaries with:"
    echo "  cd \"$SCRIPT_DIR/src\""
    echo "  cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release && cmake --build build/native   # host (this machine)"
    echo "  cmake -S . -B build/target -DCMAKE_TOOLCHAIN_FILE=toolchains/aarch64-linux-musl.cmake -DCMAKE_BUILD_TYPE=Release && cmake --build build/target   # device"
    echo "or set $var_name to an explicit path in config.local.sh."
    return 1
}

# Launch a long-running command in a new terminal window (best-effort).
launch_in_terminal() {
    local title="$1"
    shift
    local cmd_str="$*"

    local log_file="${TMPDIR:-/tmp}/qdc-sdp-$(echo "$title" | tr ' ' '-' | tr -cd '[:alnum:]-').log"

    if [[ "$PLATFORM" == "mac" ]]; then
        osascript -e "
            tell application \"Terminal\"
                activate
                do script \"echo '=== $title ==='; $cmd_str; echo ''; echo 'Process exited. Press Ctrl+C or close this window.'; exec bash\"
            end tell
        " &>/dev/null
    elif command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="$title" -- bash -c "$cmd_str; echo ''; echo 'Process exited. Press Enter to close.'; read" &>/dev/null 2>&1 &
    elif command -v konsole &>/dev/null; then
        konsole --new-tab -p tabtitle="$title" -e bash -c "$cmd_str; echo ''; echo 'Process exited. Press Enter to close.'; read" &>/dev/null 2>&1 &
    elif command -v xterm &>/dev/null; then
        xterm -T "$title" -e bash -c "$cmd_str; echo ''; echo 'Process exited. Press Enter to close.'; read" &>/dev/null 2>&1 &
    else
        echo "  (No terminal emulator found; running in background, logging to: $log_file)"
        nohup bash -c "$cmd_str" > "$log_file" 2>&1 &
    fi
}

# Parse JSON to extract QDC device ID and chipset category.
parse_qdc_session_info() {
    local json_file="$1"
    local device_id=""
    local chipset_category=""

    if command -v jq &>/dev/null; then
        device_id=$(jq -r '
            .data[]
            | select(.state == "Running" and (.sshConfigs | length) > 0)
            | "sa" + (.deviceCloudSessionId | tostring)
        ' "$json_file" 2>/dev/null | head -n1)

        chipset_category=$(jq -r '
            .data[]
            | select(.state == "Running" and (.sshConfigs | length) > 0)
            | if (.targets | length) > 0 then .targets[0].chipsetCategory else "" end
        ' "$json_file" 2>/dev/null | head -n1)
    elif command -v python3 &>/dev/null; then
        read -r device_id chipset_category < <(python3 -c "
import json, sys
with open('$json_file') as f:
    data = json.load(f).get('data', [])
for s in data:
    if s.get('state') == 'Running' and len(s.get('sshConfigs', [])) > 0:
        did = 'sa' + str(s['deviceCloudSessionId'])
        targets = s.get('targets', [])
        cat = targets[0].get('chipsetCategory', '') if targets else ''
        print(did, cat)
        sys.exit(0)
" 2>/dev/null)
    else
        echo "ERROR: Neither 'jq' nor 'python3' found. Install one to parse QDC sessions." >&2
        return 1
    fi

    echo "$device_id"
    echo "$chipset_category"
}

# Auto-detect SSH host based on DNS configuration
detect_ssh_host() {
    local is_internal=false

    if [[ "$PLATFORM" == "mac" ]]; then
        if scutil --dns 2>/dev/null | grep -qi "qualcomm\.com"; then
            is_internal=true
        fi
    else
        if grep -qi "qualcomm\.com" /etc/resolv.conf 2>/dev/null; then
            is_internal=true
        elif command -v resolvectl &>/dev/null && resolvectl status 2>/dev/null | grep -qi "qualcomm\.com"; then
            is_internal=true
        fi
    fi

    if [[ "$is_internal" == "true" ]]; then
        echo "sshtunnel@ssh-cn.qdc-internal.qualcomm.com"
    else
        echo "sshtunnel@ssh-cn.qdc.qualcomm.com"
    fi
}

# Wait (up to ~12s) until a local TCP port is listening.
wait_for_port() {
    local port="$1" desc="$2"
    for _ in 1 2 3 4 5 6; do
        if check_port_listening "$port"; then
            echo "  Port $port is listening ($desc)."
            return 0
        fi
        sleep 2
    done
    return 1
}

# ==============================================================================
# Main script logic
# ==============================================================================

# --- Validate required configuration ---
if [[ -z "${SSH_KEY:-}" ]]; then
    echo "ERROR: SSH_KEY is not set."
    echo "       Set the SSH_KEY environment variable or define it in config.local.sh."
    echo "       Example: export SSH_KEY=\"\$HOME/.ssh/id_ed25519\""
    fail
fi

if [[ -z "${SSH_USER_HOST:-}" ]]; then
    SSH_USER_HOST="$(detect_ssh_host)"
    echo "Auto-detected SSH host: $SSH_USER_HOST"
fi

if [[ -z "${QDC_API_KEY:-}" ]]; then
    echo "ERROR: QDC_API_KEY is not set."
    echo "       Set the QDC_API_KEY environment variable or define it in config.local.sh."
    fail
fi

QDC_SESSIONS_URL="${QDC_SESSIONS_URL:-https://api.qualcomm.com/deviceloud/v1/sessions}"
QDC_SESSIONS_FILE="${TMPDIR:-/tmp}/qdc_sessions.json"

if [[ -n "${1:-}" ]]; then
    QDC_DEVICE_ID="$1"
    ADB_REMOTE_HOST="${QDC_DEVICE_ID}.sa.svc.cluster.local"
    QDC_CHIPSET_CATEGORY="${QDC_CHIPSET_CATEGORY:-Mobile}"
    echo "Using manually specified QDC device ID: $1"
    echo "Using chipset category: $QDC_CHIPSET_CATEGORY (manual/default)"
else
    echo "Fetching active QDC session from API..."
    curl -s -X GET "$QDC_SESSIONS_URL" \
      -H "accept: application/json" \
      -H "Authorization: $QDC_API_KEY" \
      -H "X-QCOM-TokenType: apikey" \
      -H "X-QCOM-AppName: QDCUser" \
      -H "X-QCOM-ClientType: appName" \
      -H "X-QCOM-TracingId: qdc-sdp-remote-profiling" \
      -o "$QDC_SESSIONS_FILE"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to call QDC sessions API."
        fail
    fi

    session_info="$(parse_qdc_session_info "$QDC_SESSIONS_FILE")"
    QDC_DEVICE_ID="$(printf '%s\n' "$session_info" | sed -n '1p')"
    QDC_CHIPSET_CATEGORY="$(printf '%s\n' "$session_info" | sed -n '2p')"

    if [[ -z "$QDC_DEVICE_ID" ]]; then
        echo "ERROR: No running QDC session with SSH config found."
        echo "       Start a QDC session at https://qdc.qualcomm.com before running this script."
        fail
    fi
    if [[ -z "$QDC_CHIPSET_CATEGORY" ]]; then
        echo "WARNING: chipsetCategory not present in API response; defaulting to Mobile."
        QDC_CHIPSET_CATEGORY="Mobile"
    fi
    ADB_REMOTE_HOST="${QDC_DEVICE_ID}.sa.svc.cluster.local"
    echo "Auto-discovered QDC device ID: $QDC_DEVICE_ID"
    echo "API chipset category: $QDC_CHIPSET_CATEGORY"
fi

# ==============================================================================
# Resolve C++ binary paths
# ==============================================================================
ANDROID_REMOTE_DIR="/data/local/tmp"

# --- Detect host CPU architecture (selects the matching host binary) ---
HOST_ARCH_RAW="$(uname -m)"
case "$HOST_ARCH_RAW" in
    x86_64|amd64)   HOST_ARCH="x86_64" ;;
    aarch64|arm64)  HOST_ARCH="aarch64" ;;
    *)              HOST_ARCH="$HOST_ARCH_RAW" ;;
esac
echo "Detected host CPU: $HOST_ARCH_RAW (using qdc-tunnel-host-$HOST_ARCH)"

resolve_bin HOST_BIN qdc-tunnel-host \
    "$SCRIPT_DIR/qdc-tunnel-host-$HOST_ARCH" \
    "$SCRIPT_DIR/bin/qdc-tunnel-host-$HOST_ARCH" \
    "$SCRIPT_DIR/src/build/native/qdc-tunnel-host" \
    "$SCRIPT_DIR/bin/qdc-tunnel-host" \
    "$SCRIPT_DIR/qdc-tunnel-host" || fail

resolve_bin TARGET_BIN qdc-tunnel-target \
    "$SCRIPT_DIR/src/build/target/qdc-tunnel-target" \
    "$SCRIPT_DIR/src/build/native/qdc-tunnel-target" \
    "$SCRIPT_DIR/bin/qdc-tunnel-target" \
    "$SCRIPT_DIR/qdc-tunnel-target" || fail

require_tool ssh   || fail
require_tool curl  || fail

echo "============================================================"
echo "QDC SDP connection launcher (C++ tunnel)"
echo "============================================================"
echo "  Target binary:   $TARGET_BIN"
echo "  Host binary:     $HOST_BIN"
echo "  Chipset:         $QDC_CHIPSET_CATEGORY"
echo "  SSH host:        $SSH_USER_HOST"
echo "  SSH key:         $SSH_KEY"
echo "  ADB remote host: $ADB_REMOTE_HOST"
echo

if [[ "${QDC_CHIPSET_CATEGORY,,}" == "iot" ]]; then
    # ==========================================================================
    # IOT branch: Qualcomm Linux target reached via a QDC SSH tunnel
    #   localhost:$IOT_LOCAL_SSH_PORT  ->  <device>:22
    # ==========================================================================
    IOT_SSH_KEY="${IOT_SSH_KEY:-$SSH_KEY}"
    IOT_REMOTE_DIR="${IOT_REMOTE_DIR:-/tmp/qdc-sdp}"
    IOT_LOCAL_SSH_PORT="${IOT_LOCAL_SSH_PORT:-2222}"
    IOT_TARGET_USER="${IOT_TARGET_USER:-root}"
    IOT_TARGET_PASSWORD="${IOT_TARGET_PASSWORD:-}"

    if [[ -n "$IOT_TARGET_PASSWORD" ]]; then
        IOT_AUTH_DESC="password (from IOT_TARGET_PASSWORD)"
    else
        IOT_AUTH_DESC="key ($IOT_SSH_KEY)"
    fi

    echo "IoT Qualcomm Linux device workflow"
    echo "  IoT SSH user:   $IOT_TARGET_USER"
    echo "  IoT device auth: $IOT_AUTH_DESC"
    echo "  Local SSH port: $IOT_LOCAL_SSH_PORT (forwarded to device:22)"
    echo "  Remote dir:     $IOT_REMOTE_DIR"
    echo

    # [IOT 1/6] SSH tunnel to device port 22 (via QDC SSH host)
    echo "[IOT 1/6] Starting SSH tunnel to device SSH port ($IOT_LOCAL_SSH_PORT -> $ADB_REMOTE_HOST:22)..."
    kill_port "$IOT_LOCAL_SSH_PORT"
    launch_in_terminal "QDC SDP - IoT SSH tunnel (port 22)" \
        "ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -L $IOT_LOCAL_SSH_PORT:$ADB_REMOTE_HOST:22 -N $SSH_USER_HOST"
    sleep "$STARTUP_DELAY_SECONDS"
    if ! wait_for_port "$IOT_LOCAL_SSH_PORT" "IoT device SSH tunnel"; then
        echo "ERROR: SSH tunnel to device port 22 failed - local port $IOT_LOCAL_SSH_PORT is not listening."
        echo "       Check SSH key, QDC session ($QDC_DEVICE_ID), and network connectivity."
        fail
    fi

    IOT_TARGET_SSH="$IOT_TARGET_USER@localhost"

    # SSH/SCP options + auth for the device via the tunneled localhost port.
    IOT_SSH_AUTH=()
    IOT_AUTH_STR=""
    if [[ -n "$IOT_TARGET_PASSWORD" ]]; then
        IOT_SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p "$IOT_LOCAL_SSH_PORT")
        IOT_SCP_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -P "$IOT_LOCAL_SSH_PORT")
        if command -v sshpass &>/dev/null; then
            IOT_SSH_AUTH=(sshpass -e)
            IOT_AUTH_STR="sshpass -e "
            export SSHPASS="$IOT_TARGET_PASSWORD"
        else
            IOT_ASKPASS="$(mktemp "${TMPDIR:-/tmp}/qdc-askpass.XXXXXX")"
            printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$IOT_TARGET_PASSWORD"\n' > "$IOT_ASKPASS"
            chmod +x "$IOT_ASKPASS"
            export IOT_TARGET_PASSWORD
            export SSH_ASKPASS="$IOT_ASKPASS"
            export SSH_ASKPASS_REQUIRE=force
            trap 'rm -f "$IOT_ASKPASS"' EXIT
            IOT_SSH_AUTH=(setsid -w)
            IOT_AUTH_STR="setsid -w "
            echo "  (sshpass not found; using setsid + SSH_ASKPASS to supply the device password)"
        fi
    else
        IOT_SSH_OPTS=(-i "$IOT_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p "$IOT_LOCAL_SSH_PORT")
        IOT_SCP_OPTS=(-i "$IOT_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -P "$IOT_LOCAL_SSH_PORT")
    fi

    # [IOT 2/6] Detect target architecture (informational; the shipped binary is aarch64)
    echo "[IOT 2/6] Detecting target architecture..."
    if [[ -n "${IOT_TARGET_ARCH:-}" ]]; then
        raw_arch="$IOT_TARGET_ARCH"
    else
        raw_arch="$("${IOT_SSH_AUTH[@]}" ssh "${IOT_SSH_OPTS[@]}" -o ConnectTimeout=10 "$IOT_TARGET_SSH" "uname -m" 2>/dev/null || true)"
    fi
    case "$raw_arch" in
        aarch64|arm64)     echo "  Target architecture: aarch64" ;;
        x86_64|amd64|x64)
            echo "  WARNING: target reports x86_64 but the bundled qdc-tunnel-target is aarch64."
            echo "           Build an x86_64 device binary and set TARGET_BIN, or set IOT_TARGET_ARCH." ;;
        *)                 echo "  WARNING: could not detect target architecture (got: '${raw_arch:-empty}'); assuming aarch64." ;;
    esac

    # [IOT 3/6] Deploy the tunnel binary (single small static ELF - no JRE needed)
    echo "[IOT 3/6] Deploying qdc-tunnel-target to $IOT_REMOTE_DIR/ ..."
    "${IOT_SSH_AUTH[@]}" ssh "${IOT_SSH_OPTS[@]}" "$IOT_TARGET_SSH" "mkdir -p $IOT_REMOTE_DIR" || fail
    "${IOT_SSH_AUTH[@]}" scp "${IOT_SCP_OPTS[@]}" "$TARGET_BIN" "$IOT_TARGET_SSH:$IOT_REMOTE_DIR/qdc-tunnel-target" || fail
    "${IOT_SSH_AUTH[@]}" ssh "${IOT_SSH_OPTS[@]}" "$IOT_TARGET_SSH" "chmod 755 $IOT_REMOTE_DIR/qdc-tunnel-target" || fail

    # [IOT 4/6] Start the target tunnel on the device
    echo "[IOT 4/6] Starting Target tunnel on device..."
    # A previous tunnel detaches under init and would keep the ports bound, so kill any
    # stale instance before starting a fresh one.
    if "${IOT_SSH_AUTH[@]}" ssh "${IOT_SSH_OPTS[@]}" "$IOT_TARGET_SSH" "pgrep -f '$IOT_REMOTE_DIR/qdc-tunnel-target' >/dev/null 2>&1"; then
        echo "  Existing target tunnel found on device - killing it..."
        "${IOT_SSH_AUTH[@]}" ssh "${IOT_SSH_OPTS[@]}" "$IOT_TARGET_SSH" "pkill -f '$IOT_REMOTE_DIR/qdc-tunnel-target'" || true
        sleep 2
    fi
    launch_in_terminal "QDC SDP - IoT Target tunnel" \
        "${IOT_AUTH_STR}ssh ${IOT_SSH_OPTS[*]} $IOT_TARGET_SSH \"$IOT_REMOTE_DIR/qdc-tunnel-target --port-map 8896:8927 --port-map 8898:8929\""
    sleep "$STARTUP_DELAY_SECONDS"

    # [IOT 5/6] SSH port tunnel for the SDP transport ports 8927/8929 (via QDC SSH host)
    echo "[IOT 5/6] Starting Host-to-Target SDP SSH port tunnel (8927/8929)..."
    kill_port 8927
    kill_port 8929
    launch_in_terminal "QDC SDP - SDP SSH port tunnel" \
        "ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -L 8927:$ADB_REMOTE_HOST:8927 -L 8929:$ADB_REMOTE_HOST:8929 -N $SSH_USER_HOST"
    sleep "$STARTUP_DELAY_SECONDS"
    if ! wait_for_port 8927 "SDP port 8927" || ! wait_for_port 8929 "SDP port 8929"; then
        echo "ERROR: SDP SSH port tunnel failed - ports 8927/8929 are not listening."
        echo "       Check SSH key, device ID ($QDC_DEVICE_ID), and network connectivity."
        fail
    fi

    # [IOT 6/6] Start the host tunnel locally
    echo "[IOT 6/6] Starting Host tunnel..."
    launch_in_terminal "QDC SDP - Host tunnel" \
        "\"$HOST_BIN\" --remote-host 127.0.0.1 --port-map 8927:8896 --port-map 8929:8898"

    # Clear stale localhost host keys (right before SDP connects).
    echo "Clearing stale known_hosts entries for localhost:$IOT_LOCAL_SSH_PORT..."
    if [[ -f "$HOME/.ssh/known_hosts" ]]; then
        ssh-keygen -R "[localhost]:$IOT_LOCAL_SSH_PORT" >/dev/null 2>&1 || true
        ssh-keygen -R "[127.0.0.1]:$IOT_LOCAL_SSH_PORT" >/dev/null 2>&1 || true
    fi

else
    # ==========================================================================
    # Mobile branch: Android target via ADB
    # ==========================================================================
    # Resolve adb: honor ADB_PATH when adb is not on PATH, else use "adb" from PATH.
    ADB="${ADB_PATH:-adb}"
    if [[ -n "${ADB_PATH:-}" ]]; then
        if [[ ! -x "$ADB" ]]; then
            echo "ERROR: ADB_PATH is set but adb is not executable: \"$ADB\""
            echo "       Point ADB_PATH at the adb binary itself (not its folder) in config.local.sh."
            fail
        fi
        echo "Using adb from ADB_PATH: $ADB"
    else
        require_tool adb || fail
    fi

    echo "[1/6] Cleaning up existing local ADB server and port 5037 users..."
    "$ADB" kill-server >/dev/null 2>&1 || true
    kill_port 5037

    echo "[2/6] Starting ADB discovery SSH tunnel..."
    launch_in_terminal "QDC SDP - ADB discovery tunnel" \
        "ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -L 5037:$ADB_REMOTE_HOST:5037 -N $SSH_USER_HOST"
    sleep "$STARTUP_DELAY_SECONDS"
    if ! wait_for_port 5037 "ADB discovery tunnel"; then
        echo "ERROR: ADB discovery tunnel failed - port 5037 is not listening."
        fail
    fi
    "$ADB" devices || true

    echo "[3/6] Forwarding ADB ports to device..."
    "$ADB" forward tcp:8927 tcp:8927 || fail
    "$ADB" forward tcp:8929 tcp:8929 || fail

    echo "[4/6] Pushing qdc-tunnel-target to device and making it executable..."
    "$ADB" push "$TARGET_BIN" "$ANDROID_REMOTE_DIR/qdc-tunnel-target" || fail
    "$ADB" shell "chmod 755 $ANDROID_REMOTE_DIR/qdc-tunnel-target" || fail
    # Kill any stale instance holding the ports from a previous run.
    "$ADB" shell "pkill -f '$ANDROID_REMOTE_DIR/qdc-tunnel-target'" >/dev/null 2>&1 || true

    echo "[5/6] Starting Target tunnel..."
    launch_in_terminal "QDC SDP - Target tunnel" \
        "\"$ADB\" shell \"$ANDROID_REMOTE_DIR/qdc-tunnel-target --port-map 8896:8927 --port-map 8898:8929\""
    sleep "$STARTUP_DELAY_SECONDS"

    echo "[6/6] Starting Host-to-Target SDP SSH port tunnel + Host tunnel..."
    kill_port 8927
    kill_port 8929
    launch_in_terminal "QDC SDP - SDP SSH port tunnel" \
        "ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -L 8927:$ADB_REMOTE_HOST:8927 -L 8929:$ADB_REMOTE_HOST:8929 -L 8900:$ADB_REMOTE_HOST:8900 -L 8902:$ADB_REMOTE_HOST:8902 -L 8904:$ADB_REMOTE_HOST:8904 -L 8906:$ADB_REMOTE_HOST:8906 -L 8908:$ADB_REMOTE_HOST:8908 -L 8910:$ADB_REMOTE_HOST:8910 -L 8912:$ADB_REMOTE_HOST:8912 -L 8914:$ADB_REMOTE_HOST:8914 -L 8916:$ADB_REMOTE_HOST:8916 -L 8918:$ADB_REMOTE_HOST:8918 -L 8920:$ADB_REMOTE_HOST:8920 -L 8922:$ADB_REMOTE_HOST:8922 -L 8924:$ADB_REMOTE_HOST:8924 -L 8926:$ADB_REMOTE_HOST:8926 -N $SSH_USER_HOST"
    sleep "$STARTUP_DELAY_SECONDS"
    if ! wait_for_port 8927 "SDP port 8927" || ! wait_for_port 8929 "SDP port 8929"; then
        echo "ERROR: SDP SSH port tunnel failed - ports 8927/8929 are not listening."
        fail
    fi

    launch_in_terminal "QDC SDP - Host tunnel" \
        "\"$HOST_BIN\" --remote-host 127.0.0.1 --port-map 8927:8896 --port-map 8929:8898"
fi

echo
echo "============================================================"
echo "Launcher completed."
echo
echo "Keep the opened tunnel windows/processes running."
echo "Verify the Target tunnel shows connections,"
echo "then open Snapdragon Profiler; it should discover and connect to the device."
echo "============================================================"
echo
