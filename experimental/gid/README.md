# giD migration skeleton

The buildable seed for the ROADMAP Phase 2 migration off GtkD onto
[giD](https://github.com/Kymorphia/gid). It is a minimal GTK3 window with an
embedded VTE terminal, built entirely on giD (`gid:gtk3` + `gid:vte2`).

**This is not part of the ttyx_ build.** It exists so the migration has a known-
good, compiling starting point, and so the giD API idioms are captured in real
code. The full plan and the reason the migration must be wholesale (giD and
GtkD cannot coexist in one build) are in [`docs/gid-migration.md`](../../docs/gid-migration.md).

## Build & run

Needs a D compiler with `dub` (LDC recommended) and the GTK 3 + VTE 2.91
runtime libraries installed. giD compiles its bindings from source on first
build, so expect a few minutes the first time.

```bash
cd experimental/gid
dub run --compiler=ldc2
```

A window titled "ttyx_ giD skeleton" opens with a VTE terminal inside it.

## Notes

- `gid:vte2` is VTE for **GTK3** (libvte-2.91). `gid:vte3` is VTE for GTK4 — do
  not confuse them.
- giD version is pinned (`0.9.13`) because giD is pre-1.0 and its API can shift.
- giD's **GTK4** bindings did not compile at this pin (an accessibility-binding
  bug); that only matters for the later GTK3→GTK4 step, not this GTK3 seed.
