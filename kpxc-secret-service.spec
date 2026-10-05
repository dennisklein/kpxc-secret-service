Name:           kpxc-secret-service
Version:        0.1.0
Release:        1%{?dist}
Summary:        KeePassXC as Secret Service on a private D-Bus bus, next to GNOME Keyring

License:        MIT
URL:            https://github.com/dennisklein/kpxc-secret-service
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  make
BuildRequires:  python3
BuildRequires:  systemd-rpm-macros

Requires:       keepassxc
Requires:       dbus-broker
# gdbus
Requires:       glib2
Requires:       python3
Requires:       python3-gobject-base
Requires:       systemd
Requires:       xdg-utils
# secret-tool, used by kpxc-secret
Recommends:     libsecret
# notify-send, for "KeePassXC already runs elsewhere" notifications
Recommends:     libnotify

# Optionally opt users in at build time, so installing the package is all it
# takes: rpmbuild --define 'kpxc_users alice bob' ...
%global kpxc_users %{?kpxc_users}

%global units kpxc-bus.socket kpxc-secret-service.service

%description
Runs KeePassXC as a systemd user service on a private D-Bus bus
($XDG_RUNTIME_DIR/kpxc-bus), where it provides the Secret Service API
(org.freedesktop.secrets). The desktop's own Secret Service, such as GNOME
Keyring, stays the default on the session bus. Clients pick KeePassXC with
kpxc-secret (secret-tool), kpxc-run, or
DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/kpxc-bus.

The user units are enabled for all users but only start for users who opted
in: `kpxc-secret-service enable` as the user, or
`kpxc-secret-service enable USER` as root.

%prep
%autosetup

%build

%install
%make_install
%if "%{kpxc_users}" != ""
for user in %{kpxc_users}; do
    touch %{buildroot}%{_sysconfdir}/%{name}/users.d/"$user"
done
%endif

%check
make check

%post
%systemd_user_post %{units}

%preun
%systemd_user_preun %{units}

%files
%license LICENSE
%doc README.md
%{_bindir}/kpxc-secret-service
%{_bindir}/kpxc-secret
%{_bindir}/kpxc-run
%{_libexecdir}/%{name}/
%{_datadir}/%{name}/
%{_userunitdir}/kpxc-bus.socket
%{_userunitdir}/kpxc-bus.service
%{_userunitdir}/kpxc-secret-service.service
%{_userunitdir}/kpxc-lock-relay.service
%{_userpresetdir}/80-%{name}.preset
%dir %{_sysconfdir}/%{name}
%dir %{_sysconfdir}/%{name}/users.d
%if "%{kpxc_users}" != ""
%config(noreplace) %{_sysconfdir}/%{name}/users.d/*
%endif

%changelog
* Mon Oct 05 2026 Packager <packager@example.invalid> - 0.1.0-1
- Initial package
