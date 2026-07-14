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

import gdk.event_button : EventButton;
import gdk.event_focus : EventFocus;
import gdk.event_key : EventKey;
import gdk.types : EventType, ModifierType, KEY_Escape, KEY_Return;

import gid.basictypes : gulong;

import gio.settings : GSettings = Settings;

import glib.global : timeoutAdd;
import glib.source : Source;
import glib.types : PRIORITY_DEFAULT;

import gobject.global : signalHandlerBlock, signalHandlerUnblock;

import gtk.entry : Entry;
import gtk.event_box : EventBox;
import gtk.global : checkVersion;
import gtk.label : Label;
import gtk.stack : Stack;
import gtk.types : Align;
import gtk.widget : Widget;

import pango.types : EllipsizeMode;

import gx.gtk.util;
import gx.gtk.events;
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
    EventBox eb;
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
        eb = new EventBox();
        connectGdkEvent!EventButton(eb, "button-press-event", &onButtonPress);
        connectGdkEvent!EventButton(eb, "button-release-event", &onButtonRelease);
        eb.add(lblTitle);
        eb.setHalign(Align.Fill);
        addNamed(eb, PAGE_LABEL);

        eTitle = new Entry();
        eTitle.setWidthChars(5);
        eTitle.setHexpand(true);
        connectGdkEvent!EventKey(eTitle, "key-press-event", delegate bool(EventKey event, Widget widget) {
            switch (event.keyval) {
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
        focusOutHandlerId = connectGdkEvent!EventFocus(eTitle, "focus-out-event", &onFocusOut, Yes.After);
        if (checkVersion(3, 16, 0).length == 0) {
            titleEditor = createTitleEditHelper(eTitle, TitleEditScope.WINDOW);
            titleEditor.onPopoverShow.connect(&onPopoverShow);
            titleEditor.onPopoverClosed.connect(&onPopoverClosed);
            addNamed(titleEditor, PAGE_EDIT);
        } else {
            addNamed(eTitle, PAGE_EDIT);
        }
        setViewMode(ViewMode.LABEL);
    }

    bool onButtonRelease(EventButton event, Widget widget) {
        trace("Button release");
        if (event.button != MouseButton.PRIMARY || !buttonDown) {
            tracef("Ignoring release %b", buttonDown);
            return false;
        }
        if (controlRequired && !(event.state & ModifierType.ControlMask)) {
            tracef("No control modifier, ignoring: %d", event.state);
             return false;
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
        return false;
    }

    bool onButtonPress(EventButton event, Widget widget) {
        if (event.button != MouseButton.PRIMARY) return false;

        if (event.type == EventType.DoubleButtonPress) {
            trace("Double click press");
            buttonDown = false;
            removeTimeout();
        } else {
            trace("Single click press");
            buttonDown = true;
        }
        return false;
    }

    bool onFocusOut(EventFocus event, Widget widget) {
        trace("Focus out");
        removeTimeout();
        setViewMode(ViewMode.LABEL);
        onCancelEdit.emit();
        return false;
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
        signalHandlerBlock(eTitle, focusOutHandlerId);
    }

    void onPopoverClosed() {
        trace("Popover closing");
        signalHandlerUnblock(eTitle, focusOutHandlerId);
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
            gsSettings.destroy();
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
