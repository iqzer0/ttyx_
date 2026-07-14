/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/shortcuts.d. GtkD -> giD notes:
 *  - The raw gtkc.gobject import + `new ObjectG(ShortcutsShortcut.getType(),
 *    ["title","accelerator"], [Value, Value])` construct-property dance is
 *    replaced by giD's generated fluent builder:
 *    `ShortcutsShortcut.builder().title(t).accelerator(a).build()` (which
 *    g_object_new_with_properties's under the hood), so gobject.Value is gone.
 *  - `Builder.addFromResource` throws glib.error.ErrorWrap on failure in giD
 *    (it also returns 0), so the failure check is a try/catch instead of `!`.
 *  - `Builder.getObject` returns the most-derived registered wrapper
 *    (ObjectWrap._getDObject on the object's actual GType), so the plain
 *    `cast(ShortcutsShortcut)` / `cast(ShortcutsGroup)` / `cast(ShortcutsWindow)`
 *    downcasts carry over unchanged.
 *  - `ss.setProperty("accelerator", accelName)` carries over verbatim via
 *    ObjectWrap's templated setProperty!(string).
 */
module gx.ttyx.shortcuts;

import std.algorithm;
import std.experimental.logger;
import std.path;

import gio.settings : GSettings = Settings;

import glib.error : ErrorWrap;

import gtk.builder : Builder;
import gtk.shortcuts_group : ShortcutsGroup;
import gtk.shortcuts_shortcut : ShortcutsShortcut;
import gtk.shortcuts_window : ShortcutsWindow;

import gx.gtk.actions;
import gx.i18n.l10n;

import gx.ttyx.constants;
import gx.ttyx.preferences;

public:

ShortcutsWindow getShortcutWindow() {
    Builder builder = new Builder();
    builder.setTranslationDomain(TTYX_DOMAIN);
    try {
        if (!builder.addFromResource(SHORTCUT_UI_RESOURCE)) {
            error("Could not load shortcuts from " ~ SHORTCUT_UI_RESOURCE);
            return null;
        }
    } catch (ErrorWrap e) {
        error("Could not load shortcuts from " ~ SHORTCUT_UI_RESOURCE ~ ": " ~ e.msg);
        return null;
    }
    GSettings gsShortcuts = new GSettings(SETTINGS_KEY_BINDINGS_ID);
    string[] keys = gsShortcuts.listKeys();
    foreach(key; keys) {
        ShortcutsShortcut ss = cast(ShortcutsShortcut) builder.getObject(key);
        if (ss !is null) {
            string accelName = gsShortcuts.getString(key);
            if (accelName == SHORTCUT_DISABLED) accelName.length = 0;
            ss.setProperty("accelerator", accelName);
        } else {
            trace("Could not find shortcut for " ~ key);
        }
    }

    // Add Profile shortcuts to window
    ShortcutsGroup sgProfile = cast(ShortcutsGroup) builder.getObject("profile");
    if (sgProfile !is null) {
        string[] uuids = prfMgr.getProfileUUIDs();
        foreach (uuid; uuids) {
            GSettings gsProfile = prfMgr.getProfileSettings(uuid);
            if (gsProfile !is null) {
                string accelName = gsProfile.getString(SETTINGS_PROFILE_SHORTCUT_KEY);
                if (accelName == SHORTCUT_DISABLED) accelName.length = 0;
                trace("Create ShortcutShortcut");
                ShortcutsShortcut ss = ShortcutsShortcut.builder()
                        .title(gsProfile.getString(SETTINGS_PROFILE_VISIBLE_NAME_KEY))
                        .accelerator(accelName)
                        .build();
                if (ss !is null) {
                    sgProfile.add(ss);
                } else {
                    trace("Profile ShortcutShortcut is null");
                }
            }
        }
    } else {
        trace("Didn't find profile ShortcutGroup");
    }

    return cast(ShortcutsWindow) builder.getObject("shortcuts-ttyx");
}
