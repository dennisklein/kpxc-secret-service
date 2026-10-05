# kpxc-secret-service

Use KeePassXC through the Secret Service D-Bus API (`org.freedesktop.secrets`)
while the desktop's own Secret Service (GNOME Keyring on Fedora) stays the
default. KeePassXC runs as a systemd user service on a **private D-Bus bus**
at `$XDG_RUNTIME_DIR/kpxc-bus`, and clients pick it explicitly:

```sh
secret-tool lookup service github         # GNOME Keyring, as before
kpxc-secret lookup service github         # KeePassXC
kpxc-run git credential-libsecret get     # any Secret Service client → KeePassXC
```

`kpxc-run` sets `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/kpxc-bus`
for one command. Don't export it in your shell profile: graphical programs
would lose their desktop integration.

## Install

```sh
sudo dnf install https://github.com/dennisklein/kpxc-secret-service/releases/latest/download/kpxc-secret-service-release.noarch.rpm
sudo dnf install kpxc-secret-service
```

The first package adds the signed dnf repository (or use
`sudo dnf config-manager addrepo --from-repofile=https://dennisklein.github.io/kpxc-secret-service/kpxc-secret-service.repo`).
When the second command asks you to import the key, check its fingerprint:
`28281F7BE556E80C88D4B54A2791893E80AC10AC`, as in
[`RPM-GPG-KEY-kpxc-secret-service`](RPM-GPG-KEY-kpxc-secret-service). To
build the RPM yourself, see [Development](#development).

Then opt users in:

| Who decides | How |
|---|---|
| Administrator | `sudo kpxc-secret-service enable alice` creates `/etc/kpxc-secret-service/users.d/alice`. Works before alice's first login; starts right away if alice is logged in. |
| The user | `kpxc-secret-service enable` creates `~/.config/kpxc-secret-service/enabled` and starts everything. |
| Package build | `make rpm MOCK_OPTS="--define 'kpxc_users alice'"` builds the opt-in into the package. |

Last, in KeePassXC, choose the group each database exposes under
**Database → Database Settings → Secret Service Integration**. KeePassXC
only serves exposed groups.

## How users are opted in

An RPM cannot enable a unit for one user, so a global preset
(`80-kpxc-secret-service.preset`, applied by `%systemd_user_post`) enables
`kpxc-bus.socket` and `kpxc-secret-service.service` for everyone, and both
only start for users with a marker file:

```ini
ConditionUser=!@system
ConditionPathExists=|/etc/kpxc-secret-service/users.d/%u
ConditionPathExists=|%E/kpxc-secret-service/enabled
```

Root never writes into home directories, the choice is one file per user
(easy for Ansible or a kickstart), it works before the first login, and
`dnf remove` disables everything again.

On its first start, the user's service runs `kpxc-secret-service setup
--once`: it turns on KeePassXC's Secret Service integration
(`[FdoSecrets] Enabled=true`), adds a KeePassXC menu entry that starts
KeePassXC through the service, and removes KeePassXC's own autostart entry,
which would race with the service.

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
| `kpxc-secret-service.service` | KeePassXC with the private bus as its session bus. Starts with the graphical session, on D-Bus activation, or from the menu entry. |
| `kpxc-lock-relay.service` | Passes screen-lock signals on to KeePassXC. Pulled in by the KeePassXC service. |

- **KeePassXC has a single session bus**, so what it does on the desktop
  bus needs a bridge:
  - *Locking with the screen:* `kpxc-lock-relay` owns the screen saver names
    KeePassXC listens to on the private bus and re-emits the desktop's
    signals there. Locking through logind (suspend, `loginctl lock-session`,
    lid switch) uses the system bus; the launcher hands KeePassXC the
    user's graphical session for it.
  - *URLs and attachments:* an `xdg-open` shim opens them on the desktop
    bus, in a systemd scope of their own.
  - *Not bridged:* tray icon, notifications, dark-mode detection (set the
    theme in KeePassXC) and accessibility. Lock scripts should run
    `keepassxc --lock`, which works on any bus, since KeePassXC's own D-Bus
    interface is on the private bus too.
- **D-Bus activation works:** `kpxc-secret …` starts KeePassXC on demand,
  which asks you to unlock. It needs the graphical session, so not over SSH.
- **KeePassXC is single-instance** (lock file and local socket), so the
  menu entry runs `kpxc-secret-service open`: start the service, then let
  `keepassxc` raise the window or open the file. If KeePassXC already runs
  outside the service, the service refuses to start (exit status 75) and
  asks you to quit it.

## Security model

The private bus keeps KeePassXC away from programs that use the Secret
Service unasked: desktop applications keep using GNOME Keyring, sandboxed
Flatpak and Snap applications can't reach the socket (unless granted
`xdg-run/kpxc-bus`), and other users can't connect.

It is **not** a boundary against unsandboxed programs running as you, any
more than GNOME Keyring's bus is. They can find the socket, request secrets,
start KeePassXC to show a genuine unlock prompt, or claim
`org.freedesktop.secrets` while KeePassXC isn't running; so can your SSH
sessions. What guards your passwords is KeePassXC's **Confirm when
passwords are retrieved by clients**. Keep it on: KeePassXC's notifications
about retrieved passwords need the tray, so they never show here.

Outside of the service, KeePassXC would claim `org.freedesktop.secrets` on
the desktop bus, and without another Secret Service there serve every
application. So `kpxc-secret-service open` starts KeePassXC only through
the service while you are opted in, and reverts the setup once you aren't.
`kpxc-secret-service doctor` warns when confirmation is off, nobody owns
`org.freedesktop.secrets` on the desktop bus, or the lock relay has failed.

## Configuration

- Extra KeePassXC arguments: `systemctl --user edit kpxc-secret-service.service`
  ```ini
  [Service]
  Environment=KEEPASSXC_ARGS=--minimized
  ```
- On demand only, not at login: `sudo systemctl --global disable
  kpxc-secret-service.service` (one user can still
  `systemctl --user enable` it).
- Don't lock with the screen: `systemctl --user mask kpxc-lock-relay.service`.

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

## Opting out and uninstalling

- User: `kpxc-secret-service disable` stops the units, removes the menu
  entry and turns KeePassXC's Secret Service integration off again. If the
  administrator opted you in, mask the units instead:
  `systemctl --user mask kpxc-bus.socket kpxc-secret-service.service`.
- Administrator: `sudo kpxc-secret-service disable alice`.

After an opt-out without `disable`, the next start from the menu reverts
the setup. Before `sudo dnf remove kpxc-secret-service`, have users run
`kpxc-secret-service disable`: a leftover menu entry starts plain
`keepassxc` with the integration still on.

## Releases

Set `Version:` in the spec, commit, then `git tag v0.2.0 && git push origin
v0.2.0`. The release workflow checks the tag against `Version:` and builds
the packages without secrets. A separate job signs them: `make release-rpm`
builds `kpxc-secret-service-release` (`.repo` file and public key), and
`make repo` signs the RPMs, the SRPM and the repository metadata. The job
accepts no key but the one in `RPM-GPG-KEY-kpxc-secret-service`; to change
keys, commit the new one there. Finally the workflow creates the GitHub release
and publishes the repository (latest release only) on GitHub Pages.

One-time setup on GitHub:

1. Settings → Environments → new environment `release`: allow only the tag
   pattern `v*` (optionally require a reviewer), and add the secrets
   `GPG_PRIVATE_KEY` (`gpg --armor --export-secret-keys KEY`) and, if the
   key has one, `GPG_PASSPHRASE`. Delete repository-level copies under
   Settings → Secrets and variables → Actions: every workflow run can read
   those.
2. Settings → Rules: a tag ruleset that restricts who may create `v*` tags.
3. Settings → Pages → Source: **GitHub Actions**; Settings → Environments →
   `github-pages`: add the tag pattern `v*`.

Locally: `make rpm && make release-rpm repo GPG_KEY=you@example.org`, with
the tools from `sudo make repo-deps`.

## Development

Build the RPM with mock, in a clean chroot of your Fedora release:

```sh
sudo make build-deps     # once: mock, its rpmautospec plugin and git; adds you to the mock group
make rpm                 # after logging in again, so the group applies
sudo dnf install results/default/kpxc-secret-service-*.noarch.rpm
```

The mock group is effectively root (`mock(1)`). `make srpm` stops after the
source RPM; `MOCK_CHROOT=fedora-44-x86_64` and `MOCK_OPTS` select the chroot
and mock options. The build uses `HEAD`, not the working tree. `Release:`
and `%changelog` come from the commits (rpmautospec); `[skip changelog]` on
a line of its own keeps a commit out of the changelog, also in a squash
merge's message. The `*-deps` targets refuse to run without `sudo`, and
nothing in the Makefile calls `sudo` itself. `sudo make install` installs
without a package.

```sh
sudo make test-deps   # once: tools for lint and test
make check            # syntax checks (also run by the RPM's %check)
make lint             # shellcheck + systemd-analyze verify (needs the package installed)
make test             # tests/smoke-test.sh
```

The smoke test runs as a regular user, without systemd: a throwaway desktop
bus with a fake GNOME Keyring and screen saver, the real private bus and a
headless KeePassXC. It checks which bus owns what, `kpxc-secret`, the lock
relay, the launcher, the `xdg-open` shim, the menu entry, `setup`, `open`
and `disable`. It needs the packages from `make test-deps` and journald's
socket. The systemd
side (login, presets, conditions, activation, restarts) needs a real Fedora
session. CI builds the RPM and SRPM with mock on every push, then signs them
with a throwaway key and installs them from the resulting repository.
