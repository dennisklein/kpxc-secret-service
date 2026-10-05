# Repository configuration package, like fedora-repos or epel-release. Built
# by `make release-rpm` (which defines pkg_version and provides the sources)
# when the packages are published.
%{!?pkg_version:%{error:build with `make release-rpm`, which defines pkg_version}}

Name:           kpxc-secret-service-release
Version:        %{pkg_version}
Release:        1
Summary:        dnf repository configuration for kpxc-secret-service

License:        MIT
URL:            https://github.com/dennisklein/kpxc-secret-service
Source0:        kpxc-secret-service.repo
Source1:        RPM-GPG-KEY-kpxc-secret-service
Source2:        LICENSE

BuildArch:      noarch

%description
Adds the signed dnf repository of kpxc-secret-service and the public key its
packages and metadata are signed with. Install kpxc-secret-service from it
with `dnf install kpxc-secret-service`; updates, including to this package,
come with `dnf upgrade`.

%prep
cp -p %{SOURCE2} .

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_sysconfdir}/yum.repos.d/kpxc-secret-service.repo
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-kpxc-secret-service

%files
%license LICENSE
%config(noreplace) %{_sysconfdir}/yum.repos.d/kpxc-secret-service.repo
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-kpxc-secret-service
