# ttyx_ Roadmap

## Vision

A security-focused tiling terminal emulator for Linux/GNOME. Competes with GNOME Terminal and Ptyxis. Differentiators: **tiling** and **security hardening**.

## Completed

### Security hardening (#27)
- [x] In-memory-only scrollback with clamped limits (#23)
- [x] Core dump protection via `prctl(PR_SET_DUMPABLE)` (#23)
- [x] Secure Clear action with Ctrl+Shift+L (#23)
- [x] SSH session detection indicator (#22)
- [x] Clipboard auto-clear after configurable timeout (#39)
- [x] Bracketed paste escape sequence stripping (#42)
- [x] Multi-line paste review dialog (#42)
- [x] Expanded dangerous command detection — sudo, su, doas, rm -rf, curl|bash, dd, mkfs, fork bombs (#42)
- [x] Per-paste unsafe warning (no permanent dismissal) (#42)

### Performance
- [x] ProcessMonitor: targeted foreground process lookup instead of full /proc scan — idle CPU 1.4% → 0.1% (#41)

### Architecture
- [x] Decompose terminal.d — PreferenceRegistry, extracted ClipboardHandler, TerminalRenderer, ProcessQuery, SpawnHandler, FlatpakHostCommands (#32)

## Phase 1: Remaining security items

### Deferred (low priority or blocked)
- [ ] Security event system / audit logging — deferred to potential sectty fork
- [ ] Session lock (password to reveal scrollback after idle) — larger feature
- [ ] Secure erase on session close — minimal practical value with current protections
- [ ] OSC 52 clipboard hijacking — already blocked by VTE (not implemented)

## Phase 2: GTK4 migration

**This is the critical path for long-term viability.** Spiked July 2026 —
full plan and findings in [docs/gid-migration.md](docs/gid-migration.md); a
buildable giD seed lives in [experimental/gid/](experimental/gid/).

**Spike outcome:** giD is viable and covers the whole stack (`gid:gtk3`,
`gid:vte2` = VTE-for-GTK3, libsecret, xlib). A GTK3 window + VTE terminal
compiles and links on giD. **But giD and GtkD cannot coexist in one build**
(they share the `gtk`/`glib`/`gio`/`gobject`/… package names), so a
half-migrated codebase does not compile — the migration is a **wholesale swap**,
not incremental. Approach: a parallel giD rewrite that grows to parity (reusing
the GtkD-free logic unchanged), then a single build swap.

### Phase 2a — GtkD → giD, staying on GTK3
- [ ] Grow `experimental/gid/` into a giD-based ttyx_ (own build target, always compiles)
- [ ] Port the widget layer (app → window → session → terminal → prefs) to `gid:gtk3` + `gid:vte2`
- [ ] Reuse `gx/util/*` and pure logic unchanged; collapse `exvte.d` into native giD VTE calls
- [ ] Optionally drop vendored `secret/`/`x11/` for giD libsecret/xlib
- [ ] Swap the main dub/meson build over, delete GtkD, ship

### Phase 2b — GTK3 → GTK4 + libadwaita
- [ ] Dependency swap to `gid:gtk4` / `gid:vte3` / `gid:adw1` + API-delta pass (`add`→`setChild`, `showAll`→`present`, event/controller model)
- [ ] Adopt libadwaita for modern GNOME look and feel
- [ ] **Blocker:** giD's GTK4 bindings did not compile at v0.9.13 (accessibility binding bug) — pin a known-good release or fix upstream before starting

### Why this matters
- GTK3 is EOL — no new features, limited bug fixes
- Both competitors (GNOME Terminal, Ptyxis) are on GTK4/libadwaita
- GtkD (current D bindings) is unmaintained and will never support GTK4
- giD is the sustainable path forward

## Phase 3: Container integration (#24)

- [ ] Auto-discover Podman/Toolbox/Distrobox containers
- [ ] Spawn terminal sessions directly into containers
- [ ] Container indicator in terminal title bar (like SSH/root indicators)
- [ ] Per-container profile switching

## Phase 4: Session recording (#25)

- [ ] Capture terminal input/output for audit trail
- [ ] Session replay capability
- [ ] Structured logging for compliance

## Future: sectty fork

A potential security-hardened fork for enterprise/compliance use cases:

- Security event system with centralized audit logging
- Mandatory paste review (no opt-out)
- syslog/journald integration
- Session recording with tamper-proof logging
- Per-host security profiles
- Compliance templates (PCI-DSS, SOC2)
- Centralized policy management

### VTE fork assessment
- VTE's escape handling is centralized in `vteseq.cc` (~10k LOC) — shallow fork feasible
- VTE already blocks OSC 52 (clipboard hijack) by not implementing it
- App-layer protection (current approach) is sufficient for most security features
- Fork only if we hit a wall that VTE signals can't solve
- Contribute patches upstream first — propose filtering API to GNOME

### D language assessment
- D is viable for the current roadmap
- Gaps: no security audit tooling (like cargo-audit), no FIPS crypto, smaller community
- Not blocking for planned features — security logic is application-layer glue
- Real risk: GtkD maintenance (solved by giD migration)
- Rewrite consideration only if sectty needs security certification or terminal emulation ownership

## Competitive positioning

| Feature | GNOME Terminal | Ptyxis | ttyx_ |
|---------|---------------|--------|-------|
| Tiling | No | No | **Yes** |
| Security hardening | No | Some (VTE improvements) | **Comprehensive** |
| Container-aware | No | **Yes** (first-class) | Planned |
| GTK version | GTK4 | GTK4 | GTK3 (migration planned) |
| Maintained by | GNOME team | Christian Hergert | Community |

**ttyx_ wins on:** tiling + security, for sysadmins who SSH into production all day and want their terminal to actively protect them.

**Ptyxis wins on:** GNOME integration, container support, modern stack. But Hergert maintains 5+ major GNOME projects — focused effort on ttyx_ can outpace Ptyxis on specific features.
