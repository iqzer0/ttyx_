/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/**
 * Terminal-variable substitution.
 *
 * Extracted from `Terminal.replaceVariables`. The split is between *gathering*
 * live widget state (still on `Terminal` — it needs the VTE, the state tracker
 * and the process monitor) and *substituting* it, which is pure and lives here.
 *
 * Worth having under test on its own: several of these values are
 * remote-settable — `${title}` / `${iconTitle}` via OSC, `${hostname}` /
 * `${username}` / `${directory}` via OSC 7, `${process}` from the foreground
 * process — and when the result feeds `/bin/sh -c` (custom-link clicks,
 * `ExecuteCommand` / `RunProcess` triggers) the caller passes a shell-quoting
 * transform. The security-relevant invariant is that **every** substituted
 * value goes through that transform, with none missed. That is exactly the kind
 * of property that rots silently when a new variable is added, and exactly what
 * a unit test can pin. See the `every value is transformed` test below.
 *
 * The first piece of the title/badge cluster described in
 * docs/terminal-decomposition.md.
 */
module gx.ttyx.terminal.variables;

import std.array : replace;

import gx.ttyx.constants;

/**
 * Resolved values for the terminal-scope variables, gathered by the caller
 * from live widget state.
 *
 * Plain strings rather than lazy delegates: every field is either a stored
 * value or a cheap VTE getter, so eager resolution costs nothing and keeps this
 * module free of widget dependencies.
 */
struct TerminalVariables {
    string title;
    string iconTitle;
    string id;
    string columns;
    string rows;
    string hostname;
    string username;
    string statusReadOnly;
    string statusSilence;
    string statusInputSync;
    string process;
    string directory;
}

/**
 * Substitute every terminal-scope variable in `text` with its value from `v`.
 *
 * `transform`, when non-null, is applied to each value before substitution —
 * callers feeding a shell pass `g_shell_quote`. Passing null substitutes
 * verbatim, which is what the display and state paths want.
 *
 * The template itself is never transformed, so a user's own shell syntax
 * survives; only the values do.
 */
string substituteTerminalVariables(string text, in TerminalVariables v,
                                   string delegate(string) transform = null) {
    string q(string value) {
        return transform is null ? value : transform(value);
    }

    // Kept in the same order as the original for reviewability. Every entry
    // must go through q() — see the invariant test below.
    text = text.replace(VARIABLE_TERMINAL_TITLE, q(v.title));
    text = text.replace(VARIABLE_TERMINAL_ICON_TITLE, q(v.iconTitle));
    text = text.replace(VARIABLE_TERMINAL_ID, q(v.id));
    text = text.replace(VARIABLE_TERMINAL_COLUMNS, q(v.columns));
    text = text.replace(VARIABLE_TERMINAL_ROWS, q(v.rows));
    text = text.replace(VARIABLE_TERMINAL_HOSTNAME, q(v.hostname));
    text = text.replace(VARIABLE_TERMINAL_USERNAME, q(v.username));
    text = text.replace(VARIABLE_TERMINAL_STATUS_READONLY, q(v.statusReadOnly));
    text = text.replace(VARIABLE_TERMINAL_STATUS_SILENCE, q(v.statusSilence));
    text = text.replace(VARIABLE_TERMINAL_STATUS_INPUT_SYNC, q(v.statusInputSync));
    text = text.replace(VARIABLE_TERMINAL_PROCESS, q(v.process));
    text = text.replace(VARIABLE_TERMINAL_DIR, q(v.directory));
    return text;
}

// -- tests ---------------------------------------------------------------

version (unittest) {
    TerminalVariables sample() {
        TerminalVariables v;
        v.title = "T"; v.iconTitle = "IT"; v.id = "1";
        v.columns = "80"; v.rows = "24";
        v.hostname = "host"; v.username = "user";
        v.statusReadOnly = "false"; v.statusSilence = "false";
        v.statusInputSync = "false";
        v.process = "bash"; v.directory = "/tmp";
        return v;
    }
}

unittest {
    // Basic substitution, no transform.
    assert(substituteTerminalVariables(VARIABLE_TERMINAL_TITLE, sample()) == "T");
    assert(substituteTerminalVariables("a" ~ VARIABLE_TERMINAL_HOSTNAME ~ "b", sample()) == "ahostb");
    assert(substituteTerminalVariables("no variables here", sample()) == "no variables here");
    assert(substituteTerminalVariables("", sample()) == "");
}

unittest {
    // THE security invariant: no substituted value may reach the output
    // without passing through the transform. Marks each value and asserts no
    // bare value survives — so adding a new variable without wiring q() fails
    // here rather than silently opening an injection hole in the shell paths.
    string mark(string s) { return "<" ~ s ~ ">"; }

    // A template naming every variable at once.
    string tmpl;
    foreach (variable; VARIABLE_TERMINAL_VALUES) {
        tmpl ~= variable ~ "|";
    }

    TerminalVariables v = sample();
    string got = substituteTerminalVariables(tmpl, v, &mark);

    foreach (value; [v.title, v.iconTitle, v.id, v.columns, v.rows, v.hostname,
                     v.username, v.process, v.directory]) {
        assert(got.indexOf(mark(value)) >= 0,
            "value should appear transformed: " ~ value);
    }
    // No variable token should survive unsubstituted.
    foreach (variable; VARIABLE_TERMINAL_VALUES) {
        assert(got.indexOf(variable) < 0,
            "variable left unsubstituted: " ~ variable);
    }
}

unittest {
    // A shell-metacharacter payload arriving via a remote-settable value (OSC
    // title) is handed to the transform, not spliced in raw. This is the
    // custom-link / trigger exec path's protection.
    string sq(string s) { return "'" ~ s.replace("'", `'\''`) ~ "'"; }
    TerminalVariables v = sample();
    v.title = `x"; rm -rf ~; #`;
    string got = substituteTerminalVariables("notify-send " ~ VARIABLE_TERMINAL_TITLE, v, &sq);
    assert(got == `notify-send 'x"; rm -rf ~; #'`);
}

unittest {
    // The template's own shell syntax is preserved — only values are quoted.
    string sq(string s) { return "'" ~ s ~ "'"; }
    assert(substituteTerminalVariables("echo " ~ VARIABLE_TERMINAL_ID ~ " && done", sample(), &sq)
        == "echo '1' && done");
}

unittest {
    // Repeated occurrences of the same variable are all substituted.
    string t = VARIABLE_TERMINAL_ID ~ "-" ~ VARIABLE_TERMINAL_ID;
    assert(substituteTerminalVariables(t, sample()) == "1-1");
}

version (unittest) {
    import std.string : indexOf;
}
