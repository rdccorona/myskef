#!/bin/bash
# ---------------------------------------------------------------------------
#  Myskef — Epic games without the Epic Games Launcher
#
#  Uses legendary (https://github.com/legendary-gl/legendary, GPL-3.0), the
#  free open-source Epic client that Heroic is built on, to log in to your
#  Epic account, download a game you own into Myskef's bottle, and launch it
#  through Myskef's Wine with your account's login.
#
#  Usage:  myskef-epic.sh install   "<app name or title>"  download / update
#          myskef-epic.sh launch    "<app name or title>"
#          myskef-epic.sh uninstall "<app name or title>"
#          myskef-epic.sh login-code "<code or the whole JSON page>"
#          myskef-epic.sh whoami | logout | owned | installed
#  Lines starting with ACCOUNT=, OWNED<TAB>, INSTALLED<TAB>, NEED_LOGIN are
#  read by Myskef's window; everything else is human-readable progress.
#
#  Expects: SUPPORT, BOTTLE, WINE, WINESERVER (and WINEPREFIX)
# ---------------------------------------------------------------------------
set -u
export LEGENDARY_CONFIG_PATH="$SUPPORT/legendary-config"
LGD_DIR="$SUPPORT/legendary"
LGD="$LGD_DIR/legendary"
GAMES_DIR="$BOTTLE/drive_c/Games"
RELEASE_BASE="https://github.com/legendary-gl/legendary/releases/latest/download"
# Epic's own login page for legendary's client ID (what https://legendary.gl/epiclogin
# redirects to), so login doesn't depend on that redirect site being up.
EPIC_LOGIN_URL='https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode'
mkdir -p "$LEGENDARY_CONFIG_PATH" "$LGD_DIR" "$GAMES_DIR"

say()  { echo; echo ">>> $*"; }

# Run a command but give up after <seconds>, so a stuck legendary can never
# freeze Myskef. Exit status 124 means it took too long.
with_timeout() {  # with_timeout <seconds> <command...>
    # the command gets its own process group, so its helpers stop with it
    perl -e 'my $t = shift; my $pid = fork();
             if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
             $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; exit 124 };
             alarm $t; waitpid($pid, 0); exit($? >> 8)' "$@"
}
LGDQ() { with_timeout 20 "$LGD" "$@"; }        # quick legendary questions

# Close legendary helpers left hanging by an earlier run (they block new ones).
# Running games, installs and updates are left alone.
# With <seconds>, only quick helpers (not a library download) running longer than that.
clear_stuck_legendary() {  # clear_stuck_legendary [min_seconds]
    local pids min="${1:-0}" what="status|list|list-installed|auth|info|-V"
    [ "$min" -gt 0 ] && what="status|auth|info|-V"
    pids=$(pgrep -f "legendary-config|$LGD_DIR/legendary" 2>/dev/null | while read -r p; do
        ps -o command= -p "$p" 2>/dev/null | grep -qE "legendary(\.py)? +(-y +)?($what)( |$)" || continue
        age=$(ps -o etime= -p "$p" 2>/dev/null | awk '{ n = split($1, a, /[-:]/); s = 0; m = 1
              for (i = n; i >= 1; i--) { s += a[i] * m; m = (m == 1 ? 60 : (m == 60 ? 3600 : 86400)) } print s }')
        [ "${age:-0}" -ge "$min" ] && echo "$p"
    done)
    [ -n "$pids" ] || return 0
    echo "(closing a stuck Epic helper: $(echo $pids))"
    kill $pids 2>/dev/null; sleep 1; kill -9 $pids 2>/dev/null
    return 0
}
fail() { echo; echo "FAILED: $*"; echo "Copy everything in this window and send it to Claude."; exit 1; }

# ------------------------------------------------------------ get legendary
# A legendary that started fine once is trusted (until the file changes).
# Testing it before every use was slow, and on a busy Mac the test could time
# out and make Myskef download legendary again and again.
LGD_OK="$LGD_DIR/.verified"
lgd_stamp() { echo "$(wc -c < "$LGD" 2>/dev/null | tr -d ' ')-$(date -r "$LGD" +%s 2>/dev/null)"; }
lgd_mark_ok() { lgd_stamp > "$LGD_OK"; }
hw_arm64() { [ "$(sysctl -in hw.optional.arm64 2>/dev/null)" = "1" ] || [ "$(uname -m)" = "arm64" ]; }

get_legendary() {
    if [ -x "$LGD" ] && [ -f "$LGD_OK" ] && [ "$(cat "$LGD_OK" 2>/dev/null)" = "$(lgd_stamp)" ]; then
        # On Apple silicon, swap an Intel copy for the native one once (much faster).
        if hw_arm64 && [ ! -f "$LGD_DIR/.native-tried" ] && file "$LGD" 2>/dev/null | grep -q "x86_64" && ! file "$LGD" | grep -q arm64; then
            touch "$LGD_DIR/.native-tried"
            download_legendary legendary_macOS_arm64 quiet && return 0
        fi
        return 0
    fi
    # a copy without the mark: test it once, patiently
    if [ -x "$LGD" ] && with_timeout 180 "$LGD" -V >/dev/null 2>&1; then lgd_mark_ok; return 0; fi
    local asset="legendary_macOS_x64"
    hw_arm64 && asset="legendary_macOS_arm64"
    download_legendary "$asset" && return 0
    [ "$asset" = "legendary_macOS_arm64" ] && download_legendary legendary_macOS_x64 && return 0
    get_legendary_python
}

# download_legendary <asset> [quiet] — replaces legendary only if the new one starts
download_legendary() {
    local asset="$1" tmp="$LGD.download.$$"
    [ "${2:-}" = quiet ] || say "Downloading legendary (free, open-source Epic client) — $asset"
    if curl -fsSL --retry 3 -o "$tmp" "$RELEASE_BASE/$asset" && [ -s "$tmp" ]; then
        chmod +x "$tmp"; xattr -d com.apple.quarantine "$tmp" 2>/dev/null
        with_timeout 180 "$tmp" -V >/dev/null 2>&1 || codesign --force -s - "$tmp" 2>/dev/null
        if with_timeout 180 "$tmp" -V >/dev/null 2>&1; then
            mv -f "$tmp" "$LGD"          # atomic: a running legendary keeps its old copy
            lgd_mark_ok
            echo "legendary ready ($asset)"
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

get_legendary_python() {
    echo "(the prebuilt legendary didn't start on this Mac — trying the Python version instead)"
    # Fallback: install legendary from PyPI into a private virtual environment.
    local py=""
    for c in "$HOME/miniconda3/bin/python3" "$HOME/anaconda3/bin/python3" "$HOME/opt/anaconda3/bin/python3" \
             "$HOME/miniforge3/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$c" ] && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then py="$c"; break; fi
    done
    if [ -z "$py" ] && xcode-select -p >/dev/null 2>&1 && \
       /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
        py=/usr/bin/python3
    fi
    [ -n "$py" ] || fail "couldn't get legendary: no prebuilt binary and no Python 3.10+ found."
    say "Installing legendary with $py"
    rm -rf "$LGD_DIR/venv"
    "$py" -m venv "$LGD_DIR/venv" || fail "couldn't create a Python environment."
    "$LGD_DIR/venv/bin/pip" install -q --upgrade pip legendary-gl || fail "couldn't install legendary from PyPI."
    ln -sf "$LGD_DIR/venv/bin/legendary" "$LGD"
    "$LGD" -V >/dev/null 2>&1 || fail "legendary was installed but won't start."
    lgd_mark_ok
    echo "legendary $("$LGD" -V 2>&1 | tail -n1)"
}

# ------------------------------------------------------------------ log in
# Turn off legendary's own update check: it contacts api.legendary.gl, and when
# that site is down `legendary auth` crashes before it even uses the code.
ensure_config() {
    local cfg="$LEGENDARY_CONFIG_PATH/config.ini"
    if grep -qs "^disable_update_check" "$cfg"; then
        # legendary writes "= false" on its first run; switch it to true
        sed -i '' 's/^disable_update_check.*/disable_update_check = true/' "$cfg" 2>/dev/null ||
            sed -i 's/^disable_update_check.*/disable_update_check = true/' "$cfg"
        return 0
    fi
    if grep -qs '^\[Legendary\]' "$cfg"; then
        awk '{ print } /^\[Legendary\]/ { print "disable_update_check = true" }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    else
        printf '[Legendary]\ndisable_update_check = true\n\n' >> "$cfg"
    fi
}

# The saved sign-in (legendary's user.json) is read directly: starting legendary
# just to ask "who is signed in?" took seconds every time.
account_name() {
    local uj="$LEGENDARY_CONFIG_PATH/user.json" name
    [ -s "$uj" ] || return 1
    name=$(plutil -extract displayName raw -o - "$uj" 2>/dev/null)
    [ -n "$name" ] || name=$(sed -n 's/.*"displayName": *"\([^"]*\)".*/\1/p' "$uj" | head -n1)
    [ -n "$name" ] && echo "$name"
}
extract_code() {  # accepts the bare code or the whole {"authorizationCode":"..."} page
    local raw="$1" code
    code=$(printf '%s' "$raw" | sed -n 's/.*"authorizationCode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$code" ] || code=$(printf '%s' "$raw" | tr -d '[:space:]"')
    printf '%s' "$code"
}

logged_in() {
    local uj="$LEGENDARY_CONFIG_PATH/user.json"
    [ -s "$uj" ] && grep -q '"refresh_token"' "$uj" && [ -n "$(account_name)" ]
}

# Exchange the authorization code for a login token directly with Epic — the
# same request legendary makes (see legendary/api/egs.py, start_session) — and
# save the answer where legendary keeps its login (user.json).
EPIC_OAUTH="https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token"
EPIC_CLIENT="34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf"
EPIC_UA="UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
exchange_code() {
    local code="$1" resp
    resp=$(curl -s --max-time 30 -A "$EPIC_UA" -u "$EPIC_CLIENT" \
               -d grant_type=authorization_code --data-urlencode "code=$code" -d token_type=eg1 \
               "$EPIC_OAUTH")
    if printf '%s' "$resp" | grep -q '"access_token"'; then
        ( umask 077; printf '%s' "$resp" > "$LEGENDARY_CONFIG_PATH/user.json" )
        return 0
    fi
    printf '%s' "$resp" | sed -n 's/.*"errorMessage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/Epic said: \1/p'
    return 1
}

login() {
    ensure_config
    if logged_in; then echo "Already logged in to Epic: $(account_name)"; return 0; fi
    if [ ! -t 0 ]; then echo "NEED_LOGIN"; exit 10; fi   # Myskef's window shows its own login
    say "Log in to your Epic account"
    echo "1. Your browser will open Epic's login page. Log in with the account that owns the game."
    echo "2. After logging in you'll see a short page of text containing  \"authorizationCode\":\"....\""
    echo "3. Copy that code (or the whole page) and paste it here, then press Return."
    echo
    open "$EPIC_LOGIN_URL"
    local raw code
    for _ in 1 2 3; do
        read -r -p "Paste here: " raw
        code=$(extract_code "$raw")
        [ -n "$code" ] || continue
        if exchange_code "$code" && logged_in; then
            echo "✓ Logged in as $(account_name)."
            return 0
        fi
        echo "That didn't work — codes are single-use and expire in a few minutes."
        echo "Reloading the login page for a fresh code…"
        open "$EPIC_LOGIN_URL"
    done
    fail "couldn't log in to Epic."
}

# ------------------------------------------------------------- find a game
# prints "app_name" of the best match for $1 among owned games, platform Windows
# (accepts an exact app name, or part of the title)
find_app() {
    local q; q=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    with_timeout 600 "$LGD" list --platform Windows --tsv 2>/dev/null | tail -n +2 \
        | awk -F'\t' -v q="$q" '
            $4 == "False" && tolower($1) == q { print $1; found = 1; exit }
            $4 == "False" && !m && index(tolower($2), q) { m = $1 }
            END { if (!found && m != "") print m }'
}

installed_app() {
    local q; q=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    with_timeout 60 "$LGD" list-installed --tsv 2>/dev/null | tail -n +2 \
        | awk -F'\t' -v q="$q" '
            tolower($1) == q { print $1; found = 1; exit }
            !m && index(tolower($2), q) { m = $1 }
            END { if (!found && m != "") print m }'
}

# ------------------------------------------------------------------ main
ensure_config
cmd="${1:-}"; query="${2:-bloons td 6}"
case "$cmd" in
install|update)
    echo "=== Myskef: download an Epic game without the Epic launcher ==="
    get_legendary
    login
    say "Finding \"$query\" in your Epic library"
    app=$(find_app "$query")
    [ -n "$app" ] || fail "\"$query\" wasn't found in this Epic account's library (Windows versions). Is this the account you bought it with?"
    echo "found: $app"
    if [ -n "$(installed_app "$app")" ]; then
        say "Already installed — checking for updates"
        "$LGD" -y update "$app" || fail "the update failed."
    else
        say "Downloading and installing into Myskef (C:\\Games). This shows progress below."
        "$LGD" -y install "$app" --platform Windows --base-path "$GAMES_DIR" --skip-sdl \
            || fail "the download failed."
    fi
    echo
    echo "DONE. Open Myskef and choose the Play option for this game."
    ;;
launch)
    [ -x "$LGD" ] || { echo "legendary not set up"; exit 2; }
    app=$(installed_app "$query")
    [ -n "$app" ] || { echo "\"$query\" is not installed"; exit 3; }
    echo "$(date) myskef: launching $app via legendary"
    # Signing in to Epic before the game starts needs Epic's account server. When
    # it doesn't answer (some networks, VPNs, school Wi-Fi), legendary gives up and
    # the game never starts — so then the game is started offline instead.
    online=1
    if ! curl -s -o /dev/null --connect-timeout 8 -m 15 "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/verify"; then
        echo "myskef: Epic's sign-in server isn't answering from this network — starting the game offline"
        online=0
    fi
    if [ "$online" = 1 ]; then
        out=$(mktemp "${TMPDIR:-/tmp}/myskef-launch.XXXXXX")
        # MYSKEF_GAME_ARGS: the game's launch options from Myskef (split on spaces)
        # shellcheck disable=SC2086
        "$LGD" launch "$app" --wine "$WINE" --wine-prefix "$BOTTLE" ${MYSKEF_GAME_ARGS:-} 2>&1 | tee "$out"
        rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ] && ! grep -q "Launching $app" "$out" &&
           grep -qiE "timed out|timeout|ConnectionError|Max retries|NameResolution|Temporary failure|SSLError|Connection reset" "$out"; then
            echo "myskef: couldn't reach Epic to sign in — starting the game offline instead"
            online=0
        fi
        rm -f "$out"
        [ "$online" = 1 ] && exit "$rc"
    fi
    echo "MYSKEF_OFFLINE_LAUNCH"
    # shellcheck disable=SC2086
    exec "$LGD" launch "$app" --offline --wine "$WINE" --wine-prefix "$BOTTLE" ${MYSKEF_GAME_ARGS:-}
    ;;
uninstall)
    [ -x "$LGD" ] || fail "legendary isn't set up."
    app=$(installed_app "$query")
    [ -n "$app" ] || fail "\"$query\" isn't installed."
    say "Removing $app"
    "$LGD" -y uninstall "$app" --skip-uninstaller || fail "couldn't remove it."
    echo "DONE"
    ;;
login-code)
    clear_stuck_legendary
    ensure_config
    get_legendary
    code=$(extract_code "$query")
    [ -n "$code" ] || fail "no code was given."
    if exchange_code "$code" && logged_in; then
        echo "ACCOUNT=$(account_name)"
    else
        echo "That code didn't work. Codes are single-use and expire after a few minutes, so get a fresh one."
        exit 1
    fi
    ;;
whoami)
    clear_stuck_legendary 120
    logged_in && echo "ACCOUNT=$(account_name)"
    exit 0
    ;;
logout)
    rm -f "$LEGENDARY_CONFIG_PATH/user.json"
    echo "Logged out of Epic."
    ;;
owned)
    get_legendary
    # Quick check that Epic can be reached at all, so Myskef doesn't spin for minutes.
    if ! curl -s -o /dev/null -m 10 "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/verify"; then
        echo "OFFLINE"
        echo "Can't reach Epic's servers. Check your internet connection (or VPN) and try again."
        exit 1
    fi
    echo "STATUS: Signing in to Epic…"
    login
    echo "STATUS: Getting your game list from Epic…"
    tmp=$(mktemp "${TMPDIR:-/tmp}/myskef-owned.XXXXXX"); start=$SECONDS
    # progress ticker: Epic can take a while the first time (one request per game)
    ( while sleep 8; do echo "STATUS: Still loading your Epic library… ($((SECONDS - start)) s)"; done ) &
    ticker=$!
    n=0
    with_timeout 300 "$LGD" list --platform Windows --tsv 2>&1 >"$tmp" | while IFS= read -r l; do
        echo "$l" >> "$tmp.err"
        case "$l" in
            *etadata*|*etching*) n=$((n + 1))
                [ $((n % 3)) = 1 ] && echo "STATUS: Loading your Epic library… ($n games checked)" ;;
            *ogin*|*ession*) echo "STATUS: Signing in to Epic…" ;;
        esac
    done
    rc=${PIPESTATUS[0]}
    pkill -P "$ticker" 2>/dev/null; kill "$ticker" 2>/dev/null; wait "$ticker" 2>/dev/null
    std=$(cat "$tmp"); out="$(cat "$tmp.err" 2>/dev/null)
$std"; rm -f "$tmp" "$tmp.err"
    [ "$rc" = 124 ] && { echo "Epic took too long to send your library. Try again in a moment."; exit 1; }
    if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -q "Login failed"; then
        printf '%s\n' "$out" | tail -n 5
        # only a real sign-in problem asks you to log in again (not a network hiccup)
        if printf '%s' "$out" | grep -qiE "login failed|no saved credentials|invalid_grant|invalid refresh|not logged in|session.*expired"; then
            echo "NEED_LOGIN"; exit 10
        fi
        exit 1
    fi
    rm -f "$LGD_DIR/installed.cache"
    # legendary's own log lines start with "[" — skip them and the header row
    printf '%s\n' "$std" | grep -v '^\[' | tail -n +2 \
        | awk -F'\t' '$4 == "False" { print "OWNED\t" $1 "\t" $2 }'
    ;;
installed)
    [ -x "$LGD" ] || exit 0
    inst="$LEGENDARY_CONFIG_PATH/installed.json"
    [ -f "$inst" ] || exit 0
    cache="$LGD_DIR/installed.cache"
    if [ -s "$cache" ] && [ "$cache" -nt "$inst" ] && [ -z "$(find "$cache" -mmin +30 2>/dev/null)" ]; then
        cat "$cache"; exit 0
    fi
    get_legendary
    with_timeout 60 "$LGD" list-installed --tsv 2>/dev/null | tail -n +2 \
        | awk -F'\t' '{ print "INSTALLED\t" $1 "\t" $2 "\t" $3 "\t" $5 "\t" $6 "\t" $7 }' > "$cache.$$"
    if [ -s "$cache.$$" ]; then mv -f "$cache.$$" "$cache"; cat "$cache"; else rm -f "$cache.$$"; fi
    ;;
prepare)
    # Setup: install legendary now, so the first Epic sign-in doesn't wait for it.
    ensure_config
    get_legendary
    echo "legendary ready"
    exit 0
    ;;
login-url)
    echo "$EPIC_LOGIN_URL"
    ;;
*)
    echo "usage: $0 install|update|launch|uninstall|login-code|whoami|logout|owned|installed"; exit 64 ;;
esac
