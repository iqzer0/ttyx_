/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/customtitle.d. GtkD -> giD notes:
 *  - gtkc.glib raw C (g_timeout_add + extern(C) trampoline + g_source_remove)
 *    -> delegate-native glib.global.timeoutAdd(PRIORITY_DEFAULT, ms, dlg)
 *    (giD GC-roots the closure internally, threads.d pattern) and
 *    glib.source.Source.remove(tag); the static extern(C) timeoutCallback is
 *    gone — its body lives in the timeout delegate.
 *  - gobject.Signals.handlerBlock/handlerUnblock -> free functions
 *    gobject.global.signalHandlerBlock/signalHandlerUnblock.
 *  - GtkD's generic gdk.Event -> typed event structs: button signals get
 *    gdk.event_button.EventButton (.button/.state/.type fields, no
 *    getEventType()/event.button dance), key-press gets
 *    gdk.event_key.EventKey (.keyval field, no out-param getKeyval), focus-out
 *    gets gdk.event_focus.EventFocus.
 *  - `new Value(500)` + getSettings().getProperty(GTK_DOUBLE_CLICK_TIME, v)
 *    -> giD typed property getSettings().gtkDoubleClickTime (gobject.Value
 *    and the GTK_DOUBLE_CLICK_TIME constant are no longer needed; the GtkD
 *    500 fallback only ever seeded a Value that GTK always overwrote).
 *  - gtk.Version.checkVersion -> gtk.global.checkVersion (same null-on-ok
 *    string contract).
 *  - addOn* -> connect* (connectButtonPressEvent/connectButtonReleaseEvent/
 *    connectKeyPressEvent/connectFocusOutEvent/connectDestroy);
 *    ConnectFlags.AFTER -> Yes.After; GSettings.addOnChanged ->
 *    connectChanged(null, dlg) (detail parameter first, null = all keys).
 *  - GdkKeysyms.GDK_* -> gdk.types.KEY_*; enums PascalCase: Align.Fill/
 *    Center, EllipsizeMode.Start (pango.types), EventType.DoubleButtonPress,
 *    ModifierType.ControlMask.
 */
module gx.ttyx.customtitle;

import std.experimental.logger;
import std.typecons : Yes;

import gdk.types : ModifierType, KEY_Escape, KEY_Return;

import gid.basictypes : gulong;

import gio.settings : GSettings = Settings;

import glib.global : timeoutAdd;
import glib.source : Source;
import glib.types : PRIORITY_DEFAULT;

import gobject.global : signalHandlerBlock, signalHandlerUnblock;

import gtk.entry : Entry;
import gtk.event_controller_focus : EventControllerFocus;
import gtk.event_controller_key : EventControllerKey;
import gtk.gesture_click : GestureClick;
import gtk.global : checkVersion;
import gtk.label : Label;
import gtk.stack : Stack;
import gtk.types : Align;
import gtk.widget : Widget;

import pango.types : EllipsizeMode;

import gx.gtk.util;
import gx.i18n.l10n;

import gx.ttyx.common;
import gx.ttyx.constants;
import gx.ttyx.preferences;
import gx.ttyx.prefeditor.titleeditor;

/**
 * Custom title for AppWindow that allows the user
 * to click on the label in the headerbar and edit
 * the application title directly. Note this feature
 * is not available when CSD is disabled.
 */
public class CustomTitle: Stack {

private:
    enum PAGE_LABEL = "label";
    enum PAGE_EDIT = "edit";

    Entry eTitle;
    EventControllerFocus focusController;
    Label lblTitle;

    uint timeoutID;

    bool buttonDown;

    TitleEditBox titleEditor;

    gulong focusOutHandlerId;

    GSettings gsSettings;
    bool controlRequired;

    void createUI() {
        setHalign(Align.Fill);

        lblTitle = new Label(_(APPLICATION_NAME));
        lblTitle.setHalign(Align.Center);
        lblTitle.getStyleContext().addClass("title");
        lblTitle.setEllipsize(EllipsizeMode.Start);
        // GTK4: GtkEventBox is gone — any widget takes controllers directly, so
        // the label itself carries the click gesture. setButton(1) restricts it
        // to the primary button, which replaces the `event.button != PRIMARY`
        // checks the GTK3 handlers opened with.
        GestureClick clickGesture = new GestureClick();
        clickGesture.setButton(1);
        clickGesture.connectPressed(&onButtonPress);
        clickGesture.connectReleased(&onButtonRelease);
        lblTitle.addController(clickGesture);
        lblTitle.setHalign(Align.Fill);
        addNamed(lblTitle, PAGE_LABEL);

        eTitle = new Entry();
        eTitle.setWidthChars(5);
        eTitle.setHexpand(true);
        EventControllerKey keyController = new EventControllerKey();
        keyController.connectKeyPressed(delegate bool(uint keyval, uint keycode, ModifierType state, EventControllerKey c) {
            switch (keyval) {
                case KEY_Escape:
                    setViewMode(ViewMode.LABEL);
                    onCancelEdit.emit();
                    return true;
                case KEY_Return:
                    onTitleChange.emit(eTitle.getText());
                    setViewMode(ViewMode.LABEL);
                    return true;
                default:
            }
            return false;
        });
        eTitle.addController(keyController);
        // GTK4: focus-out-event -> EventControllerFocus.leave. The handler ID is
        // kept for block/unblock, but note it now belongs to the CONTROLLER —
        // signalHandlerBlock must be given focusController, not eTitle.
        focusController = new EventControllerFocus();
        focusOutHandlerId = focusController.connectLeave(&onFocusOut, Yes.After);
        eTitle.addController(focusController);
        if (gtkAtLeast(3, 16, 0)) {
            titleEditor = createTitleEditHelper(eTitle, TitleEditScope.WINDOW);
            titleEditor.onPopoverShow.connect(&onPopoverShow);
            titleEditor.onPopoverClosed.connect(&onPopoverClosed);
            addNamed(titleEditor, PAGE_EDIT);
        } else {
            addNamed(eTitle, PAGE_EDIT);
        }
        setViewMode(ViewMode.LABEL);
    }

    void onButtonRelease(int nPress, double x, double y, GestureClick gesture) {
        trace("Button release");
        // The gesture is bound to the primary button via setButton(1), so the
        // GTK3 `event.button != PRIMARY` check is implied.
        if (!buttonDown) {
            tracef("Ignoring release %b", buttonDown);
            return;
        }
        ModifierType state = gesture.getCurrentEventState();
        if (controlRequired && !(state & ModifierType.ControlMask)) {
            tracef("No control modifier, ignoring: %d", state);
            return;
        }
        removeTimeout();

        uint doubleClickTime = getSettings().gtkDoubleClickTime;
        timeoutID = timeoutAdd(PRIORITY_DEFAULT, doubleClickTime, delegate bool() {
            trace("Timeout callback received");
            doEdit();
            timeoutID = 0;
            return false;
        });
        buttonDown = false;
    }

    void onButtonPress(int nPress, double x, double y, GestureClick gesture) {
        // GTK4: double-click is nPress == 2, not a separate event type.
        if (nPress == 2) {
            trace("Double click press");
            buttonDown = false;
            removeTimeout();
        } else {
            trace("Single click press");
            buttonDown = true;
        }
    }

    void onFocusOut(EventControllerFocus controller) {
        trace("Focus out");
        removeTimeout();
        setViewMode(ViewMode.LABEL);
        onCancelEdit.emit();
    }

    enum ViewMode {LABEL, EDITOR}

    void setViewMode(ViewMode mode) {
        final switch (mode) {
            case ViewMode.LABEL:
                setVisibleChildName(PAGE_LABEL);
                setHexpand(false);
                break;
            case ViewMode.EDITOR:
                setHexpand(true);
                setVisibleChildName(PAGE_EDIT);
                eTitle.grabFocus();
        }
    }

    void doEdit() {
        buttonDown = false;

        string value;
        CumulativeResult!string result = new CumulativeResult!string();
        onEdit.emit(result);
        if (result.getResults().length == 0) return;
        else value = result.getResults()[0];

        if (value.length > 0) {
            eTitle.setText(value);
        }
        setViewMode(ViewMode.EDITOR);
    }

    void removeTimeout() {
        if (timeoutID > 0) {
            Source.remove(timeoutID);
            timeoutID = 0;
        }
    }

    void onPopoverShow() {
        trace("Popover showing");
        signalHandlerBlock(focusController, focusOutHandlerId);
    }

    void onPopoverClosed() {
        trace("Popover closing");
        signalHandlerUnblock(focusController, focusOutHandlerId);
    }

public:
    this() {
        super();
        gsSettings = new GSettings(SETTINGS_ID);
        gsSettings.connectChanged(null, delegate(string key, GSettings gs) {
            if (key == SETTINGS_CONTROL_CLICK_TITLE_KEY) {
                controlRequired = gsSettings.getBoolean(SETTINGS_CONTROL_CLICK_TITLE_KEY);
            }
        });
        controlRequired = gsSettings.getBoolean(SETTINGS_CONTROL_CLICK_TITLE_KEY);
        createUI();
        connectDestroy(delegate() {
            removeTimeout();
            gsSettings = null; // GTK4/giD: no ObjectG.destroy; dropping the reference releases it
            gsSettings = null;
        });
    }

    @property string title() {
        return lblTitle.getText();
    }

    @property void title(string title) {
        lblTitle.setText(title);
    }

    GenericEvent!() onCancelEdit;

    GenericEvent!(CumulativeResult!string) onEdit;

    GenericEvent!(string) onTitleChange;
}
