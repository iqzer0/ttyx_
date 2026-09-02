#!/usr/bin/env python3
"""GTK4 sweep: GtkReliefStyle and GtkShadowType are gone.

  x.setRelief(ReliefStyle.None)          -> x.setHasFrame(false)
  x.setRelief(ReliefStyle.Normal)        -> x.setHasFrame(true)
  x.setShadowType(ShadowType.None)       -> (deleted; no shadow is the only GTK4 state)
  x.setShadowType(ShadowType.<other>)    -> x.setHasFrame(true)

The last rule is right for ScrolledWindow and wrong for Frame/Viewport/
AspectFrame, which have no has-frame property in GTK4 (their border is pure
CSS). Those cannot be told apart from the receiver name, so this pass converts
them all and lets the compiler report "no property setHasFrame" on the
Frame-likes; a second pass deletes those lines. Deterministic and loud, rather
than guessing types from variable names.

The enum tokens are then removed from `gtk.types` import lists, preserving line
wrapping. Prints the four formatting assertions the IconSize sweep taught us to
check: long lines added, blank lines removed, comma-space joins, live uses left.
"""
import re, glob, subprocess

def live_uses(txt, tok):
    # Strip every import statement first — including wrapped multi-line ones,
    # whose continuation lines do not start with "import" and were previously
    # miscounted as live uses, which made this pass refuse to remove the token.
    txt = re.sub(r'^import\b[^;]*;', '', txt, flags=re.M | re.S)
    return sum(l.count(tok) for l in txt.splitlines()
               if not l.strip().startswith(('*','//','/*')))

changed = 0
for p in glob.glob('source/**/*.d', recursive=True):
    orig = open(p).read(); s = orig
    s = re.sub(r'\.setRelief\(\s*ReliefStyle\.None\s*\)', '.setHasFrame(false)', s)
    s = re.sub(r'\.setRelief\(\s*ReliefStyle\.\w+\s*\)', '.setHasFrame(true)', s)
    # ShadowType.None: drop the whole statement line
    s = re.sub(r'^[ \t]*\w+(?:\.\w+)*\.setShadowType\(\s*ShadowType\.None\s*\);[ \t]*\n', '', s, flags=re.M)
    s = re.sub(r'\.setShadowType\(\s*ShadowType\.\w+\s*\)', '.setHasFrame(true)', s)
    if s == orig:
        continue
    for tok in ('ReliefStyle', 'ShadowType'):
        if live_uses(s, tok) == 0:
            def drop(m, tok=tok):
                body = m.group(2)
                body = re.sub(r'\b'+tok+r'\s*,[ \t]*(\r?\n)', r'\1', body)
                body = re.sub(r'\b'+tok+r'\s*,[ \t]*', '', body)
                body = re.sub(r',[ \t]*\b'+tok+r'\b', '', body)
                return f'{m.group(1)}{body};'
            s = re.sub(r'(import\s+gtk\.types\s*:\s*)([^;]+);', drop, s)
    open(p,'w').write(s); changed += 1
print(f"files changed: {changed}")
