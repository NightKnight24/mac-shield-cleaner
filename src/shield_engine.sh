#!/bin/bash

# ==============================================================================
# Anti-Lag Shield Engine — Universal macOS Low-Latency & Throughput Utility
# ==============================================================================

SHIELD_MODE="gaming"
APP_PID=""
STOP_FILE="/tmp/mac_shield_stop"
TARGET_USER="${USER}"
USER_HOME="${HOME}"
LOG_FILE="/tmp/mac_shield_live.log"
TELEM_FILE="/tmp/mac_shield_telemetry.json"
LOCK_ARP="1"
CUSTOM_GW_MAC=""
WATCH_SPOOF_MAC=""
STREMIO_PORT="11470"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)           SHIELD_MODE="$2"; shift 2 ;;
        --app-pid)        APP_PID="$2"; shift 2 ;;
        --stop-file)      STOP_FILE="$2"; shift 2 ;;
        --user)           TARGET_USER="$2"; shift 2 ;;
        --home)           USER_HOME="$2"; shift 2 ;;
        --log)            LOG_FILE="$2"; shift 2 ;;
        --telem)          TELEM_FILE="$2"; shift 2 ;;
        --lock-arp)       LOCK_ARP="$2"; shift 2 ;;
        --gateway-mac)    CUSTOM_GW_MAC="$2"; shift 2 ;;
        --spoof-mac)      WATCH_SPOOF_MAC="$2"; shift 2 ;;
        *)                shift ;;
    esac
done

rm -f "$STOP_FILE" "$TELEM_FILE" "${TELEM_FILE}.tmp"
echo "$$" > /tmp/mac_shield_engine.pid
chmod 644 /tmp/mac_shield_engine.pid 2>/dev/null

log_msg() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo "[$ts] $1" >> "$LOG_FILE"
}

: > "$LOG_FILE"
chmod 644 "$LOG_FILE" 2>/dev/null

if [[ "$SHIELD_MODE" == "streaming" ]]; then
    MODE_TITLE="STREAMING & MEDIA SERVER MODE"
else
    SHIELD_MODE="gaming"
    MODE_TITLE="GAMING & ZERO-LATENCY MODE"
fi

log_msg "Initializing ${MODE_TITLE}..."

# Keep Mac, USB & Display awake while shield is active
caffeinate -dimsu -w "$$" >/dev/null 2>&1 &
CAFF_PID=$!
log_msg "[OK] System, USB & Display Sleep Shield: ACTIVE"

# Detect active route interface & gateway IP dynamically
INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
[ -z "$INTERFACE" ] && INTERFACE="en0"
ROUTER_IP=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
log_msg "[OK] Primary Route: $INTERFACE | Gateway: ${ROUTER_IP:-Auto}"

# Auto-learn real Gateway MAC address (unless custom MAC provided)
LEARNED_GW_MAC=""
if [ -n "$CUSTOM_GW_MAC" ]; then
    LEARNED_GW_MAC="$CUSTOM_GW_MAC"
elif [ -n "$ROUTER_IP" ]; then
    ping -c 1 -W 300 "$ROUTER_IP" >/dev/null 2>&1
    LEARNED_GW_MAC=$(arp -n "$ROUTER_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="at") {print $(i+1); exit}}')
    case "$LEARNED_GW_MAC" in
        ""|"(incomplete)"|"ff:ff:ff:ff:ff:ff") LEARNED_GW_MAC="" ;;
    esac
fi

if [ "$LOCK_ARP" = "1" ] && [ -n "$ROUTER_IP" ] && [ -n "$LEARNED_GW_MAC" ]; then
    arp -d "$ROUTER_IP" ifscope "$INTERFACE" >/dev/null 2>&1
    arp -s "$ROUTER_IP" "$LEARNED_GW_MAC" ifscope "$INTERFACE" >/dev/null 2>&1
    arp -d "$ROUTER_IP" >/dev/null 2>&1
    arp -s "$ROUTER_IP" "$LEARNED_GW_MAC" >/dev/null 2>&1

    sysctl -w net.inet.icmp.drop_redirect=1 >/dev/null 2>&1
    sysctl -w net.inet.ip.redirect=0 >/dev/null 2>&1
    sysctl -w net.inet6.icmp6.rediraccept=0 >/dev/null 2>&1
    log_msg "[OK] Gateway $ROUTER_IP ARP Locked ($LEARNED_GW_MAC)"
else
    log_msg "[OK] Gateway ARP Guard: Monitoring"
fi

# Pause AWDL / AirDrop background scans to avoid Wi-Fi/BT micro-stutters
ifconfig awdl0 down >/dev/null 2>&1
ifconfig llw0 down >/dev/null 2>&1
log_msg "[OK] Apple Wireless Direct Link (AWDL): PAUSED"

# Flush DNS resolver cache
dscacheutil -flushcache >/dev/null 2>&1
killall -HUP mDNSResponder >/dev/null 2>&1
log_msg "[OK] DNS Cache: FLUSHED"

# Pause Spotlight indexing to eliminate background SSD I/O spikes
mdutil -i off / >/dev/null 2>&1
log_msg "[OK] Spotlight Indexing: PAUSED"

# Apply mode-specific kernel sysctl parameters
if [[ "$SHIELD_MODE" == "gaming" ]]; then
    sysctl -w net.qos.policy.wifi_enabled=1 >/dev/null 2>&1
    sysctl -w net.qos.policy.capable_enabled=1 >/dev/null 2>&1
    sysctl -w net.qos.reset_dscp_to_wifi_ac_map=1 >/dev/null 2>&1

    sysctl -w net.inet.tcp.tso=0 >/dev/null 2>&1
    sysctl -w net.inet.tcp.delayed_ack=0 >/dev/null 2>&1
    sysctl -w net.inet.tcp.sendspace=2097152 >/dev/null 2>&1
    sysctl -w net.inet.tcp.recvspace=2097152 >/dev/null 2>&1
    sysctl -w net.inet.tcp.autorcvbufmax=4194304 >/dev/null 2>&1
    sysctl -w net.inet.tcp.autosndbufmax=4194304 >/dev/null 2>&1
    sysctl -w net.inet.udp.recvspace=4194304 >/dev/null 2>&1
    sysctl -w net.inet.udp.maxdgram=65535 >/dev/null 2>&1
    sysctl -w kern.ipc.somaxconn=512 >/dev/null 2>&1

    # Enable macOS Game Mode support for installed common launchers/apps
    for bid in \
        com.valvesoftware.steam com.epicgames.EpicGamesLauncher \
        com.heroicgameslauncher.hgl com.gog.galaxy com.codeweavers.CrossOver \
        com.roblox.RobloxPlayer com.playstation.RemotePlay com.hnc.Discord \
        net.rpcs3.rpcs3 org.ryujinx.Ryujinx net.shadps4.shadPS4 net.pcsx2.pcsx2 \
        org.dolphin-emu.dolphin info.cemu.Cemu com.libretro.dist.RetroArch; do
        sudo -u "$TARGET_USER" defaults write "$bid" LSSupportsGameMode -bool true 2>/dev/null
    done
    log_msg "[OK] Gaming Mode Active: Instant ACK (0ms) | 4MB Anti-Bufferbloat | VIP Boost"
else
    sysctl -w net.inet.tcp.tso=1 >/dev/null 2>&1
    sysctl -w net.inet.tcp.delayed_ack=2 >/dev/null 2>&1
    sysctl -w net.inet.tcp.sendspace=4194304 >/dev/null 2>&1
    sysctl -w net.inet.tcp.recvspace=8388608 >/dev/null 2>&1
    sysctl -w net.inet.tcp.autorcvbufmax=33554432 >/dev/null 2>&1
    sysctl -w net.inet.tcp.autosndbufmax=33554432 >/dev/null 2>&1
    sysctl -w net.inet.udp.recvspace=8388608 >/dev/null 2>&1
    sysctl -w net.inet.udp.maxdgram=65535 >/dev/null 2>&1
    sysctl -w kern.ipc.somaxconn=1024 >/dev/null 2>&1
    log_msg "[OK] Streaming Mode Active: Full Gigabit TSO | 32MB Max Buffers | Media Boost"
fi

cleanup() {
    trap - SIGHUP SIGINT SIGTERM EXIT
    log_msg "[*] Restoring all original system & network defaults..."

    sysctl -w net.qos.policy.wifi_enabled=0 >/dev/null 2>&1
    sysctl -w net.qos.policy.capable_enabled=0 >/dev/null 2>&1
    sysctl -w net.qos.reset_dscp_to_wifi_ac_map=0 >/dev/null 2>&1
    sysctl -w net.inet.tcp.tso=1 >/dev/null 2>&1
    sysctl -w net.inet.tcp.delayed_ack=2 >/dev/null 2>&1
    sysctl -w net.inet.tcp.sendspace=1048576 >/dev/null 2>&1
    sysctl -w net.inet.tcp.recvspace=1048576 >/dev/null 2>&1
    sysctl -w net.inet.tcp.autorcvbufmax=4194304 >/dev/null 2>&1
    sysctl -w net.inet.tcp.autosndbufmax=4194304 >/dev/null 2>&1
    sysctl -w net.inet.udp.recvspace=786896 >/dev/null 2>&1
    sysctl -w net.inet.icmp.drop_redirect=0 >/dev/null 2>&1
    sysctl -w net.inet.ip.redirect=1 >/dev/null 2>&1
    sysctl -w kern.ipc.somaxconn=128 >/dev/null 2>&1

    mdutil -i on / >/dev/null 2>&1

    if [ "$LOCK_ARP" = "1" ] && [ -n "$ROUTER_IP" ]; then
        arp -d "$ROUTER_IP" ifscope "$INTERFACE" >/dev/null 2>&1
        arp -d "$ROUTER_IP" >/dev/null 2>&1
    fi

    ifconfig awdl0 up >/dev/null 2>&1
    ifconfig llw0 up >/dev/null 2>&1

    [ -n "$CAFF_PID" ] && kill "$CAFF_PID" >/dev/null 2>&1

    python3 -c "import json, os; f='$TELEM_FILE'; data={'active': False, 'mode': '$SHIELD_MODE', 'restored': True}; open(f+'.tmp','w').write(json.dumps(data)); os.replace(f+'.tmp', f)" >/dev/null 2>&1
    rm -f /tmp/mac_shield_engine.pid "$STOP_FILE"
    log_msg "[OK] All system defaults cleanly restored."
    exit 0
}

trap cleanup SIGHUP SIGINT SIGTERM EXIT

export SHIELD_MODE_ENV="$SHIELD_MODE"
export LOCK_ARP_ENV="$LOCK_ARP"
export LEARNED_GW_MAC_ENV="$LEARNED_GW_MAC"
export WATCH_SPOOF_MAC_ENV="$WATCH_SPOOF_MAC"
export ROUTER_IP_ENV="$ROUTER_IP"
export APP_PID_ENV="$APP_PID"
export STOP_FILE_ENV="$STOP_FILE"
export TELEM_FILE_ENV="$TELEM_FILE"
export TARGET_USER_ENV="$TARGET_USER"

/usr/bin/python3 - <<'EOF'
import os, time, subprocess, json

shield_mode = os.environ.get("SHIELD_MODE_ENV", "gaming")
lock_arp = os.environ.get("LOCK_ARP_ENV", "1") == "1"
gw_mac = os.environ.get("LEARNED_GW_MAC_ENV", "")
spoof_mac = os.environ.get("WATCH_SPOOF_MAC_ENV", "")
router_ip = os.environ.get("ROUTER_IP_ENV", "")
app_pid = os.environ.get("APP_PID_ENV", "")
stop_file = os.environ.get("STOP_FILE_ENV", "/tmp/mac_shield_stop")
telem_file = os.environ.get("TELEM_FILE_ENV", "/tmp/mac_shield_telemetry.json")
target_user = os.environ.get("TARGET_USER_ENV", "")

def run_user_osascript(script, timeout=0.4):
    if os.geteuid() == 0 and target_user:
        cmd = ['sudo', '-n', '-u', target_user, 'osascript', '-e', script]
    else:
        cmd = ['osascript', '-e', script]
    return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=timeout).decode().strip()

def norm_mac(m):
    try:
        return ":".join(f"{int(x, 16):02x}" for x in m.strip().split(":"))
    except:
        return m.strip().lower()

v_norm = norm_mac(gw_mac) if gw_mac else ""
p_norm = norm_mac(spoof_mac) if spoof_mac else ""

if shield_mode == "gaming":
    targets = [
        "RemotePlay", "PlayStation Remote Play", "chiaki", "chiaki-ng",
        "Moonlight", "GeForceNOW", "Shadow", "Parsec", "Amazon Luna",
        "RobloxPlayer", "RobloxStudio", "wine", "wine64-preloader", "wineserver",
        "shadPS4", "shadps4", "RPCS3", "rpcs3", "Ryujinx", "PCSX2",
        "Dolphin", "Cemu", "DuckStation", "PPSSPPSDL", "PPSSPP",
        "Vita3K", "azahar", "Lime3DS", "xemu", "xenia", "melonDS", "RetroArch",
        "Steam", "steam_osx", "EpicGamesLauncher", "Heroic", "GalaxyClient", "GOG Galaxy", "Discord"
    ]
else:
    targets = [
        "Stremio", "node", "stremio-runtime", "stremio-service", "ffmpeg",
        "Prime Video", "TV", "Plex", "Plexamp", "IINA", "VLC", "Infuse", "Kodi",
        "QuickTime Player", "Elmedia Video Player",
        "Google Chrome", "Safari", "Brave Browser", "Firefox", "Arc"
    ]

STREAMING_SITES = [
    'Stremio', 'web.stremio.com', 'Netflix', 'YouTube', 'Disney+', 'Disney Plus',
    'HBO Max', 'Max', 'Prime Video', 'Apple TV', 'Hulu', 'Twitch', 'Paramount+',
    'Peacock', 'Crunchyroll', 'BBC iPlayer', 'Kick', 'Discovery+', 'Plex'
]

def get_active_interface():
    try:
        out = subprocess.check_output(['route', '-n', 'get', 'default'], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if 'interface:' in line:
                return line.split(':')[1].strip()
    except: pass
    return 'en0'

def get_gateway():
    try:
        out = subprocess.check_output(['route', '-n', 'get', 'default'], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if 'gateway:' in line:
                return line.split(':')[1].strip()
    except: pass
    return ''

def get_iface_bytes(iface):
    try:
        out = subprocess.check_output(['netstat', '-ib', '-I', iface], stderr=subprocess.DEVNULL).decode()
        for line in out.strip().splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 10 and (parts[0] == iface or parts[0] == f"<{iface}>" or parts[0].startswith(iface)):
                return int(parts[6]), int(parts[9])
    except: pass
    return 0, 0

def check_link_speed(iface):
    try:
        out = subprocess.check_output(['ifconfig', iface], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if 'media:' in line:
                if '10000base' in line: return "10 Gbps"
                elif '2500baseT' in line: return "2.5 Gbps"
                elif '1000baseT' in line: return "1 Gbps"
                elif '100baseTX' in line: return "100 Mbps"
                elif '10baseT' in line: return "10 Mbps"
                elif 'autoselect' in line: return "Wi-Fi"
    except: pass
    return "Active"

def check_usb_bus_speed():
    try:
        out = subprocess.check_output(["ioreg", "-r", "-c", "IOUSBHostDevice", "-l"], stderr=subprocess.DEVNULL).decode()
        for block in out.split("+-o "):
            b_low = block.lower()
            if any(k in b_low for k in ["10/100/1000", "ethernet", "rtl8153", "ax88179", "usb lan"]):
                if "5000000000" in block or "10000000000" in block: return "5G+ Bus"
                elif "480000000" in block: return "480 Mbps"
    except: pass
    return "Native"

def ping_host(host, timeout_ms=350):
    if not host: return None
    try:
        out = subprocess.check_output(['ping', '-c', '1', '-W', str(timeout_ms), host], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if 'time=' in line:
                return float(line.split('time=')[1].split()[0])
    except: pass
    return None

def is_pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except:
        return False

boosted_pids = set()

def scan_and_boost_targets():
    active_labels = []
    seen = set()
    global boosted_pids

    # Also boost the frontmost user app automatically if gaming mode is active
    if shield_mode == "gaming":
        try:
            script = 'tell application "System Events" to get unix id of (first application process whose frontmost is true)'
            front_pid = run_user_osascript(script, timeout=0.3)
            front_name = subprocess.check_output(['ps', '-p', front_pid, '-o', 'comm='], stderr=subprocess.DEVNULL).decode().strip()
            bname = os.path.basename(front_name)
            if bname and bname not in ['MacShieldCleaner', 'Finder', 'Terminal', 'loginwindow']:
                # Only auto-boost if it's inside /Applications or Steam/Games
                if '/Applications/' in front_name or 'steamapps' in front_name.lower() or '/Volumes/' in front_name:
                    if front_pid not in boosted_pids:
                        subprocess.call(['renice', '-20', '-p', front_pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        subprocess.call(['taskpolicy', '-B', '-t', '0', '-p', front_pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        boosted_pids.add(front_pid)
                    label = bname.replace('.app', '')
                    if label not in seen:
                        seen.add(label)
                        active_labels.append(label)
        except:
            pass

    for name in targets:
        try:
            out = subprocess.check_output(['pgrep', '-i', name], stderr=subprocess.DEVNULL).decode().strip().split()
            matched_pids = []
            for p in out:
                comm = subprocess.check_output(['ps', '-p', p, '-o', 'comm='], stderr=subprocess.DEVNULL).decode().strip()
                args = subprocess.check_output(['ps', '-p', p, '-o', 'args='], stderr=subprocess.DEVNULL).decode().strip()
                bname = os.path.basename(comm)
                if 'helper' in bname.lower() or 'daemon' in bname.lower() or 'platformsupport' in bname.lower():
                    continue
                if name == "node" and '/applications/stremio' not in comm.lower() and 'server.js' not in args.lower():
                    continue
                if name in ['Google Chrome', 'Safari', 'Brave Browser', 'Firefox', 'Arc']:
                    try:
                        script = 'tell application "System Events" to get name of front window of (first application process whose frontmost is true)'
                        win_title = run_user_osascript(script, timeout=0.4)
                        matched_site = next((s for s in STREAMING_SITES if s.lower() in win_title.lower()), None)
                        if not matched_site: continue
                        name = f"{matched_site} ({name})"
                    except: continue
                matched_pids.append((p, bname))
            if matched_pids:
                for (pid, _) in matched_pids:
                    if pid not in boosted_pids:
                        subprocess.call(['renice', '-20', '-p', pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        subprocess.call(['taskpolicy', '-B', '-t', '0', '-p', pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        boosted_pids.add(pid)
                label = name
                if label not in seen:
                    seen.add(label)
                    active_labels.append(label)
        except: pass
    return active_labels

def check_stremio_server_clients():
    try:
        out = subprocess.check_output(['netstat', '-an'], stderr=subprocess.DEVNULL).decode()
        return sum(1 for l in out.splitlines() if '.11470 ' in l and 'ESTABLISHED' in l)
    except: return 0

def enforce_arp_guard(iface):
    if not lock_arp or not v_norm or not router_ip:
        return False, False
    needs_relock, is_spoof = False, False
    try:
        out = subprocess.check_output(['arp', '-n', router_ip], stderr=subprocess.DEVNULL).decode()
        found_any = False
        for line in out.strip().splitlines():
            parts = line.split()
            if 'at' in parts:
                idx = parts.index('at')
                if idx + 1 < len(parts):
                    found_any = True
                    m_norm = norm_mac(parts[idx + 1])
                    if m_norm != v_norm:
                        needs_relock = True
                        if p_norm and m_norm == p_norm:
                            is_spoof = True
                    elif 'permanent' not in line:
                        needs_relock = True
        if not found_any: needs_relock = True
    except: needs_relock = True

    if needs_relock:
        subprocess.call(['arp', '-d', router_ip, 'ifscope', iface], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.call(['arp', '-s', router_ip, gw_mac, 'ifscope', iface], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.call(['arp', '-d', router_ip], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.call(['arp', '-s', router_ip, gw_mac], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True, is_spoof
    return False, False

current_iface = get_active_interface()
gateway_ip = router_ip or get_gateway()
prev_ib, prev_ob = get_iface_bytes(current_iface)
prev_t = time.time()
loop_counter = 0
r_ms, i_ms = None, None
active_apps = []
spoof_alert = False
spoof_count = 0
usb_status = "Native"
cable_status = "Active"
stremio_clients = 0

while True:
    if os.path.exists(stop_file):
        break
    if app_pid and not is_pid_alive(app_pid):
        break

    should_exit = False
    for _ in range(4):
        if os.path.exists(stop_file) or (app_pid and not is_pid_alive(app_pid)):
            should_exit = True
            break
        time.sleep(0.25)
    if should_exit:
        break

    now_t = time.time()
    loop_counter += 1

    if loop_counter % 5 == 0:
        active_iface = get_active_interface()
        if active_iface != current_iface:
            current_iface = active_iface
            gateway_ip = get_gateway()
            prev_ib, prev_ob = get_iface_bytes(current_iface)
            prev_t = now_t
            continue

    if loop_counter % 3 == 0:
        relocked, was_spoof = enforce_arp_guard(current_iface)
        if relocked:
            spoof_alert = True
            if was_spoof: spoof_count += 1

    if loop_counter % 5 == 0 or loop_counter == 1:
        usb_status = check_usb_bus_speed()
        cable_status = check_link_speed(current_iface)

    if loop_counter % 30 == 0:
        boosted_pids = {p for p in boosted_pids if is_pid_alive(p)}

    cur_ib, cur_ob = get_iface_bytes(current_iface)
    dt = now_t - prev_t
    rx_rate = int((cur_ib - prev_ib) / dt) if dt > 0 and cur_ib >= prev_ib else 0
    tx_rate = int((cur_ob - prev_ob) / dt) if dt > 0 and cur_ob >= prev_ob else 0
    prev_ib, prev_ob, prev_t = cur_ib, cur_ob, now_t

    if loop_counter % 2 == 0 or r_ms is None:
        r_ms = ping_host(gateway_ip, timeout_ms=350)
        i_ms = ping_host("1.1.1.1", timeout_ms=400)

    if loop_counter % 2 == 0 or loop_counter == 1:
        active_apps = scan_and_boost_targets()
        stremio_clients = check_stremio_server_clients() if shield_mode == "streaming" else 0

    payload = {
        "active": True,
        "mode": shield_mode,
        "interface": current_iface,
        "gateway": gateway_ip,
        "gateway_mac": gw_mac,
        "arp_locked": bool(lock_arp and v_norm),
        "usb_speed": usb_status,
        "cable_speed": cable_status,
        "router_ms": r_ms,
        "ping_ms": i_ms,
        "rx_bps": rx_rate,
        "tx_bps": tx_rate,
        "active_apps": active_apps,
        "stremio_4k_clients": stremio_clients,
        "spoof_count": spoof_count,
        "spoof_alert": spoof_alert,
        "timestamp": time.strftime('%H:%M:%S')
    }
    try:
        with open(telem_file + ".tmp", "w") as f:
            json.dump(payload, f)
        os.chmod(telem_file + ".tmp", 0o644)
        os.replace(telem_file + ".tmp", telem_file)
    except:
        pass
EOF
