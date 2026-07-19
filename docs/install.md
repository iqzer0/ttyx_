---
title: Install
layout: default
nav_order: 2
permalink: /install/
---

# Install

Two install paths depending on who you are:

| If you are… | Use this |
|--------------|------------|
| An end user who wants to run ttyx_ | [Flatpak](#flatpak-recommended) — signed bundle with checksum verification |
| A distro packager, or a developer building from source | [Source build](#source-build) via Dub |

---

## Flatpak (recommended)

Flatpak is the supported direct-user distribution channel. Each release ships a signed `.flatpak` bundle and a detached GPG signature over the SHA-256 checksums, so you can verify integrity end-to-end.

### 1. Download the latest release

Grab `ttyx-<version>_x86_64.flatpak` and `ttyx-<version>_SHA256SUMS.asc` from the [latest release](https://github.com/gwelr/ttyx_/releases/latest).

### 2. Verify the bundle

```bash
# Verify the signature on the checksum file
gpg --verify ttyx-<version>_SHA256SUMS.asc

# Verify the bundle's checksum matches
sha256sum -c ttyx-<version>_SHA256SUMS.asc 2>/dev/null
```

Both commands must exit with success before installing.

### 3. Install

```bash
flatpak install --user ttyx-<version>_x86_64.flatpak
```

### 4. Run

Launch from your desktop environment's application menu, or run:

```bash
flatpak run io.github.gwelr.ttyx
```

---

## Source build

For distro packagers, Flatpak maintainers, or developers.

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

The Flatpak manifest at `flatpak/io.github.gwelr.ttyx.yaml` uses exactly this
recipe.

---

## First launch

On first run:

- If you previously used Tilix, ttyx_ [automatically migrates]({{ site.baseurl }}/migrating/) your session files and reads existing saved passwords.
- The terminal opens with the default profile. Preferences live under **Hamburger menu → Preferences** (or `Ctrl+,`).
- Security options are consolidated under **Preferences → Advanced → Security**.

---

## Troubleshooting

### App icon shows as a broken placeholder

Typically a stale icon cache from a previous install. Clear the user-level cache and let GTK regenerate it:

```bash
rm -f ~/.local/share/flatpak/exports/share/icons/hicolor/icon-theme.cache
gtk-update-icon-cache -f ~/.local/share/flatpak/exports/share/icons/hicolor/
```

Then relaunch ttyx_.

### Quake mode doesn't position correctly on Wayland

See the [Wayland section on the Quake manual page]({{ site.baseurl }}/manual/quake/#wayland) for compositor-specific notes and workarounds.
