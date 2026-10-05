#!/bin/bash
# End-to-end smoke test of kpxc-secret-service, without systemd:
#
#  - a throwaway "desktop" session bus (dbus-daemon) with a fake GNOME Keyring
#    owning org.freedesktop.secrets and a fake GNOME screen saver,
#  - the private bus, run by dbus-broker-launch with kpxc-bus.conf on a socket
#    passed in by systemd-socket-activate (as kpxc-bus.socket would),
#  - KeePassXC (offscreen) started through libexec/kpxc-keepassxc with a test
#    database whose root group is exposed to the Secret Service,
#  - the lock relay, the xdg-open shim and `kpxc-secret-service setup`.
#
# Run it as a regular user. Needs dbus-daemon, dbus-broker-launch,
# systemd-socket-activate, gdbus, keepassxc, secret-tool, python3-gobject and
# pykeepass. PYTHON selects the interpreter that has gi and pykeepass.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
PYTHON=${PYTHON:-python3}

T=$(mktemp -d)
pids=()
cleanup() {
    # SIGKILL: an offscreen KeePassXC may sit in a dialog nobody can answer.
    for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null || :; done
    wait 2>/dev/null || :
    if [ -n "${KEEP_TMP-}" ]; then echo "kept $T" >&2; else rm -rf "$T"; fi
}
trap cleanup EXIT

export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_DATA_HOME=$T/home/.local/share
export XDG_RUNTIME_DIR=$T/run TMPDIR=$T/tmp QT_QPA_PLATFORM=offscreen
export PATH=$repo/bin:$T/bin:$PATH
unset DBUS_SESSION_BUS_ADDRESS DISPLAY WAYLAND_DISPLAY XDG_SESSION_ID
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" "$T/bin"
chmod 700 "$XDG_RUNTIME_DIR"

# logind as kpxc-keepassxc sees it: the user's graphical session.
printf '#!/bin/sh\n[ "$1 $3 $4" = "show-user --property=Display --value" ] && echo smoke-session\n' \
    >"$T/bin/loginctl"
chmod +x "$T/bin/loginctl"

desktop=unix:path=$XDG_RUNTIME_DIR/bus
private=unix:path=$XDG_RUNTIME_DIR/kpxc-bus

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Command name of the process owning NAME on the bus at ADDRESS, if any.
owner() {
    local pid
    pid=$(gdbus call --address "$1" --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID "$2" 2>/dev/null |
        sed -n 's/^(uint32 \([0-9]*\),)$/\1/p') || :
    if [ -n "$pid" ]; then cat "/proc/$pid/comm"; fi
}

collection_locked() {
    gdbus call --address "$private" --dest org.freedesktop.secrets --object-path "$1" \
        --method org.freedesktop.DBus.Properties.Get org.freedesktop.Secret.Collection Locked
}

# --- desktop session bus with fake GNOME Keyring and screen saver ----------
dbus-daemon --session --address="$desktop" --nofork --nopidfile >/dev/null &
pids+=($!)
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 0.1; done
export DBUS_SESSION_BUS_ADDRESS=$desktop

"$PYTHON" - >"$T/fake-desktop.log" 2>&1 <<'EOF' &
import signal
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
for name in ("org.freedesktop.secrets", "org.gnome.ScreenSaver"):
    bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                  "RequestName", GLib.Variant("(su)", (name, 4)), None, 0, -1, None)

def screen_locked():
    bus.emit_signal(None, "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver",
                    "ActiveChanged", GLib.Variant("(b)", (True,)))
    return GLib.SOURCE_CONTINUE

GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, screen_locked)
GLib.MainLoop().run()
EOF
fake_desktop=$!
pids+=("$fake_desktop")
gdbus wait --session --timeout 10 org.gnome.ScreenSaver

# --- private bus, as kpxc-bus.socket + kpxc-bus.service would run it -------
# dbus-broker-launch logs straight to journald.
[ -S /run/systemd/journal/socket ] || fail "dbus-broker-launch needs journald's socket"
sed "s|/usr/share/kpxc-secret-service/dbus-1/services|$repo/data/dbus-1/services|" \
    "$repo/data/kpxc-bus.conf" >"$T/kpxc-bus.conf"
# Like the user manager, hand it the desktop bus to reach "systemd" through.
systemd-socket-activate --listen="$XDG_RUNTIME_DIR/kpxc-bus" \
    --setenv=DBUS_SESSION_BUS_ADDRESS --setenv=XDG_RUNTIME_DIR \
    dbus-broker-launch --scope user --config-file "$T/kpxc-bus.conf" 2>"$T/broker.log" &
pids+=($!)
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/kpxc-bus" ] && break; sleep 0.1; done

activatable=$(gdbus call --address "$private" --dest org.freedesktop.DBus \
    --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListActivatableNames |
    grep -o "'[^']*'" | tr -d "'" | sort | paste -sd ' ')
[ "$activatable" = "org.freedesktop.DBus org.freedesktop.secrets" ] ||
    fail "activatable names on the private bus: $activatable"
pass "only org.freedesktop.secrets is activatable on the private bus"

# --- per-user setup ------------------------------------------------------------
ini=$XDG_CONFIG_HOME/keepassxc/keepassxc.ini
mkdir -p "$(dirname "$ini")" "$XDG_CONFIG_HOME/autostart"
cat >"$ini" <<'EOF'
[General]
ConfigVersion=2
UpdateCheckMessageShown=true

[FdoSecrets]
ConfirmAccessItem=false
ShowNotification=false
UnlockBeforeSearch=false
EOF
touch "$XDG_CONFIG_HOME/autostart/org.keepassxc.KeePassXC.desktop"

"$PYTHON" "$repo/bin/kpxc-secret-service" setup --once

grep -qx 'Enabled=true' "$ini" || fail "setup did not enable FdoSecrets: $(cat "$ini")"
grep -qx 'ConfirmAccessItem=false' "$ini" || fail "setup lost existing settings: $(cat "$ini")"
[ "$(grep -c '^\[FdoSecrets\]' "$ini")" = 1 ] || fail "setup duplicated the section: $(cat "$ini")"
pass "setup enabled KeePassXC's Secret Service integration"
[ ! -e "$XDG_CONFIG_HOME/autostart/org.keepassxc.KeePassXC.desktop" ] ||
    fail "setup kept KeePassXC's autostart entry"
pass "setup removed KeePassXC's autostart entry"
[ -e "$XDG_CONFIG_HOME/kpxc-secret-service/setup-done" ] || fail "setup did not record completion"

# keepassxc for the commands that start it, where the real one is not wanted.
mkdir -p "$T/stub"
printf '#!/bin/sh\necho "keepassxc-stub: $*"\n' >"$T/stub/keepassxc"
chmod +x "$T/stub/keepassxc"

menu=$XDG_DATA_HOME/applications/org.keepassxc.KeePassXC.desktop
if [ -e /usr/share/applications/org.keepassxc.KeePassXC.desktop ]; then
    grep -qx 'X-KPXC-Secret-Service=true' "$menu" || fail "menu entry not generated"
    if command -v desktop-file-validate >/dev/null; then
        desktop-file-validate "$menu" || fail "invalid menu entry"
    fi
    # In a home of its own: with the package installed, the entry runs
    # `kpxc-secret-service open`, which undoes the setup of users who are not
    # opted in (this test never opts in).
    launched=$(HOME=$T/menu-home XDG_CONFIG_HOME=$T/menu-home/.config \
        XDG_DATA_HOME=$T/menu-home/.local/share PATH=$T/stub:$PATH \
        "$PYTHON" - "$menu" "$T/my file.kdbx" <<'EOF'
import subprocess, sys
from gi.repository import Gio, GLib
info = Gio.DesktopAppInfo.new_from_filename(sys.argv[1])
ok, argv = GLib.shell_parse_argv(info.get_commandline())
assert argv[:2] == ["sh", "-c"] and argv[-1] == "%f", argv
print(subprocess.run(argv[:-1] + [sys.argv[2]], capture_output=True, text=True).stdout.strip())
EOF
)
    [ "$launched" = "keepassxc-stub: $T/my file.kdbx" ] || fail "menu entry runs: $launched"
    pass "menu entry parses and hands files to keepassxc"
fi

# --- KeePassXC on the private bus --------------------------------------------
PYTHONPATH=${PYKEEPASS_PATH:-} "$PYTHON" - "$T/test.kdbx" <<'EOF'
import sys
from lxml import etree
from pykeepass import create_database

kp = create_database(sys.argv[1], password="pw")
kp.add_entry(kp.root_group, "kpxc-smoke", "user", "s3cret")
# Expose the root group to the Secret Service, as Database Settings would.
meta = kp._xpath("/KeePassFile/Meta", first=True)
custom = meta.find("CustomData")
if custom is None:
    custom = etree.SubElement(meta, "CustomData")
item = etree.SubElement(custom, "Item")
etree.SubElement(item, "Key").text = "FDO_SECRETS_EXPOSED_GROUP"
etree.SubElement(item, "Value").text = "{%s}" % kp.root_group.uuid
kp.save()
EOF

# KeePassXC follows logind's Lock signal for the session in XDG_SESSION_ID.
mkdir -p "$T/stub-session"
printf '#!/bin/sh\necho "${XDG_SESSION_ID-}"\n' >"$T/stub-session/keepassxc"
chmod +x "$T/stub-session/keepassxc"
[ "$(PATH=$T/stub-session:$PATH "$repo/libexec/kpxc-keepassxc")" = smoke-session ] ||
    fail "kpxc-keepassxc does not hand KeePassXC the user's graphical session"
[ "$(XDG_SESSION_ID=own PATH=$T/stub-session:$PATH "$repo/libexec/kpxc-keepassxc")" = own ] ||
    fail "kpxc-keepassxc replaced an XDG_SESSION_ID it was given"
pass "kpxc-keepassxc hands KeePassXC the graphical session for logind's Lock signal"

echo pw | "$repo/libexec/kpxc-keepassxc" --pw-stdin "$T/test.kdbx" >"$T/keepassxc.log" 2>&1 &
keepassxc_pid=$!
pids+=("$keepassxc_pid")
gdbus wait --address "$private" --timeout 30 org.keepassxc.KeePassXC.MainWindow ||
    fail "KeePassXC did not appear on the private bus: $(cat "$T/keepassxc.log")"
gdbus wait --address "$private" --timeout 15 org.freedesktop.secrets

[ "$(owner "$private" org.freedesktop.secrets)" = keepassxc ] ||
    fail "org.freedesktop.secrets on the private bus is not KeePassXC"
pass "KeePassXC owns org.freedesktop.secrets on the private bus"
[ "$(owner "$desktop" org.freedesktop.secrets)" = "$(cat "/proc/$fake_desktop/comm")" ] ||
    fail "the desktop's Secret Service was displaced"
[ -z "$(owner "$desktop" org.keepassxc.KeePassXC.MainWindow)" ] ||
    fail "KeePassXC is on the desktop bus"
pass "the desktop bus keeps its own Secret Service and does not see KeePassXC"

collection=$(gdbus call --address "$private" --dest org.freedesktop.secrets \
    --object-path /org/freedesktop/secrets --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.Secret.Service Collections | grep -o "/org/freedesktop/secrets/collection/[^']*")
[ -n "$collection" ] || fail "the test database is not exposed as a collection"
# --pw-stdin unlocks the database shortly after KeePassXC registers on the bus.
for _ in $(seq 50); do
    [ "$(collection_locked "$collection")" = "(<false>,)" ] && break
    sleep 0.2
done
[ "$(collection_locked "$collection")" = "(<false>,)" ] || fail "the test database did not unlock"

[ "$(timeout 20 kpxc-secret lookup Title kpxc-smoke)" = s3cret ] ||
    fail "kpxc-secret lookup did not return the KeePassXC entry"
pass "kpxc-secret looks up KeePassXC entries"
printf stored | timeout 20 kpxc-secret store --label=kpxc-smoke-store smoke key
[ "$(timeout 20 kpxc-secret lookup smoke key)" = stored ] || fail "store/lookup round trip failed"
pass "kpxc-secret stores secrets in KeePassXC"
[ "$(timeout 5 secret-tool lookup Title kpxc-smoke 2>/dev/null)" != s3cret ] ||
    fail "plain secret-tool reached KeePassXC"
pass "plain secret-tool still talks to the desktop's Secret Service"

# --- lock relay -------------------------------------------------------------------
# KeePassXC ignores signals from a relay that waits in the queue for a name
# someone else owns, so the relay must fail instead.
"$PYTHON" - "$private" <<'EOF' &
import sys
from gi.repository import Gio, GLib
bus = Gio.DBusConnection.new_for_address_sync(
    sys.argv[1], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT
    | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
              "RequestName", GLib.Variant("(su)", ("org.gnome.ScreenSaver", 4)), None, 0, -1, None)
GLib.MainLoop().run()
EOF
squatter=$!
pids+=("$squatter")
gdbus wait --address "$private" --timeout 10 org.gnome.ScreenSaver
status=0
timeout 10 "$PYTHON" "$repo/libexec/kpxc-lock-relay" 2>"$T/relay-squatted.log" || status=$?
[ "$status" = 1 ] ||
    fail "relay exited with $status while another connection owned a name: $(cat "$T/relay-squatted.log")"
pass "the relay fails when it cannot own a screen saver name"
kill "$squatter"
for _ in $(seq 50); do [ -z "$(owner "$private" org.gnome.ScreenSaver)" ] && break; sleep 0.1; done

"$PYTHON" "$repo/libexec/kpxc-lock-relay" 2>"$T/relay.log" &
pids+=($!)
gdbus wait --address "$private" --timeout 10 org.gnome.ScreenSaver
kill -USR1 "$fake_desktop"
for _ in $(seq 50); do
    [ "$(collection_locked "$collection")" = "(<true>,)" ] && break
    sleep 0.2
done
[ "$(collection_locked "$collection")" = "(<true>,)" ] ||
    fail "KeePassXC did not lock on the desktop's screen lock: $(cat "$T/relay.log")"
pass "the relay locks KeePassXC when the desktop's screen locks"

# --- xdg-open shim -------------------------------------------------------------------
mkdir -p "$T/xdg"
cat >"$T/xdg/xdg-open" <<'EOF'
#!/bin/sh
echo "bus=$DBUS_SESSION_BUS_ADDRESS leaked=${KPXC_SECRET_SERVICE_DESKTOP_BUS-} path=$PATH args=$*"
EOF
chmod +x "$T/xdg/xdg-open"
opened=$(env -i KPXC_SECRET_SERVICE_DESKTOP_BUS="$desktop" DBUS_SESSION_BUS_ADDRESS="$private" \
    PATH="/usr/libexec/kpxc-secret-service/shims:$T/xdg" /bin/sh "$repo/libexec/shims/xdg-open" https://example.org)
[ "$opened" = "bus=$desktop leaked= path=$T/xdg args=https://example.org" ] ||
    fail "xdg-open shim: $opened"
pass "xdg-open shim hands opened URLs the desktop bus"

# --- status, doctor, disable ---------------------------------------------------------
for command in status doctor; do
    out=$("$PYTHON" "$repo/bin/kpxc-secret-service" $command 2>&1) || :
    case $out in *Traceback*) fail "kpxc-secret-service $command crashed: $out" ;; esac
done
pass "status and doctor run"
# The test's keepassxc.ini has ConfirmAccessItem=false.
case $out in *"without asking"*) ;; *) fail "doctor does not warn about ConfirmAccessItem=false: $out" ;; esac
pass "doctor warns when KeePassXC hands out passwords without asking"

kill -9 "$keepassxc_pid"
wait "$keepassxc_pid" 2>/dev/null || :

# Opted in, but the service did not start (here: there is no systemd).
# KeePassXC started anyway would serve the Secret Service on the desktop bus.
marker=$XDG_CONFIG_HOME/kpxc-secret-service/enabled
touch "$marker"
if out=$(PATH=$T/stub:$PATH "$PYTHON" "$repo/bin/kpxc-secret-service" open 2>&1); then
    fail "open succeeded although the service did not start: $out"
fi
case $out in *keepassxc-stub*) fail "open started KeePassXC outside of the service: $out" ;; esac
pass "open does not start KeePassXC outside of the service it failed to start"
rm "$marker"

# Not opted in (any more), e.g. after the administrator disabled the user.
out=$(PATH=$T/stub:$PATH "$PYTHON" "$repo/bin/kpxc-secret-service" open "$T/test.kdbx" 2>&1) ||
    fail "open without opt-in: $out"
case $out in *"keepassxc-stub: $T/test.kdbx"*) ;; *) fail "open did not start keepassxc: $out" ;; esac
grep -qx 'Enabled=false' "$ini" || fail "open without opt-in left FdoSecrets enabled"
[ ! -e "$menu" ] || fail "open without opt-in left the menu entry"
pass "open without opt-in undoes the setup, then starts KeePassXC"

# `disable USER` (root only) deletes users.d/USER, so USER must not be a path.
"$PYTHON" -B - "$repo/bin/kpxc-secret-service" <<'EOF' || fail "users.d accepts paths as user names"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("kpxc_secret_service", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
for name in ("../../passwd", "/etc/passwd", "..", ""):
    try:
        module.users_d_marker(name)
    except module.Error:
        continue
    sys.exit(f"accepted {name!r}")
assert module.users_d_marker("alice") == module.USERS_DIR / "alice"
EOF
pass "disable USER refuses names that point outside of users.d"

"$PYTHON" "$repo/bin/kpxc-secret-service" setup >/dev/null
grep -qx 'Enabled=true' "$ini" || fail "setup did not enable FdoSecrets again"
"$PYTHON" "$repo/bin/kpxc-secret-service" disable >/dev/null 2>&1 || :
grep -qx 'Enabled=false' "$ini" || fail "disable left FdoSecrets enabled"
[ ! -e "$menu" ] || fail "disable left the menu entry"
pass "disable reverts the per-user setup"

echo "All smoke tests passed."
