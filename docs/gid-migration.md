---
title: giD Migration Plan
layout: default
nav_order: 8
permalink: /gid-migration/
---

# giD / GTK4 migration plan
{: .no_toc }

Planning record for ROADMAP Phase 2 — moving off the unmaintained GtkD bindings.
Written after a spike in July 2026. This is a **decision-of-record**, not a
step-by-step guide; it captures what was validated, the constraints that shape
the work, and the approach.

1. TOC
{:toc}

## Summary

**giD is a viable replacement for GtkD and covers ttyx_'s entire stack, but the
migration must be a wholesale swap — it cannot be done incrementally with both
bindings present.** The spike proved a GTK3 window with an embedded VTE terminal
compiles and links under giD on a real machine; it also proved that adding giD
alongside GtkD breaks the build, because the two bindings share the same D
package names and cannot occupy one compiler import path.

## What giD is

[giD](https://github.com/Kymorphia/gid) ("giddy", DUB package `gid`, currently
v0.9.x, pre-1.0, actively developed) generates D bindings from GObject
Introspection (GIR) XML via the `gidgen` tool. It is the intended successor to
GtkD, which is unmaintained and will never support GTK4.

giD ships DUB sub-packages for exactly ttyx_'s dependencies:

| ttyx_ needs | giD sub-package | Notes |
|-------------|-----------------|-------|
| GTK 3 | `gid:gtk3` | |
| VTE for GTK 3 (libvte-2.91) | **`gid:vte2`** | ⚠️ `gid:vte3` is VTE-for-**GTK4** — counterintuitive |
| libsecret | `gid:secret1` (approx.) | can replace the vendored `source/secret/` |
| Xlib | `gid:xlib2` | a path for the vendored `source/x11/` |
| Future: GTK4 / libadwaita / VTE-GTK4 | `gid:gtk4`, `gid:adw1`, `gid:vte3` | Phase 2b |

## The load-bearing constraint: no coexistence

GtkD and giD both define modules under the top-level packages `gtk`, `glib`,
`gio`, `gobject`, `gdk`, `pango`, `cairo`, and `vte`. Each binding compiles
perfectly **in isolation**, but any single `dub` build graph that contains both
merges their import paths, the package names collide, and the build fails.

Validated three ways during the spike:

- Adding `gid:gtk3` + `gid:vte2` to ttyx_'s `dub.json` alongside `gtk-d` → 20
  compile errors **inside GtkD's own generated code** (`undefined identifier
  ConnectFlags` / `GdkPixdata`).
- Splitting them into two isolated library sub-packages under one root project →
  still failed, symmetrically (giD's `glib2` broke, GtkD's `glib` shadowing it).
- Building either sub-package **alone** → succeeds.

`dub` has no option to stop transitive import-path merging. Regenerating giD
under a custom package prefix (e.g. `gid.gtk.*`) via `gidgen` is not practically
available — giD's module namespaces are derived from the GObject namespace
names, with no prefix option.

**Consequence: a half-migrated codebase does not build.** File-by-file migration
with both bindings linked is impossible.

## Approach: parallel rewrite to parity

Because the codebase cannot be half-migrated, the migration is a **parallel giD
rewrite that grows to feature parity**, then a single build swap:

1. Grow the giD skeleton (see `experimental/gid/`) into a giD-based ttyx_,
   building it as its own target so it always compiles.
2. Port the widget layer into it in dependency order (app → window → session →
   terminal → dialogs/preferences), translating GtkD API calls to giD.
3. Reuse the binding-agnostic code **unchanged** — `source/gx/util/*` (geometry,
   string, redact, proc, array, path) and the pure logic they host (session
   snapshot, regex-token substitution, redaction, dangerous-command detection)
   have no GtkD imports and carry over as-is.
4. When the giD build reaches parity and the test suite passes, swap the main
   build (`dub.json` + `meson.build`) over to giD and delete the GtkD code.

Do this **on GTK3 first** (`gid:gtk3` + `gid:vte2`), isolating the binding swap
from the toolkit-version change. GTK3→GTK4 (Phase 2b) is then a dependency swap
(`gid:gtk4`/`gid:vte3`/`gid:adw1`) plus an API-delta pass.

### Migration surface

- **~48 files** import GtkD (~681 import lines).
- **14 of those** use low-level `gtkc.*` C bindings — the trickiest. One,
  `source/gx/ttyx/terminal/exvte.d`, exists only to hand-write VTE C bindings
  (`vte_terminal_paste_text`, disable-background-draw) that `gid:vte2` provides
  natively — so it largely disappears.
- The vendored `source/secret/` (10 files) and `source/x11/` (2 files) have giD
  equivalents and can be dropped.

### API differences (GtkD → giD)

| | GtkD | giD |
|---|---|---|
| Module | `gtk.Application` | `gtk.application` (snake_case) |
| Signals | `addOnActivate(&cb)` | `connectActivate(&cb)` |
| Add child (GTK3) | `add(w)` | `add(w)` (GTK4: `setChild`) |
| App flags | `GApplicationFlags` | `gio.types : ApplicationFlags` |
| Memory | manual-ish | toggle references + GC |

giD is more D-idiomatic, but the translation is per-file, not mechanical.

## Risks

- **giD is pre-1.0** — API can shift between releases; pin the version.
- **giD's GTK4 bindings currently do not compile** here (v0.9.13:
  `undefined identifier AccessiblePlatformState` in `gtk4/accessible_mixin.d`).
  Irrelevant to the GTK3-first phase, but a blocker for Phase 2b — pin a
  known-good giD release or report upstream before starting GTK4.
- **Single maintainer** — same bus-factor shape as GtkD, but giD is *actively*
  developed (GtkD is not).
- **Wholesale swap** — no user-visible progress and no shippable state until the
  giD build reaches parity. Scope it deliberately.

## Status

- ✅ Spike done: giD viable, stack covered, coexistence ruled out.
- ✅ Buildable skeleton committed at `experimental/gid/` (GTK3 window + VTE
  terminal, compiles and links).
- ⏳ Not started: the parallel rewrite.

## Building the skeleton

See `experimental/gid/README.md`. In short: `cd experimental/gid && dub run`
(needs a D compiler with `dub`, and GTK3 + VTE 2.91 runtime libraries).
