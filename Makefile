NAME    := kpxc-secret-service
DESTDIR ?=

# Fedora paths; the units and scripts refer to these literally.
bindir         := /usr/bin
libexecdir     := /usr/libexec/$(NAME)
datadir        := /usr/share/$(NAME)
docdir         := /usr/share/doc/$(NAME)
userunitdir    := /usr/lib/systemd/user
userpresetdir  := /usr/lib/systemd/user-preset
sysconfdir     := /etc/$(NAME)

SHELL_SCRIPTS  := bin/kpxc-run bin/kpxc-secret libexec/kpxc-keepassxc libexec/shims/xdg-open
PYTHON_SCRIPTS := bin/kpxc-secret-service libexec/kpxc-lock-relay
UNITS          := $(wildcard units/*)

.PHONY: all install check lint test sources srpm rpm repo clean build-deps repo-deps test-deps require-root require-mock

all:

install:
	install -Dm0755 -t $(DESTDIR)$(bindir) bin/kpxc-secret-service bin/kpxc-secret bin/kpxc-run
	install -Dm0755 -t $(DESTDIR)$(libexecdir) libexec/kpxc-keepassxc libexec/kpxc-lock-relay
	install -Dm0755 -t $(DESTDIR)$(libexecdir)/shims libexec/shims/xdg-open
	install -Dm0644 -t $(DESTDIR)$(datadir) data/kpxc-bus.conf
	install -Dm0644 -t $(DESTDIR)$(datadir)/dbus-1/services data/dbus-1/services/org.freedesktop.secrets.service
	install -Dm0644 -t $(DESTDIR)$(userunitdir) $(UNITS)
	install -Dm0644 -t $(DESTDIR)$(userpresetdir) data/80-$(NAME).preset
	install -dm0755 $(DESTDIR)$(sysconfdir)/users.d

# Syntax checks; run from the RPM's %check.
check:
	for f in $(SHELL_SCRIPTS); do sh -n $$f || exit 1; done
	for f in $(PYTHON_SCRIPTS); do python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' $$f || exit 1; done

# Needs shellcheck and systemd-analyze; verify expects the files installed
# (the units name absolute paths), e.g. in a scratch VM after `sudo make install`.
lint: check
	shellcheck $(SHELL_SCRIPTS)
	XDG_RUNTIME_DIR=$${XDG_RUNTIME_DIR:-$$(mktemp -d)} systemd-analyze --user --man=no verify $(UNITS)

# End-to-end test of the bus plumbing, KeePassXC and the lock relay in a
# throwaway D-Bus environment (needs dbus-daemon, dbus-broker, keepassxc,
# secret-tool and python3-gobject; see tests/smoke-test.sh).
test:
	tests/smoke-test.sh

# Sources for the SRPM: a clone of HEAD plus the release tarball. The clone
# carries the git history, from which rpmautospec fills in %autorelease and
# %autochangelog (see the rpmautospec plugin in $(MOCK) below).
SRCDIR := build/sources

sources:
	@git diff --quiet HEAD -- || echo "warning: uncommitted changes are not part of the build" >&2
	rm -rf $(SRCDIR)
	git clone --quiet . $(SRCDIR)
	version=$$(sed -n 's/^Version:[[:space:]]*//p' $(SRCDIR)/$(NAME).spec) && \
	    git -C $(SRCDIR) archive --prefix=$(NAME)-$$version/ --output=$(NAME)-$$version.tar.gz HEAD

# Packages are built with mock in a clean chroot. MOCK_CHROOT is a mock
# config such as fedora-44-x86_64; "default" follows the host's release.
# Extra mock options, e.g. MOCK_OPTS="--define 'kpxc_users alice'".
MOCK_CHROOT ?= default
MOCK_OPTS   ?=
RESULTDIR   ?= results/$(MOCK_CHROOT)
MOCK         = mock -r $(MOCK_CHROOT) --resultdir $(RESULTDIR) --enable-plugin=rpmautospec $(MOCK_OPTS)

srpm: require-mock sources
	rm -f $(RESULTDIR)/*.rpm
	$(MOCK) --buildsrpm --spec $(SRCDIR)/$(NAME).spec --sources $(SRCDIR)

rpm: srpm
	$(MOCK) --rebuild $(RESULTDIR)/$(NAME)-*.src.rpm

# Signed dnf repository of the packages from `make rpm`, in REPODIR, to be
# served at REPO_URL. GPG_KEY selects the signing key (fingerprint, key ID or
# e-mail); GPG_PASSPHRASE_FILE optionally holds its passphrase.
REPODIR             ?= build/repo
REPO_URL            ?= https://dennisklein.github.io/kpxc-secret-service
GPG_KEY             ?=
GPG_PASSPHRASE_FILE ?=
GPG_ARGS = --batch --yes $(if $(GPG_PASSPHRASE_FILE),--pinentry-mode loopback --passphrase-file $(GPG_PASSPHRASE_FILE))

repo:
	@[ -n "$(GPG_KEY)" ] || { echo "Set GPG_KEY to the signing key, e.g. make repo GPG_KEY=you@example.org" >&2; exit 1; }
	@ls $(RESULTDIR)/*.rpm 2>/dev/null | grep -qv '\.src\.rpm$$' || { echo "No packages in $(RESULTDIR); run make rpm first" >&2; exit 1; }
	rm -rf $(REPODIR)
	mkdir -p $(REPODIR)
	find $(RESULTDIR) -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm' -exec cp -t $(REPODIR) {} +
	rpmsign --define '_gpg_name $(GPG_KEY)' --define '_gpg_sign_cmd_extra_args $(GPG_ARGS)' \
	    --addsign $(REPODIR)/*.rpm
	createrepo_c --quiet $(REPODIR)
	gpg $(GPG_ARGS) --local-user '$(GPG_KEY)' --armor --detach-sign $(REPODIR)/repodata/repomd.xml
	gpg --armor --export '$(GPG_KEY)' > $(REPODIR)/RPM-GPG-KEY-$(NAME)
	printf '%s\n' '[$(NAME)]' 'name=$(NAME)' 'baseurl=$(REPO_URL)' 'enabled=1' \
	    'gpgcheck=1' 'repo_gpgcheck=1' 'gpgkey=$(REPO_URL)/RPM-GPG-KEY-$(NAME)' \
	    > $(REPODIR)/$(NAME).repo

require-mock:
	@command -v mock >/dev/null || { echo "mock is not installed; run: sudo make build-deps" >&2; exit 1; }

# Host packages. These targets must be run as root by the user, e.g.
# `sudo make build-deps`; the Makefile itself never calls sudo.
BUILD_DEPS := mock mock-rpmautospec git-core
REPO_DEPS  := createrepo_c rpm-sign gnupg2
TEST_DEPS  := ShellCheck systemd glib2 dbus-daemon dbus-broker keepassxc libsecret \
              desktop-file-utils python3-gobject-base 'python3dist(pykeepass)'

# For `make rpm` and `make srpm`. Also adds the invoking user to the mock
# group, which mock requires; note that membership is root-equivalent (mock(1)).
build-deps: require-root
	dnf install -y $(BUILD_DEPS)
	@if [ -n "$${SUDO_USER-}" ] && [ "$$SUDO_USER" != root ] && \
	    ! id -nG "$$SUDO_USER" | grep -qw mock; then \
	    usermod -a -G mock "$$SUDO_USER" && \
	    echo "Added $$SUDO_USER to the mock group; log in again (or run 'newgrp mock') before 'make rpm'."; \
	fi

# For `make repo`.
repo-deps: require-root
	dnf install -y $(REPO_DEPS)

# For `make lint` and `make test`.
test-deps: require-root
	dnf install -y $(TEST_DEPS)

require-root:
	@if [ "$$(id -u)" -ne 0 ]; then \
	    echo "This installs packages, run it as root: sudo make $(MAKECMDGOALS)" >&2; exit 1; \
	fi

clean:
	rm -rf build results
