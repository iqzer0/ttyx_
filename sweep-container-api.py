#!/usr/bin/env python3
"""Compiler-driven container-API sweep.

GTK4 replaced GtkContainer.add with type-specific methods, so the correct
replacement depends on the receiver's type — which cannot be inferred from a
variable name. But the compiler reports it:

    no property `add` for `box` of type `gtk.box.Box`

so drive the rewrite off that instead of guessing. Converges because each pass
lets modules compile further and reveal more.
"""
import re, subprocess, sys, collections, glob

# type -> replacement method for `add`
ADD_MAP = {
    'gtk.box.Box': 'append',
    'gtk.list_box.ListBox': 'append',
    'gtk.stack.Stack': 'addChild',
}
# bare `add(` inside a subclass: resolve from the enclosing `class X : Base`
BASE_MAP = {
    'Box': 'append', 'ListBox': 'append',
    'ApplicationWindow': 'setChild', 'Window': 'setChild', 'Revealer': 'setChild',
    'Frame': 'setChild', 'ScrolledWindow': 'setChild', 'Popover': 'setChild',
    'Overlay': 'setChild', 'ListBoxRow': 'setChild', 'Stack': 'addChild',
}
# anything Bin-like takes a single child
SETCHILD_TYPES = {
    'gtk.scrolled_window.ScrolledWindow', 'gtk.frame.Frame', 'gtk.revealer.Revealer',
    'gtk.menu_button.MenuButton', 'gtk.window.Window', 'gtk.overlay.Overlay',
    'gtk.viewport.Viewport', 'gtk.expander.Expander', 'gtk.button.Button',
    'gtk.toggle_button.ToggleButton', 'gtk.check_button.CheckButton',
    'gtk.event_box.EventBox', 'gtk.aspect_frame.AspectFrame',
    'gtk.popover.Popover', 'gtk.application_window.ApplicationWindow',
    'gtk.list_box_row.ListBoxRow',
}

ERR = re.compile(r'^(?P<file>source/[^(]+)\((?P<line>\d+)\): Error: no property `(?P<meth>add)` for `(?P<recv>[^`]+)` of type `(?P<type>[^`]+)`')
BARE = re.compile(r'^(?P<file>source/[^(]+)\((?P<line>\d+)\): Error: undefined identifier `add`$')

CLASS_DECL = re.compile(r'^\s*(?:final\s+|abstract\s+)?class\s+(\w+)\s*:\s*([\w.]+)')

def enclosing_class(lines, i):
    """Nearest preceding `class Name : Base` -> (Name, Base) or (None, None)."""
    for j in range(i, -1, -1):
        m = CLASS_DECL.match(lines[j])
        if m: return m.group(1), m.group(2).split('.')[-1]
    return None, None

def declared_base(name):
    """Find `class name : Base` anywhere in source/ -> Base (last segment) or None."""
    for p in glob.glob('source/**/*.d', recursive=True):
        for l in open(p):
            m = CLASS_DECL.match(l)
            if m and m.group(1) == name: return m.group(2).split('.')[-1]
    return None

def resolve_base(base):
    """Walk project-local bases (ProfilePage -> Box) until a mapped GTK one."""
    for _ in range(6):
        if base is None or base in BASE_MAP: return base
        base = declared_base(base)
    return None

def base_of_gx_type(ty):
    """A `gx.*` receiver type (e.g. `this` inside a page): its nearest mapped base."""
    return resolve_base(declared_base(ty.split('.')[-1]))

def failing_files():
    out = subprocess.run(['./typecheck-gtk4.sh','--all'], capture_output=True, text=True, timeout=3000).stdout
    return [l.split()[1] for l in out.splitlines() if l.strip().startswith('FAIL')]

def errors_for(f):
    out = subprocess.run(['./typecheck-gtk4.sh', f], capture_output=True, text=True, timeout=300).stdout
    res = []
    for l in out.splitlines():
        if (m := ERR.match(l.strip())): res.append(m.groupdict())
        elif (m := BARE.match(l.strip())): res.append({**m.groupdict(), 'type': None})
    return res

total = collections.Counter()
for it in range(6):
    edits = collections.defaultdict(list)   # file -> [(line, type)]
    for f in (sys.argv[1:] or failing_files()):
        for e in errors_for(f):
            edits[e['file']].append((int(e['line']), e['type']))
    if not edits:
        print(f"iteration {it}: no `.add` errors left"); break
    n = 0
    for f, sites in edits.items():
        lines = open(f).read().split('\n')
        for ln, ty in sites:
            i = ln - 1
            if i >= len(lines):
                continue
            if ty is None:
                # bare `add(...)` — must be a statement-leading call
                if not re.match(r'\s*add\(', lines[i]):
                    continue
                cls, base = enclosing_class(lines, i)
                base = resolve_base(base)
                if base not in BASE_MAP:
                    print(f"  UNMAPPED bare add in class {cls} : {base} at {f}:{ln} — skipping"); continue
                repl = BASE_MAP[base]
                print(f"  bare add  {f}:{ln}  {cls} : {base}  -> {repl}")
                lines[i] = re.sub(r'^(\s*)add\(', rf'\1{repl}(', lines[i], count=1)
                n += 1; total[f'bare:{base}'] += 1
                continue
            if '.add(' not in lines[i]:
                continue
            if ty in ADD_MAP:
                repl = ADD_MAP[ty]
            elif ty in SETCHILD_TYPES:
                repl = 'setChild'
            elif ty.startswith('gx.') and (b := base_of_gx_type(ty)) in BASE_MAP:
                repl = BASE_MAP[b]
                print(f"  gx type   {f}:{ln}  {ty} : {b}  -> {repl}")
            else:
                print(f"  UNMAPPED type {ty} at {f}:{ln} — skipping"); continue
            lines[i] = lines[i].replace('.add(', f'.{repl}(', 1)
            n += 1; total[ty] += 1
        open(f, 'w').write('\n'.join(lines))
    print(f"iteration {it}: rewrote {n} site(s)")
    if n == 0:
        break

print("\ntotals by type:")
for t, c in total.most_common():
    print(f"  {c:3}  {t}")
