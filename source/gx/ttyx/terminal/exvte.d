/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/exvte.d. Differences from GtkD:
 *   - vtePasteText: giD binds vte_terminal_paste_text natively, so the
 *     GtkD-3.10 compatibility shim (Linker + __gshared function pointer)
 *     is gone — it is a plain call to Terminal.pasteText.
 *   - The patched-VTE signals (notification-received /
 *     terminal-screen-changed) are connected with hand-written closure
 *     marshals mirroring giD's generated connect* methods (DClosure +
 *     connectSignalClosure, signal args first, instance last). The GtkD
 *     DelegateWrapper/extern(C)-callback machinery is gone; availability is
 *     still probed with signalLookup, as in the gx.gtk.vte port.
 *   - vte_terminal_get/set_disable_bg_draw exist only in patched VTE builds,
 *     so they are resolved at runtime via dlsym(RTLD_DEFAULT) — a link-time
 *     extern(C) would fail against standard VTE. Null-guarded: getDisableBGDraw
 *     returns false and setDisableBGDraw is a no-op on standard VTE.
 *   - VTE enums come from vte.types with PascalCase members.
 */
module gx.ttyx.terminal.exvte;

import core.sys.posix.unistd;

import std.experimental.logger;
import std.typecons : Tuple;

import gid.basictypes : gulong;
import gid.gid : Flag, gidInvokeCallbackExceptionHandler;

import gobject.dclosure : DClosure, DGClosure;
import gobject.global : signalLookup;
import gobject.value : getVal;
import gobject.c.types : GClosure, GValue;

import vte.terminal : Terminal;
import vte.types : CursorBlinkMode, CursorShape, EraseBinding, TextBlinkMode;
import vte.c.types : VteTerminal;

import gx.ttyx.constants;
import gx.ttyx.terminal.util;

enum TerminalScreen {
    NORMAL = 0,
    ALTERNATE = 1
};

/**
 * Extends the giD VTE widget to support various patches
 * which provide additional features when available.
 */
class ExtendedVTE : Terminal {

private:
    bool ignoreFirstNotification = true;

public:

    /**
	 * Sets our main struct and passes it to the parent class.
	 */
    this(void* ptr, Flag!"Take" take) {
        super(ptr, take);
    }

    /**
	 * Creates a new terminal widget.
	 */
    this() {
        super();
    }

    debug(Destructors) {
        ~this() {
            import std.stdio: writeln;
            writeln("******** VTE Destructor");
        }
    }

    /**
     * Emitted when a process running in the terminal wants to
     * send a notification to the desktop environment (patched VTE only).
     *
     * Callback: void delegate(string summary, string bod, Terminal terminal)
     *
     * Returns the signal handler id, or 0 when the running VTE does not
     * carry the notification patch.
     */
    gulong addOnNotificationReceived(void delegate(string, string, Terminal) dlg) {
        alias T = typeof(dlg);
        if (signalLookup("notification-received", Terminal._getGType()) == 0)
            return 0;

        extern(C) static void _cmarshal(GClosure* _closure, GValue* _returnValue, uint _nParams, const(GValue)* _paramVals, void* _invocHint, void* _marshalData) nothrow
        {
            assert(_nParams == 3, "Unexpected number of signal parameters");
            auto _dClosure = cast(DGClosure!T*)_closure;
            Tuple!(string, string, Terminal) _paramTuple;
            _paramTuple[0] = getVal!(string)(&_paramVals[1]);
            _paramTuple[1] = getVal!(string)(&_paramVals[2]);
            _paramTuple[2] = getVal!(Terminal)(&_paramVals[0]);
            try
            {
                _dClosure.cb(_paramTuple[]);
            }
            catch (Exception e)
            {
                gidInvokeCallbackExceptionHandler(e, "gx.ttyx.terminal.exvte.notificationReceived");
            }
        }

        auto closure = new DClosure(dlg, &_cmarshal);
        return connectSignalClosure("notification-received", closure);
    }

    /**
     * Emitted when the terminal switches between the normal and the
     * alternate screen (patched VTE only).
     *
     * Callback: void delegate(int screen, Terminal terminal)
     *
     * Returns the signal handler id, or 0 when the running VTE does not
     * carry the screen-changed patch.
     */
    gulong addOnTerminalScreenChanged(void delegate(int, Terminal) dlg) {
        alias T = typeof(dlg);
        if (signalLookup("terminal-screen-changed", Terminal._getGType()) == 0)
            return 0;

        extern(C) static void _cmarshal(GClosure* _closure, GValue* _returnValue, uint _nParams, const(GValue)* _paramVals, void* _invocHint, void* _marshalData) nothrow
        {
            assert(_nParams == 2, "Unexpected number of signal parameters");
            auto _dClosure = cast(DGClosure!T*)_closure;
            Tuple!(int, Terminal) _paramTuple;
            _paramTuple[0] = getVal!(int)(&_paramVals[1]);
            _paramTuple[1] = getVal!(Terminal)(&_paramVals[0]);
            try
            {
                _dClosure.cb(_paramTuple[]);
            }
            catch (Exception e)
            {
                gidInvokeCallbackExceptionHandler(e, "gx.ttyx.terminal.exvte.terminalScreenChanged");
            }
        }

        auto closure = new DClosure(dlg, &_cmarshal);
        return connectSignalClosure("terminal-screen-changed", closure);
    }

    public bool getDisableBGDraw() {
        if (p_vte_terminal_get_disable_bg_draw is null)
            return false;
        return p_vte_terminal_get_disable_bg_draw(cast(VteTerminal*) _cPtr) != 0;
    }

    public void setDisableBGDraw(bool isDisabled) {
        if (p_vte_terminal_set_disable_bg_draw is null)
            return;
        p_vte_terminal_set_disable_bg_draw(cast(VteTerminal*) _cPtr, isDisabled);
    }

    /**
     * Returns the child pid running in the terminal or -1
     * if no child pid is running. May also return the VTE gpid
     * as well which also indicates no child process.
     */
    pid_t getChildPid() {
        if (isFlatpak()) {
            warning("getChildPid should not be called from a Flatpak environment.");
            return -1;
        } else {
            if (getPty() is null)
                return false;
            return tcgetpgrp(getPty().getFd());
        }
    }
}

/**
 * Sends text to the terminal as if pasted. giD binds
 * vte_terminal_paste_text natively (the GtkD 3.10.x compatibility shim
 * this function used to carry is no longer needed).
 */
void vtePasteText(ExtendedVTE terminal, string text) {
    terminal.pasteText(text);
}

private:

// vte_terminal_get/set_disable_bg_draw exist only in patched VTE builds
// (e.g. Fedora's). Resolve them at runtime so linking against standard VTE
// still works; the accessors above null-guard.
__gshared extern(C) {
    int function(VteTerminal* terminal) p_vte_terminal_get_disable_bg_draw;
    void function(VteTerminal* terminal, int isDisabled) p_vte_terminal_set_disable_bg_draw;
}

shared static this() {
    import core.sys.linux.dlfcn : RTLD_DEFAULT;
    import core.sys.posix.dlfcn : dlsym;

    p_vte_terminal_get_disable_bg_draw = cast(typeof(p_vte_terminal_get_disable_bg_draw))
        dlsym(RTLD_DEFAULT, "vte_terminal_get_disable_bg_draw");
    p_vte_terminal_set_disable_bg_draw = cast(typeof(p_vte_terminal_set_disable_bg_draw))
        dlsym(RTLD_DEFAULT, "vte_terminal_set_disable_bg_draw");
}

// ---------------------------------------------------------------------------
// VTE enum conversion helpers
// ---------------------------------------------------------------------------

package:

import gx.ttyx.preferences;

/// Convert a text blink mode settings string to VTE enum.
TextBlinkMode getTextBlinkMode(string mode) {
    import std.algorithm : countUntil;
    long i = countUntil(SETTINGS_PROFILE_TEXT_BLINK_MODE_VALUES, mode);
    return cast(TextBlinkMode) i;
}

/// Convert a cursor blink mode settings string to VTE enum.
CursorBlinkMode getBlinkMode(string mode) {
    import std.algorithm : countUntil;
    long i = countUntil(SETTINGS_PROFILE_CURSOR_BLINK_MODE_VALUES, mode);
    return cast(CursorBlinkMode) i;
}

/// Convert an erase binding settings string to VTE enum.
EraseBinding getEraseBinding(string binding) {
    import std.algorithm : countUntil;
    long i = countUntil(SETTINGS_PROFILE_ERASE_BINDING_VALUES, binding);
    return cast(EraseBinding) i;
}

/// Convert a cursor shape settings string to VTE enum.
CursorShape getCursorShape(string shape) {
    final switch (shape) {
    case SETTINGS_PROFILE_CURSOR_SHAPE_BLOCK_VALUE:
        return CursorShape.Block;
    case SETTINGS_PROFILE_CURSOR_SHAPE_IBEAM_VALUE:
        return CursorShape.Ibeam;
    case SETTINGS_PROFILE_CURSOR_SHAPE_UNDERLINE_VALUE:
        return CursorShape.Underline;
    }
}

// ---------------------------------------------------------------------------
// Unit tests for VTE enum converters
// ---------------------------------------------------------------------------

/// Test: getCursorShape converts all shape values.
unittest {
    assert(getCursorShape(SETTINGS_PROFILE_CURSOR_SHAPE_BLOCK_VALUE) == CursorShape.Block);
    assert(getCursorShape(SETTINGS_PROFILE_CURSOR_SHAPE_IBEAM_VALUE) == CursorShape.Ibeam);
    assert(getCursorShape(SETTINGS_PROFILE_CURSOR_SHAPE_UNDERLINE_VALUE) == CursorShape.Underline);
}
