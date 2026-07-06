# SDP WebSocket Tunnel (Java)

Designed to setup websocket tunnel between **Android** (via `app_process`) and **Windows / Linux / macOS** (via standard JVM).

## Architecture

```
ANDROID (SDPCore initiates)                              WINDOWS (SDPClient listens)
┌─────────────────────────────────────┐                 ┌──────────────────────────────────────┐
│ SDPCore                               │                 │ SDPClient (listens :6500 / :6502)      │
│   │ connects to local TCP :6500       │                 │            ▲                           │
│   ▼                                   │                 │            │ TCP :6500 / :6502         │
│ Android WS Tunnel                     │                 │ Windows WS Tunnel                      │
│   • TCP listen   :6500 / :6502        │                 │   • WS  connect → localhost:9000/9002  │
│   • forwards TCP → WS  :9000 / :9002  │                 │   • forwards WS → TCP :6500 / :6502     │
│   • WS SERVER    :9000 / :9002        │                 │   • WS CLIENT                          │
│              ▲                        │                 │            │                           │
└──────────────┼────────────────────────┘                 └────────────┼──────────────────────────┘
               │                                                        │
               └───────── SSH -L 9000:<android>:9000 ───────────────────┘
                          SSH -L 9002:<android>:9002
                          (separate SSH terminal you open)
```

## Build Outputs

The CI pipeline produces **2 downloadable JAR files**:

| File | Platform | Format | How to run |
|------|----------|--------|------------|
| `tunnel-android-reverse-1.0.0.jar` | Android | DEX bytecode | `adb push` + `app_process` |
| `tunnel-windows-reverse-1.0.0.jar` | Windows / Linux / macOS | JVM fat JAR | `java -jar` (JDK 18+) |

> Download pre-built JARs from the [GitHub Releases](../../releases) page.

## Prerequisites

- **JDK 18+** (for building locally)
- **Gradle** (wrapper included — or use system Gradle)
- **Android SDK build-tools** (for `d8`, only needed to build the Android DEX JAR)

## Build Locally

```bash
cd tools/websocket-tunnel-QDC

# Windows-side fat JAR (JVM)
./gradlew windowsJar     # → build/libs/tunnel-windows-reverse-1.0.0.jar

# Android DEX JAR (converted to Dalvik bytecode via d8)
./gradlew dexJar         # → build/libs/tunnel-android-reverse-1.0.0.jar
```

On Windows use `gradlew.bat` instead of `./gradlew`:
```cmd
cd tools\websocket-tunnel-QDC
gradlew.bat windowsJar
gradlew.bat dexJar
```

> **Important:** Android's ART runtime cannot execute standard JVM `.class` bytecode.
> You **must** use the `dexJar` task to produce a DEX-converted JAR for `app_process`.

## One-click QDC SDP connection launcher

### Windows

```cmd
tools\websocket-tunnel-QDC\connect-qdc-sdp.bat
```

### Linux (Ubuntu 24) / macOS

```bash
chmod +x tools/websocket-tunnel-QDC/connect-qdc-sdp.sh   # first time only
tools/websocket-tunnel-QDC/connect-qdc-sdp.sh
```

> **Additional dependency for Linux/Mac:** The script uses `jq` for JSON parsing
> (with a `python3` fallback). Install with `sudo apt install jq` (Ubuntu) or
> `brew install jq` (macOS).

### Configuration

The launcher reads secrets and connection details from **environment variables**.
You can set them in your shell or place them in a git-ignored config file:

- **Windows:** `config.local.bat` (see `config.local.bat.template`)
- **Linux / macOS:** `config.local.sh` (see `config.local.sh.template`)

| Variable | Required | Description |
|----------|----------|-------------|
| `SSH_KEY` | **Yes** | Path to your SSH private key (e.g. `~/.ssh/id_ed25519` or `C:\Users\you\.ssh\id_ed25519`) |
| `QDC_API_KEY` | **Yes** | Your QDC API key for session discovery |
| `SSH_USER_HOST` | No | SSH `user@host` for the QDC tunnel endpoint (auto-detected if not set — see below) |
| `QDC_SESSIONS_URL` | No | QDC sessions API endpoint (has a built-in default) |

#### SSH host auto-detection

If `SSH_USER_HOST` is not explicitly set, the script auto-detects whether you are on
the Qualcomm corporate network:

- **Windows:** inspects DNS Servers entries from `ipconfig /all` output.
- **Linux:** checks `/etc/resolv.conf` and `resolvectl status`.
- **macOS:** checks `scutil --dns` output.

If a DNS entry contains `qualcomm.com` → uses `sshtunnel@ssh.qdc-internal.qualcomm.com` (on-network).
Otherwise → uses `sshtunnel@ssh.qdc.qualcomm.com` (off-network / external).

You can still override this by setting `SSH_USER_HOST` in your environment or in
your platform's `config.local.*` file.

### Usage

```bash
# Auto-discover QDC device from the running session via API:
./connect-qdc-sdp.sh

# Or pass a known device ID directly (skips API lookup):
./connect-qdc-sdp.sh sa630771
```

Windows equivalent:
```cmd
connect-qdc-sdp.bat
connect-qdc-sdp.bat sa630771
```

### What the launcher does

The script opens separate terminal windows for each long-running tunnel and performs
the following **7 steps** in order:

1. **ADB cleanup** — kills the local ADB server and any process on TCP port `5037`.
2. **ADB discovery SSH tunnel** — opens an SSH tunnel (`-L 5037:<device>:5037`) so
   the local ADB client can discover the remote device. Retries up to 3 times until
   port `5037` is listening.
3. **ADB port forwarding** — runs `adb forward tcp:8900 tcp:8900` and
   `adb forward tcp:8902 tcp:8902`.
4. **Push Android DEX JAR** — uploads `tunnel-android-reverse-1.0.0.jar` to
   `/data/local/tmp/` on the device.
5. **Start Android websocket tunnel** — launches `TunnelAndroidReverse` via
   `app_process` with port mappings `6500:8900` and `6502:8902`.
6. **SDP SSH port tunnel** — opens SSH tunnels for ports `8900` and `8902` from
   localhost to the remote device. Retries up to 3 times until both ports are
   listening.
7. **Start host websocket tunnel** — runs `TunnelWindowsReverse` (JVM fat JAR, works
   on any OS) with `--remote-host 127.0.0.1 --port-map 8900:6500 --port-map 8902:6502`.

### JAR file resolution

By default the script looks for JARs in the same folder as the script:

```
tools/websocket-tunnel-QDC/
```

and falls back to:

```
~/Downloads/          (Linux / macOS)
%USERPROFILE%\Downloads\   (Windows)
```

If the JARs are not present, build them and copy to the script folder:

```bash
cd tools/websocket-tunnel-QDC
./gradlew windowsJar dexJar
cp build/libs/tunnel-*.jar .
```

Windows equivalent:
```cmd
cd tools\websocket-tunnel-QDC
gradlew.bat windowsJar dexJar
copy build\libs\tunnel-*.jar .
```

### Prerequisites (checked at runtime)

The script verifies that `ssh`, `adb`, and `java` are available in `PATH` before
proceeding.

On Linux/macOS the script additionally benefits from:
- `jq` — for JSON parsing (falls back to `python3` if unavailable)
- A GUI terminal emulator (`gnome-terminal`, `konsole`, `xterm`, or macOS Terminal.app)
  for opening tunnel windows. If none is available (e.g. headless/SSH session), tunnels
  are launched as background processes with log files in `/tmp/`.

### Linux/macOS terminal window behavior

On Windows, each long-running tunnel opens in its own `cmd.exe` window. On
Linux/macOS, the script attempts to open new terminal windows using (in order):

1. **macOS** — Terminal.app via `osascript`
2. **Linux** — `gnome-terminal`, `konsole`, or `xterm`
3. **Fallback** — `nohup` background process with output logged to `/tmp/qdc-sdp-*.log`

PID information and log paths are printed so you can monitor or stop individual tunnels.

### After the launcher completes

Keep the opened tunnel windows running. Verify the Android websocket tunnel window
shows connections, then open Snapdragon Profiler — it should discover the device.

### Manual run

### Android side (via ADB)

```bash
# 1. Push the DEX JAR to the device
adb push tunnel-android-reverse-1.0.0.jar /data/local/tmp/

# 2. Run on device (requires shell / root access)
adb shell "cd /data/local/tmp && \
    CLASSPATH=tunnel-android-reverse-1.0.0.jar \
    app_process / com.sdp.tunnel.TunnelAndroidReverse \
    --tcp-port 6500 --ws-port 9000"

# Multiple ports
adb shell "cd /data/local/tmp && \
    CLASSPATH=tunnel-android-reverse-1.0.0.jar \
    app_process / com.sdp.tunnel.TunnelAndroidReverse \
    --port-map 6500:9000 --port-map 6502:9002"
```

### Host side (Windows / Linux / macOS)

```bash
# Single port
java -jar tunnel-windows-reverse-1.0.0.jar --remote-host <android-ip> --remote-port 6500

# Multiple ports
java -jar tunnel-windows-reverse-1.0.0.jar --remote-host <android-ip> --port-map 8900:6500 --port-map 8902:6502
```

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/build-websocket-tunnel.yml`) automates:

1. **Build** — compiles both JARs on every push/PR touching `tools/websocket-tunnel-QDC/`
2. **Artifact Upload** — both JARs available as downloadable build artifacts
3. **Release** — when a tag `v*` is pushed, creates a GitHub Release with both JARs attached

### Triggering a Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

This creates a GitHub Release where users can download the executable JARs directly.

## Common Pitfalls

| Error | Cause | Fix |
|-------|-------|-----|
| `no class name or --zygote supplied` | Missing `/` (cmd-dir) between `app_process` and the class name | Use `app_process /` (with the slash) |
| `Aborted` / class-load crash | JAR contains JVM `.class` bytecode instead of DEX | Rebuild with `./gradlew dexJar` |
| `UnsupportedClassVersionError` | JDK version mismatch | Ensure JDK 18+ is installed |
| SSH tunnel failed after 3 attempts — port not listening | SSH key auth rejected, wrong device ID, or network unreachable | Verify `SSH_KEY` path, `SSH_USER_HOST`, device ID, and that the QDC session is running |
| `ERROR: Required tool "ssh" was not found in PATH` | Missing CLI prerequisite | Install OpenSSH / add `ssh`, `adb`, or `java` to your `PATH` |
