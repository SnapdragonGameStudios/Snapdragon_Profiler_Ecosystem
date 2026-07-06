#!/usr/bin/env bash
#============================================================================================================
#  
#                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
#                               SPDX-License-Identifier: BSD-3-Clause
#  
#============================================================================================================ 
# ==============================================================================
# QDC SDP one-click connection launcher (Linux / macOS)
#
# Starts the SSH, ADB, Android app_process, and host Java tunnel steps needed
# for Snapdragon Profiler device discovery through SDP.
#
# REQUIRED environment variables (or set them in config.local.sh):
#   QDC_API_KEY       - Your QDC API key
#   SSH_KEY           - Path to your SSH private key (e.g. ~/.ssh/id_ed25519)
#
# OPTIONAL environment variables:
#   SSH_USER_HOST     - SSH user@host (auto-detected from DNS servers if not set)
#   QDC_SESSIONS_URL  - QDC sessions API endpoint (has a default)
# ==============================================================================

set -euo pipefail

CONNECTION_CATEGORY="QDC Cloud device"

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

# --- Helper functions ---

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

resolve_file() {
    local primary="$1"
    local fallback="$2"
    local var_name="$3"

    if [[ -f "$primary" ]]; then
        eval "$var_name=\"$primary\""
        return 0
    fi

    if [[ -f "$fallback" ]]; then
        eval "$var_name=\"$fallback\""
        return 0
    fi

    echo "ERROR: Could not find required file:"
    echo "  \"$primary\""
    echo "or fallback:"
    echo "  \"$fallback\""
    echo
    echo "Build the JARs with:"
    echo "  cd \"$SCRIPT_DIR\""
    echo "  ./gradlew windowsJar dexJar"
    echo "or download them to ~/Downloads."
    return 1
}

# Launch a long-running command in a new terminal window (best-effort).
# Falls back to background process with log file if no terminal emulator found.
launch_in_terminal() {
    local title="$1"
    shift
    local cmd_str="$*"

    local log_file="${TMPDIR:-/tmp}/qdc-sdp-$(echo "$title" | tr ' ' '-' | tr -cd '[:alnum:]-').log"

    if [[ "$PLATFORM" == "mac" ]]; then
        # macOS: use Terminal.app via osascript
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
        # Fallback: run in background with log file
        echo "  (No terminal emulator found; running in background, logging to: $log_file)"
        nohup bash -c "$cmd_str" > "$log_file" 2>&1 &
    fi
}

# Parse JSON to extract QDC device ID. Prefers jq, falls back to python3.
parse_qdc_device_id() {
    local json_file="$1"
    local device_id=""

    if command -v jq &>/dev/null; then
        device_id=$(jq -r '
            .data[]
            | select(.state == "Running" and (.sshConfigs | length) > 0)
            | "sa" + (.deviceCloudSessionId | tostring)
        ' "$json_file" 2>/dev/null | head -n1)
    elif command -v python3 &>/dev/null; then
        device_id=$(python3 -c "
import json, sys
with open('$json_file') as f:
    data = json.load(f).get('data', [])
for s in data:
    if s.get('state') == 'Running' and len(s.get('sshConfigs', [])) > 0:
        print('sa' + str(s['deviceCloudSessionId']))
        sys.exit(0)
" 2>/dev/null)
    else
        echo "ERROR: Neither 'jq' nor 'python3' found. Install one to parse QDC sessions." >&2
        return 1
    fi

    echo "$device_id"
}

# Auto-detect SSH host based on DNS configuration
detect_ssh_host() {
    local is_internal=false

    if [[ "$PLATFORM" == "mac" ]]; then
        # macOS: check DNS configuration via scutil
        if scutil --dns 2>/dev/null | grep -qi "qualcomm\.com"; then
            is_internal=true
        fi
    else
        # Linux: check /etc/resolv.conf and systemd-resolved
        if grep -qi "qualcomm\.com" /etc/resolv.conf 2>/dev/null; then
            is_internal=true
        elif command -v resolvectl &>/dev/null && resolvectl status 2>/dev/null | grep -qi "qualcomm\.com"; then
            is_internal=true
        fi
    fi

    if [[ "$is_internal" == "true" ]]; then
        echo "sshtunnel@ssh.qdc-internal.qualcomm.com"
    else
        echo "sshtunnel@ssh.qdc.qualcomm.com"
    fi
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

# Auto-determine SSH_USER_HOST from DNS servers if not already set
if [[ -z "${SSH_USER_HOST:-}" ]]; then
    SSH_USER_HOST="$(detect_ssh_host)"
    echo "Auto-detected SSH host: $SSH_USER_HOST"
fi

if [[ -z "${QDC_API_KEY:-}" ]]; then
    echo "ERROR: QDC_API_KEY is not set."
    echo "       Set the QDC_API_KEY environment variable or define it in config.local.sh."
    fail
fi

# Default sessions URL if not overridden
QDC_SESSIONS_URL="${QDC_SESSIONS_URL:-https://api.qualcomm.com/deviceloud/v1/sessions}"

QDC_SESSIONS_FILE="${TMPDIR:-/tmp}/qdc_sessions.json"

# QDC device ID changes with each cloud session.
# Optionally pass the device ID as the first argument to skip the API lookup:
#   ./connect-qdc-sdp.sh sa630771
if [[ -n "${1:-}" ]]; then
    QDC_DEVICE_ID="$1"
    ADB_REMOTE_HOST="${QDC_DEVICE_ID}.sa.svc.cluster.local"
    echo "Using manually specified QDC device ID: $1"
else
    echo "Fetching active QDC session from API..."
    curl -s -X GET "$QDC_SESSIONS_URL" \
      -H "accept: application/json" \
      -H "Authorization: $QDC_API_KEY" \
      -H "X-QCOM-TokenType: apikey" \
      -H "X-QCOM-AppName: QDCUser" \
      -H "X-QCOM-ClientType: appName" \
      -H "X-QCOM-TracingId: 4cf76b2b-bfa4-4f27-91da-378bf2a52288" \
      -o "$QDC_SESSIONS_FILE"

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to call QDC sessions API."
        fail
    fi

    QDC_DEVICE_ID="$(parse_qdc_device_id "$QDC_SESSIONS_FILE")"

    if [[ -z "$QDC_DEVICE_ID" ]]; then
        echo "ERROR: No running QDC session with SSH config found."
        echo "       Start a QDC session at https://qdc.qualcomm.com before running this script."
        fail
    fi

    ADB_REMOTE_HOST="${QDC_DEVICE_ID}.sa.svc.cluster.local"
    echo "Auto-discovered QDC device ID: $QDC_DEVICE_ID"
fi

# --- Resolve JAR files ---
LOCAL_ANDROID_JAR="$SCRIPT_DIR/tunnel-android-reverse-1.0.0.jar"
LOCAL_HOST_JAR="$SCRIPT_DIR/tunnel-windows-reverse-1.0.0.jar"
DOWNLOAD_ANDROID_JAR="$HOME/Downloads/tunnel-android-reverse-1.0.0.jar"
DOWNLOAD_HOST_JAR="$HOME/Downloads/tunnel-windows-reverse-1.0.0.jar"

ANDROID_REMOTE_DIR="/data/local/tmp"
ANDROID_REMOTE_JAR="tunnel-android-reverse-1.0.0.jar"

STARTUP_DELAY_SECONDS=5

echo "============================================================"
echo "QDC SDP connection launcher ($PLATFORM)"
echo "============================================================"
echo

require_tool ssh || fail
require_tool adb || fail
require_tool java || fail

ANDROID_JAR=""
HOST_JAR=""
resolve_file "$LOCAL_ANDROID_JAR" "$DOWNLOAD_ANDROID_JAR" ANDROID_JAR || fail
resolve_file "$LOCAL_HOST_JAR" "$DOWNLOAD_HOST_JAR" HOST_JAR || fail

echo "Using Android tunnel JAR: \"$ANDROID_JAR\""
echo "Using host tunnel JAR:    \"$HOST_JAR\""
echo "Connection category: $CONNECTION_CATEGORY"
echo "SSH host: $SSH_USER_HOST"
echo "SSH private key: \"$SSH_KEY\""
echo "ADB remote host: $ADB_REMOTE_HOST"
echo

echo "[1/7] Cleaning up existing local ADB server and port 5037 users..."
adb kill-server >/dev/null 2>&1 || true
kill_port 5037

echo "[2/7] Starting ADB discovery SSH tunnel in a new window..."
SSH2_ATTEMPT=0
while true; do
    SSH2_ATTEMPT=$((SSH2_ATTEMPT + 1))
    if [[ $SSH2_ATTEMPT -gt 1 ]]; then
        echo "Retrying ADB discovery SSH tunnel (attempt $SSH2_ATTEMPT/3)..."
        kill_port 5037
    fi

    launch_in_terminal "QDC SDP - ADB discovery tunnel" \
        "ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -L 5037:$ADB_REMOTE_HOST:5037 -N $SSH_USER_HOST"

    sleep "$STARTUP_DELAY_SECONDS"

    if check_port_listening 5037; then
        break
    fi

    if [[ $SSH2_ATTEMPT -ge 3 ]]; then
        echo "ERROR: ADB discovery SSH tunnel failed after 3 attempts - port 5037 is not listening."
        echo "       Check SSH key, device ID ($QDC_DEVICE_ID), and network connectivity."
        fail
    fi
done
echo "Port 5037 is listening - ADB discovery SSH tunnel OK."
echo
echo "Discovered ADB devices:"
adb devices
echo

echo "[3/7] Forwarding Linux ADB ports to Android device..."
adb forward tcp:8900 tcp:8900 || fail
adb forward tcp:8902 tcp:8902 || fail

echo "[4/7] Pushing Android DEX tunnel JAR to device..."
adb push "$ANDROID_JAR" "$ANDROID_REMOTE_DIR/$ANDROID_REMOTE_JAR" || fail

echo "[5/7] Starting Android websocket tunnel in a new window..."
launch_in_terminal "QDC SDP - Android websocket tunnel" \
    "adb shell \"cd $ANDROID_REMOTE_DIR && CLASSPATH=$ANDROID_REMOTE_JAR app_process / com.sdp.tunnel.TunnelAndroidReverse --port-map 6500:8900 --port-map 6502:8902\""
sleep "$STARTUP_DELAY_SECONDS"

echo "[6/7] Starting host-to-device SDP SSH port tunnel in a new window..."
SSH6_ATTEMPT=0
while true; do
    SSH6_ATTEMPT=$((SSH6_ATTEMPT + 1))
    if [[ $SSH6_ATTEMPT -gt 1 ]]; then
        echo "Retrying SDP SSH port tunnel (attempt $SSH6_ATTEMPT/3)..."
        kill_port 8900
        kill_port 8902
    fi

    launch_in_terminal "QDC SDP - SDP SSH port tunnel" \
        "ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -L 8900:$ADB_REMOTE_HOST:8900 -L 8902:$ADB_REMOTE_HOST:8902 -N $SSH_USER_HOST"

    sleep "$STARTUP_DELAY_SECONDS"

    if check_port_listening 8900 && check_port_listening 8902; then
        break
    fi

    if [[ $SSH6_ATTEMPT -ge 3 ]]; then
        echo "ERROR: SDP SSH port tunnel failed after 3 attempts - ports 8900/8902 are not listening."
        echo "       Check SSH key, device ID ($QDC_DEVICE_ID), and network connectivity."
        fail
    fi
done
echo "Ports 8900 and 8902 are listening - SDP SSH port tunnel OK."

echo "[7/7] Starting host websocket tunnel in a new window..."
launch_in_terminal "QDC SDP - Host websocket tunnel" \
    "java -jar \"$HOST_JAR\" --remote-host 127.0.0.1 --port-map 8900:6500 --port-map 8902:6502"

echo
echo "============================================================"
echo "Launcher completed."
echo
echo "Keep the opened tunnel windows running."
echo "Verify the Android websocket tunnel window shows connections."
echo "Then open Snapdragon Profiler; it should discover the device."
echo "============================================================"
echo
read -rp "Press Enter to continue..."