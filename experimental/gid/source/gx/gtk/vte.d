/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/vte.d.
 *
 * Version + keystroke helpers translate cleanly. Feature detection needed a
 * partial reimplementation:
 *  - The Tilix-patched signals (notification-received / terminal-screen-changed)
 *    are still detected at runtime via gobject.global.signalLookup against the
 *    VTE Terminal GType — this works under giD too.
 *  - DISABLE_BACKGROUND_DRAW was detected in GtkD by inspecting linker load
 *    failures for the patched `vte_terminal_get_disable_bg_draw` symbol. giD
 *    binds only standard VTE (that symbol isn't in VTE's GIR) and has no linker
 *    introspection, so the feature is reported unavailable; isVTEBackgroundDraw-
 *    Enabled() falls back to the VTE version check, which covers modern VTE.
 */
module gx.gtk.vte;

import std.format;

import gdk.types : ModifierType, KEY_Page_Up, KEY_Page_Down, KEY_Home, KEY_End, KEY_Up, KEY_Down;

import gobject.global : signalLookup;
import gobject.types : GType;

import vte.terminal : Terminal;
import vte.global : getMajorVersion, getMinorVersion;

// Constants used to version VTE features
int[2] VTE_VERSION_MINIMAL = [0, 46];
int[2] VTE_VERSION_COPY_AS_HTML = [0, 49];
int[2] VTE_VERSION_HYPERLINK = [0, 49];
int[2] VTE_VERSION_BACKGROUND_OPERATOR = [0, 51];
int[2] VTE_VERSION_TEXT_BLINK_MODE = [0, 51];
int[2] VTE_VERSION_BOLD_IS_BRIGHT = [0, 51];
int[2] VTE_VERSION_CELL_SCALE = [0, 51];
int[2] VTE_VERSION_BACKGROUND_GET_COLOR = [0, 53];

/**
 * PCRE2 constants for VTE Regex
 */
enum PCRE2Flags : uint {
    ALLOW_EMPTY_CLASS   = 0x00000001u,  /* C       */
    ALT_BSUX            = 0x00000002u,  /* C       */
    PCRE2_AUTO_CALLOUT  = 0x00000004u,  /* C       */
    CASELESS            = 0x00000008u,  /* C       */
    DOLLAR_ENDONLY      = 0x00000010u,  /*   J M D */
    DOTALL              = 0x00000020u,  /* C       */
    DUPNAMES            = 0x00000040u,  /* C       */
    EXTENDED            = 0x00000080u,  /* C       */
    FIRSTLINE           = 0x00000100u,  /*   J M D */
    MATCH_UNSET_BACKREF = 0x00000200u,  /* C J M   */
    MULTILINE           = 0x00000400u,  /* C       */
    NEVER_UCP           = 0x00000800u,  /* C       */
    NEVER_UTF           = 0x00001000u,  /* C       */
    NO_AUTO_CAPTURE     = 0x00002000u,  /* C       */
    NO_AUTO_POSSESS     = 0x00004000u,  /* C       */
    NO_DOTSTAR_ANCHOR   = 0x00008000u,  /* C       */
    NO_START_OPTIMIZE   = 0x00010000u,  /*   J M D */
    UCP                 = 0x00020000u,  /* C J M D */
    UNGREEDY            = 0x00040000u,  /* C       */
    UTF                 = 0x00080000u,  /* C J M D */
    ANCHORED            = 0x80000000u,
    NO_UTF_CHECK        = 0x40000000u
}

/**
 * Determines if the key value and modifier represent a hard coded key sequence
 * that VTE handles internally.
 */
bool isVTEHandledKeystroke(uint keyval, ModifierType modifier) {
    if ((keyval == KEY_Page_Up ||
        keyval == KEY_Page_Down ||
        keyval == KEY_Home ||
        keyval == KEY_End) && (ModifierType.ShiftMask & modifier)) {
            return true;
        }
    if ((keyval == KEY_Up ||
        keyval == KEY_Down) &&
        (ModifierType.ShiftMask & modifier) &&
        (ModifierType.ControlMask & modifier)) {
            return true;
        }
    return false;
}

/**
 * Check if the VTE version is the same or higher then requested
 */
bool checkVTEVersionNumber(uint requiredMajor, uint requiredMinor) {
    return vteMajorVersion > requiredMajor || (vteMajorVersion == requiredMajor && vteMinorVersion >= requiredMinor);
}

/**
 * Check version number where first element of array is major and second is minor
 */
bool checkVTEVersion(int[2] versionNum) {
    return checkVTEVersionNumber(versionNum[0], versionNum[1]);
}

string getVTEVersion() {
    return format("%d.%d", vteMajorVersion, vteMinorVersion);
}

enum TerminalFeature {
    EVENT_NOTIFICATION,
    EVENT_SCREEN_CHANGED,
    DISABLE_BACKGROUND_DRAW
}

/**
 * Determine which terminal features are supported.
 */
bool checkVTEFeature(TerminalFeature feature) {
    // Initialized features if not done yet, can't do it statically
    // due to need for GTK to load first
    if (!featuresInitialized) {
        // Registering the VTE Terminal GType makes its (possibly patched)
        // signals discoverable via signalLookup.
        GType terminalType = Terminal._getGType();

        // Check if patched events are available
        string[] events = ["notification-received", "terminal-screen-changed"];
        foreach (i, event; events) {
            bool supported = (signalLookup(event, terminalType) != 0);
            terminalFeatures[cast(TerminalFeature) i] = supported;
        }

        // See the module header: the patched disable-background-draw symbol is
        // not bound by giD (standard-VTE GIR), so report it unavailable. The
        // caller falls back to the version check for modern VTE.
        terminalFeatures[TerminalFeature.DISABLE_BACKGROUND_DRAW] = false;

        featuresInitialized = true;
    }
    if (feature in terminalFeatures) {
        return terminalFeatures[feature];
    } else {
        return false;
    }
}

bool isVTEBackgroundDrawEnabled() {
    return checkVTEFeature(TerminalFeature.DISABLE_BACKGROUND_DRAW) || checkVTEVersion(VTE_VERSION_BACKGROUND_OPERATOR);
}

private:

uint vteMajorVersion = 0;
uint vteMinorVersion = 46;

bool featuresInitialized = false;
bool[TerminalFeature] terminalFeatures;

static this() {
    // Get version numbers
    try {
        vteMajorVersion = getMajorVersion();
        vteMinorVersion = getMinorVersion();
    }
    catch (Error) {
        //Ignore, means VTE doesn't support version API, default to 46
    }
}

@system
unittest {
    vteMajorVersion = 0;
    vteMinorVersion = 46;

    assert(!checkVTEVersionNumber(0, 50));
    assert(checkVTEVersionNumber(0, 46));
    assert(checkVTEVersionNumber(0, 42));

    vteMajorVersion = 1;
    vteMinorVersion = 0;
    assert(checkVTEVersionNumber(1, 0));
    assert(!checkVTEVersionNumber(1, 1));
    assert(checkVTEVersionNumber(0, 9));

    vteMajorVersion = getMajorVersion();
    vteMinorVersion = getMinorVersion();
    assert(checkVTEVersion(VTE_VERSION_MINIMAL));
}
