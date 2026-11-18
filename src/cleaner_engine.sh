#!/bin/bash

# ==============================================================================
# Universal macOS Cache, Temp, System Data & External Drive Cleaner Engine
# ==============================================================================

MODE="scan"
CATS="app_caches,containers,browsers,desktop_app_support,system_user_temp,bottles,dev_caches,logs,system_data_bloat"
EXT_VOL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan)      MODE="scan"; shift ;;
        --clean)     MODE="clean"; shift ;;
        --ext-scan)  MODE="ext_scan"; shift ;;
        --ext-clean) MODE="ext_clean"; shift ;;
        --vol)       EXT_VOL="$2"; shift 2 ;;
        --cats)      CATS="$2"; shift 2 ;;
        *)           shift ;;
    esac
done

USER_C_DIR="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)"; USER_C_DIR="${USER_C_DIR%/}"
USER_T_DIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)";  USER_T_DIR="${USER_T_DIR%/}"
USER_X_DIR=""
if [ -n "$USER_C_DIR" ]; then
    USER_X_DIR="$(dirname "$USER_C_DIR")/X"
fi
AS="$HOME/Library/Application Support"

get_free_kb() { df -k / | awk 'NR==2 {print $4+0}'; }
get_total_kb() { df -k / | awk 'NR==2 {print $2+0}'; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

refresh_running() {
    RUNNING_IDS="$(lsappinfo list 2>/dev/null | grep -o 'bundleID="[^"]*"' | cut -d'"' -f2 | tr '[:upper:]' '[:lower:]' | sort -u)"
    RUNNING_PROCS="$(ps -axo comm= 2>/dev/null | tr '[:upper:]' '[:lower:]')"
}

proc_names_for() {
    case "$(lower "$1")" in
        google|chrome|com.google.chrome*)        echo "Google Chrome" ;;
        bravesoftware|com.brave.browser*)        echo "Brave Browser" ;;
        "microsoft edge"|com.microsoft.edgemac*) echo "Microsoft Edge" ;;
        vivaldi|com.vivaldi.vivaldi*)            echo "Vivaldi" ;;
        com.operasoftware.opera*|opera)          echo "Opera" ;;
        chromium|org.chromium.chromium*)         echo "Chromium" ;;
        firefox|mozilla|org.mozilla.firefox*)    echo "firefox" ;;
        discord|com.hnc.discord*)                echo "Discord" ;;
        steam|com.valvesoftware.steam*)          echo "steam_osx" ;;
        heroic|com.heroicgameslauncher*)         echo "Heroic" ;;
        crossover|com.codeweavers*)              echo "CrossOver" ;;
        *)                                       echo "$1" ;;
    esac
}

is_running() {
    local key; key="$(lower "$1")"
    local id
    for id in $RUNNING_IDS; do
        case "$key" in "$id"|"$id".*) return 0 ;; esac
    done
    local IFS='|' name lname
    for name in $(proc_names_for "$1") "$1"; do
        lname="$(lower "$name")"
        [ ${#lname} -lt 3 ] && continue
        case "$RUNNING_PROCS" in
            *"/$lname"*|*"/$lname.app/"*) return 0 ;;
        esac
    done
    return 1
}

is_shader_cache() {
    case "$(lower "$1")" in
        d3dm|com.apple.metal|*shadercache*|*shader_cache*) return 0 ;;
    esac
    return 1
}

dir_kb() {
    local d="$1"
    [ -e "$d" ] && [ ! -L "$d" ] || { echo 0; return; }
    local val
    val=$(du -skx "$d" 2>/dev/null | awk 'NR==1{print $1+0}')
    echo "${val:-0}"
}

has_cat() {
    case ",$CATS," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

SKIPPED_APPS=""
CLEANED_KB=0

note_skip() {
    case "|$SKIPPED_APPS|" in *"|$1|"*) ;; *) SKIPPED_APPS="${SKIPPED_APPS:+$SKIPPED_APPS|}$1" ;; esac
}

purge_dir() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    [ -L "$dir" ] && return 0
    case "$dir" in
        "$HOME"/*|"$USER_C_DIR"|"$USER_C_DIR"/*|"$USER_T_DIR"|"$USER_T_DIR"/*|"$USER_X_DIR"|"$USER_X_DIR"/*|/private/tmp|/private/tmp/*|/Library/Caches*) ;;
        *) return 0 ;;
    esac
    ls "$dir" >/dev/null 2>&1 || return 0
    local kb; kb=$(dir_kb "$dir")
    find "$dir" -xdev -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    local left; left=$(dir_kb "$dir")
    local diff=$((kb - left))
    [ "$diff" -gt 0 ] && CLEANED_KB=$((CLEANED_KB + diff))
}

purge_path() {
    local p="$1"
    [ -e "$p" ] || [ -L "$p" ] || return 0
    case "$p" in "$HOME"/*|"$USER_C_DIR"/*|"$USER_X_DIR"/*|/private/tmp/*) ;; *) return 0 ;; esac
    local kb=0
    [ -L "$p" ] || kb=$(dir_kb "$p")
    rm -rf "$p" 2>/dev/null && CLEANED_KB=$((CLEANED_KB + kb))
}

CHROMIUM_CACHE_NAMES=("Cache" "Code Cache" "GPUCache" "DawnCache" "DawnGraphiteCache" \
    "DawnWebGPUCache" "GrShaderCache" "GraphiteDawnCache" "ShaderCache" "CachedData" \
    "Service Worker/CacheStorage" "Service Worker/ScriptCache" "component_crx_cache" "Crashpad/completed")

BROWSER_ROOTS=(
    "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium"
    "BraveSoftware/Brave-Browser" "Microsoft Edge" "Vivaldi" "Arc/User Data"
    "com.operasoftware.Opera" "com.operasoftware.OperaGX"
)

# ------------------------------------------------------------------------------
# SCAN MODE
# ------------------------------------------------------------------------------
if [ "$MODE" = "scan" ]; then
    refresh_running
    kb_app_caches=$(dir_kb "$HOME/Library/Caches")
    kb_cont_caches=0
    for c in "$HOME/Library/Containers"/*/Data/Library/Caches "$HOME/Library/Group Containers"/*/Library/Caches; do
        [ -d "$c" ] && [ ! -L "$c" ] && kb_cont_caches=$((kb_cont_caches + $(dir_kb "$c")))
    done

    kb_browsers=0
    for root in "${BROWSER_ROOTS[@]}"; do
        R="$AS/$root"
        [ -d "$R" ] || continue
        for n in "GrShaderCache" "ShaderCache" "GraphiteDawnCache" "component_crx_cache" "Crashpad/completed"; do
            kb_browsers=$((kb_browsers + $(dir_kb "$R/$n")))
        done
        for prof in "$R"/*/; do
            prof="${prof%/}"
            [ -d "$prof" ] || continue
            for n in "${CHROMIUM_CACHE_NAMES[@]}"; do
                kb_browsers=$((kb_browsers + $(dir_kb "$prof/$n")))
            done
        done
    done

    kb_user_sys=$(( $(dir_kb "$USER_C_DIR") + $(dir_kb "$USER_T_DIR") ))
    kb_dev=$(( $(dir_kb "$HOME/.cache") + $(dir_kb "$HOME/.npm/_cacache") + $(dir_kb "$HOME/Library/Developer/Xcode/DerivedData") + $(dir_kb "$HOME/Library/Developer/CoreSimulator/Caches") ))
    [ -d "$HOME/Library/Caches/Homebrew" ] && kb_dev=$((kb_dev + $(dir_kb "$HOME/Library/Caches/Homebrew")))
    kb_logs=$(dir_kb "$HOME/Library/Logs")
    kb_trash=$(dir_kb "$HOME/.Trash")

    kb_chrome_ai=$(dir_kb "$AS/Google/Chrome/OptGuideOnDeviceModel")
    kb_aerials=$(dir_kb "$AS/com.apple.wallpaper/aerials/videos")
    kb_x_clones=0
    [ -n "$USER_X_DIR" ] && kb_x_clones=$(dir_kb "$USER_X_DIR")
    kb_discord_old=$(dir_kb "$AS/discord/download")
    if [ -d "$AS/discord" ]; then
        latest_disc=$(ls -1d "$AS/discord"/app-* 2>/dev/null | sort -V | tail -n 1)
        for d_ver in "$AS/discord"/app-*; do
            [ -d "$d_ver" ] && [ "$d_ver" != "$latest_disc" ] && kb_discord_old=$((kb_discord_old + $(dir_kb "$d_ver")))
        done
    fi
    kb_sys_bloat=$((kb_chrome_ai + kb_aerials + kb_x_clones + kb_discord_old))

    kb_shaders=0
    for sd in "$USER_C_DIR/d3dm" "$USER_C_DIR/com.apple.metal"; do
        [ -d "$sd" ] && kb_shaders=$((kb_shaders + $(dir_kb "$sd")))
    done
    kb_sys_wide=$(dir_kb "/Library/Caches")

    open_apps=""
    for app in "Google Chrome" "Brave Browser" "Microsoft Edge" "Vivaldi" "Opera" "Chromium" "firefox" "Safari" "Discord" "steam_osx" "Heroic" "CrossOver"; do
        pgrep -i -x "$app" >/dev/null 2>&1 && open_apps="${open_apps:+$open_apps,}$app"
    done

    total_kb=$(get_total_kb)
    free_kb=$(get_free_kb)
    used_kb=$((total_kb - free_kb))

    python3 - <<EOF
import json, subprocess, os

def du_kb(path):
    if not os.path.exists(path): return 0
    try:
        out = subprocess.check_output(["du", "-skx", path], stderr=subprocess.DEVNULL).decode().split()[0]
        return int(out)
    except:
        return 0

home = os.path.expanduser("~")
inspect_candidates = [
    ("Application Support", os.path.join(home, "Library/Application Support")),
    ("User Library Caches", os.path.join(home, "Library/Caches")),
    ("User Containers", os.path.join(home, "Library/Containers")),
    ("4K Aerial Wallpapers", os.path.join(home, "Library/Application Support/com.apple.wallpaper/aerials")),
    ("Xcode & Simulators", os.path.join(home, "Library/Developer")),
    ("Spotlight Metadata", os.path.join(home, "Library/Metadata")),
    ("iCloud Drive Local Cache", os.path.join(home, "Library/Mobile Documents")),
    ("Downloads", os.path.join(home, "Downloads")),
    ("User .cache", os.path.join(home, ".cache")),
    ("Homebrew (/opt/homebrew)", "/opt/homebrew"),
    ("Docker / Containers", os.path.join(home, "Library/Containers/com.docker.docker")),
]
top_items = []
for label, p in inspect_candidates:
    kb = du_kb(p)
    if kb > 10240:
        top_items.append({"label": label, "path": p, "kb": kb})
top_items.sort(key=lambda x: x["kb"], reverse=True)

data = {
    "total_kb": $total_kb,
    "free_kb": $free_kb,
    "used_kb": $used_kb,
    "open_apps": [a for a in "$open_apps".split(",") if a],
    "categories": {
        "app_caches": $kb_app_caches,
        "containers": $kb_cont_caches,
        "browsers": $kb_browsers,
        "desktop_app_support": 0,
        "system_user_temp": $kb_user_sys,
        "bottles": 0,
        "dev_caches": $kb_dev,
        "logs": $kb_logs,
        "system_data_bloat": $kb_sys_bloat,
        "shaders": $kb_shaders,
        "system_wide": $kb_sys_wide,
        "trash": $kb_trash
    },
    "top_items": top_items[:12]
}
print(json.dumps(data))
EOF
    exit 0
fi

# ------------------------------------------------------------------------------
# EXTERNAL DRIVE MODES (--ext-scan / --ext-clean)
# ------------------------------------------------------------------------------
validate_ext_vol() {
    [ -n "$EXT_VOL" ] && [ -d "$EXT_VOL" ] && [ ! -L "$EXT_VOL" ] || return 1
    case "$EXT_VOL" in
        /Volumes/*)
            [ "$EXT_VOL" = "/Volumes/Macintosh HD" ] && return 1
            [ "$EXT_VOL" = "/Volumes/Recovery" ] && return 1
            return 0
            ;;
        *) return 1 ;;
    esac
}

if [ "$MODE" = "ext_scan" ]; then
    validate_ext_vol || { echo '{"error":"Invalid external volume"}'; exit 1; }
    uid=$(id -u)
    kb_ext_trash=$(dir_kb "$EXT_VOL/.Trashes/$uid")
    [ "$kb_ext_trash" -eq 0 ] && kb_ext_trash=$(dir_kb "$EXT_VOL/.Trashes")
    kb_ext_temp=$(( $(dir_kb "$EXT_VOL/.TemporaryItems") + $(dir_kb "$EXT_VOL/Temp") ))
    kb_ext_steam=$(( $(dir_kb "$EXT_VOL/SteamLibrary/steamapps/downloading") + $(dir_kb "$EXT_VOL/SteamLibrary/steamapps/temp") + $(dir_kb "$EXT_VOL/SteamLibrary/steamapps/depotcache") + $(dir_kb "$EXT_VOL/SteamLibrary/appcache") ))
    kb_ext_spot=$(( $(dir_kb "$EXT_VOL/.Spotlight-V100") + $(dir_kb "$EXT_VOL/.fseventsd") ))
    dot_count=$(find "$EXT_VOL" -xdev -maxdepth 3 \( -name "._*" -o -name ".DS_Store" \) 2>/dev/null | wc -l | awk '{print $1+0}')
    kb_ext_dots=$((dot_count * 128))
    ext_total=$(df -k "$EXT_VOL" | awk 'NR==2 {print $2+0}')
    ext_free=$(df -k "$EXT_VOL" | awk 'NR==2 {print $4+0}')
    ext_used=$((ext_total - ext_free))
    python3 - <<EOF
import json
print(json.dumps({
    "mount": "$EXT_VOL",
    "total_kb": $ext_total,
    "free_kb": $ext_free,
    "used_kb": $ext_used,
    "dot_sample_count": $dot_count,
    "categories": {
        "ext_trashes": $kb_ext_trash,
        "ext_temp": $kb_ext_temp,
        "ext_steam_cache": $kb_ext_steam,
        "ext_appledouble": $kb_ext_dots,
        "ext_spotlight": $kb_ext_spot
    }
}))
EOF
    exit 0
fi

if [ "$MODE" = "ext_clean" ]; then
    validate_ext_vol || { echo "RESULT|0|0|0|"; exit 1; }
    EXT_START=$(df -k "$EXT_VOL" | awk 'NR==2 {print $4+0}')
    EXT_CLEANED=0

    purge_ext_dir() {
        local d="$1"
        [ -d "$d" ] && [ ! -L "$d" ] || return 0
        local kb; kb=$(dir_kb "$d")
        find "$d" -xdev -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        local left; left=$(dir_kb "$d")
        local diff=$((kb - left))
        [ "$diff" -gt 0 ] && EXT_CLEANED=$((EXT_CLEANED + diff))
    }

    echo "PROGRESS|10|Checking external drive permissions..."
    if has_cat "ext_trashes"; then
        echo "PROGRESS|25|Emptying Drive Trash (.Trashes)..."
        purge_ext_dir "$EXT_VOL/.Trashes/$(id -u)"
        purge_ext_dir "$EXT_VOL/.Trashes"
    fi
    if has_cat "ext_temp"; then
        echo "PROGRESS|42|Cleaning Temporary & Installer Files (.TemporaryItems, Temp)..."
        purge_ext_dir "$EXT_VOL/.TemporaryItems"
        purge_ext_dir "$EXT_VOL/Temp"
    fi
    if has_cat "ext_steam_cache"; then
        echo "PROGRESS|60|Cleaning Steam Download & Depot Caches..."
        purge_ext_dir "$EXT_VOL/SteamLibrary/steamapps/downloading"
        purge_ext_dir "$EXT_VOL/SteamLibrary/steamapps/temp"
        purge_ext_dir "$EXT_VOL/SteamLibrary/steamapps/depotcache"
        purge_ext_dir "$EXT_VOL/SteamLibrary/appcache"
    fi
    if has_cat "ext_appledouble"; then
        echo "PROGRESS|78|Removing macOS ._* AppleDouble & .DS_Store Clutter..."
        cnt=$(find "$EXT_VOL" -xdev \( -name "._*" -o -name ".DS_Store" \) -type f 2>/dev/null | wc -l | awk '{print $1+0}')
        find "$EXT_VOL" -xdev \( -name "._*" -o -name ".DS_Store" \) -type f -delete 2>/dev/null
        EXT_CLEANED=$((EXT_CLEANED + cnt * 8))
    fi
    if has_cat "ext_spotlight"; then
        echo "PROGRESS|92|Clearing Spotlight & FSEvents Logs..."
        purge_ext_dir "$EXT_VOL/.Spotlight-V100"
        purge_ext_dir "$EXT_VOL/.fseventsd"
    fi

    EXT_END=$(df -k "$EXT_VOL" | awk 'NR==2 {print $4+0}')
    NET_DIFF=$((EXT_END - EXT_START))
    [ "$NET_DIFF" -gt "$EXT_CLEANED" ] && EXT_CLEANED="$NET_DIFF"
    echo "PROGRESS|100|External drive cleanup complete!"
    echo "RESULT|${EXT_START}|${EXT_END}|${EXT_CLEANED}|"
    exit 0
fi

# ------------------------------------------------------------------------------
# INTERNAL CLEAN MODE
# ------------------------------------------------------------------------------
START_KB=$(get_free_kb)
refresh_running
CLEAR_SHADERS=0
has_cat "shaders" && CLEAR_SHADERS=1

echo "PROGRESS|5|Starting cleanup..."

if has_cat "app_caches"; then
    echo "PROGRESS|14|Cleaning User App Caches (~/Library/Caches)..."
    if [ -d "$HOME/Library/Caches" ]; then
        for item in "$HOME/Library/Caches"/* "$HOME/Library/Caches"/.[!.]*; do
            [ -e "$item" ] || continue
            base="$(basename "$item")"
            if is_running "$base"; then note_skip "$base"; continue; fi
            if [ $CLEAR_SHADERS -eq 0 ] && is_shader_cache "$base"; then continue; fi
            if [ -d "$item" ] && [ ! -L "$item" ]; then purge_dir "$item"; else purge_path "$item"; fi
        done
    fi
fi

if has_cat "containers"; then
    echo "PROGRESS|24|Cleaning Sandboxed Containers & Group Containers..."
    for c in "$HOME/Library/Containers"/*; do
        [ -d "$c" ] || continue
        id="$(basename "$c")"
        if is_running "$id"; then note_skip "$id"; continue; fi
        purge_dir "$c/Data/Library/Caches"
        if [ -d "$c/Data/tmp" ] && [ ! -L "$c/Data/tmp" ]; then
            find "$c/Data/tmp" -xdev -mindepth 1 -maxdepth 1 ! -type s -mtime +1 -exec rm -rf {} + 2>/dev/null
        fi
    done
    for g in "$HOME/Library/Group Containers"/*; do
        [ -d "$g" ] || continue
        purge_dir "$g/Library/Caches"
    done
    purge_dir "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
fi

if has_cat "browsers"; then
    echo "PROGRESS|34|Cleaning Browser Caches (keeping cookies & logins)..."
    for root in "${BROWSER_ROOTS[@]}"; do
        R="$AS/$root"
        [ -d "$R" ] || continue
        owner="${root%%/*}"
        if is_running "$owner"; then note_skip "$owner"; continue; fi
        for n in "GrShaderCache" "ShaderCache" "GraphiteDawnCache" "component_crx_cache" "Crashpad/completed"; do
            purge_dir "$R/$n"
        done
        for prof in "$R"/*/; do
            prof="${prof%/}"
            [ -d "$prof" ] || continue
            for n in "${CHROMIUM_CACHE_NAMES[@]}"; do purge_dir "$prof/$n"; done
        done
    done
fi

if has_cat "desktop_app_support"; then
    echo "PROGRESS|45|Cleaning Desktop App Caches (Discord, Steam, Heroic, Electron)..."
    for app in "$AS"/*; do
        [ -d "$app" ] && [ ! -L "$app" ] || continue
        base="$(basename "$app")"
        case "$base" in
            CrossOver|Google|Chromium|BraveSoftware|"Microsoft Edge"|Vivaldi|Arc|com.operasoftware.*|MobileSync|AddressBook|CallHistoryDB|Knowledge|com.apple.*) continue ;;
        esac
        if is_running "$base"; then note_skip "$base"; continue; fi
        while IFS= read -r d; do
            case "$d" in */Bottles/*|*/Prefixes/*|*/tools/*|*/drive_c/*) continue ;; esac
            purge_dir "$d"
        done < <(find "$app" -xdev -maxdepth 4 -type d \( -name "Cache" -o -name "Code Cache" -o -name "GPUCache" \
                  -o -name "DawnCache" -o -name "DawnGraphiteCache" -o -name "DawnWebGPUCache" -o -name "GrShaderCache" \
                  -o -name "CachedData" -o -name "CacheStorage" -o -name "ScriptCache" -o -name "htmlcache" \
                  -o -name "appcache" -o -name "logs" \) -prune 2>/dev/null)
    done
fi

if has_cat "system_user_temp"; then
    echo "PROGRESS|55|Cleaning Per-User System Caches & Temp Files..."
    if [ -n "$USER_C_DIR" ] && [ -d "$USER_C_DIR" ]; then
        for item in "$USER_C_DIR"/*; do
            [ -e "$item" ] || continue
            base="$(basename "$item")"
            if is_shader_cache "$base"; then
                [ $CLEAR_SHADERS -eq 1 ] && purge_dir "$item"
                continue
            fi
            case "$base" in com.apple.*) continue ;; esac
            if is_running "$base"; then note_skip "$base"; continue; fi
            if [ -d "$item" ]; then purge_dir "$item"; else purge_path "$item"; fi
        done
    fi
    rm -rf "$TMPDIR"/com.google.*.ShipIt* "$TMPDIR"/*.dmg "$TMPDIR"/TemporaryItems/* 2>/dev/null
    find "$TMPDIR" -xdev -mindepth 1 -maxdepth 2 ! -type s -mtime +1 -exec rm -rf {} + 2>/dev/null
    find /private/tmp -xdev -user "$(whoami)" -mindepth 1 ! -type s -mtime +1 -exec rm -rf {} + 2>/dev/null
fi

if has_cat "bottles"; then
    echo "PROGRESS|64|Cleaning Wine / CrossOver / Heroic Bottle Temp Files..."
    if ! pgrep -x wineserver >/dev/null 2>&1; then
        for p in "$AS/CrossOver/Bottles"/* "$HOME/Games/Heroic/Prefixes"/* "$HOME/Games/Heroic/Prefixes/default"/*; do
            [ -d "$p/drive_c" ] || continue
            purge_dir "$p/drive_c/windows/temp"
            for u in "$p"/drive_c/users/*; do
                purge_dir "$u/AppData/Local/Temp"
                purge_dir "$u/AppData/Local/CrashDumps"
                purge_dir "$u/Temp"
            done
            for s in "$p/drive_c/Program Files (x86)/Steam" "$p/drive_c/Program Files/Steam"; do
                purge_dir "$s/appcache/httpcache"
                purge_dir "$s/config/htmlcache"
                purge_dir "$s/logs"
                purge_dir "$s/dumps"
            done
        done
    fi
fi

if has_cat "dev_caches"; then
    echo "PROGRESS|74|Cleaning Developer & Package Manager Caches..."
    command -v brew >/dev/null 2>&1 && brew cleanup --prune=all -s >/dev/null 2>&1
    if command -v uv >/dev/null 2>&1; then
        find "$HOME/.cache/uv/archive-v0" -mindepth 1 -maxdepth 1 -mtime +3 -exec rm -rf {} + 2>/dev/null
        uv cache prune --force >/dev/null 2>&1 || true
    fi
    if command -v npm >/dev/null 2>&1; then
        npm cache clean --force >/dev/null 2>&1
        purge_dir "$HOME/.npm/_cacache"; purge_dir "$HOME/.npm/_logs"; purge_dir "$HOME/.npm/_npx"
    fi
    command -v yarn >/dev/null 2>&1 && yarn cache clean >/dev/null 2>&1
    command -v pnpm >/dev/null 2>&1 && pnpm store prune >/dev/null 2>&1
    command -v go   >/dev/null 2>&1 && go clean -cache >/dev/null 2>&1
    purge_dir "$HOME/.cache/pip"
    purge_dir "$HOME/.gradle/caches"
    purge_dir "$HOME/.cargo/registry/cache"
    purge_dir "$HOME/Library/Developer/Xcode/DerivedData"
    purge_dir "$HOME/Library/Developer/CoreSimulator/Caches"
    purge_dir "$HOME/Library/Developer/Xcode/iOS Device Logs"
    if [ -d "$HOME/.cache" ] && [ ! -L "$HOME/.cache" ]; then
        for c_item in "$HOME/.cache"/* "$HOME/.cache"/.[!.]*; do
            [ -e "$c_item" ] || continue
            [ "$(basename "$c_item")" = "uv" ] && continue
            purge_path "$c_item"
        done
    fi
fi

if has_cat "system_data_bloat"; then
    echo "PROGRESS|82|Cleaning Heavy System Data Bloat (Chrome AI, Aerials, Clones)..."
    purge_path "$AS/Google/Chrome/OptGuideOnDeviceModel"
    purge_dir "$AS/com.apple.wallpaper/aerials/videos"
    [ -n "$USER_X_DIR" ] && purge_dir "$USER_X_DIR/com.google.Chrome.code_sign_clone"
    purge_dir "$AS/discord/download"
    if [ -d "$AS/discord" ]; then
        latest_disc=$(ls -1d "$AS/discord"/app-* 2>/dev/null | sort -V | tail -n 1)
        for d_ver in "$AS/discord"/app-*; do
            [ -d "$d_ver" ] && [ "$d_ver" != "$latest_disc" ] && purge_path "$d_ver"
        done
    fi
fi

if has_cat "shaders"; then
    echo "PROGRESS|88|Clearing GPU Shader Caches..."
    for sd in "$USER_C_DIR/d3dm" "$USER_C_DIR/com.apple.metal"; do
        [ -d "$sd" ] && purge_dir "$sd"
    done
fi

if has_cat "logs"; then
    echo "PROGRESS|91|Purging Logs, QuickLook & DNS Cache..."
    purge_dir "$HOME/Library/Logs"
    qlmanage -r cache >/dev/null 2>&1
    dscacheutil -flushcache 2>/dev/null
fi

if has_cat "trash"; then
    echo "PROGRESS|94|Emptying Trash..."
    purge_dir "$HOME/.Trash"
fi

if has_cat "system_wide" && [ "$(id -u)" -eq 0 ]; then
    echo "PROGRESS|97|Cleaning System-Wide Caches, Logs & APFS Snapshots..."
    find /Library/Caches -xdev -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    find /Library/Logs/DiagnosticReports -xdev -mindepth 1 -exec rm -rf {} + 2>/dev/null
    find /private/var/log -xdev -type f \( -name "*.gz" -o -name "*.bz2" -o -name "*.[0-9]" \) -exec rm -f {} + 2>/dev/null
    find /private/var/tmp -xdev -mindepth 1 ! -type s -mtime +3 -exec rm -rf {} + 2>/dev/null
    tmutil thinlocalsnapshots / 10000000000 4 >/dev/null 2>&1 || true
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
fi

END_KB=$(get_free_kb)
echo "PROGRESS|100|Cleanup complete!"
echo "RESULT|${START_KB}|${END_KB}|${CLEANED_KB}|${SKIPPED_APPS}"
