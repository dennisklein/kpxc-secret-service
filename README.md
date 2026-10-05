# kpxc-secret-service

Use KeePassXC through the Secret Service D-Bus API (`org.freedesktop.secrets`)
while the desktop's own Secret Service (GNOME Keyring on Fedora) stays the
default. KeePassXC runs as a systemd user service on a **private D-Bus bus**
at `$XDG_RUNTIME_DIR/kpxc-bus`, and clients pick it explicitly:

```sh
secret-tool lookup service github         # GNOME Keyring, as before
kpxc-secret lookup service github         # KeePassXC
kpxc-run git credential-libsecret get     # any Secret Service client → KeePassXC
DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/kpxc-bus secret-tool …   # by hand
```

Shell aliases like
`alias kpxc-secret='DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/kpxc-bus secret-tool'`
keep working; `kpxc-secret` is the same thing as a command, so it also works
in scripts.

## Install

Build the RPM (needs `rpm-build` and `systemd-rpm-macros`) and install it:

```sh
make rpm
sudo dnf install rpms/noarch/kpxc-secret-service-*.noarch.rpm
```

`make srpm` produces a source RPM for mock or COPR. The package requires
`keepassxc` and `dbus-broker`, both from Fedora.

Then choose the users, in whichever way suits you:

| Who decides | How |
|---|---|
| Administrator | `sudo kpxc-secret-service enable alice` creates `/etc/kpxc-secret-service/users.d/alice`. Works for users who have never logged in. If alice is logged in, it starts right away. |
| The user | `kpxc-secret-service enable` creates `~/.config/kpxc-secret-service/enabled` and starts everything. |
| Package build | `make rpm RPMBUILD_OPTS="--define 'kpxc_users alice'"` builds a package that already contains alice's opt-in, so installing it is the only step. |

One step stays inside KeePassXC, because the setting lives in each database:
choose which group a database exposes under **Database → Database Settings →
Secret Service Integration**. KeePassXC only serves exposed groups.

## Why RPM, and how a user is chosen

Shipping user units in an RPM is normal: Fedora puts many of them in
`/usr/lib/systemd/user`. What an RPM cannot do is enable a unit for one
particular user. Scriptlets run as root without a user context, and Fedora's
`%systemd_user_post` only applies **global** presets. So the setup has two
layers:

1. **The package enables the units for everyone.** A preset
   (`80-kpxc-secret-service.preset`, applied by `%systemd_user_post`) enables
   `kpxc-bus.socket` and `kpxc-secret-service.service` globally.
2. **Each user opts in.** Both units carry
   ```ini
   ConditionUser=!@system
   ConditionPathExists=|/etc/kpxc-secret-service/users.d/%u
   ConditionPathExists=|%E/kpxc-secret-service/enabled
   ```
   so they only start for a user with one of the two marker files (`|` makes
   the conditions OR). For everyone else, systemd silently skips them.

This means root never writes into home directories, the choice is declarative
(one file per user, easy to manage with Ansible or a kickstart), it works
before the user's first login, and `dnf remove` disables everything again.

Settings that do live in the user's home are changed by the user's own
service on its first start (`ExecStartPre=kpxc-secret-service setup --once`):

- turn on KeePassXC's Secret Service integration (`[FdoSecrets] Enabled=true`),
- add a KeePassXC menu entry that starts KeePassXC through the service,
- remove KeePassXC's own autostart entry, which would race with the service.

Alternatives considered:

- *Root runs `systemctl --user enable` for the user.* This needs the user's
  manager to be running (`systemctl --user -M alice@`), or root has to write
  into their home. It also fails for users who have never logged in.
- *`.wants/` symlinks shipped in `/usr`.* Same effect as the preset, but an
  admin can't override them with `systemctl --global disable`.
- *No package.* `sudo make install` installs the same files, and the opt-in
  works the same way.

## How it works

```
 desktop session bus  $XDG_RUNTIME_DIR/bus       private bus  $XDG_RUNTIME_DIR/kpxc-bus
┌───────────────────────────────────────────┐   ┌────────────────────────────────────────────┐
│ org.freedesktop.secrets → gnome-keyring   │   │ org.freedesktop.secrets → KeePassXC        │
│ org.gnome.ScreenSaver   → gnome-shell ────┼─▶ │ org.gnome.ScreenSaver   → kpxc-lock-relay  │
│                                           │   │                           (re-emits)       │
│ secret-tool, browsers, desktop apps       │   │ kpxc-secret, kpxc-run, …                   │
└───────────────────────────────────────────┘   └────────────────────────────────────────────┘
```

| Unit | What it does |
|---|---|
| `kpxc-bus.socket` | Listens on `%t/kpxc-bus` (mode 0600). Starts at login for users who opted in. |
| `kpxc-bus.service` | `dbus-broker-launch` with `kpxc-bus.conf`, socket-activated. Only `org.freedesktop.secrets` is activatable on this bus. |
| `kpxc-secret-service.service` | Runs KeePassXC with the private bus as its session bus. Starts with the graphical session, when a client asks for `org.freedesktop.secrets` on the private bus (D-Bus activation), or from the KeePassXC menu entry. |
| `kpxc-lock-relay.service` | Passes screen-lock signals on to KeePassXC (see below). Pulled in by the KeePassXC service. |

Design points worth knowing:

- **KeePassXC has a single session bus.** It uses the same connection for the
  Secret Service as for everything else. The service therefore starts it with
  `DBUS_SESSION_BUS_ADDRESS` pointing at the private bus
  (`libexec/kpxc-keepassxc`), and whatever KeePassXC normally does on the
  desktop bus needs a bridge:
  - *Lock on screen lock:* `kpxc-lock-relay` owns `org.gnome.ScreenSaver`
    (and the other names KeePassXC listens to) on the private bus and
    re-emits the desktop's signals there. KeePassXC's own "lock databases
    when session is locked" setting then applies unchanged. Locking on
    suspend uses the system bus and works anyway.
  - *Opening URLs and attachments:* an `xdg-open` shim, early in KeePassXC's
    `PATH`, gives the opened application the desktop bus and its own systemd
    scope. Without it, a browser started from KeePassXC would end up on the
    private bus and would be killed together with KeePassXC.
  - *Not bridged:* tray icon (StatusNotifierItem), desktop notifications,
    dark-mode detection through the settings portal, and accessibility
    (AT-SPI). If you rely on the dark theme, set it explicitly in KeePassXC.
- **D-Bus activation works on the private bus.** `dbus-broker-launch` asks
  systemd to start `SystemdService=` units over the regular session bus. So
  `kpxc-secret …` starts KeePassXC on demand, and KeePassXC asks you to
  unlock.
- **KeePassXC is single-instance** through a lock file and local socket, not
  D-Bus. A second `keepassxc` just hands over to the running one. That's why
  the menu entry goes through `kpxc-secret-service open`: start the service,
  then let `keepassxc` raise its window or open the file. If KeePassXC already
  runs outside the service, the service refuses to start (exit status 75,
  no restart loop) and shows a notification telling you to quit it.

## Configuration

- Extra KeePassXC arguments: `systemctl --user edit kpxc-secret-service.service`
  ```ini
  [Service]
  Environment=KEEPASSXC_ARGS=--minimized
  ```
- Start KeePassXC on demand only, not at login (for all users):
  `sudo systemctl --global disable kpxc-secret-service.service`. Individual
  users can still opt into login start with
  `systemctl --user enable kpxc-secret-service.service`.
- Don't lock with the screen: `systemctl --user mask kpxc-lock-relay.service`.
- Point other programs at KeePassXC: use `kpxc-run`, or set
  `DBUS_SESSION_BUS_ADDRESS=$(kpxc-secret-service address)` for that
  program only. Don't export it in your shell profile, because every
  graphical program started from that shell would then lose its desktop
  integration.

## Day to day

```sh
kpxc-secret-service status     # what runs, who owns org.freedesktop.secrets where
kpxc-secret-service doctor     # checks with hints
kpxc-secret-service open       # start/raise KeePassXC (what the menu entry runs)
journalctl --user -u kpxc-secret-service -u kpxc-bus -u kpxc-lock-relay
```

- *"KeePassXC is already running outside of kpxc-secret-service":* quit that
  KeePassXC, then run `kpxc-secret-service open`.
- *A client hangs:* KeePassXC is probably waiting for you to unlock a
  database or confirm access. Also check that the database exposes a group.
- *Over SSH or on a text console:* KeePassXC needs the graphical session, so
  activation fails there (`Requisite=graphical-session.target`).

## Opting out and uninstalling

- User: `kpxc-secret-service disable` stops the units, removes the menu entry
  and turns KeePassXC's Secret Service integration off again (on the desktop
  bus it would only collide with GNOME Keyring). If the administrator opted
  you in, it tells you how to mask the units instead.
- Administrator: `sudo kpxc-secret-service disable alice`.
- `sudo dnf remove kpxc-secret-service` disables the units globally. Have
  users run `kpxc-secret-service disable` first. A menu entry left behind
  falls back to starting plain `keepassxc`.

## Files

| Path | Purpose |
|---|---|
| `/usr/bin/kpxc-secret-service` | Management CLI: `enable`, `disable`, `status`, `doctor`, `setup`, `open`, `list`, `address` |
| `/usr/bin/kpxc-secret`, `/usr/bin/kpxc-run` | Clients against the private bus |
| `/usr/lib/systemd/user/kpxc-*.{socket,service}` | The units above |
| `/usr/lib/systemd/user-preset/80-kpxc-secret-service.preset` | Global enablement |
| `/usr/libexec/kpxc-secret-service/` | KeePassXC launcher, lock relay, `xdg-open` shim |
| `/usr/share/kpxc-secret-service/` | Bus configuration and the activation file |
| `/etc/kpxc-secret-service/users.d/` | Users opted in by the administrator |

## Development

```sh
make check   # syntax checks (also run by the RPM's %check)
make lint    # shellcheck + systemd-analyze verify
make test    # tests/smoke-test.sh
```

The smoke test runs without systemd. It builds a throwaway desktop bus with a
fake GNOME Keyring and screen saver, plus the real private bus
(`dbus-broker-launch` with `kpxc-bus.conf`) and a headless KeePassXC started
through `kpxc-keepassxc` with a test database. It checks:

- which bus owns what,
- that `kpxc-secret` lookups and stores reach KeePassXC while plain
  `secret-tool` does not,
- that the relay locks KeePassXC when the screen saver activates,
- the `xdg-open` shim, the generated menu entry, `setup` and `disable`.

It needs `dbus-daemon`, `dbus-broker`, `keepassxc`, `libsecret`,
`python3-gobject` and `pykeepass`. It must run as a regular user, and
`dbus-broker-launch` needs journald's socket.

The smoke test does not cover the systemd side: login ordering, presets,
conditions, D-Bus activation through systemd, and restart behaviour. That
needs a real Fedora session.
