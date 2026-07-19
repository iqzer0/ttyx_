---
title: Install
layout: default
nav_order: 2
permalink: /install/
---

# Install

ttyx_ installs from source: build with Dub, install with the bundled
`install.sh`. Releases are GPG-signed git tags — verify with
`git verify-tag vX.Y.Z` (or check the signed checksums attached to the
[latest release](https://github.com/gwelr/ttyx_/releases/latest)).

---

## Source build

### Requirements

- GTK 3.18+
- VTE 0.46+ (0.76+ recommended — some features like triggers depend on newer VTE releases)
- dconf / GSettings
- A D compiler (LDC recommended for release builds, DMD also supported)

### Building with Dub (the build system)

ttyx_ builds with [Dub](https://dub.pm/) against the [giD](https://github.com/Kymorphia/gid)
GObject-Introspection bindings (`gid:gtk3`, `gid:vte2`, `gid:secret1`). giD is a
source-only Dub package compiled into the binary, so — unlike the old GtkD
bindings — nothing D-specific needs to be installed system-wide. (The Meson
build was retired together with GtkD.)

**Debian / Ubuntu build dependencies:**

```bash
sudo apt-get install libgtk-3-dev libvte-2.91-dev libatk1.0-dev \
  libcairo2-dev libpango1.0-dev librsvg2-dev libglib2.0-dev \
  libsecret-1-dev
```

**Build, test, install:**

```bash
dub build --build=release --compiler=ldc2

# Unit tests:
dub test --compiler=ldc2

# Install (binary + schemas, gresource, icons, translations, man page):
sudo ./install.sh
```

**Offline / vendored builds** (distro packaging, sandboxed builds): download
the giD package archive from
`https://code.dlang.org/packages/gid/0.9.13.zip`, then:

```bash
unzip gid-0.9.13.zip
export DUB_HOME=$PWD/.dub
dub add-local gid-0.9.13 0.9.13
dub build --build=release --compiler=ldc2 --skip-registry=all
```

---

## First launch

On first run:

- If you previously used Tilix, ttyx_ [automatically migrates]({{ site.baseurl }}/migrating/) your session files and reads existing saved passwords.
- The terminal opens with the default profile. Preferences live under **Hamburger menu → Preferences** (or `Ctrl+,`).
- Security options are consolidated under **Preferences → Advanced → Security**.

---

## Troubleshooting

### App icon shows as a broken placeholder

Typically a stale icon cache from a previous install. Refresh the icon cache for your install prefix and let GTK regenerate it:

```bash
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor/
```

Then relaunch ttyx_.

### Quake mode doesn't position correctly on Wayland

See the [Wayland section on the Quake manual page]({{ site.baseurl }}/manual/quake/#wayland) for compositor-specific notes and workarounds.
