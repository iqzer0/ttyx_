# `terminal.d` decomposition — proposal

**Status:** proposal, nothing extracted yet. Written 2026-09-01 against
`terminal.d` at 3,944 lines.

## The current state, honestly

The ROADMAP lists *"Decompose terminal.d — PreferenceRegistry, extracted
ClipboardHandler, TerminalRenderer, ProcessQuery, SpawnHandler,
FlatpakHostCommands (#32)"* as complete under **Architecture**. That work was
real and those modules exist. But `terminal.d` is still **3,944 lines and one
class** (`Terminal : EventBox, ITerminal, ITerminalContext, ISyncInputEmitter`)
with **123 member functions** — the largest file in the repository by a wide
margin. Marking the item done while the God class remains sets up the next
person to trust a description the code does not support. It should be reopened.

## The clusters

Five cohesive groups account for most of the file:

| Cluster | Approx. span | Lines |
|---|---|---:|
| UI construction (`createUI`, title pane, actions, popovers, menus) | 405–1000 | ~595 |
| Drag and drop (`setupDragAndDrop`, `onVTEDrag*`, quadrant logic) | 2852–3173 | ~321 |
| URL / hyperlink matching and opening (`updateMatch`, `openURI`, `regexTag`) | 1980–2250 | ~270 |
| Triggers (`onVTECheckTriggers`, `processTrigger`, template substitution) | 1691–1855 | ~164 |
| Title / badge / display text (`updateTitle`, `updateBadge`, `replaceVariables`) | 1387–1530 | ~143 |

## The finding that decides the sequencing

The obvious move is "extract all five." That would be a mistake right now,
because Phase 2b is about to rewrite some of these clusters anyway. Measuring
the overlap — counting lines in each cluster that WP2/WP4/WP6 touch
(`connectGdkEvent`, `connectDraw`, `.run()`, `EventBox`, drag APIs, `.add(`,
`packStart`, `Clipboard`) — separates them cleanly:

| Cluster | Lines | GTK4-affected | Verdict |
|---|---:|---:|---|
| Drag and drop | 321 | **35** | defer — GTK4 rewrites DnD wholesale |
| UI construction | 595 | **30** | defer — container/`showAll` churn |
| URL match + open | 270 | 3 | **extract now** |
| Title / badge / display | 143 | 1 | **extract now** |
| Triggers | 164 | **0** | **extract now** |

**Recommendation: extract the three GTK4-independent clusters now (~577 lines,
essentially zero overlap with the migration), and leave drag-and-drop and UI
construction alone until Phase 2b rewrites them.**

Extracting the entangled clusters first would mean refactoring ~900 lines that
WP2/WP4/WP6 immediately churn again — two large diffs over the same lines,
doubled review, and merge pain for no benefit. Conversely the other three are
nearly untouched by GTK4, so extracting them now is free of conflict risk *and*
makes the migration easier by shrinking the file the porter has to hold in their
head.

## Proposed modules

Each follows the pattern the existing extractions established: constructor takes
`ITerminalContext` plus the callbacks it needs, so the logic is reachable
without a live widget tree.

### `terminal/triggers.d` (~164 lines) — do this one first

`onVTECheckTriggers`, `processTrigger`, `shellCommandFromTemplate` and the
`triggers[]` state. The best candidate of the three:

- **Zero GTK4 overlap.** Nothing here moves in the port.
- **It is the security-critical shell-exec path** — `EXECUTE_COMMAND` and
  `RUN_PROCESS` hand `g_shell_quote`d templates to `/bin/sh -c`. That code
  deserves to be readable in isolation and directly unit-testable, the way
  `redact.d` and `regex.d` already are.
- It only reaches back into `Terminal` for VTE access, state updates and
  notifications — all already expressible through `ITerminalContext`.

Note WP7 deletes the patched-VTE feature probes that gate trigger firing. Do the
extraction first; the deletion is then a small change in one small module rather
than another edit to the 3,900-line file.

### `terminal/urlmatch.d` (~270 lines)

`updateMatch`, `openURI`, `isAllowedUriScheme`, the `regexTag` map and the
`TerminalURLMatch` handling. Also security-relevant — this is the OSC 8 scheme
allow-list and the custom-link shell-exec path. The 3 GTK4-affected lines are
incidental (`showAll` on an error dialog).

### `terminal/titlebuilder.d` (~143 lines)

`updateDisplayText`, `updateTitle`, `updateBadge`, `replaceVariables`,
`checkAutomaticProfileSwitch`. `replaceVariables` is already
transform-parameterised for shell quoting, so it is close to pure and wants
tests — it is the function that resolves remote-settable OSC values.

## Expected outcome

`terminal.d` drops from ~3,944 to roughly **3,370 lines** — still large, but the
remainder is genuinely widget code (UI construction, DnD, VTE wiring, event
handlers) rather than mixed-in business logic, and the parts most worth testing
are out where they can be tested.

Full decomposition below ~2,000 lines needs the UI-construction and DnD clusters
too, and that is a Phase 2b follow-on, not a prerequisite.

## Sequencing

1. `triggers.d` — highest value (security-critical, zero GTK4 overlap, testable)
2. `urlmatch.d`
3. `titlebuilder.d`
4. *(Phase 2b runs)*
5. Extract DnD and UI construction as part of, or immediately after, WP2/WP4/WP6
   — the port creates the natural seams

Each of 1–3 is independently shippable and independently revertible. None should
be bundled with a behaviour change.
