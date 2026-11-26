#!/bin/bash
# ---------------------------------------------------------------------------
#  Myskef — a tiny Windows-game launcher for macOS, built on Wine.
#  Wine (https://www.winehq.org) is free, open-source software (LGPL).
#  Wine engine builds are downloaded from Gcenx/macOS_Wine_builds on GitHub.
# ---------------------------------------------------------------------------
set -u
set -o pipefail
# Always run natively on Apple silicon. If this was started under Rosetta (for
# example with "Open using Rosetta" ticked), everything Myskef starts would be
# translated too: a slower window and the Intel build of every helper.
if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = "1" ] && [ -z "${MYSKEF_NATIVE:-}" ]; then
    export MYSKEF_NATIVE=1
    exec arch -arm64 /bin/bash "$0" "$@"
fi

APP_NAME="Myskef"
APP_VERSION="2.12.3"
SUPPORT="$HOME/Library/Application Support/Myskef"
ENGINE_DIR="$SUPPORT/engine"
BOTTLE="$SUPPORT/bottles/default"
LOG_DIR="$SUPPORT/logs"
LOG="$LOG_DIR/myskef.log"
CONFIG="$SUPPORT/config"
RELEASES_API="https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=15"
EPIC_MSI_URL="https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi"

mkdir -p "$ENGINE_DIR" "$BOTTLE" "$LOG_DIR"
touch "$CONFIG"
# Start a fresh log when it gets big (games can write thousands of lines per session).
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 5000000 ] && ! pgrep -f "legendary launch" >/dev/null 2>&1; then
    mv -f "$LOG" "$LOG_DIR/myskef.previous.log" 2>/dev/null
fi

# Run as "myskef-core.sh <command> [args]" for Myskef's window (output goes to
# the window and the log, no dialogs), or "myskef-core.sh menu" for the
# classic dialog menu.
MODE="${1:-menu}"
if [ "$MODE" = "running" ]; then   # polled by the window: quick, and not logged
    pgrep -x wineserver >/dev/null 2>&1 && echo "running=yes" || echo "running=no"; exit 0
fi
if [ "$MODE" = "menu" ]; then HEADLESS=0; else HEADLESS=1; fi
if [ "$HEADLESS" = 1 ]; then
    exec > >(tee -a "$LOG") 2>&1
else
    exec >>"$LOG" 2>&1
fi
echo "===== $APP_NAME $APP_VERSION: $MODE ${2:-} $(date) ====="

# --------------------------------------------------------------- UI helpers
# Text is passed to AppleScript as an argument, so quotes in messages are safe.

say_info() {   # say_info "message"
    osascript - "$1" <<'APPLESCRIPT' >/dev/null
on run argv
    display dialog (item 1 of argv) with title "Myskef" buttons {"OK"} default button "OK" with icon note
end run
APPLESCRIPT
}

say_error() {
    osascript - "$1" <<'APPLESCRIPT' >/dev/null
on run argv
    display dialog (item 1 of argv) with title "Myskef" buttons {"OK"} default button "OK" with icon stop
end run
APPLESCRIPT
}

ask_yes_no() { # ask_yes_no "question" "Yes label" -> returns 0 if confirmed
    local answer
    answer=$(osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
    try
        set r to display dialog (item 1 of argv) with title "Myskef" buttons {"Cancel", (item 2 of argv)} default button (item 2 of argv) with icon caution
        return button returned of r
    on error
        return "Cancel"
    end try
end run
APPLESCRIPT
)
    [ "$answer" = "$2" ]
}

notify() {
    osascript - "$1" <<'APPLESCRIPT' >/dev/null
on run argv
    display notification (item 1 of argv) with title "Myskef"
end run
APPLESCRIPT
}

pick_from_list() { # pick_from_list "prompt" item1 item2 ... -> prints choice or "false"
    osascript - "$@" <<'APPLESCRIPT'
on run argv
    set thePrompt to item 1 of argv
    set theItems to items 2 thru -1 of argv
    set r to choose from list theItems with title "Myskef" with prompt thePrompt default items {item 1 of theItems}
    if r is false then return "false"
    return item 1 of r
end run
APPLESCRIPT
}

pick_exe() {
    osascript <<'APPLESCRIPT'
try
    set f to choose file with prompt "Choose a Windows program (.exe or .msi) to run with Myskef:"
    return POSIX path of f
on error
    return ""
end try
APPLESCRIPT
}

# In the window, questions were already asked by the window itself, so answer
# yes; messages become tagged lines the window shows.
if [ "$HEADLESS" = 1 ]; then
    say_info()   { echo "INFO: $1"; }
    say_error()  { echo "ERROR: $1"; }
    ask_yes_no() { echo "STATUS: ${2:-OK}"; return 0; }
    notify()     { echo "STATUS: $1"; }
fi

# ------------------------------------------------------------- config / env
get_config() { grep -E "^$1=" "$CONFIG" 2>/dev/null | tail -n1 | cut -d= -f2-; }
set_config() {
    grep -vE "^$1=" "$CONFIG" > "$CONFIG.tmp" 2>/dev/null || true
    echo "$1=$2" >> "$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
}

find_wine() {
    local bundle bin
    bundle=$(find "$ENGINE_DIR" -maxdepth 1 -name "Wine*.app" -type d | head -n1)
    [ -n "$bundle" ] || return 1
    bin="$bundle/Contents/Resources/wine/bin"
    if [ -x "$bin/wine" ]; then WINE="$bin/wine"
    elif [ -x "$bin/wine64" ]; then WINE="$bin/wine64"
    else return 1; fi
    WINESERVER="$bin/wineserver"
    return 0
}

setup_env() {
    export WINEPREFIX="$BOTTLE"
    export WINEDEBUG="${WINEDEBUG:--all}"
    # These Wine builds have no OpenGL, so Direct3D goes through Vulkan -> MoltenVK -> Metal.
    # (Used only when DXVK is switched off.)
    export WINE_D3D_CONFIG="renderer=vulkan"
    export MVK_CONFIG_RESUME_LOST_DEVICE=1
    perf_env
}

# Speed settings, applied to everything Myskef launches.
perf_env() {
    if [ "$(get_config DEBUG)" != "on" ]; then
        export DXVK_LOG_LEVEL=none MVK_CONFIG_LOG_LEVEL=0 DXMT_LOG_PATH=none   # no log writing while playing
    fi
    # Rosetta can translate AVX/AVX2 (macOS 15+), but only tells games when asked;
    # some newer games refuse to start without it.
    if [ "$(get_config AVX)" = "on" ]; then export ROSETTA_ADVERTISE_AVX=1; else unset ROSETTA_ADVERTISE_AVX; fi
    export WINEMSYNC=1                                       # faster thread sync, if the engine supports it
    # MoltenVK (Vulkan -> Metal, used by DXVK and by Vulkan games):
    export MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1   # compile shaders on all cores: less stutter
    if [ "$(get_config FAST_SUBMIT)" != "off" ]; then
        export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0        # hand frames to Metal off the game's render thread
    else
        unset MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS
    fi
    # FPS counter: Apple's Metal HUD works for DirectX (via DXVK) and Vulkan games alike
    unset DXVK_HUD
    if [ "$(get_config FPS_HUD)" = "on" ]; then export MTL_HUD_ENABLED=1; else unset MTL_HUD_ENABLED; fi
    local cap; cap=$(get_config FPS_CAP)
    case "$cap" in 30|60) export DXVK_FRAME_RATE="$cap" ;; *) unset DXVK_FRAME_RATE ;; esac
    # Input delay (DXVK): by default a game may queue up to 3 frames ahead of
    # the GPU, and each queued frame is delay between your click and the screen.
    local conf="$SUPPORT/dxvk.conf"
    {
        echo "# written by Myskef; changed in Settings → Performance"
        if [ "$(get_config LOW_LATENCY)" != "off" ]; then
            echo "dxgi.maxFrameLatency = 1"
            echo "d3d9.maxFrameLatency = 1"
        fi
        if [ "$(get_config VSYNC)" = "off" ]; then
            echo "dxgi.syncInterval = 0"
            echo "d3d9.presentInterval = 0"
        fi
    } > "$conf"
    export DXVK_CONFIG_FILE="$conf"
}

perf_menu() {
    local hud cap choice
    while true; do
        hud=$(get_config FPS_HUD); [ "$hud" = "on" ] || hud="off"
        cap=$(get_config FPS_CAP); case "$cap" in 30|60) ;; *) cap="off" ;; esac
        choice=$(pick_from_list "Performance. A steady 60 FPS cap keeps a MacBook cooler, so it doesn't slow itself down in long games. The FPS counter shows in the game's top-left corner." \
            "FPS counter: $hud  (click to switch)" \
            "Frame-rate cap: $cap  (click to change)" \
            "Done")
        case "$choice" in
            "FPS counter"*) [ "$hud" = "on" ] && set_config FPS_HUD off || set_config FPS_HUD on ;;
            "Frame-rate cap"*)
                case "$cap" in off) set_config FPS_CAP 60 ;; 60) set_config FPS_CAP 30 ;; *) set_config FPS_CAP off ;; esac ;;
            *) return ;;
        esac
    done
}

# ---------------------------------------------------------------- set up
check_rosetta() {
    [ "$(uname -m)" = "arm64" ] || return 0          # Intel Mac: nothing to do
    arch -x86_64 /usr/bin/true 2>/dev/null && return 0
    if ask_yes_no "Myskef's Wine engine needs Apple's Rosetta 2, which isn't installed yet. Install it now? (Free, from Apple, about a minute.)" "Install Rosetta"; then
        notify "Installing Rosetta 2…"
        if softwareupdate --install-rosetta --agree-to-license; then return 0; fi
        say_error "Rosetta couldn't be installed automatically. Open Terminal and run:
softwareupdate --install-rosetta"
    fi
    return 1
}

install_engine() {
    find_wine && return 0
    notify "Looking up the latest Wine engine…"
    local urls url tmp
    urls=$(curl -fsSL "$RELEASES_API" | grep -oE '"browser_download_url": *"[^"]+"' | sed -E 's/.*"(https[^"]+)"/\1/')
    # wine-devel first: newer Unity games (BTD6 included) need Wine 11.3+ for the
    # mouse to work (EnableMouseInPointer / WM_POINTER), and wine-stable is 11.0.
    url=$(printf '%s\n' "$urls" | grep -E '/wine-devel[^/]*\.tar\.xz$' | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$urls" | grep -E '/wine-stable[^/]*\.tar\.xz$' | head -n1)
    if [ -z "$url" ]; then
        say_error "Couldn't find a Wine engine to download. Check your internet connection and try again.

(Details are in: $LOG)"
        return 1
    fi
    echo "Engine URL: $url"
    notify "Downloading the Wine engine (about 200 MB)…"
    tmp="$SUPPORT/engine-download.tar.xz"
    if ! curl -fL --retry 3 -o "$tmp" "$url"; then
        say_error "The Wine engine download failed. Try again in a moment."
        rm -f "$tmp"; return 1
    fi
    notify "Unpacking the Wine engine…"
    if ! tar -xJf "$tmp" -C "$ENGINE_DIR"; then
        say_error "Couldn't unpack the Wine engine. The download may be damaged; try again."
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    xattr -dr com.apple.quarantine "$ENGINE_DIR" 2>/dev/null || true
    find_wine || { say_error "The Wine engine was downloaded but Myskef couldn't find it inside."; return 1; }
    echo "Engine ready: $WINE"
}

init_bottle() {
    setup_env
    if [ ! -f "$BOTTLE/system.reg" ]; then
        notify "Creating your Windows bottle (first time only)…"
        "$WINE" wineboot --init
        "$WINESERVER" -w
        "$WINE" reg add 'HKCU\Software\Wine' /v Version /d win10 /f
        "$WINESERVER" -w
    fi
}

# DXVK-macOS: free Direct3D 10/11 -> Vulkan translator for Wine on Mac.
# Wine's built-in D3D can't offer the D3D11 feature levels the Epic launcher
# and Unity games need on MoltenVK, so Myskef installs DXVK into the bottle.
DXVK_API="https://api.github.com/repos/Gcenx/DXVK-macOS/releases?per_page=5"
DXVK_MARKER="$BOTTLE/.myskef-dxvk2"
# DXVK-macOS ships d3d11/d3d10 DLLs but deliberately NO dxgi.dll (Wine's own dxgi is used).
DXVK_DLLS="d3d11 d3d10core d3d10 d3d10_1"

install_dxvk() {
    [ -f "$DXVK_MARKER" ] && return 0
    notify "Installing the DXVK graphics layer…"
    local urls url tmpdir dll f kind copied=""
    # Undo Myskef 1.1's dxgi override (there is no native dxgi.dll to load).
    "$WINE" reg delete 'HKCU\Software\Wine\DllOverrides' /v dxgi /f 2>/dev/null
    urls=$(curl -fsSL "$DXVK_API" | grep -oE '"browser_download_url": *"[^"]+"' \
           | sed -E 's/.*"(https[^"]+)"/\1/' | grep -E '\.tar\.(gz|xz)$')
    # Prefer the normal build over the "builtin" and "async" variants.
    url=$(printf '%s\n' "$urls" | grep -viE 'builtin|async' | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$urls" | grep -vi builtin | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$urls" | head -n1)
    if [ -z "$url" ]; then
        say_error "Couldn't find the DXVK graphics layer to download. Check your internet connection and try again."
        return 1
    fi
    echo "DXVK URL: $url"
    tmpdir=$(mktemp -d)
    if ! curl -fL --retry 3 -o "$tmpdir/dxvk.tar" "$url" || ! tar -xf "$tmpdir/dxvk.tar" -C "$tmpdir"; then
        say_error "The DXVK download failed. Try again in a moment."
        rm -rf "$tmpdir"; return 1
    fi
    echo "DXVK archive contents:"; find "$tmpdir" -name '*.dll'
    for dll in $DXVK_DLLS; do
        # Decide 64- vs 32-bit by reading each DLL's header, not by folder name.
        while IFS= read -r f; do
            kind=$(file -b "$f")
            case "$kind" in
                *x86-64*) cp -f "$f" "$BOTTLE/drive_c/windows/system32/$dll.dll" && copied="$copied $dll" ;;
                *80386*)  [ -d "$BOTTLE/drive_c/windows/syswow64" ] && cp -f "$f" "$BOTTLE/drive_c/windows/syswow64/$dll.dll" ;;
            esac
        done < <(find "$tmpdir" -name "$dll.dll")
    done
    rm -rf "$tmpdir"
    if [ -z "$copied" ]; then
        say_error "DXVK downloaded, but Myskef couldn't find its 64-bit DLLs inside. Please send the log (Show log) so this can be fixed."
        return 1
    fi
    for dll in $(printf '%s\n' $copied | sort -u); do
        "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d "native,builtin" /f
    done
    "$WINESERVER" -w
    date > "$DXVK_MARKER"
    echo "DXVK installed:$copied"
}

remove_dxvk() {
    setup_env
    for dll in $DXVK_DLLS dxgi; do
        "$WINE" reg delete 'HKCU\Software\Wine\DllOverrides' /v "$dll" /f 2>/dev/null
    done
    "$WINESERVER" -w
    # Restore Wine's own DLLs
    "$WINE" wineboot -u
    "$WINESERVER" -w
    rm -f "$DXVK_MARKER"
}

epic_exe() {
    local base="$BOTTLE/drive_c/Program Files (x86)/Epic Games/Launcher/Portal/Binaries"
    for p in "$base/Win64/EpicGamesLauncher.exe" "$base/Win32/EpicGamesLauncher.exe" \
             "$BOTTLE/drive_c/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

install_epic() {
    epic_exe >/dev/null && return 0
    notify "Downloading the Epic Games Launcher…"
    local msi="$SUPPORT/EpicInstaller.msi"
    if ! curl -fL --retry 3 -o "$msi" "$EPIC_MSI_URL"; then
        say_error "Couldn't download the Epic Games Launcher installer."
        return 1
    fi
    notify "Installing the Epic Games Launcher…"
    "$WINE" msiexec /i "$msi" /q
    "$WINESERVER" -w
    rm -f "$msi"
    epic_exe >/dev/null || { say_error "The Epic Games Launcher didn't install correctly. Try 'Set up' again, or see the log."; return 1; }
}

full_setup() {
    check_rosetta || return 1
    install_engine || return 1
    init_bottle
    if [ "$(get_config GRAPHICS)" != "wined3d" ]; then install_dxvk || return 1; fi
    install_epic || return 1
    say_info "Myskef is ready!

To play Bloons TD 6:
1. Choose 'Open Epic Games Launcher'.
2. Log in, go to Library, install Bloons TD 6.
3. Press Launch. If the game asks for permission to use your Epic account, press Confirm."
}

# ------------------------------------------------------- engine updates
MIN_WINE="11.3"   # first Wine with mouse support for newer Unity games
engine_version() { "$WINE" --version 2>/dev/null | sed -nE 's/^wine-([0-9]+\.[0-9]+).*/\1/p'; }
version_lt() {    # version_lt A B  ->  true if A < B
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n | head -n1)" = "$1" ]
}
wait_wineserver() {  # wineserver -w, but never longer than $1 seconds
    "$WINESERVER" -w & local p=$! i
    for i in $(seq "${1:-60}"); do kill -0 "$p" 2>/dev/null || return 0; sleep 1; done
    "$WINESERVER" -k 2>/dev/null; kill "$p" 2>/dev/null; return 0
}
ensure_engine_fresh() {
    find_wine || return 0
    local v; v=$(engine_version)
    [ -n "$v" ] && version_lt "$v" "$MIN_WINE" || return 0
    if [ "$HEADLESS" = 1 ] && [ "${FORCE_ENGINE_UPDATE:-0}" != 1 ]; then
        echo "STATUS: A Wine engine update is available (Settings → Engine)."; return 0
    fi
    ask_yes_no "Myskef's Wine engine (Wine $v) is too old for the mouse in newer games like Bloons TD 6: the game starts but ignores clicks.

Update the engine now? It's a free download of about 200 MB and takes a few minutes. Your bottle and downloaded games stay as they are." "Update engine" || return 0
    setup_env
    "$WINESERVER" -k 2>/dev/null
    local old="$SUPPORT/engine-old"
    rm -rf "$old"; mkdir -p "$old"
    find "$ENGINE_DIR" -maxdepth 1 -name "Wine*.app" -type d -exec mv {} "$old/" \;
    if ! install_engine; then
        find "$old" -maxdepth 1 -name "Wine*.app" -type d -exec mv {} "$ENGINE_DIR/" \;
        find_wine; return 1
    fi
    rm -rf "$old"
    setup_env
    notify "Updating your bottle for the new engine…"
    "$WINE" wineboot -u
    wait_wineserver 120
    rm -f "$DXVK_MARKER"   # reinstall DXVK on top of the updated bottle
    echo "Engine updated: $v -> $(engine_version)"
    notify "Wine engine updated to $(engine_version)"
}

ensure_ready() {
    if find_wine && [ -f "$BOTTLE/system.reg" ]; then ensure_engine_fresh; return 0; fi
    ask_yes_no "Myskef isn't set up yet. Set it up now? It downloads the free Wine engine and creates your Windows bottle." "Set up" || return 1
    check_rosetta || return 1
    install_engine || return 1
    init_bottle
}

# ------------------------------------------------------------------ DXMT
# DXMT (github.com/3Shain/dxmt, LGPL) translates Direct3D 10/11 straight to
# Metal, skipping DXVK -> Vulkan -> MoltenVK, which is often much faster.
# It replaces Wine's own d3d11/dxgi, so it lives in a second copy of the
# engine (an APFS clone, so it takes almost no extra disk space). Games set
# to DXMT run with that copy; everything else keeps the normal engine.
# Gcenx's Wine builds export the macOS-driver functions DXMT needs.
DXMT_API="https://api.github.com/repos/3Shain/dxmt/releases/latest"
DXMT_DIR="$SUPPORT/engine-dxmt"

dxmt_wine() {  # path of the DXMT engine's wine, if installed
    local b; b=$(find "$DXMT_DIR" -maxdepth 1 -name "Wine*.app" -type d 2>/dev/null | head -n1)
    [ -n "$b" ] && [ -x "$b/Contents/Resources/wine/bin/wine" ] && echo "$b/Contents/Resources/wine/bin/wine"
}

pick_x64() {  # pick_x64 <dir> <file name> -> the 64-bit copy of that DLL
    local f
    find "$1" -name "$2" | while IFS= read -r f; do
        file -b "$f" | grep -q 'x86-64' && { echo "$f"; break; }
    done
}

dxmt_prefix_files() {  # winemetal.dll also has to be in the bottle's system32
    local w; w=$(dxmt_wine) || return 0
    cp -f "$(dirname "$w")/../lib/wine/x86_64-windows/winemetal.dll" "$BOTTLE/drive_c/windows/system32/winemetal.dll" 2>/dev/null
    return 0
}

install_dxmt() {
    find_wine || return 1
    local want; want=$(engine_version)
    if [ -n "$(dxmt_wine)" ] && [ "$(cat "$DXMT_DIR/.engine" 2>/dev/null)" = "$want" ]; then
        dxmt_prefix_files; return 0
    fi
    echo "STATUS: Downloading DXMT (Direct3D to Metal)…"
    local urls url tmp bundle lib f n
    urls=$(curl -fsSL "$DXMT_API" | grep -oE '"browser_download_url": *"[^"]+"' | sed -E 's/.*"(https[^"]+)"/\1/')
    url=$(printf '%s\n' "$urls" | grep -E 'builtin.*\.tar\.(gz|xz)$' | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$urls" | grep -E '\.tar\.(gz|xz)$' | head -n1)
    [ -n "$url" ] || { echo "ERROR: Couldn't find DXMT to download. Check your internet connection and try again."; return 1; }
    echo "DXMT URL: $url"
    tmp=$(mktemp -d)
    if ! curl -fL --retry 3 -o "$tmp/dxmt.tar" "$url" || ! tar -xf "$tmp/dxmt.tar" -C "$tmp"; then
        echo "ERROR: The DXMT download failed. Try again in a moment."; rm -rf "$tmp"; return 1
    fi
    echo "DXMT files:"; find "$tmp" -type f \( -name '*.dll' -o -name '*.so' \) | sed "s#^$tmp/##"
    echo "STATUS: Preparing a DXMT copy of the Wine engine…"
    bundle=$(cd "$(dirname "$WINE")/../../../.." && pwd)
    rm -rf "$DXMT_DIR"; mkdir -p "$DXMT_DIR"
    cp -cpR "$bundle" "$DXMT_DIR/" 2>/dev/null || cp -pR "$bundle" "$DXMT_DIR/"
    lib="$(dirname "$(dxmt_wine)")/../lib/wine"
    if [ ! -d "$lib/x86_64-windows" ] || [ ! -d "$lib/x86_64-unix" ]; then
        echo "ERROR: Unexpected Wine engine layout; DXMT wasn't installed."; rm -rf "$tmp" "$DXMT_DIR"; return 1
    fi
    local got=" "
    for n in winemetal.dll d3d11.dll dxgi.dll d3d10core.dll; do
        f=$(pick_x64 "$tmp" "$n")
        if [ -n "$f" ] && cp -f "$f" "$lib/x86_64-windows/$n"; then got="$got$n "; fi
    done
    f=$(find "$tmp" -name winemetal.so | head -n1)
    if [ -n "$f" ] && cp -f "$f" "$lib/x86_64-unix/winemetal.so"; then got="${got}winemetal.so "; fi
    rm -rf "$tmp"
    echo "installed:$got"
    for n in winemetal.dll d3d11.dll dxgi.dll winemetal.so; do
        case "$got" in *" $n "*) ;; *)
            echo "ERROR: The DXMT download didn't contain $n. Open the details and send them to Claude."
            rm -rf "$DXMT_DIR"; return 1 ;;
        esac
    done
    xattr -dr com.apple.quarantine "$DXMT_DIR" 2>/dev/null
    echo "$want" > "$DXMT_DIR/.engine"
    basename "$url" > "$DXMT_DIR/.dxmt"
    dxmt_prefix_files
    echo "STATUS: DXMT is ready ($(basename "$url"))."
}

global_gfx() { case "$(get_config GRAPHICS)" in wined3d|dxmt) get_config GRAPHICS ;; *) echo dxvk ;; esac; }
game_gfx() {   # game_gfx <app> -> that game's graphics layer (or the global one)
    local g; g=$(get_config "GAME_${1}_GFX")
    case "$g" in dxvk|dxmt|wined3d|d3dmetal) echo "$g" ;; *) global_gfx ;; esac
}

# Pick the engine and DLL overrides for what launches next:
#   dxvk    normal engine, DXVK's d3d11 from the bottle (registry default)
#   dxmt    DXMT engine copy, its built-in d3d11/dxgi
#   wined3d normal engine, Wine's own d3d11
# ------------------------------------------- D3DMetal (Apple's Game Porting Toolkit)
# Apple's own DirectX 11/12 -> Metal translator, in Gcenx's free build of the
# Game Porting Toolkit. It only works with its own Wine (7.7), so it gets its own
# Windows bottle; games stay where they are installed.
GPTK_URL="https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz"
GPTK_SHA256="d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e"
GPTK_DIR="$SUPPORT/engine-gptk"
GPTK_BOTTLE="$SUPPORT/bottles/d3dmetal"
gptk_wine() {
    local w="$GPTK_DIR/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
    [ -x "$w" ] && [ -f "$GPTK_DIR/.ok" ] && echo "$w"
}
gptk_wineserver() { local w; w=$(gptk_wine) && echo "$(dirname "$w")/wineserver"; }

install_gptk() {
    [ -n "$(gptk_wine)" ] && return 0
    if [ "$(uname -m)" != "arm64" ]; then
        echo "ERROR: D3DMetal needs a Mac with Apple silicon (M1 or newer)."; return 1
    fi
    if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ] 2>/dev/null; then
        echo "ERROR: D3DMetal needs macOS 14 Sonoma or newer."; return 1
    fi
    local tmp="$SUPPORT/gptk.tar.xz"
    echo "STATUS: Downloading Apple's D3DMetal (about 230 MB, only once)…"
    if ! curl -fL --retry 3 -o "$tmp" "$GPTK_URL"; then
        rm -f "$tmp"; echo "ERROR: Couldn't download D3DMetal. Check your internet connection and try again."; return 1
    fi
    if [ "$(shasum -a 256 "$tmp" | awk '{print $1}')" != "$GPTK_SHA256" ]; then
        rm -f "$tmp"; echo "ERROR: The D3DMetal download was damaged. Try again."; return 1
    fi
    echo "STATUS: Unpacking D3DMetal…"
    rm -rf "$GPTK_DIR"; mkdir -p "$GPTK_DIR"
    if ! tar -xJf "$tmp" -C "$GPTK_DIR"; then
        rm -f "$tmp"; rm -rf "$GPTK_DIR"; echo "ERROR: Couldn't unpack D3DMetal (is the disk full?)."; return 1
    fi
    rm -f "$tmp"
    xattr -dr com.apple.quarantine "$GPTK_DIR" 2>/dev/null
    if [ ! -x "$GPTK_DIR/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64" ] ||
       [ ! -d "$GPTK_DIR/Game Porting Toolkit.app/Contents/Resources/wine/lib/external/D3DMetal.framework" ]; then
        echo "ERROR: The D3DMetal download didn't contain the expected files."; rm -rf "$GPTK_DIR"; return 1
    fi
    date > "$GPTK_DIR/.ok"
    echo "D3DMetal installed in $GPTK_DIR"
}

# Switch this run to the D3DMetal engine and its bottle (created on first use).
use_gptk() {
    install_gptk || return 1
    WINE=$(gptk_wine); WINESERVER=$(gptk_wineserver)
    BOTTLE="$GPTK_BOTTLE"; export WINEPREFIX="$BOTTLE"
    STEAM_DIR="$BOTTLE/drive_c/Program Files (x86)/Steam"; STEAM_EXE="$STEAM_DIR/steam.exe"
    STEAM_MARKER="$BOTTLE/.myskef-steam4"
    unset WINEDLLOVERRIDES
    export WINEESYNC=1                       # this Wine has esync, not msync
    if [ ! -f "$BOTTLE/system.reg" ]; then
        echo "STATUS: Preparing D3DMetal's Windows setup (first time only, about a minute)…"
        mkdir -p "$BOTTLE"
        WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all "$WINE" wineboot -i >>"$LOG" 2>&1
        "$WINESERVER" -w 2>/dev/null
        WINEDEBUG=-all "$WINE" reg add 'HKCU\Software\Wine' /v Version /d win10 /f >>"$LOG" 2>&1
        [ -f "$BOTTLE/system.reg" ] || { echo "ERROR: Couldn't create D3DMetal's Windows setup. Open the details to see why."; return 1; }
    fi
    GFX_SELECTED=1
    echo "graphics layer: d3dmetal ($WINE, bottle $BOTTLE)"
}

# Close whatever runs in the D3DMetal bottle (e.g. its Steam).
stop_gptk() {
    local ws; ws=$(gptk_wineserver) || return 0
    [ -f "$GPTK_BOTTLE/system.reg" ] || return 0
    WINEPREFIX="$GPTK_BOTTLE" "$ws" -k 2>/dev/null
    return 0
}

use_graphics() {
    if [ "$1" = "d3dmetal" ]; then use_gptk; return; fi
    find_wine || return 1
    case "$1" in
        dxmt)
            install_dxmt || return 1
            WINE=$(dxmt_wine); WINESERVER="$(dirname "$WINE")/wineserver"
            export WINEDLLOVERRIDES="d3d11,d3d10core,d3d10,d3d10_1,dxgi=b" ;;
        wined3d)
            export WINEDLLOVERRIDES="d3d11,d3d10core,d3d10,d3d10_1=b" ;;
        *)  unset WINEDLLOVERRIDES ;;
    esac
    GFX_SELECTED=1
    echo "graphics layer: $1 ($WINE)"
}

ensure_graphics() {  # DXVK is always kept installed (games can choose it)
    setup_env
    install_dxvk || return 1
    [ "$(get_config GRAPHICS)" = "dxmt" ] && { install_dxmt || return 1; }
    return 0
}


# ------------------------------------------------- Epic Online Services fix
# Epic's EOS installer can't finish under Wine (its .NET steps fail or hang).
# Resources/myskef-eos-fix.sh installs it with those steps switched off and
# does their work itself. See the comments in that script.
APP_RES="$(cd "$(dirname "$0")" && pwd)"   # this script lives in Resources

eos_installer_path() {
    find "$BOTTLE/drive_c/Program Files/Epic Games/Launcher/Portal/Extras/EOS" \
         "$BOTTLE/drive_c/Program Files (x86)/Epic Games/Launcher/Portal/Extras/EOS" \
         -iname '*Installer*.exe' 2>/dev/null | head -n1
}

fix_eos() {
    ensure_ready || return
    local eos
    eos=$(eos_installer_path)
    if [ -z "$eos" ]; then
        say_error "Myskef couldn't find Epic's Online Services installer. Open the Epic Games Launcher once first (it downloads it), then try again."
        return
    fi
    ask_yes_no "This fixes the purple 'Epic Online Services is not installed' banner.

Myskef will close the Epic launcher, install Epic Online Services in a way that works under Wine, and register it. It takes about 1–3 minutes.

A Terminal window will show the progress. Wait until it says DONE." "Start" || return

    setup_env
    local job="$SUPPORT/fix-eos.command"
    {
        echo '#!/bin/bash'
        printf 'export WINEPREFIX=%q WINE=%q WINESERVER=%q BOTTLE=%q EOS_INSTALLER=%q\n' \
            "$BOTTLE" "$WINE" "$WINESERVER" "$BOTTLE" "$eos"
        printf 'exec /bin/bash %q\n' "$APP_RES/myskef-eos-fix.sh"
    } > "$job"
    chmod +x "$job"
    open -a Terminal "$job"
}


# ------------------------------------------- Epic games without the launcher
# Resources/myskef-epic.sh uses legendary (open-source Epic client) to log in,
# download a game you own into the bottle, and launch it through Myskef.
epic_job() { # epic_job install|launch "<title>"
    setup_env
    local job="$SUPPORT/epic-$1.command"
    {
        echo '#!/bin/bash'
        printf 'export SUPPORT=%q BOTTLE=%q WINEPREFIX=%q WINE=%q WINESERVER=%q WINE_D3D_CONFIG=%q WINEDEBUG=-all\n' \
            "$SUPPORT" "$BOTTLE" "$BOTTLE" "$WINE" "$WINESERVER" "${WINE_D3D_CONFIG:-}"
        export -p | grep -E ' (DXVK_|DXMT_|MVK_CONFIG_|MTL_HUD|WINEMSYNC|WINEESYNC|WINEDLLOVERRIDES|ROSETTA_ADVERTISE_AVX|MYSKEF_GAME_ARGS)'
        printf 'exec /bin/bash %q %q %q\n' "$APP_RES/myskef-epic.sh" "$1" "$2"
    } > "$job"
    chmod +x "$job"
    echo "$job"
}

epic_download() { # epic_download "<title>"
    ensure_ready || return
    ensure_graphics || return
    local title="$1"
    ask_yes_no "Myskef will download \"$title\" straight from your Epic account — no Epic Games Launcher needed.

A Terminal window will open. The first time, it asks you to log in to Epic in your browser and paste a code. Then it shows the download progress. Wait until it says DONE." "Download" || return
    open -a Terminal "$(epic_job install "$title")"
}

# The Epic Games Launcher adds itself to Windows' "Run at startup" list, so
# every time the bottle starts (e.g. for BTD6) the launcher opens too and eats
# CPU/RAM. Games installed through Myskef don't need it, so switch that off.
disable_epic_autostart() {
    local reg="$BOTTLE/user.reg"
    [ -f "$reg" ] && grep -q 'EpicGamesLauncher.exe' "$reg" || return 0
    if pgrep -x wineserver >/dev/null 2>&1; then
        "$WINE" reg delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v EpicGamesLauncher /f 2>/dev/null
        return 0
    fi
    awk 'BEGIN { run = "[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run]" }
         /^\[/ { inrun = (index($0, run) == 1) }
         inrun && index($0, "EpicGamesLauncher.exe") { next }
         { print }' "$reg" > "$reg.myskef" && mv "$reg.myskef" "$reg"
    echo "Turned off Epic launcher autostart"
}

epic_play() { # epic_play "<title>"
    ensure_ready || return
    ensure_graphics || return
    disable_epic_autostart
    local title="$1" job
    if [ ! -x "$SUPPORT/legendary/legendary" ]; then
        ask_yes_no "\"$title\" isn't downloaded yet. Download it now?" "Download" && epic_download "$title"
        return
    fi
    job=$(epic_job launch "$app")
    notify "Starting $title…"
    nohup /bin/bash "$job" >>"$LOG" 2>&1 &
    start_ngen_guard
    sleep 8
    if tail -n 5 "$LOG" | grep -q "is not installed"; then
        ask_yes_no "\"$title\" isn't downloaded yet. Download it now?" "Download" && epic_download "$title"
    fi
}

epic_other() {
    local t
    t=$(osascript <<'APPLESCRIPT'
try
    set r to display dialog "Which Epic game? Type part of its name exactly as it appears in your Epic library:" default answer "" with title "Myskef" buttons {"Cancel", "Download"} default button "Download"
    return text returned of r
on error
    return ""
end try
APPLESCRIPT
)
    [ -n "$t" ] && epic_download "$t"
}

# ---------------------------------------------------------------- actions
launch_detached() { # launch_detached <args...>
    setup_env
    [ -n "${GFX_SELECTED:-}" ] || use_graphics "$(global_gfx)" >>"$LOG" 2>&1
    nohup "$WINE" "$@" >>"$LOG" 2>&1 &
    start_ngen_guard
}

# .NET's background pre-compiler (ngen/mscorsvw) can spin forever under Wine.
# While Wine is running, stop any of its workers that run for 3+ minutes.
start_ngen_guard() {
    pgrep -f "myskef-ngen-guard" >/dev/null 2>&1 && return
    nohup /bin/bash -c '
        # myskef-ngen-guard
        sleep 10
        while pgrep -x wineserver >/dev/null 2>&1; do
            ps -axo pid=,etime=,command= | grep -E "ngen\.exe|mscorsvw\.exe" | grep -v grep |
            while read -r pid et cmd; do
                case "$et" in 0[3-9]:*|[1-5][0-9]:*|*:*:*|*-*)
                    echo "$(date) myskef: stopped stuck .NET pre-compiler $pid ($et)"; kill "$pid" ;;
                esac
            done
            sleep 30
        done' >>"$LOG" 2>&1 &
}

open_epic() {
    ensure_ready || return
    ensure_graphics || return
    local exe
    if ! exe=$(epic_exe); then
        install_epic || return
        exe=$(epic_exe) || return
    fi
    notify "Starting the Epic Games Launcher… (the first start can take a minute)"
    launch_detached "$exe" -SkipBuildPatchPrereq
}

run_program() {
    ensure_ready || return
    ensure_graphics || return
    local f; f=$(pick_exe)
    [ -n "$f" ] || return
    case "$f" in
        *.msi|*.MSI) launch_detached msiexec /i "$f" ;;
        *)           (cd "$(dirname "$f")" && launch_detached "$f") ;;
    esac
}

graphics_menu() {
    local current choice
    current=$(get_config GRAPHICS); [ "$current" = "wined3d" ] || current="DXVK"
    choice=$(pick_from_list "Graphics layer (now: $current). DXVK is recommended: Wine's built-in layer can't run DirectX 11 apps like the Epic launcher on Apple GPUs." \
        "DXVK (recommended)" "Wine built-in")
    case "$choice" in
        "DXVK (recommended)")
            set_config GRAPHICS dxvk
            ensure_ready && setup_env && install_dxvk && notify "Graphics layer: DXVK" ;;
        "Wine built-in")
            set_config GRAPHICS wined3d
            find_wine && [ -f "$DXVK_MARKER" ] && remove_dxvk
            notify "Graphics layer: Wine built-in" ;;
    esac
}

debug_toggle() {
    if ask_yes_no "Turn on detailed Wine logging for the next launch? (Useful if a game crashes; it makes games slower.)" "Turn on"; then
        set_config DEBUG on
    else
        set_config DEBUG off
    fi
}

reset_bottle() {
    ask_yes_no "This deletes your Myskef Windows bottle, including the Epic launcher and any games installed inside it. Your BTD6 progress is saved to your account, but downloads will need to be redone. Continue?" "Delete bottle" || return
    find_wine && WINEPREFIX="$BOTTLE" "$WINESERVER" -k 2>/dev/null
    rm -rf "$BOTTLE"
    mkdir -p "$BOTTLE"
    say_info "Bottle deleted. Choose 'Set up' to create a fresh one."
}

force_quit() {
    find_wine && WINEPREFIX="$BOTTLE" "$WINESERVER" -k 2>/dev/null
    notify "All Windows programs in Myskef were closed."
}

# ------------------------------------------------------------------ main
# ------------------------------------------------------ window commands
# Everything Myskef's window can ask for. Each prints progress lines and ends
# with DONE on success (exit status 0) or an ERROR: line (exit status 1).

run_epic() {  # run_epic <myskef-epic.sh args...>  (no keyboard: never waits for input)
    setup_env
    SUPPORT="$SUPPORT" BOTTLE="$BOTTLE" WINE="${WINE:-}" WINESERVER="${WINESERVER:-}" \
        /bin/bash "$APP_RES/myskef-epic.sh" "$@" </dev/null
}

cli_status() {
    local v="" ok="no" acct=""
    echo "version=$APP_VERSION"
    if [ "$(uname -m)" != "arm64" ] || arch -x86_64 /usr/bin/true 2>/dev/null; then echo "rosetta=ok"; else echo "rosetta=missing"; fi
    if find_wine; then
        v=$(engine_version)
        { [ -n "$v" ] && ! version_lt "$v" "$MIN_WINE"; } && ok="yes"
        echo "engine=${v:-unknown}"
    else
        echo "engine=none"
    fi
    echo "engine_ok=$ok"
    [ -f "$BOTTLE/system.reg" ] && echo "bottle=yes" || echo "bottle=no"
    echo "graphics=$(global_gfx)"
    [ -n "$(dxmt_wine)" ] && echo "dxmt=$(cat "$DXMT_DIR/.dxmt" 2>/dev/null)" || echo "dxmt=no"
    [ "$(get_config AVX)" = "on" ] && echo "avx=on" || echo "avx=off"
    grep -E '^GAME_[A-Za-z0-9_.:-]+_(GFX|ARGS)=' "$CONFIG" 2>/dev/null
    [ -f "$DXVK_MARKER" ] && echo "dxvk=yes" || echo "dxvk=no"
    [ "$(get_config FPS_HUD)" = "on" ] && echo "fps_hud=on" || echo "fps_hud=off"
    case "$(get_config FPS_CAP)" in 30|60) echo "fps_cap=$(get_config FPS_CAP)" ;; *) echo "fps_cap=off" ;; esac
    [ "$(get_config DEBUG)" = "on" ] && echo "debug=on" || echo "debug=off"
    [ "$(get_config FAST_SUBMIT)" = "off" ] && echo "fast_submit=off" || echo "fast_submit=on"
    [ "$(get_config LOW_LATENCY)" = "off" ] && echo "low_latency=off" || echo "low_latency=on"
    [ "$(get_config UNITY_NOLOG)" = "off" ] && echo "unity_nolog=off" || echo "unity_nolog=on"
    [ "$(get_config CLOSE_STEAM)" = "off" ] && echo "close_steam=off" || echo "close_steam=on"
    [ -n "$(gptk_wine)" ] && echo "d3dmetal=yes" || echo "d3dmetal=no"
    [ "$(get_config VSYNC)" = "off" ] && echo "vsync=off" || echo "vsync=game"
    pgrep -x wineserver >/dev/null 2>&1 && echo "running=yes" || echo "running=no"
    epic_exe >/dev/null 2>&1 && echo "epic_launcher=yes" || echo "epic_launcher=no"
    [ -x "$SUPPORT/legendary/legendary" ] && echo "legendary=yes" || echo "legendary=no"
    echo "support=$SUPPORT"
    echo "log=$LOG"
    echo "legendary_config=$SUPPORT/legendary-config"
    echo "games_dir=$BOTTLE/drive_c/Games"
    if [ -f "$STEAM_EXE" ]; then echo "steam=yes"; else echo "steam=no"; fi
    [ "$(get_config STEAM_RENDER)" = "software" ] && echo "steam_render=software" || echo "steam_render=gpu"
    pgrep -f 'steam\.exe' >/dev/null 2>&1 && echo "steam_running=yes" || echo "steam_running=no"
    if [ -x "$SUPPORT/legendary/legendary" ] && find_wine; then
        run_epic whoami
        run_epic installed
    fi
    steam_games
}

# Unity games (BTD6, Raft…) write a log line, with a stack trace, for every warning,
# and some warn thousands of times per session. Through Wine those file writes are
# slow, so Unity's own log is switched off unless Debug mode is on or the game's
# launch options already choose a log.
unity_quiet_args() {  # unity_quiet_args <game folder> <launch options>
    local dir="$1" args="${2:-}"
    [ "$(get_config DEBUG)" = "on" ] && return 0
    [ "$(get_config UNITY_NOLOG)" = "off" ] && return 0
    case " $args " in *" -nolog "*|*" -logFile "*|*" -logfile "*) return 0 ;; esac
    [ -n "$dir" ] && [ -f "$dir/UnityPlayer.dll" ] && echo "-nolog"
}

# Steam's window is a full web browser running through Rosetta. When it is only
# sitting in the background, it takes memory and processor time from the game,
# so it is closed before an Epic game starts (unless Steam is running something).
close_idle_steam() {
    [ "$(get_config CLOSE_STEAM)" = "off" ] && return 0
    pgrep -f 'steam\.exe' >/dev/null 2>&1 || return 0
    local others
    others=$(ps -axo command= | grep -iE '[a-z0-9_)]\.exe' |
        grep -viE 'steam(webhelper|service|errorreporter)?\.exe|gameoverlayui|services\.exe|explorer\.exe|winedevice|plugplay|svchost|rpcss|conhost|start\.exe|tabtip|rundll32|wineboot|winemenubuilder|grep')
    if [ -n "$others" ]; then
        echo "Steam is busy (something else is running in it); leaving it open"
        return 0
    fi
    echo "STATUS: Closing Steam in the background to free memory for the game…"
    "$WINESERVER" -k 2>/dev/null
    wait_wineserver 15 2>/dev/null
    return 0
}

cli_play() {  # cli_play "<app name or title>" ["<display name>"]
    local app="$1" title="${2:-$1}" job
    ensure_ready || return 1
    ensure_graphics || return 1
    disable_epic_autostart
    [ -x "$SUPPORT/legendary/legendary" ] || { echo "ERROR: \"$title\" isn't downloaded yet."; return 1; }
    setup_env; close_idle_steam
    use_graphics "$(game_gfx "$app")" || return 1
    MYSKEF_GAME_ARGS=$(get_config "GAME_${app}_ARGS")
    local gdir extra
    gdir=$(run_epic installed 2>/dev/null | awk -F'\t' -v a="$app" '$1 == "INSTALLED" && $2 == a { print $7; exit }')
    extra=$(unity_quiet_args "$gdir" "$MYSKEF_GAME_ARGS")
    [ -n "$extra" ] && { MYSKEF_GAME_ARGS="${MYSKEF_GAME_ARGS:+$MYSKEF_GAME_ARGS }$extra"; echo "game options: $MYSKEF_GAME_ARGS"; }
    export MYSKEF_GAME_ARGS
    job=$(epic_job launch "$app")
    echo "STATUS: Starting $title…"
    local from new i
    from=$(( $(wc -c < "$LOG") + 1 ))
    nohup /bin/bash "$job" >>"$LOG" 2>&1 </dev/null &
    start_ngen_guard
    # Watch what legendary does for up to ~30 s, so the Play button can say what happened.
    local seg offline=0
    for i in $(seq 1 30); do
        sleep 1
        new=$(tail -c +"$from" "$LOG" 2>/dev/null)
        if printf '%s' "$new" | grep -q "is not installed"; then
            echo "ERROR: \"$title\" isn't installed. Download it first."; return 1
        fi
        seg="$new"
        if printf '%s' "$new" | grep -q "MYSKEF_OFFLINE_LAUNCH"; then
            if [ "$offline" = 0 ]; then
                offline=1
                echo "STATUS: Epic isn't reachable from this network, so $title is starting offline…"
            fi
            seg="${new##*MYSKEF_OFFLINE_LAUNCH}"      # only what happened after switching to offline
        fi
        printf '%s' "$seg" | grep -q "Launching $app" && break
        if printf '%s' "$seg" | grep -qE "Failed to execute script|Traceback \(most recent"; then
            if [ "$offline" = 0 ]; then
                # a sign-in timeout is followed by an offline start: give it a moment
                sleep 3; new=$(tail -c +"$from" "$LOG" 2>/dev/null)
                printf '%s' "$new" | grep -q "MYSKEF_OFFLINE_LAUNCH" && continue
            fi
            echo "ERROR: The Epic helper (legendary) crashed while starting $title. Open the activity log to see why."
            return 1
        fi
        [ "$i" = 3 ] && [ "$offline" = 0 ] && echo "STATUS: Signing in to Epic…"
    done
    echo "STATUS: $title is starting. The first start after an update can take a minute."
}

cli_set() {  # cli_set KEY VALUE
    case "$1" in
        FPS_HUD|FPS_CAP|DEBUG|STEAM_RENDER|FAST_SUBMIT|AVX|LOW_LATENCY|VSYNC|UNITY_NOLOG|CLOSE_STEAM) set_config "$1" "$2"; echo "STATUS: Saved." ;;
        GRAPHICS)
            case "$2" in
                dxmt)    ensure_ready && setup_env && install_dxvk && install_dxmt || return 1
                         set_config GRAPHICS dxmt; echo "STATUS: Graphics layer: DXMT (Metal)" ;;
                wined3d) set_config GRAPHICS wined3d; echo "STATUS: Graphics layer: Wine built-in" ;;
                *)       ensure_ready && setup_env && install_dxvk || return 1
                         set_config GRAPHICS dxvk; echo "STATUS: Graphics layer: DXVK" ;;
            esac
            echo "STATUS: Restart Steam (Tools → Force quit, then open it again) for Steam games to use it." ;;
        GAME_*_GFX)
            if [ "$2" = "dxmt" ]; then ensure_ready && setup_env && install_dxmt || return 1; fi
            if [ "$2" = "d3dmetal" ]; then ensure_ready && use_gptk || return 1; fi
            set_config "$1" "$2"; echo "STATUS: Saved." ;;
        GAME_*_ARGS) set_config "$1" "$2"; echo "STATUS: Saved." ;;
        *) echo "ERROR: unknown setting $1"; return 1 ;;
    esac
}

UPLOADS_DIR="$BOTTLE/drive_c/Myskef Uploads"

cli_run() {  # cli_run [--copy] /path/to/program(.exe .msi .bat .cmd .lnk)
    local copy=0 f
    [ "${1:-}" = "--copy" ] && { copy=1; shift; }
    f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || { echo "ERROR: Couldn't find “$(basename "${f:-file}")”. It may have been moved or deleted."; return 1; }
    case "$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')" in
        exe|msi|bat|cmd|lnk) ;;
        *) echo "ERROR: “$(basename "$f")” isn't a Windows program. Myskef runs .exe, .msi and .bat files."; return 1 ;;
    esac
    ensure_ready || return 1
    ensure_graphics || return 1
    if [ "$copy" = 1 ]; then
        mkdir -p "$UPLOADS_DIR"
        cp -f "$f" "$UPLOADS_DIR/" || { echo "ERROR: Couldn't copy “$(basename "$f")” into Myskef."; return 1; }
        f="$UPLOADS_DIR/$(basename "$f")"
        echo "STATUS: Copied into Myskef (C:\\Myskef Uploads)"
    fi
    xattr -d com.apple.quarantine "$f" 2>/dev/null
    echo "PROGRAM_PATH=$f"
    case "$f" in
        *.[mM][sS][iI]) launch_detached msiexec /i "$f" ;;
        *.[lL][nN][kK]|*.[bB][aA][tT]|*.[cC][mM][dD])
                        (cd "$(dirname "$f")" && launch_detached start /unix "$f") ;;
        *)              (cd "$(dirname "$f")" && launch_detached "$f") ;;
    esac
    echo "STATUS: Started $(basename "$f")"
}

# ------------------------------------------------------------------ updates
# Myskef updates itself from the releases of a public GitHub repository, set in
# Resources/update.conf. A release holds Myskef.zip (the app, with the window
# already built for Apple silicon and Intel) and Myskef.zip.sha256.
update_repo() {
    local res="${MYSKEF_RES:-$APP_RES}"
    sed -n 's/^repo=\(..*\)$/\1/p' "$res/update.conf" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

# version_newer A B: true if version A is newer than version B (e.g. 2.12.0 > 2.11.3)
version_newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
        for (i = 1; i <= n; i++) { if ((x[i] + 0) > (y[i] + 0)) exit 0; if ((x[i] + 0) < (y[i] + 0)) exit 1 }
        exit 1 }'
}

json_get() {  # json_get <file> <key path, e.g. assets.0.name>
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

cli_update_check() {
    local repo tmp tag ver i name url sha_url notes
    repo=$(update_repo)
    [ -n "$repo" ] || { echo "UPDATE_NONE=not-configured"; return 0; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/myskef-release.XXXXXX")
    if ! curl -fsSL -m 20 -H "Accept: application/vnd.github+json" -o "$tmp" \
            "https://api.github.com/repos/$repo/releases/latest"; then
        rm -f "$tmp"; echo "UPDATE_NONE=unreachable"; return 0
    fi
    tag=$(json_get "$tmp" tag_name); ver="${tag#v}"
    if [ -z "$ver" ] || ! version_newer "$ver" "$APP_VERSION"; then
        rm -f "$tmp"; echo "UPDATE_NONE=up-to-date ($APP_VERSION)"; return 0
    fi
    url=""; sha_url=""
    for i in $(seq 0 30); do
        name=$(json_get "$tmp" "assets.$i.name") || break
        case "$name" in
            Myskef.zip)        url=$(json_get "$tmp" "assets.$i.browser_download_url") ;;
            Myskef.zip.sha256) sha_url=$(json_get "$tmp" "assets.$i.browser_download_url") ;;
        esac
    done
    notes=$(json_get "$tmp" body | head -c 4000 | base64 | tr -d '\n')
    rm -f "$tmp"
    if [ -z "$url" ] || [ -z "$sha_url" ]; then echo "UPDATE_NONE=release-incomplete"; return 0; fi
    echo "UPDATE_VERSION=$ver"
    echo "UPDATE_URL=$url"
    echo "UPDATE_SHA_URL=$sha_url"
    echo "UPDATE_NOTES=$notes"
}

# Download, check and install an update, then reopen Myskef.
cli_update_install() {  # cli_update_install <zip url> <sha256 url> <pid of the window to wait for>
    local url="$1" sha_url="$2" pid="${3:-}" res app parent tmp want got newver backup helper
    res="${MYSKEF_RES:-$APP_RES}"
    app=$(cd "$res/../.." && pwd)
    parent=$(dirname "$app")
    case "$app" in
        */AppTranslocation/*|/Volumes/*)
            echo "ERROR: Move Myskef into your Applications folder first (drag it there in Finder), open it from there, and try again."; return 1 ;;
    esac
    if [ ! -w "$parent" ] || [ ! -w "$app" ]; then
        echo "ERROR: Myskef can't replace itself where it is ($parent). Move it into your Applications folder and try again."; return 1
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/myskef-update.XXXXXX")
    echo "STATUS: Downloading the update…"
    if ! curl -fL --retry 3 -o "$tmp/Myskef.zip" "$url" || ! curl -fsSL --retry 3 -o "$tmp/Myskef.zip.sha256" "$sha_url"; then
        rm -rf "$tmp"; echo "ERROR: Couldn't download the update. Check your internet connection and try again."; return 1
    fi
    want=$(awk '{print $1; exit}' "$tmp/Myskef.zip.sha256")
    got=$(shasum -a 256 "$tmp/Myskef.zip" | awk '{print $1}')
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        rm -rf "$tmp"; echo "ERROR: The update download was damaged (checksum mismatch). Try again."; return 1
    fi
    echo "STATUS: Checking the update…"
    mkdir -p "$tmp/x"
    ditto -x -k "$tmp/Myskef.zip" "$tmp/x" || { rm -rf "$tmp"; echo "ERROR: Couldn't unpack the update."; return 1; }
    local new="$tmp/x/Myskef.app"
    if [ ! -f "$new/Contents/Info.plist" ] ||
       [ "$(plutil -extract CFBundleIdentifier raw -o - "$new/Contents/Info.plist" 2>/dev/null)" != "com.myskef.launcher" ]; then
        rm -rf "$tmp"; echo "ERROR: The download isn't a Myskef update."; return 1
    fi
    newver=$(plutil -extract CFBundleShortVersionString raw -o - "$new/Contents/Info.plist" 2>/dev/null)
    if ! version_newer "$newver" "$APP_VERSION"; then
        rm -rf "$tmp"; echo "ERROR: The download ($newver) isn't newer than this Myskef ($APP_VERSION)."; return 1
    fi
    xattr -cr "$new" 2>/dev/null
    backup="$SUPPORT/previous-version"
    mkdir -p "$backup"
    # The swap happens after the window closes, so nothing is replaced while running.
    helper="$tmp/install.sh"
    cat > "$helper" <<HELPER
#!/bin/bash
for i in \$(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
sleep 0.5
rm -rf "$backup/Myskef.app"
if mv "$app" "$backup/Myskef.app" && mv "$new" "$app"; then
    echo "\$(date) updated Myskef $APP_VERSION -> $newver (previous version kept in $backup)" >> "$LOG"
    printf '%s\n%s\n' "$APP_VERSION" "$newver" > "$SUPPORT/just-updated"
else
    [ -d "$app" ] || mv "$backup/Myskef.app" "$app"
    echo "\$(date) update to $newver failed; kept $APP_VERSION" >> "$LOG"
fi
open "$app"
rm -rf "$tmp"
HELPER
    chmod +x "$helper"
    nohup /bin/bash "$helper" >/dev/null 2>&1 </dev/null &
    echo "UPDATE_READY=$newver"
    echo "STATUS: Myskef $newver is ready. Myskef will close and reopen."
}

# A zip of this app (with its window already built, when it is) plus the
# "Read me first" guide, for sending to friends. Nothing from the user's
# Library (games, accounts, settings) is included.
cli_share() {  # cli_share /path/to/Myskef.zip
    local out="${1:-}" app tmp res="${MYSKEF_RES:-$APP_RES}"
    [ -n "$out" ] || { echo "ERROR: Choose where to save the zip."; return 1; }
    case "$out" in *.zip) ;; *) out="$out.zip" ;; esac
    app=$(cd "$res/../.." && pwd)
    [ -d "$app/Contents" ] || { echo "ERROR: Couldn't find the Myskef app to copy."; return 1; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/myskef-share.XXXXXX")
    echo "STATUS: Copying Myskef…"
    ditto "$app" "$tmp/Myskef.app" || { rm -rf "$tmp"; echo "ERROR: Couldn't copy the app."; return 1; }
    rm -f "$tmp/Myskef.app/Contents/MacOS/"*.building 2>/dev/null
    xattr -cr "$tmp/Myskef.app" 2>/dev/null
    cp "$res/Read me first.txt" "$tmp/Read me first.txt" 2>/dev/null
    if [ -x "$tmp/Myskef.app/Contents/MacOS/MyskefUI" ]; then
        echo "The window is already built for $(uname -m) Macs: friends with the same kind of Mac won't need Apple's developer tools."
    else
        echo "The window isn't built inside the app, so friends' Macs will build it on first launch."
    fi
    echo "STATUS: Making the zip…"
    rm -f "$out"
    if ! (cd "$tmp" && ditto -c -k --sequesterRsrc . "$out"); then
        rm -rf "$tmp"; echo "ERROR: Couldn't save the zip there. Try your Desktop or Downloads folder."; return 1
    fi
    rm -rf "$tmp"
    echo "SHARE_PATH=$out"
    echo "STATUS: Saved $(basename "$out") ($(du -h "$out" | cut -f1 | tr -d ' ')). Send it with AirDrop, a USB stick or any chat app."
}

# Shortcuts that installed Windows programs made (Start menu and desktop),
# plus files kept in C:\Myskef Uploads.  PROGRAM <TAB> name <TAB> Mac path
cli_programs() {
    [ -d "$BOTTLE/drive_c" ] || return 0
    local d
    {
        for d in "$BOTTLE/drive_c/ProgramData/Microsoft/Windows/Start Menu" \
                 "$BOTTLE/drive_c/users"/*/"AppData/Roaming/Microsoft/Windows/Start Menu" \
                 "$BOTTLE/drive_c/users/Public/Desktop" \
                 "$BOTTLE/drive_c/users"/*/Desktop; do
            # a Desktop that links to the Mac's Desktop is skipped
            [ -d "$d" ] && [ ! -L "$d" ] && find "$d" -iname '*.lnk' 2>/dev/null
        done
        [ -d "$UPLOADS_DIR" ] && find "$UPLOADS_DIR" -maxdepth 1 -type f \( -iname '*.exe' -o -iname '*.msi' -o -iname '*.bat' \) 2>/dev/null
    } | awk '{
        n = $0; sub(/.*\//, "", n); sub(/\.[A-Za-z]+$/, "", n); low = tolower(n)
        if (low ~ /uninstall|readme|read me|help|manual|website|license|release notes|support|^steam$|epic games launcher/) next
        if (seen[low]++) next
        printf "PROGRAM\t%s\t%s\n", n, $0 }'
}

cli_fix_eos() {
    ensure_ready || return 1
    local eos; eos=$(eos_installer_path)
    [ -n "$eos" ] || { echo "ERROR: Epic's Online Services installer wasn't found. Open the Epic Games Launcher once first (it downloads it), then try again."; return 1; }
    setup_env
    WINEPREFIX="$BOTTLE" WINE="$WINE" WINESERVER="$WINESERVER" BOTTLE="$BOTTLE" EOS_INSTALLER="$eos" \
        /bin/bash "$APP_RES/myskef-eos-fix.sh" </dev/null
}

# ------------------------------------------------------------------ Steam
# The Windows Steam client, installed into the same bottle. You log in inside
# Steam's own window (Myskef never sees your Steam password), download games
# there, and Myskef lists them and starts them through Steam.
STEAM_DIR="$BOTTLE/drive_c/Program Files (x86)/Steam"
STEAM_EXE="$STEAM_DIR/steam.exe"
STEAM_SETUP_URL="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
# (Steam's window fix is steam_window_fix below. Don't pass -cef-disable-gpu
# here: the fix draws Steam's window with the GPU, inside the main process.)
STEAM_MARKER="$BOTTLE/.myskef-steam4"
STEAM_TWEAKED=0

# Steam settings for Wine: no Steam overlay (it crashes games under Wine),
# no crash dialogs from Steam's helpers, and Steam's browser drawn with the
# GPU through DXVK (Wine's own Direct3D can't compile its shaders on Macs).
steam_tweaks() {
    steam_window_fix
    [ -f "$STEAM_MARKER" ] && return 0
    setup_env
    local app='HKCU\Software\Wine\AppDefaults\steamwebhelper.exe\DllOverrides'
    # load Myskef's window fix as winmm.dll in Steam's browser only (see below)
    "$WINE" reg add "$app" /v winmm /d "native,builtin" /f
    # undo earlier Myskef versions (2.1.0–2.1.2)
    "$WINE" reg delete "$app" /v d3d11 /f 2>/dev/null
    "$WINE" reg delete "$app" /v libglesv2 /f 2>/dev/null
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v gameoverlayrenderer /d "" /f
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v gameoverlayrenderer64 /d "" /f
    "$WINE" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f
    date > "$STEAM_MARKER"
    STEAM_TWEAKED=1
}

# Steam's window is Chromium, which draws it from a separate GPU helper
# process; Wine's Mac driver can't show a Metal surface drawn by another
# process, so Steam stays black. With --in-process-gpu Chromium draws it in
# its main process instead, which Wine does support. Resources/steam/winmm.dll (source: steamfix.c) is loaded
# only in steamwebhelper.exe and adds Chromium's --in-process-gpu switch to
# its main process. All winmm functions go to winmm_orig.dll, a copy of this
# engine's own winmm.dll. Copied each time, so it always matches the engine.
steam_window_fix() {
    local sys="$BOTTLE/drive_c/windows/system32" orig
    orig=$(find "$(dirname "$WINE")/.." -path '*x86_64-windows/winmm.dll' 2>/dev/null | head -n1)
    if [ -z "$orig" ] || [ ! -f "$APP_RES/steam/winmm.dll" ]; then
        echo "STATUS: (Steam window fix unavailable: missing files)"; return 0
    fi
    cp -f "$orig" "$sys/winmm_orig.dll" && cp -f "$APP_RES/steam/winmm.dll" "$sys/winmm.dll"
}

steam_libraries() {  # every Steam library folder, as Mac paths
    {
        echo "$STEAM_DIR"
        if [ -f "$STEAM_DIR/steamapps/libraryfolders.vdf" ]; then
            awk -F'"' '$2 == "path" { print $4 }' "$STEAM_DIR/steamapps/libraryfolders.vdf" |
            while IFS= read -r wp; do
                d=$(printf '%s' "${wp:0:1}" | tr 'A-Z' 'a-z')
                rest=$(printf '%s' "${wp:2}" | sed 's#\\\\#/#g; s#\\#/#g')
                echo "$BOTTLE/dosdevices/$d:$rest"
            done
        fi
    } | while IFS= read -r p; do [ -d "$p" ] && (cd "$p" && pwd -P); done | awk '!seen[$0]++'
}

steam_games() {  # STEAMGAME <TAB> appid <TAB> name <TAB> bytes <TAB> installed 1/0 <TAB> folder
    [ -d "$STEAM_DIR" ] || return 0
    local lib f
    steam_libraries | while IFS= read -r lib; do
        for f in "$lib"/steamapps/appmanifest_*.acf; do
            [ -f "$f" ] || continue
            awk -v lib="$lib" '
                function val(line,   a) { split(line, a, "\""); return a[4] }
                $1 == "\"appid\""      && appid == "" { appid = val($0) }
                $1 == "\"name\""       && name == ""  { name = val($0) }
                $1 == "\"SizeOnDisk\""                { size = val($0) }
                $1 == "\"StateFlags\""                { flags = val($0) + 0 }
                $1 == "\"installdir\""                { dir = val($0) }
                END {
                    # 228980 = Steamworks Common Redistributables (not a game)
                    if (appid != "" && appid != "228980")
                        printf "STEAMGAME\t%s\t%s\t%s\t%d\t%s\n", appid, name, size, (flags % 8 >= 4) ? 1 : 0, lib "/steamapps/common/" dir
                }' "$f"
        done
    done
}

# Every game in your Steam library: Steam keeps artwork for each app in your
# library under appcache/librarycache (one folder or file per app id), and
# names come from the public Steam store (cached in steam-names.tsv).
# STEAMOWNED <TAB> appid <TAB> name
steam_owned() {
    [ -d "$STEAM_DIR" ] || return 0
    local cache="$STEAM_DIR/appcache/librarycache" names="$SUPPORT/steam-names.tsv" id name type resp
    touch "$names"
    {
        ls "$cache" 2>/dev/null | sed -nE 's/^([0-9]+).*/\1/p'
        steam_games | cut -f2
    } | sort -un | while IFS= read -r id; do
        [ -n "$id" ] && [ "$id" != 228980 ] || continue
        if ! grep -q "^$id	" "$names"; then
            resp=$(curl -s --max-time 15 "https://store.steampowered.com/api/appdetails?appids=$id&filters=basic&l=english")
            type=$(printf '%s' "$resp" | grep -oE '"type":"[^"]*"' | head -n1 | sed -E 's/"type":"(.*)"/\1/')
            name=$(printf '%s' "$resp" | grep -oE '"name":"([^"\\]|\\.)*"' | head -n1 | sed -E 's/^"name":"(.*)"$/\1/' |
                   sed 's/\\u00ae/®/g; s/\\u2122/™/g; s/\\u2019/’/g; s/\\"/"/g; s/\\\//\//g')
            [ -n "$type" ] || type="unknown"
            [ -n "$name" ] || name="Steam app $id"
            printf '%s\t%s\t%s\n' "$id" "$type" "$name" >> "$names"
            sleep 0.3
        fi
        awk -F'\t' -v id="$id" '$1 == id && ($2 == "game" || $2 == "unknown") { print "STEAMOWNED\t" $1 "\t" $3; exit }' "$names"
    done
}

cli_steam_install() {
    ensure_ready || return 1
    ensure_graphics || return 1
    setup_env
    if [ ! -f "$STEAM_EXE" ]; then
        local setup="$SUPPORT/SteamSetup.exe"
        echo "STATUS: Downloading Steam's installer…"
        if ! curl -fL --retry 3 -o "$setup" "$STEAM_SETUP_URL"; then
            rm -f "$setup"
            echo "ERROR: Couldn't download Steam's installer. Check your internet connection and try again."
            return 1
        fi
        echo "STATUS: Installing Steam…"
        "$WINE" "$setup" /S
        rm -f "$setup"
        sleep 2
        [ -f "$STEAM_EXE" ] || { echo "ERROR: Steam's installer finished, but Steam isn't there. Open the details to see what happened."; return 1; }
    fi
    echo "STATUS: Applying Steam fixes for Wine…"
    steam_tweaks
    echo "STATUS: Steam is installed."
}

cli_steam_open() {  # cli_steam_open [extra steam.exe arguments…]
    ensure_ready || return 1
    ensure_graphics || return 1
    [ -f "$STEAM_EXE" ] || { echo "ERROR: Steam isn't installed yet."; return 1; }
    disable_epic_autostart
    steam_tweaks
    setup_env
    # "software" drawing: Chromium's built-in SwiftShader instead of the GPU
    if [ "$(get_config STEAM_RENDER)" = "software" ]; then
        export MYSKEF_CEF_EXTRA="--use-angle=swiftshader --use-gl=angle"
    else
        unset MYSKEF_CEF_EXTRA
    fi
    # new Steam settings only apply to a fresh Steam, so close a running one
    if { [ "$STEAM_TWEAKED" = 1 ] || [ "${STEAM_RESTART:-0}" = 1 ]; } && pgrep -f 'steam\.exe' >/dev/null 2>&1; then
        echo "STATUS: Restarting Steam with the new settings…"
        "$WINESERVER" -k 2>/dev/null; sleep 2
    fi
    # Steam's own window only works on DXVK, whatever the games use.
    # A Steam left running on the DXMT engine (Myskef 2.5.0) is restarted.
    if ps -axo command= | grep -i 'steam\.exe' | grep -v grep | grep -q 'engine-dxmt'; then
        echo "STATUS: Restarting Steam on DXVK…"
        "$WINESERVER" -k 2>/dev/null; wait_wineserver 2>/dev/null; sleep 1
    fi
    if ps -axo command= | grep -i 'steam\.exe' | grep -v grep | grep -q 'engine-gptk'; then
        echo "STATUS: Closing the D3DMetal Steam…"; stop_gptk; sleep 2
    fi
    use_graphics dxvk || return 1
    (cd "$STEAM_DIR" && launch_detached "$STEAM_EXE" ${1+"$@"})
    echo "STATUS: Steam is starting. Its very first start downloads Steam's latest version and can take a few minutes."
}

# D3DMetal for Steam games: a second Steam lives in the D3DMetal bottle. Its
# game folder (steamapps) is the main Steam's, so nothing is downloaded twice.
# Only one of the two Steams runs at a time.
cli_steam_play_d3dmetal() {  # cli_steam_play_d3dmetal <appid>
    local id="$1" main_apps setup
    ensure_ready || return 1
    main_apps="$STEAM_DIR/steamapps"
    [ -d "$main_apps" ] || { echo "ERROR: Install the game with Steam first."; return 1; }
    if pgrep -f 'steam\.exe' >/dev/null 2>&1 && ! ps -axo command= | grep -i 'steam\.exe' | grep -v grep | grep -q 'engine-gptk'; then
        echo "STATUS: Closing the regular Steam…"
        setup_env; "$WINESERVER" -k 2>/dev/null; wait_wineserver 20 2>/dev/null; sleep 1
    fi
    use_gptk || return 1
    setup_env; unset WINEMSYNC DXVK_CONFIG_FILE; export WINEESYNC=1
    if [ ! -f "$STEAM_EXE" ]; then
        setup="$SUPPORT/SteamSetup.exe"
        echo "STATUS: Installing Steam for D3DMetal (first time only)…"
        curl -fL --retry 3 -o "$setup" "$STEAM_SETUP_URL" || { rm -f "$setup"; echo "ERROR: Couldn't download Steam's installer."; return 1; }
        "$WINE" "$setup" /S >>"$LOG" 2>&1; rm -f "$setup"; sleep 2
        [ -f "$STEAM_EXE" ] || { echo "ERROR: Steam didn't install in D3DMetal's setup. Open the details to see why."; return 1; }
    fi
    if [ ! -L "$STEAM_DIR/steamapps" ]; then
        [ -d "$STEAM_DIR/steamapps" ] && mv "$STEAM_DIR/steamapps" "$STEAM_DIR/steamapps.unused.$(date +%s)"
        ln -s "$main_apps" "$STEAM_DIR/steamapps"
        echo "linked $STEAM_DIR/steamapps -> $main_apps"
    fi
    steam_tweaks
    if [ "$(get_config STEAM_RENDER)" = "software" ]; then
        export MYSKEF_CEF_EXTRA="--use-angle=swiftshader --use-gl=angle"
    else
        unset MYSKEF_CEF_EXTRA
    fi
    echo "STATUS: Starting the game with D3DMetal…"
    # shellcheck disable=SC2046
    local gargs gdir2; gargs=$(get_config "GAME_steam:${id}_ARGS")
    gdir2=$(steam_games | awk -F'\t' -v id="$id" '$2 == id { print $6; exit }')
    gargs="${gargs:+$gargs }$(unity_quiet_args "$gdir2" "$gargs")"
    # shellcheck disable=SC2086
    (cd "$STEAM_DIR" && launch_detached "$STEAM_EXE" -silent -applaunch "$id" $gargs)
    sleep 6
    echo "STATUS: Starting. The first time, sign in to Steam in the window that opens; after that it remembers you."
}

# The main program of an installed Steam game (Mac path).
steam_game_exe() {
    local dir d
    dir=$(steam_games | awk -F'\t' -v id="$1" '$2 == id { print $6; exit }')
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    # Unity games: <Name>.exe next to <Name>_Data
    for d in "$dir"/*_Data; do
        [ -d "$d" ] && [ -f "${d%_Data}.exe" ] && { echo "${d%_Data}.exe"; return 0; }
    done
    # otherwise the biggest program near the top, skipping helpers and installers
    find "$dir" -maxdepth 3 -iname '*.exe' ! -iname '*crash*' ! -iname '*unins*' ! -iname '*setup*' \
        ! -iname '*redist*' ! -iname 'vc_*' ! -iname 'dxsetup*' ! -iname '*helper*' -print0 2>/dev/null |
        xargs -0 ls -S 2>/dev/null | head -n1
}

# Steam games on DXVK are started by Steam as usual. On DXMT or Wine built-in,
# Myskef starts the game itself with that graphics layer while Steam keeps
# running in the background (on DXVK) for login, saves and achievements.
cli_steam_play() {  # cli_steam_play <appid>
    local id="$1" gfx exe dir i
    gfx=$(game_gfx "steam:$id")
    if [ "$gfx" = "d3dmetal" ]; then cli_steam_play_d3dmetal "$id"; return; fi
    if [ "$gfx" = "dxvk" ]; then
        local sdir sextra
        sdir=$(steam_games | awk -F'\t' -v id="$id" '$2 == id { print $6; exit }')
        sextra=$(unity_quiet_args "$sdir" "")
        # shellcheck disable=SC2086
        cli_steam_open -silent -applaunch "$id" $sextra; return
    fi
    exe=$(steam_game_exe "$id")
    if [ -z "$exe" ] || [ ! -f "$exe" ]; then
        echo "ERROR: Couldn't find this game's program file. Open the game's ⋯ → Game settings… and choose DXVK, then Steam starts it itself."
        return 1
    fi
    echo "game program: $exe"
    if ! pgrep -f 'steam\.exe' >/dev/null 2>&1; then
        cli_steam_open -silent || return 1
        echo "STATUS: Waiting for Steam to start…"
        for i in $(seq 1 90); do pgrep -f 'steamwebhelper' >/dev/null 2>&1 && break; sleep 1; done
        sleep 12
    fi
    dir=$(dirname "$exe")
    [ -f "$dir/steam_appid.txt" ] || echo "$id" > "$dir/steam_appid.txt" 2>/dev/null
    export SteamAppId="$id" SteamGameId="$id" SteamOverlayGameId="$id"
    use_graphics "$gfx" || return 1
    echo "STATUS: Starting the game with $gfx…"
    # shellcheck disable=SC2086
    local sargs; sargs=$(get_config "GAME_steam:${id}_ARGS")
    sargs="${sargs:+$sargs }$(unity_quiet_args "$dir" "$sargs")"
    # shellcheck disable=SC2086
    (cd "$dir" && launch_detached "$exe" $sargs)
    sleep 8
    echo "STATUS: The game is starting."
}

[ "$(get_config DEBUG)" = "on" ] && export WINEDEBUG="err+all,fixme-all"

if [ "$HEADLESS" = 1 ]; then
    shift
    rc=0
    case "$MODE" in
        status)        cli_status ;;
        setup)         check_rosetta && install_engine && init_bottle && ensure_graphics || rc=1
                       if [ "$rc" = 0 ]; then
                           echo "STATUS: Getting the Epic Games helper (legendary)…"
                           run_epic prepare || echo "(legendary will be downloaded at the first Epic sign-in instead)"
                           echo "STATUS: Myskef is set up."
                       fi ;;
        update-engine) FORCE_ENGINE_UPDATE=1; ensure_engine_fresh && ensure_graphics || rc=1 ;;
        play)          cli_play "${1:-Bloons TD 6}" "${2:-}" || rc=1 ;;
        epic)          case "${1:-}" in install|update|launch|uninstall) ensure_ready || rc=1 ;; esac
                       if [ "$rc" = 0 ]; then run_epic "$@" || rc=$?; fi ;;
        set)           cli_set "${1:-}" "${2:-}" || rc=1 ;;
        run)           cli_run "$@" || rc=1 ;;
        programs)      cli_programs ;;
        share)         cli_share "${1:-}" || rc=1 ;;
        update-check)  cli_update_check ;;
        update-install) cli_update_install "${1:-}" "${2:-}" "${3:-}" || rc=1 ;;
        open-epic)     open_epic || rc=1 ;;
        winecfg)       { ensure_ready && launch_detached winecfg; } || rc=1 ;;
        open-c)        open "$BOTTLE/drive_c" 2>/dev/null || open "$BOTTLE" ;;
        force-quit)    find_wine && WINEPREFIX="$BOTTLE" "$WINESERVER" -k 2>/dev/null; stop_gptk; pkill -f "legendary launch" 2>/dev/null; echo "STATUS: All Windows programs were closed." ;;
        fix-eos)       cli_fix_eos || rc=1 ;;
        steam-install) cli_steam_install || rc=1 ;;
        steam-open)    cli_steam_open || rc=1 ;;
        steam-restart) STEAM_RESTART=1; cli_steam_open || rc=1 ;;
        steam-play)    [ -n "${1:-}" ] && cli_steam_play "$1" || rc=1 ;;
        steam-uninstall) [ -n "${1:-}" ] && cli_steam_open "steam://uninstall/$1" || rc=1 ;;
        steam-games)   steam_games ;;
        steam-owned)   steam_owned ;;
        steam-get)     [ -n "${1:-}" ] && cli_steam_open "steam://install/$1" || rc=1 ;;
        show-log)      open -a Console "$LOG" 2>/dev/null || open "$LOG" ;;
        reset-bottle)  find_wine && WINEPREFIX="$BOTTLE" "$WINESERVER" -k 2>/dev/null
                       rm -rf "$BOTTLE"; mkdir -p "$BOTTLE"; echo "STATUS: Bottle deleted." ;;
        *)             echo "ERROR: unknown command $MODE"; rc=64 ;;
    esac
    if [ "$rc" = 0 ]; then echo "DONE"; else echo "FAILED ($rc)"; fi
    exit "$rc"
fi

# --------------------------------------------------- classic dialog menu
while true; do
    choice=$(pick_from_list "Myskef $APP_VERSION — what do you want to do?" \
        "🎈  Play Bloons TD 6" \
        "⬇️  Download / update Bloons TD 6 (from your Epic account)" \
        "🎮  Download another Epic game…" \
        "▶  Open Epic Games Launcher" \
        "🧩  Fix Epic Online Services (purple banner)…" \
        "⚙  Set up / repair Myskef" \
        "📂  Run a Windows program (.exe / .msi)…" \
        "⚡  Performance (FPS counter, frame cap)…" \
        "🎨  Graphics layer…" \
        "🔧  Wine settings (winecfg)" \
        "💽  Open C: drive" \
        "⛔  Force quit Windows programs" \
        "🪵  Detailed logging…" \
        "📄  Show log" \
        "🗑  Reset bottle…" \
        "Quit Myskef")
    echo "Menu: $choice"
    case "$choice" in
        *"Play Bloons"*)      epic_play "Bloons TD 6"; exit 0 ;;
        *"Bloons TD 6 (from"*) epic_download "Bloons TD 6"; exit 0 ;;
        *"another Epic"*)     epic_other; exit 0 ;;
        *"Open Epic"*)        open_epic; exit 0 ;;
        *"Epic Online"*)      fix_eos; exit 0 ;;
        *"Set up"*)           full_setup ;;
        *"Run a Windows"*)    run_program; exit 0 ;;
        *"Performance"*)      perf_menu ;;
        *"Graphics"*)         graphics_menu ;;
        *"winecfg"*)          ensure_ready && launch_detached winecfg; exit 0 ;;
        *"C: drive"*)         open "$BOTTLE/drive_c" 2>/dev/null || open "$BOTTLE" ;;
        *"Force quit"*)       force_quit ;;
        *"logging"*)          debug_toggle ;;
        *"Show log"*)         open -a Console "$LOG" 2>/dev/null || open "$LOG" ;;
        *"Reset bottle"*)     reset_bottle ;;
        *)                    exit 0 ;;
    esac
done
