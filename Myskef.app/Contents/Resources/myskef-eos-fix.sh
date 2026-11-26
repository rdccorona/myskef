#!/bin/bash
# ---------------------------------------------------------------------------
#  Myskef — Epic Online Services installer for Wine
#
#  Epic's EOS installer (an MSI built with WiX) runs 20 small .NET "custom
#  actions". Under Wine they either fail (Wine Mono) or hang (real .NET), and
#  one failure aborts the whole install with error 1603.
#
#  Those actions only do three things:
#    1. send telemetry,
#    2. write a handful of registry values under HKLM\SOFTWARE\Epic Games\EOS,
#    3. run EpicOnlineServicesUserHelper.exe --setup --msimode=NewInstall.
#
#  So Myskef takes the MSI out of Epic's own installer on this Mac, switches
#  those 20 actions off (Wine's msidb tool), installs it with msiexec, and then
#  does jobs 2 and 3 itself. Nothing of Epic's is redistributed by Myskef.
#
#  Expects: WINEPREFIX, WINE, WINESERVER, BOTTLE, EOS_INSTALLER (unix path)
# ---------------------------------------------------------------------------
set -u
export WINEDEBUG=-all

WORK_UNIX="$BOTTLE/drive_c/myskef-eos"
WORK_WIN='C:\myskef-eos'
EOS_COMPONENTS="UserHelper UIHelper InstallHelper MainService"

step()  { echo; echo ">>> $*"; }
fail()  { echo; echo "FAILED: $*"; echo "Copy everything in this window and send it to Claude."; exit 1; }

# Run a Wine command, but give up after $1 seconds (macOS has no `timeout`).
run_with_limit() {
    local limit="$1"; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 2; waited=$((waited + 2))
        if [ "$waited" -ge "$limit" ]; then
            echo "(still running after ${limit}s — stopping it)"
            kill "$pid" 2>/dev/null
            return 124
        fi
    done
    wait "$pid"
}

# Wait for Wine to go idle, but never forever: some Wine background helpers
# linger after an install, and `wineserver -w` would then wait indefinitely.
wait_wine() {
    local limit="${1:-30}"
    run_with_limit "$limit" "$WINESERVER" -w >/dev/null 2>&1 || "$WINESERVER" -k 2>/dev/null
    return 0
}

# unix path inside the bottle -> Windows path
winpath() {
    local p="${1#"$BOTTLE"/drive_c/}"
    p="${p//\//\\}"
    printf 'C:\\%s' "$p"
}

echo "=== Myskef: Epic Online Services fix (v1.4.3) ==="
[ -f "$EOS_INSTALLER" ] || fail "Epic's Online Services installer was not found."

step "Step 1/5: closing anything still running in the bottle"
"$WINESERVER" -k 2>/dev/null
sleep 1
rm -rf "$WORK_UNIX"; mkdir -p "$WORK_UNIX"

step "Step 2/5: taking the install package out of Epic's installer"
perl -e '
    my ($in, $out) = @ARGV;
    open(my $fh, "<:raw", $in) or die "cannot read installer\n";
    local $/; my $d = <$fh>; close $fh;
    my $sig = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1";      # MSI / OLE file signature
    my $i = index($d, $sig);
    die "no install package found inside the installer\n" if $i < 0;
    open(my $o, ">:raw", $out) or die "cannot write package\n";
    print $o substr($d, $i); close $o;
    printf "found it (%.0f MB)\n", (length($d) - $i) / 1048576;
' "$EOS_INSTALLER" "$WORK_UNIX/eos.msi" || fail "couldn't extract the install package."

step "Step 3/5: switching off the steps that break under Wine"
( cd "$WORK_UNIX" && "$WINE" msidb -d "$WORK_WIN\\eos.msi" -f "$WORK_WIN" -e InstallExecuteSequence CustomAction Property )
for t in InstallExecuteSequence CustomAction Property; do
    [ -s "$WORK_UNIX/$t.idt" ] || fail "couldn't read the package's $t table."
done
managed=$(tr -d '\r' < "$WORK_UNIX/CustomAction.idt" | awk -F'\t' 'NR>3 && $3=="CABinaryManaged" {print $1}')
[ -n "$managed" ] || fail "didn't find Epic's .NET steps — the installer may have changed."
# (macOS awk can't take a multi-line -v value, so pass the names space-separated)
managed_list=$(printf "%s " $managed)
awk -F'\t' -v OFS='\t' -v list="$managed_list" '
    BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    { sub(/\r$/, "") }
    NR > 3 && ($1 in skip) { $2 = "0" }
    { printf "%s\r\n", $0 }' "$WORK_UNIX/InstallExecuteSequence.idt" > "$WORK_UNIX/seq.tmp" \
    && mv "$WORK_UNIX/seq.tmp" "$WORK_UNIX/InstallExecuteSequence.idt"
"$WINE" msidb -d "$WORK_WIN\\eos.msi" -f "$WORK_WIN" -i InstallExecuteSequence.idt \
    || fail "couldn't write the patched step list back."
# verify
mkdir -p "$WORK_UNIX/check"
"$WINE" msidb -d "$WORK_WIN\\eos.msi" -f "$WORK_WIN\\check" -e InstallExecuteSequence
off=$(tr -d '\r' < "$WORK_UNIX/check/InstallExecuteSequence.idt" | awk -F'\t' 'NR>3 && $2=="0"' | wc -l | tr -d ' ')
echo "switched off $off of $(echo "$managed" | wc -l | tr -d ' ') .NET steps"
[ "$off" -ge 1 ] || fail "the patch didn't stick."

product_code=$(tr -d '\r' < "$WORK_UNIX/Property.idt" | awk -F'\t' '$1=="ProductCode"{print $2}')
main_version=$(tr -d '\r' < "$WORK_UNIX/CustomAction.idt" | awk -F'\t' '$1=="CreateRegistryKeysData"{print $4}' \
               | tr ';' '\n' | sed -n 's/^MainService_Version=//p')
echo "package: Epic Online Services, product code $product_code, service version ${main_version:-unknown}"

step "Step 4/5: installing Epic Online Services"
run_with_limit 900 "$WINE" msiexec /i "$WORK_WIN\\eos.msi" /qn ALLUSERS=1 /l*v "$WORK_WIN\\install.log"
rc=$?
wait_wine 30
tail -n 3 "$WORK_UNIX/install.log" 2>/dev/null | tr -d '\r' | sed 's/^/   log: /'
install_dir=""
for d in "$BOTTLE/drive_c/Program Files (x86)/Epic Games/Epic Online Services" \
         "$BOTTLE/drive_c/Program Files/Epic Games/Epic Online Services"; do
    [ -d "$d" ] && [ -n "$(find "$d" -iname '*.exe' 2>/dev/null | head -n1)" ] && { install_dir="$d"; break; }
done
[ -n "$install_dir" ] || fail "msiexec finished (code $rc) but Epic Online Services files aren't there."
echo "installed to $(winpath "$install_dir")"

step "Step 5/5: doing the jobs of the switched-off steps"
REG='HKLM\SOFTWARE\Epic Games\EOS'
[ -n "$product_code" ] && "$WINE" reg add "$REG" /v MSIProductCode /t REG_SZ /d "$product_code" /reg:32 /f >/dev/null
for comp in $EOS_COMPONENTS; do
    exe="EpicOnlineServices$comp.exe"
    [ "$comp" = "MainService" ] && exe="EpicOnlineServicesHost.exe"
    found=$(find "$install_dir" -iname "$exe" -not -path '*/.egstore/*' 2>/dev/null | awk '{ print length, $0 }' | sort -n | head -n1 | cut -d' ' -f2-)
    if [ -z "$found" ]; then echo "  ! $comp: $exe not found, skipping"; continue; fi
    version="1.0.0"; [ "$comp" = "MainService" ] && [ -n "$main_version" ] && version="$main_version"
    "$WINE" reg add "$REG\\$comp" /v Path    /t REG_SZ /d "$(winpath "$found")" /reg:32 /f >/dev/null
    "$WINE" reg add "$REG\\$comp" /v Version /t REG_SZ /d "$version" /reg:32 /f >/dev/null
    echo "  ✓ registered $comp"
done
"$WINE" reg add "$REG\\RegisteredProducts" /v Manual /t REG_DWORD /d 1 /reg:32 /f >/dev/null && echo "  ✓ registered product (manual install)"

helper=$(find "$install_dir" -iname 'EpicOnlineServicesUserHelper.exe' -not -path '*/.egstore/*' | head -n1)
if [ -n "$helper" ]; then
    echo "  running Epic's setup helper (up to 2 minutes)…"
    ( cd "$(dirname "$helper")" && run_with_limit 120 "$WINE" "$(winpath "$helper")" --setup --msimode=NewInstall )
    echo "  ✓ setup helper finished (code $?; 15 just means its own service step failed — handled next)"
else
    echo "  ! setup helper not found, skipping"
fi

# Epic's helper registers the "EpicOnlineServices" Windows service by running
# "EpicOnlineServicesHost.exe install", which fails under Wine (exit code 1006).
# Register the same service directly with Wine's own sc tool instead.
host=$(find "$install_dir" -iname 'EpicOnlineServicesHost.exe' -not -path '*/.egstore/*' 2>/dev/null \
       | awk '{ print length, $0 }' | sort -n | head -n1 | cut -d' ' -f2-)
if [ -n "$host" ]; then
    if "$WINE" sc query EpicOnlineServices 2>/dev/null | grep -q "SERVICE_NAME"; then
        echo "  ✓ Epic Online Services service already registered"
    else
        "$WINE" sc create EpicOnlineServices binpath= "\"$(winpath "$host")\"" \
            start= demand displayname= "Epic Online Services" >/dev/null 2>&1
        if "$WINE" sc query EpicOnlineServices 2>/dev/null | grep -q "SERVICE_NAME"; then
            echo "  ✓ registered the Epic Online Services service"
        else
            echo "  ! couldn't register the Epic Online Services service"
        fi
    fi
fi
wait_wine 30

echo
echo "DONE. Epic Online Services is installed."
echo "Open Myskef and choose 'Open Epic Games Launcher' — the purple banner should be gone."
