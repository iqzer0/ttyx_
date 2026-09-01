# Changelog

All notable changes to **ttyx_** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **`$1` in a trigger or custom-link template gave the whole regex match instead of the first capture group.** Both paths built their substitution array as `[wholeMatch] ~ allCaptures`, but `std.regex`'s `Captures` and GLib's `fetchAll()` *already* return the whole match as element 0 — so it was duplicated and every capture group shifted up by one, leaving the first real group reachable only as `$2`. This contradicted the documented convention (`$0` = whole match, `$1..` = groups) and broke the manual's own worked example, which tells users to write `username=$1;hostname=$2`. **Behaviour change:** if you worked around this by writing `$2` where you meant the first group, those templates need adjusting back to the documented numbering.
- **A session loaded with `--session` in a new process showed a literal `${title}` in the titlebar.** `Session.currentTerminal` is assigned only in `createUI(Terminal)` and in the focus-in handler, and the deserialization path goes through neither — so it stayed null until some terminal happened to take focus. `session-name` defaults to `${title}`, which only the active terminal can resolve, so the token reached the titlebar verbatim. Interactive loads self-corrected because the window was already focused; a fresh `--session` process computed its title first. The same null also made `focusRestore()` a no-op, so a loaded session could come up with focus in no terminal at all. `parseSession` now seeds `currentTerminal` from the restored layout, and `getDisplayText` blanks unresolved terminal-scope variables (driven off the canonical variable list) rather than passing them through.
- **`install.sh` no longer generates into the source tree.** The compiled gresource, the localized `.desktop` and appdata files, and transient `.mo` files were all written next to their own sources. Run under `sudo` — the normal case for the default `/usr` prefix — that left root-owned files scattered through a user-owned checkout, which then broke every subsequent non-root `dub build` and `./install.sh` with permission errors until they were removed by hand. Everything now goes to `build/` (override with `BUILD_DIR=`), which is gitignored and disposable, so a root install is cleaned up with `rm -rf build`. `install.sh` also no longer rewrites the tracked `po/LINGUAS`: nothing in the script reads it, and `extract-strings.sh` already owns that job.
- **Saving a session permanently switched the process to the C locale.** `Session.serialize` set `LC_ALL=C` so the generated JSON would not be locale-specific, then "restored" it with `setlocale(LC_ALL, null)` — but a null locale argument *queries* the locale and changes nothing. After the first session save the whole process stayed in the C locale, which also switched `LC_MESSAGES` and left the UI untranslated for the rest of the run. The previous locale is now snapshotted and genuinely restored.
- **Several unguarded array indexes in session serialization and terminal un-parenting.** `serializeBox`, `serialize`, `findOtherChild` and `unparentTerminal` all indexed `getChildren(...)[0]` without checking for an empty result — an out-of-bounds read, and a silent one in a `-boundscheck=off` release build. `findOtherChild` now identifies the terminal's side by direct parentage instead of indexing, the serialization paths raise a diagnosable `SessionCreationException` (both callers already show an error dialog), and `unparentTerminal` logs and bails rather than reading past the end.
- **`Session.focusDirection` dereferenced `currentTerminal` without a null check**, unlike every sibling focus method — and `removeTerminalReferences` sets that field to null.
- **`AppWindow.saveSession` had its null check on the wrong branch.** `if (session !is null && (...))` guarded only the Save-As path; a null session fell through to the `else` and dereferenced it.
- **Null-safety made consistent across `AppWindow`.** `getCurrentSession()` and `Notebook.getTabLabel()` results were null-checked at roughly half their call sites. The reachable unguarded ones are fixed, most importantly: the deferred idle callback after a page switch (the session can be closed between the switch and the callback), and `onSessionProcessNotification`, which is driven by the background process monitor and so can fire during window teardown.
- **`ttyx --group` crashed with a silent core dump.** A bare `--group` was sliced as `arg[8..$]` out of a 7-character string. `-g` with no value read past the end of the argument array. Both are bounds-checked now, and `--groupXY` no longer silently swallows a character — GLib reports it as the unknown option it is.
- **`ttyx -g <invalid-id>` aborted on an unhandled exception.** The "application ID is not valid" warning had a `%s` with no argument, so `std.format` threw `FormatException` out of the `Tilix` constructor — which `main()` calls outside its try/catch. It now warns and falls back to the default application ID as intended.
- **Theme-specific and scrollbar CSS never loaded.** Three sites still built `css/tilix.<theme>.css` resource paths after the rebrand, but the gresource ships `css/ttyx.*`, so 9 of the 12 bundled CSS files silently failed to resolve. This also left the scrollbar `CssProvider` permanently null, which disabled transparent terminal scrollbars on Adwaita, Arc, Arc-Dark, Arc-Darker, Ambiance, Radiance and Lavender. Both URIs are now built by `themeCssResourceURI` / `scrollbarCssResourceURI` in `constants.d` so the prefix has a single definition, pinned by a unit test.
- **Two screen-wide `CssProvider`s leaked per terminal.** The root and SSH title-bar tints were installed from `createTitlePane()`, which runs once per `Terminal` — so every split and every tab added two more providers to the default screen, none ever removed, and GTK re-walks all of them on style invalidation. Installation is idempotent now.
- **`install.sh` could never use its own fallbacks.** `set -o errexit` is active, so the trailing `if [ $? -ne 0 ]` checks after each `msgfmt` were dead code: on a system with older gettext the install aborted instead of falling back to a plain copy. The fallbacks are part of the condition now.
- **`install.sh` named the wrong package for missing commands.** Two commands ship in `glib2`, so the parallel command/package lists walked by index drifted by one and mis-reported 4 of 7 — a missing `msgfmt` told you to install `desktop-file-utils`. Replaced with an explicit mapping.
- **`install.sh` and `uninstall.sh` broke on prefixes containing whitespace.** `uninstall.sh` ran `rm -rf` on an unquoted `${PREFIX}`, so `./uninstall.sh "/opt/my prefix"` word-split into `rm -rf /opt/my prefix/share/ttyx` and, as root, deleted `/opt/my`. Every path in both scripts is quoted now, and both are clean under `shellcheck` at all severities.
- **`uninstall.sh` failed when no translated man pages were installed** — an unmatched glob stays literal in POSIX `sh`, so `rm` was handed a nonexistent path. Directory walks are guarded and removals use `rm -f`, so an uninstall no longer stops partway through on a partial install.
- **`install.sh` required GNU `find`.** `find -printf` (used to regenerate `po/LINGUAS`) is a GNU extension, unavailable under the busybox/BSD `sh` the shebang allows. Replaced with a POSIX glob and `basename`.
- **The installed AppStream metadata carried no release history.** `NEWS` is the source of truth and `extract-strings.sh` already converted it for string extraction, but `install.sh` never did — so software centres showed no version information. It now injects releases via `appstreamcli news-to-metainfo` when available, skipping cleanly when it is not. The metadata also validates clean (`appstreamcli validate`) for the first time: the homepage and bugtracker URLs pointed at `github.com/gwelr/ttyx` rather than `ttyx_` and returned 404.
- **In-app help links pointed at upstream Tilix's site.** The VTE-configuration warning dialog and the title-editor help menu opened `gnunn1.github.io/tilix-web`, which this fork does not control. Both now open the corresponding ttyx_ manual page.
- **The password manager's hidden ID column was bound to the name column** — a copy-paste slip that would have rendered the wrong text the moment the column was made visible.
- **`/proc` stat reads logged a full backtrace for a routine race.** A process exiting between being enumerated and having its `/proc/<pid>/stat` read is normal for a polling monitor; it was logged with `warning(e)`, printing ~15 stack frames each time and burying genuine warnings. Downgraded to a concise trace, with unexpected exceptions still logged in full.

### Changed
- **Terminal-variable substitution extracted to `gx.ttyx.terminal.variables`.** `Terminal.replaceVariables` now gathers live widget state and delegates the substitution to a pure `substituteTerminalVariables`. The point is testability of a security property: several of these values are remote-settable (`${title}`/`${iconTitle}` via OSC, `${hostname}`/`${username}`/`${directory}` via OSC 7, `${process}` from the foreground process), and when the result feeds `/bin/sh -c` every one of them must pass through the shell-quoting transform. That invariant is now pinned by a test that drives the full variable list and asserts no raw value survives — so adding a variable without wiring the transform fails a test instead of quietly opening an injection hole.
- **Trigger match collection extracted to `gx.ttyx.terminal.triggers`.** The matching and position-ordering half of `Terminal.onVTECheckTriggers` is now a free function, `collectTriggerMatches`, unit-testable without a live VTE — which is how the `$1` bug above was found. Ordering by position of appearance (rather than trigger-definition order) is now covered by tests, since the dispatch loop depends on it. Action dispatch stays on `Terminal` for now; see [docs/terminal-decomposition.md](docs/terminal-decomposition.md).
- **New application icon** — a chevron-X above a cursor bar on a dark rounded square ("Midnight"). The scalable and symbolic hicolor icons are regenerated from the design sheet, which lives in `data/icons/design/` with alternate colorways (Amber, Ice, Paper).

### Documentation
- **The security page claimed trigger and custom-link substitutions were not shell-quoted.** They are, and have been: `g_shell_quote` is applied to every regex capture group and every remote-settable title variable on all three shell-exec paths. The page now documents what is actually implemented, including the `SendText` exemption, the OSC 8 scheme allow-list, and the remaining caveat that quoting bounds injection but does not sanitise a value's meaning as an *argument*.
- **The dangerous-command pattern list was wrong in both directions** — it documented `eval` (never implemented) and omitted `pkexec` (implemented). It now also states plainly that matching is substring-based, requires a line break to fire, over-matches (`visudo`), is trivially evadable, and is a guard against your own careless paste rather than a security boundary.
- Removed stale references to dropped distribution channels: the docs landing page still offered "Flatpak (recommended) and source builds (Meson / Dub)" and the changelog page still advertised "downloadable Flatpak bundles". Both Flatpak packaging and the Meson build were retired in 1.3.0-beta.1.
- The README's security bullet now distinguishes what is on by default from what is one toggle away, rather than leading with the opt-in dangerous-command alert.

## [1.3.0-beta.1] — 2026-08-08

First beta of the 1.3.0 line — the giD build. Runtime behaviour is intended to be identical to 1.2.0; this beta's validation period exists to prove exactly that.

### Changed
- **The shipping build swapped from GtkD to giD** — the `ttyx` binary is now built on [giD](https://github.com/Kymorphia/gid) (`gid:gtk3` / `gid:vte2` / `gid:pangocairo1` / `gid:secret1`, v0.9.13) instead of the unmaintained GtkD bindings, completing ROADMAP Phase 2a. All 44 GtkD-coupled modules were ported; the GtkD-free logic carried over unchanged. The vendored libsecret bindings (`source/secret/`, `source/secretc/`) are deleted in favour of `gid:secret1`; the vendored `source/x11/` stays (giD's xlib2 lacks the raw event types it needs). A giD signal-marshal bug is worked around in `gx/gtk/events.d` (upstream: Kymorphia/gid#52). Dub is now the single build system — Meson is retired (giD publishes no pkg-config packages). Runtime behaviour is intended to be unchanged; this release is a beta to validate exactly that.
- **Flatpak packaging dropped** — the Flatpak manifest and toolbox shims are removed; building from source is the supported distribution channel.
- **Unsafe-paste alert now ships default-off** — the dangerous-command warning dialog (sudo / `rm -rf` / `curl|bash` patterns in pasted text) interrupted legitimate admin pastes often enough that default-on was more annoyance than protection. It is now opt-in under Preferences → Global → Clipboard. The always-on protections stand: bracketed-paste escape stripping (no setting) and the multi-line paste review (still default-on), so hidden-newline and paste-mode-breakout attacks remain covered by default; only the command-pattern heuristic is opt-in.

### Fixed
- **`install.sh` hung indefinitely on systems with po4a installed** — `data/man/po/` no longer exists, so the man-translation loop's unmatched glob stayed a literal `*.man.po` (POSIX sh) and `po4a-translate` blocked forever trying to read it (first surfaced as 28-minute CI job hangs; affects any user install with po4a present, including the v1.2.0 tarball). The loop now skips when no translation files exist.
- **Release builds with plain `ldc2` failed on the `-inline` dflag** — dub.json's release build type carried DMD-only `-inline` in the compiler-agnostic `dflags`, so `dub build --build=release --compiler=ldc2` (the CI and RELEASE.md invocation) failed with `Unknown command line argument` on every LDC tested. Every post-swap CI run was red because of this. The flag moved to `dflags-dmd`; LDC's `-O3` already enables inlining.
- **Remote `ttyx -a <action>` invocations hung instead of exiting** — the second instance executed its action on the primary but the caller never returned. GtkD's command-line handler took a `Scoped!ApplicationCommandLine` whose scope-exit unref signalled the remote to exit; the giD port's wrapper held its GObject ref until GC finalization, so the remote hung. The wrapper is now destroyed explicitly at handler exit, restoring the eager-unref semantics.

## [1.2.0] — 2026-08-08

Security-focused GA release of the 1.2.0 line. All changes from 1.2.0-beta.1 plus the security and crash fixes below. This is the last release built on GtkD.

### Security
- **Confirmation prompt before a restored session runs an embedded command** — a session file's per-terminal `overrideCommand` was executed as the terminal's child process the moment the session loaded, with no prompt, so opening a crafted or shared `.json` (via Open Session or `--session`) silently ran an attacker-chosen command in an attacker-chosen directory. Restoring a session that carries an embedded command now shows a modal confirmation naming the command, defaulting to the safe choice; declining opens a normal shell. Only the session-restore path prompts — CLI (`-e`/`-x`) and profile custom commands are trusted and unaffected. The command is shown as plain text so it cannot inject Pango markup into the dialog.
- **Custom-link and trigger commands now shell-quote attacker-controlled substitutions** — clicking a custom link, and the `EXECUTE_COMMAND`/`RUN_PROCESS` triggers, substituted regex match tokens (`$0..$N`, drawn from terminal output) and terminal variables (`${title}`, `${hostname}`, ... — several remote-settable via OSC) into a string handed to `/bin/sh -c` with no escaping. A captured or OSC-set value containing shell metacharacters (`; rm -rf ~`, `` `…` ``, `$(…)`) therefore injected into the command — for custom links on a single click, for triggers automatically (trigger firing requires a Tilix-patched VTE). Every substituted value now passes through `g_shell_quote` via a new `replaceMatchTokensQuoted` helper and a shell-quoting mode of `replaceVariables`, so values become inert shell words while the user's own template syntax (pipes, `&&`, redirects) is preserved. Display/state/notification actions are unaffected (still substituted verbatim). As a side effect the trigger handler no longer mutates the shared trigger object, so repeated fires are idempotent.
- **Paste sanitization now applied on every paste path** — `stripPasteEscapes` produced a sanitized string, but the default paste path (with neither `paste-strip-first-char` nor `paste-strip-trailing-whitespace` enabled, the shipped default) fell through to VTE's `pasteClipboard()`/`pastePrimary()`, which re-read the *raw* selection from the OS and discarded the sanitized result — contradicting the function's "unconditional sanitization" contract. All paste branches now feed the sanitized text through `vte_terminal_paste_text`, which still applies bracketed-paste wrapping, so editors keep receiving properly-bracketed pastes.
- **Bracketed-paste stripping hardened against split/overlapping markers** — `stripPasteEscapes` ran each regex a single, non-overlapping, non-re-scanning pass, so removing one match could splice the surrounding bytes into a freshly-formed marker (e.g. `\x1b[20` + `\x1b[201~` + `1~` collapsed to a live `\x1b[201~` after the inner removal, terminating bracketed-paste mode early and letting the trailing bytes run as keystrokes). Stripping now loops to a fixed point; each pass only deletes, so it is guaranteed to terminate.
- **Carriage return treated as a command submitter in paste checks** — `isPasteUnsafe`, the multi-line review gate, and the advanced-paste gate tested only for LF (`\n`), so a CR-terminated payload (`sudo reboot\r`) — which auto-executes just like LF — slipped past both the dangerous-command warning and the multi-line review dialog. A new `containsLineBreak` helper matches both LF and CR; unit tests cover the previously-evading cases.
- **Proxy credentials redacted in the spawn-failure log** — when a child process failed to spawn, `spawnTerminalProcess` dumped the full environment at error level (not gated behind verbose logging), including the `http_proxy`/`https_proxy` URLs that `setProxyEnv` builds with inline `user:password`. The environment dump now runs each entry through a new `redactEnvEntry` helper (secret/token/auth values replaced with a placeholder, proxy-URL userinfo stripped), and the argument dump strips URL userinfo.
- **OSC 8 hyperlinks are restricted to an allow-listed set of URI schemes** — an OSC 8 hyperlink carries an arbitrary URI chosen by whatever wrote to the terminal, and `openURI` handed it to the desktop URI handler (`MountOperation.showUri`) after only a `file://`-remote check — so a `javascript:`, `data:`, or scriptable custom scheme was opened blindly. Non-`file` URIs now pass through a new `isAllowedUriScheme` allowlist (http/https/ftp/ftps/sftp/file/mailto/news/nntp/telnet/webcal/sip/sips/h323 — the schemes the built-in link regexes produce); anything else is refused with a dialog. The CWD-in-browser action is unaffected (always a local `file://`).
- **Trigger regex input is bounded to mitigate ReDoS** — user-configured trigger patterns are matched with `std.regex` (a backtracking engine with no step/time limit that cannot be interrupted) against terminal output on the UI thread. With `unlimited` trigger lines or very wide lines, a catastrophic-backtracking pattern could hang the UI on adversarial output. The scanned text is now capped (keeping the most recent output) via a new `boundedTail` helper as defense-in-depth. Note: this path only runs on a Tilix-patched VTE, and the pattern is the user's own — the cap bounds input amplification, it does not make an arbitrary pattern safe.
- **Log redaction completeness** — the sensitive-key fragment list gained `pwd`, `key`, `private`, and `passphrase` (so `MYSQL_PWD`, `SSH_PRIVATE_KEY`, `GPG_KEY`, etc. are redacted), and `redactSensitive` now strips URL userinfo from *every* value, not just proxy-keyed ones — so a credential-bearing URL under an unrecognized key (e.g. `DATABASE_URL=postgres://u:pw@h/db`) no longer leaks. `cmdparams.d` now imports the redaction helper and strips URL userinfo from the parsed `--command`/`-e`, working-directory, cwd, and title values it re-logs at trace level (previously logged verbatim, unlike the raw argv which `app.d` already redacts).
- **Retrieved keyring passwords use non-pageable memory** — the password-insert path now calls `passwordLookupvNonpageableSync` instead of `passwordLookupvSync`, so a retrieved secret lives in memory libsecret keeps out of swap rather than ordinary pageable memory.

### Fixed
- **Crash reading the host shell from a malformed passwd entry** — `getHostShell` (Flatpak path) sliced `passwd.split(":")[6]` without checking the field count, throwing a `RangeError` on an entry with fewer than 7 fields. The field count is now guarded and the function returns null on a malformed entry.
- **Crash loading a session with a corrupt orientation value** — a session JSON whose paned `orientation` was neither 0 nor 1 was cast straight to GTK's `Orientation` enum and hit a `final switch`, throwing a `SwitchError`. Because that is an `Error` rather than an `Exception`, the session-load `catch (Exception)` did not catch it and the app crashed on opening a crafted or corrupt session file. Orientation is now validated by a testable `parseOrientation` helper that rejects out-of-range values so the load fails gracefully.
- **Crash reading a child process name from a malformed `/proc` stat** — `TerminalProcessQuery` sliced the `comm` field between `(` and `)` without checking they exist; a missing `)` made `lastIndexOf` return -1, which wrapped to `SIZE_MAX` in a `size_t` and threw a `RangeError` the `catch (FileException)` could not catch (reachable in the Flatpak path when the host toolbox returns empty/non-stat output). Parsing moved to a guarded, unit-tested `parseProcName` helper in `gx.util.proc` that returns null on malformed input.

## [1.2.0-beta.1] — 2026-04-29

First beta of the 1.2.0 release. Validation period before GA.

### Added
- **OSC 11 (dynamic background color) support** — apps like neovim and theme-switching scripts can now change the terminal background at runtime via `printf '\033]11;#rrggbb\007'`; reset with `printf '\033]111\007'`. ttyx_ no longer disables VTE's native background painting, so OSC 11 is honoured natively. The badge draw signal moved from the BEFORE phase to AFTER so badges still render on top of the terminal output (#47).
- Documentation site at <https://gwelr.github.io/ttyx_/> — built with Jekyll + just-the-docs, manual content adapted from upstream Tilix under MPL-2.0 (#59, #60, #61, #63, #64).
- Unit test coverage for the password manager row-removal path, extracted as `removeRowById` (#54).
- Unit tests for the proxy URL builder, sensitive-value redaction, and process introspection helpers (#55, #56, #58).

### Changed
- **`TerminalRegex` converted to a tagged union over `BuiltinRegex` / `CustomRegex`** — the previous flat struct carried a `command` field that was "only used for custom regex", a conditionally-meaningful field that nothing enforced at the type level. Splitting the two variants makes it impossible at compile time to attach a command to a builtin URL regex or to construct a custom-link regex without one (the `CustomRegex` constructor's `in` contracts require a non-empty pattern and a non-null command). The custom-link click handler in `Terminal.openURI` now dispatches via `match!` — the `command` access is reachable only inside the `CustomRegex` branch. UFCS accessors (`pattern`, `caseless`, `flavor`) keep call-site code at consumers that only need shared fields unchanged. Wire format and runtime behaviour unchanged. Mirrors the same pattern as #33's `SyncInputEvent` SumType conversion (#87).
- **Synchronized-input event payload converted to a tagged union** — `SyncInputEvent` is now a `std.sumtype.SumType` of `SyncKeyPressEvent`, `SyncTextEvent`, `SyncInsertTerminalNumberEvent`, `SyncResetEvent`, and `SyncResetAndClearEvent`. Each variant carries exactly the fields it needs and rejects null payloads via `in` contracts, so it is now impossible at compile time to construct a key-press event without an `Event` or a text event without a payload. The consumer in `Terminal.handleSyncInput` dispatches via `match!`, which is exhaustive at compile time — adding a future variant without handling it will fail to compile (#33).
- **Terminal serialisation centralised on a typed `TerminalSnapshot` struct** — replaces the ad-hoc JSON building that was scattered between `session.d` and `terminal.d`. Adding a persisted field is now a single struct change instead of coordinated edits in two files. Wire format unchanged; `Nullable!string` makes optional override fields explicit; the dead per-terminal `width`/`height` writes (never read on the per-terminal deserialise path) are dropped from the format. Lenient deserialisation: missing keys default-initialise, unknown keys are ignored. Verified by a golden-JSON roundtrip test (#34).
- **`enable-wide-handle` now defaults to `true`** — the splitter between split terminals is now wide by default, making it easier to see and grab on dark themes and HiDPI displays. Existing users who have explicitly toggled this preference are unaffected; only fresh installs and users who never touched it pick up the new default. Set to `false` to restore the previous 1-pixel splitter (#48).
- Extracted pure helpers out of the terminal widget module to reduce complexity and unlock testing: `pointInTriangle` → `gx.util.geometry`, `parsePairs` → `gx.util.string`, process introspection → `gx.util.proc` (#57, #58).
- Process root detection now goes through a single `readProcStatus` helper; the `/proc/[pid]/status` parser was previously duplicated across `monitor.d` and `activeprocess.d` (#58).
- Debug log path resolution now prefers `$XDG_RUNTIME_DIR/ttyx.log` over `/tmp/ttyx.log` when file logging is enabled (#55).

### Fixed
- **Triggers with an unrecognised action name are now skipped instead of silently rewritten to UpdateState** — the `TerminalTrigger` constructor used to fall through to `default: break;` on any unknown action name, leaving `action` at its enum init value (`UPDATE_STATE`). A typo, a stale config from a different fork, or a future schema migration with renamed actions would silently rewrite the user's trigger to a working-but-wrong UpdateState. The constructor now throws `UnknownTriggerActionException`; the loader in `Terminal.loadTriggers` catches and logs `Skipping trigger entry with unknown action 'X' (pattern 'Y')`. Note: this only affects users who have triggers configured (the trigger UI is gated behind a Tilix-patched VTE — see #95) (#88).
- **Trigger templates: `$0` now substitutes the whole match (not the first capture group)** — `replaceMatchTokens` had a `size_t` off-by-one underflow (`i - 1` on the first iteration wrapped to `size_t.max`), which silently shifted every token by one: `$0` got the first capture group, `$1` got the second, and the whole match was never substitutable. The function now iterates in reverse to also handle `$10`/`$1` correctly (without reverse iteration the `$1` pass would corrupt the start of `$10`, `$11`, ...). User-configured triggers that relied on the bugged behaviour will need their template indices shifted up by one (#84).
- **Maximized terminal not restored on session load** — loading a saved session whose JSON has `maximized: true` on a child no longer leaves the user looking at the half-empty Paned. Root cause: `gtk_stack_set_visible_child` is a silent no-op when the target child has never been shown, and on the restore path `parseSession` runs before `nb.showAll()` cascades show to the stack pages. Fixed by explicitly calling `show()` on the maximized stack page before switching to it; idempotent in the user-triggered Ctrl+Shift+X path. Pre-existing since the upstream Tilix 2017 implementation; surfaced in #91 during the #89 refactor smoke test (#91).
- **Password manager delete silently failed** — the delete button claimed success even when the keyring operation failed, and legacy-schema entries from the Tilix migration couldn't be deleted at all (#50, #54).
- **Proxy URL malformed** — the generated `http_proxy` URL had a redundant leading `@` before userinfo, which strict RFC-3986 parsers reject; credentials were also not percent-encoded, so passwords containing `@`, `:`, `/` broke the URL entirely (#51, #55).
- **`https_proxy` missing authentication** — the auth block was gated on `scheme == "http"` so the HTTPS proxy never received credentials even when configured (#51, #55).
- **Debian Testing CI build** — GtkD bindings were removed from Debian Testing's apt archive; CI now builds GtkD from source on that image (#49).
- **CI: LDC compiler installed from upstream tarball** — `ldc` is currently missing from Debian Testing during a transition. All container-based CI images (Debian Stable, Debian Testing, Ubuntu Noble) now install LDC 1.40.0 from the official `ldc-developers` GitHub release tarball instead of apt, so CI is no longer coupled to any one distro's apt archive. Same mitigation pattern as the GtkD-from-source fix from #49.

### Security
- **Config migration hardened against symlink attacks** — `migrateConfigBetween` now refuses to follow symlinks and skips existing target files during the Tilix → ttyx_ first-run migration (#49).
- **Sensitive values redacted in trace logs** — environment variables whose keys contain `password`/`token`/`secret`/`auth` are replaced with `[redacted]`; proxy URLs have their userinfo stripped before logging (#51, #55, #56).
- **Command-line arguments and hyperlink traces redacted** — URL userinfo is stripped from argv and from terminal hyperlink click events before they reach any log sink (#56).

## [1.1.1] — 2026-04-18

Maintenance release focused on identity: ttyx_ became its own project, with automatic migration for users coming from Tilix.

### Added
- **Automatic migration from Tilix on first run**: `~/.config/tilix/` is copied to `~/.config/ttyx/` (original kept as backup); libsecret entries stored under the old Tilix schema are still read and new passwords are written to the ttyx schema; both `TTYX_ID` and `TILIX_ID` are set in shells so existing shell integrations keep working.
- New "Migrating from Tilix" section in README.
- New "Troubleshooting" section covering stale icon caches and Wayland Quake-mode limitations.
- `ROADMAP.md` documenting vision and phase plan.

### Changed
- Renamed user-visible Tilix references in the Nautilus menu, shortcuts window, GSettings descriptions, icon filenames, and log/temp paths.
- Rewrote the man page under ttyx_ identity.
- Dropped 30 stale translation files that still carried Tilix-branded source strings.
- Release process simplified: ship only the Flatpak bundle with signed checksums. The hand-assembled binary tarball was dropped — distro packagers should build from source, Flatpak covers direct users.

### Fixed
- Color scheme list no longer shows duplicates when the same scheme exists in both user config and system data dirs (user config wins).
- Post-install script writes a minimal `index.theme` at the install prefix so `gtk-update-icon-cache` can generate a valid icon cache.
- AppStream metadata no longer includes stale Tilix release entries.

## [1.1.0] — 2026-04-15

A major security and performance release. ttyx_ positioned itself as a security-conscious tiling terminal emulator for Linux.

### Added
- **Paste protection** — bracketed-paste escape stripping (blocks `ESC[200~` / `ESC[201~` injection), multi-line paste review dialog, dangerous-command detection (`sudo`, `su`, `rm -rf`, `curl | bash`, `dd if=`, `mkfs`, `chmod 777`, fork bombs), per-paste warnings that appear every time rather than once per session.
- **Clipboard auto-clear** — clears clipboard after a configurable 5–300 s timeout to prevent sensitive data from lingering.
- **SSH session indicator** — blue tint and label when connected via ssh, scp, sftp, mosh, or sshfs.
- **Root indicator** — red tint and label when running with elevated privileges.
- **Core-dump protection** — `prctl(PR_SET_DUMPABLE, 0)` blocks `/proc/pid/mem` reads and core-dump generation; toggleable for debugging.
- **In-memory-only scrollback** — removed the unlimited scrollback option; capped at 256–999,999 lines, never written to disk.
- **Secure Clear** (`Ctrl+Shift+L`) — on-demand wipe of the scrollback buffer.
- 119 unit tests covering security, clipboard, rendering, and process-monitor modules.
- Security options consolidated under **Preferences → Advanced → Security** with descriptive labels.

### Changed
- **ProcessMonitor optimization** — idle CPU reduced from 1.4% to 0.1% by replacing full `/proc` scans with targeted foreground-process lookups.
- **Major terminal.d decomposition** — `terminal.d` (178 KB) had `ClipboardHandler`, `TerminalRenderer`, `ProcessQuery`, `SpawnHandler`, `FlatpakHostCommands` extracted.
- PreferenceRegistry pattern replaced the switch-based preference dispatch.

### Fixed
- GC crash when opening preferences on GLib 2.84+ (Flatpak environments).
- SSH and root indicators not clearing when the foreground process exits.
- Color scheme test when schemes are not installed in XDG paths.

## [1.0.2] — 2026-04-07

First release under the ttyx_ name.

### Added
- New tabs open next to the current tab (not at the end).
- Option to strip trailing whitespace on copy.
- Visual indicator when terminal is running as root.
- `~` and `@` added to default word-select characters.
- 8 new built-in color schemes: Catppuccin (Latte, Mocha), Dracula, Gruvbox (Dark, Light), Nord, One Dark, Tokyo Night.
- Comprehensive unit test suite across utility and core modules.

### Changed
- Release build optimizations: proper `-O3`, `-release`, `-inline`, `-boundscheck=off` flags for both meson and dub. Binary size dropped from 17 MB (debug) to 3.3 MB (release, stripped).

### Fixed
- Crash on malformed URIs in OSC 7 and drag-and-drop.
- Color schemes with `use-theme-colors` incorrectly shown as "Custom".
- Title bar markup rendering (`setText` instead of `setMarkup`).
- Focus stealing on terminal restart.
- Proxy host protocol prefix duplication.
- Empty clipboard text after stripping whitespace.
- Preferences dialog segfaults when changing profiles or closing the dialog.

## Attribution

ttyx_ is a fork of [Tilix](https://github.com/gnunn1/tilix) by Gerald Nunn, licensed under [MPL-2.0](LICENSE). Release history before 1.0.2 is part of the upstream Tilix project.
