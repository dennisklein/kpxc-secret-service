NAME    := kpxc-secret-service
VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' $(NAME).spec)
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

.PHONY: all install check lint test dist rpm srpm clean

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

dist: $(NAME)-$(VERSION).tar.gz

$(NAME)-$(VERSION).tar.gz: $(shell git ls-files 2>/dev/null)
	git ls-files | tar --transform 's,^,$(NAME)-$(VERSION)/,' -czf $@ -T -

# Extra rpmbuild options, e.g. RPMBUILD_OPTS="--define 'kpxc_users alice'".
RPMBUILD_OPTS ?=
RPMBUILD = rpmbuild --define "_sourcedir $(CURDIR)" --define "_srcrpmdir $(CURDIR)" \
                    --define "_rpmdir $(CURDIR)/rpms" $(RPMBUILD_OPTS)

rpm: dist
	$(RPMBUILD) -bb $(NAME).spec

srpm: dist
	$(RPMBUILD) -bs $(NAME).spec

clean:
	rm -rf $(NAME)-*.tar.gz *.src.rpm rpms
