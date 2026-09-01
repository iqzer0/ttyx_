/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/**
 * Trigger match collection.
 *
 * Extracted from `Terminal.onVTECheckTriggers`, which is a method on a
 * ~3,900-line widget class and therefore could not be tested without a live
 * GTK/VTE tree. This half is pure — text in, ordered matches out — and it is
 * the security-relevant half: the groups it produces are substituted into
 * trigger templates, and for the `ExecuteCommand` / `RunProcess` actions those
 * templates are handed to `/bin/sh -c`. Ordering matters too, because triggers
 * fire in the order returned.
 *
 * The action *dispatch* half (`processTrigger`) stays on `Terminal` for now: it
 * reaches into override fields, the action group, focus state and four update
 * methods, so moving it needs a wider context interface than
 * `ITerminalContext` currently offers. See docs/terminal-decomposition.md.
 */
module gx.ttyx.terminal.triggers;

import std.algorithm : sort;
import std.regex : matchAll;

import gx.ttyx.terminal.types : TerminalTrigger, TerminalTriggerMatch;

/**
 * Match every trigger against `text` and return the matches ordered by their
 * position in the buffer.
 *
 * Order is by position of appearance, not by trigger definition order, so that
 * output which activates several triggers fires them in the sequence the user
 * actually saw. A trigger matching repeatedly yields one entry per match.
 *
 * `groups[0]` is the whole match and `groups[1..]` the capture groups, matching
 * the `$0..$N` substitution convention in `gx.ttyx.terminal.regex`.
 *
 * Callers are responsible for bounding `text` — `std.regex` is a backtracking
 * engine with no step limit and cannot be interrupted, so a pathological
 * user-supplied pattern over a large input would hang the UI thread.
 */
TerminalTriggerMatch[] collectTriggerMatches(string text, TerminalTrigger[] triggers) {
    TerminalTriggerMatch[] result;
    if (text.length == 0 || triggers.length == 0) return result;

    foreach (trigger; triggers) {
        foreach (m; matchAll(text, trigger.compiledRegex)) {
            // std.regex's Captures already yields the whole match as element
            // 0, so iterating it gives exactly the documented $0..$N layout.
            // The original code prepended m.hit as well, duplicating the whole
            // match and shifting every capture group up by one — so $1 gave
            // the whole match and the first real group was only reachable as
            // $2, contradicting both the manual and its own worked example.
            string[] groups;
            foreach (group; m.captures) {
                groups ~= group;
            }
            result ~= TerminalTriggerMatch(trigger, groups, m.pre.length);
        }
    }

    // Stable ordering by buffer position. `sort` with a strict-less predicate
    // keeps equally-positioned matches in trigger-definition order.
    return result.sort!((a, b) => a.index < b.index).release;
}

// -- tests ---------------------------------------------------------------

version (unittest) {
    import gx.ttyx.preferences : SETTINGS_PROFILE_TRIGGER_UPDATE_TITLE_VALUE;

    // TerminalTrigger's constructor compiles the regex and maps the action
    // name, so tests build them the same way the settings loader does.
    TerminalTrigger mk(string pattern, string parameters = "p") {
        return new TerminalTrigger(pattern, SETTINGS_PROFILE_TRIGGER_UPDATE_TITLE_VALUE, parameters);
    }
}

unittest {
    // Empty inputs yield nothing rather than throwing.
    assert(collectTriggerMatches("", [mk("x")]).length == 0);
    TerminalTrigger[] none;
    assert(collectTriggerMatches("some text", none).length == 0);
}

unittest {
    // groups[0] is the whole match; captures follow, matching $0..$N.
    auto m = collectTriggerMatches("build failed: disk full", [mk(`failed: (.+)$`)]);
    assert(m.length == 1);
    assert(m[0].groups.length == 2);
    assert(m[0].groups[0] == "failed: disk full");
    assert(m[0].groups[1] == "disk full");
}

unittest {
    // Regression: the worked example shipped in docs/manual/triggers.md.
    // Pattern captures user and host; the manual tells users to write
    // "username=$1;hostname=$2". Before the fix the whole match was
    // duplicated into groups[0..1], so $1 was the whole match and the real
    // groups were only reachable as $2/$3 — the documented example was wrong
    // in the shipped product.
    auto m = collectTriggerMatches("[alice@server ~]$ ",
        [mk(`^\[(?P<user>.*)@(?P<host>[-a-zA-Z0-9]*)`)]);
    assert(m.length == 1);
    assert(m[0].groups[0] == "[alice@server", "$0 is the whole match");
    assert(m[0].groups[1] == "alice",  "$1 must be the FIRST capture group");
    assert(m[0].groups[2] == "server", "$2 must be the second capture group");
}

unittest {
    // A trigger matching several times yields one entry per match, in order.
    auto m = collectTriggerMatches("a1 a2 a3", [mk(`a(\d)`)]);
    assert(m.length == 3);
    assert(m[0].groups[1] == "1");
    assert(m[1].groups[1] == "2");
    assert(m[2].groups[1] == "3");
    assert(m[0].index < m[1].index && m[1].index < m[2].index);
}

unittest {
    // Matches from different triggers interleave by buffer position, NOT by
    // the order the triggers were defined in. This is the ordering guarantee
    // the dispatch loop relies on.
    auto triggers = [mk("second"), mk("first")];
    auto m = collectTriggerMatches("first then second", triggers);
    assert(m.length == 2);
    assert(m[0].groups[0] == "first", "earlier text must fire first");
    assert(m[1].groups[0] == "second");
}

unittest {
    // A trigger that matches nothing contributes nothing, and does not
    // disturb the ordering of the ones that do.
    auto m = collectTriggerMatches("alpha beta", [mk("nomatch"), mk("beta"), mk("alpha")]);
    assert(m.length == 2);
    assert(m[0].groups[0] == "alpha");
    assert(m[1].groups[0] == "beta");
}

unittest {
    // Regression guard for the security-relevant path: shell metacharacters in
    // captured output are returned verbatim here. Quoting is the caller's job
    // (replaceMatchTokensQuoted / g_shell_quote) — this function must not
    // silently alter the payload, or the quoting layer would be reasoning
    // about different text than actually matched.
    auto m = collectTriggerMatches(`Build failed: oops"; rm -rf ~; #`, [mk(`failed: (.+)$`)]);
    assert(m.length == 1);
    assert(m[0].groups[1] == `oops"; rm -rf ~; #`);
}

// -- end-to-end contract tests -------------------------------------------
//
// The `$N` substitution contract has broken twice, in different halves of
// the pipeline and for different reasons:
//
//   1. replaceMatchTokens had a size_t underflow (`i - 1` wrapping on the
//      first iteration), so $0 resolved to the first capture group (#84).
//   2. Both match collectors prepended the whole match to an array that
//      already contained it at index 0, so $1 resolved to the whole match.
//
// Each half is now unit-tested on its own, but neither bug lived *inside* a
// half — both lived at the seam, where one side's output feeds the other's
// input. These tests compose the real functions and pin the contract the
// manuals promise users, so a regression in either half fails here.

version (unittest) {
    import gx.ttyx.terminal.regex : replaceMatchTokens, replaceMatchTokensQuoted;

    /// Match `text`, then substitute into `template_` exactly as the trigger
    /// and custom-link dispatch paths do.
    string substituteFirstMatch(string text, string pattern, string template_) {
        auto matches = collectTriggerMatches(text, [mk(pattern)]);
        assert(matches.length > 0, "test pattern did not match");
        return replaceMatchTokens(template_, matches[0].groups);
    }
}

unittest {
    // The worked example from docs/manual/triggers.md, end to end. If either
    // half regresses, this is the test that notices.
    assert(substituteFirstMatch("[alice@server ~]$ ",
        `^\[(?P<user>.*)@(?P<host>[-a-zA-Z0-9]*)`,
        "username=$1;hostname=$2") == "username=alice;hostname=server");
}

unittest {
    // The worked example from docs/manual/customlinks.md: Python traceback ->
    // `gedit +$2 $1`, i.e. capture groups used out of order as real argv.
    assert(substituteFirstMatch(`File "/tmp/app.py", line 42, in main`,
        `File "([^"]+)", line (\d+)`,
        "gedit +$2 $1") == "gedit +42 /tmp/app.py");
}

unittest {
    // $0 is the whole match — the half of the contract that bug #84 broke.
    assert(substituteFirstMatch("error: disk full", `error: (.+)$`, "notify $0")
        == "notify error: disk full");
    // ...and $1 is the FIRST capture group — the half this session's bug broke.
    assert(substituteFirstMatch("error: disk full", `error: (.+)$`, "notify $1")
        == "notify disk full");
}

unittest {
    // Double-digit tokens must not be corrupted by the single-digit pass.
    // Guards the reverse-iteration order in replaceMatchTokens across the seam.
    string text = "a b c d e f g h i j k";
    string pattern = `(a) (b) (c) (d) (e) (f) (g) (h) (i) (j) (k)`;
    assert(substituteFirstMatch(text, pattern, "[$10][$11][$1]") == "[j][k][a]");
}

unittest {
    // The security contract across the seam: a capture containing shell
    // metacharacters survives matching verbatim, and the quoted substitution
    // renders it a single inert word. Mirrors the attack in docs/security.md.
    string sq(string s) {
        import std.array : replace;
        return "'" ~ s.replace("'", `'\''`) ~ "'";
    }
    auto m = collectTriggerMatches(`Build failed: oops"; rm -rf ~; #`,
        [mk(`failed: (.+)$`)]);
    assert(m.length == 1);
    string cmd = replaceMatchTokensQuoted(`notify-send "Build failed" $1`,
        m[0].groups, &sq);
    // The whole payload lands inside a single quoted word, so the `;` is a
    // literal character rather than a command separator.
    assert(cmd == `notify-send "Build failed" 'oops"; rm -rf ~; #'`);
}
