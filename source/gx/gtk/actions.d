/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/actions.d. The pure string helpers and their unit
 * tests are unchanged. GtkD -> giD notes:
 *  - Accelerator parse/label are free functions in gtk.global.
 *  - ActionMapIF -> gio.action_map.ActionMap; SimpleAction stateful ctor is the
 *    static SimpleAction.newStateful; signals via connectActivate/ChangeState
 *    (delegate signature void(Variant, SimpleAction) matches GtkD).
 *  - Only gio.Application has getDefault; re-type it to gtk.Application via
 *    giD's ObjectWrap._getDObject re-wrap (a plain cast could see a base-typed
 *    wrapper) so setAccelsForAction is reachable.
 */
module gx.gtk.actions;

import std.experimental.logger;
import std.string;
import std.typecons : No;

import gio.action_map : ActionMap;
import gio.simple_action : SimpleAction;
import gio.settings : GSettings = Settings;
import gio.application : GioApplication = Application;

import glib.variant : GVariant = Variant;
import glib.variant_type : GVariantType = VariantType;

import gobject.object : ObjectWrap;

import gdk.types : ModifierType;

import gtk.global : acceleratorParse, acceleratorGetLabel;
import gtk.application : Application;

import gx.i18n.l10n;

private Application app = null;

enum SHORTCUT_DISABLED = N_("disabled");

/**
 * Convert an accelerator name to a label
 */
string acceleratorNameToLabel(string acceleratorName) {
    uint acceleratorKey;
    ModifierType acceleratorMods;
    acceleratorParse(acceleratorName, acceleratorKey, acceleratorMods);
    string label = acceleratorGetLabel(acceleratorKey, acceleratorMods);
    if (label == "") {
      label = _(SHORTCUT_DISABLED);
    }
    return label;
}

/**
 * Given an action prefix and id returns the detailed name
 */
string getActionDetailedName(string prefix, string id) {
    return prefix ~ "." ~ id;
}

/**
 * Returns the key for the corresponding prefix and id. The string
 * that is returned is the key to locate the shortcut in a
 * GSettings object
 */
string getActionKey(string prefix, string id) {
    return prefix ~ "-" ~ id;
}

/**
  * Given a GSettings key, returns the coresponding action prefix and id.
  */
void getActionNameFromKey(string key, out string prefix, out string id) {
    ptrdiff_t index = key.indexOf("-");
    if (index >= 0) {
        prefix = key[0 .. index];
        id = key[index + 1 .. $];
    }
}

string keyToDetailedActionName(string key) {
    string prefix, id;
    getActionNameFromKey(key, prefix, id);
    return prefix ~ "." ~ id;
}

/**
    * Adds a new action to the specified menu, looking up its accelerator in
    * GSettings under "{prefix}-{id}". This code from grestful.
    */
SimpleAction registerActionWithSettings(ActionMap actionMap, string prefix, string id, GSettings settings, void delegate(GVariant,
        SimpleAction) cbActivate = null, GVariantType type = null, GVariant state = null, void delegate(GVariant,
        SimpleAction) cbStateChange = null) {

    string[] shortcuts;
    try {
        string shortcut = settings.getString(getActionKey(prefix, id));
        if (shortcut.length > 0 && shortcut != SHORTCUT_DISABLED)
            shortcuts = [shortcut];
    }
    catch (Exception) {
        //TODO - This does not work, figure out to catch GLib-GIO-ERROR
        tracef("No shortcut for action %s.%s", prefix, id);
    }

    return registerAction(actionMap, prefix, id, shortcuts, cbActivate, type, state, cbStateChange);
}

/**
    * Adds a new action to the specified menu with an optional accelerator.
    * This code from grestful.
    */
SimpleAction registerAction(ActionMap actionMap, string prefix, string id, string[] accelerators = null, void delegate(GVariant,
        SimpleAction) cbActivate = null, GVariantType parameterType = null, GVariant state = null, void delegate(GVariant,
        SimpleAction) cbStateChange = null) {
    SimpleAction action;
    if (state is null)
        action = new SimpleAction(id, parameterType);
    else {
        action = SimpleAction.newStateful(id, parameterType, state);
    }

    if (cbActivate !is null)
        action.connectActivate(cbActivate);

    if (cbStateChange !is null)
        action.connectChangeState(cbStateChange);

    actionMap.addAction(action);

    if (accelerators.length > 0) {
        if (app is null) {
            GioApplication def = GioApplication.getDefault();
            if (def !is null)
                app = ObjectWrap._getDObject!(Application)(def._cPtr, No.Take);
        }
        if (app !is null) {
            app.setAccelsForAction(prefix.length == 0 ? id : getActionDetailedName(prefix, id), accelerators);
        } else {
            errorf("Accelerator for action %s could not be registered", id);
        }
    }
    return action;
}

// --------------------------------------------------------------------------
// Unit tests for action name parsing (pure — unchanged from the GtkD version)
// --------------------------------------------------------------------------

/// Test: getActionNameFromKey splits on first hyphen
unittest {
    string prefix, id;
    getActionNameFromKey("terminal-split-horizontal", prefix, id);
    assert(prefix == "terminal");
    assert(id == "split-horizontal");
}

/// Test: getActionDetailedName joins with dot
unittest {
    assert(getActionDetailedName("win", "close") == "win.close");
    assert(getActionDetailedName("terminal", "copy") == "terminal.copy");
}

/// Test: getActionKey joins with hyphen
unittest {
    assert(getActionKey("terminal", "split-horizontal") == "terminal-split-horizontal");
}

/// Test: keyToDetailedActionName converts hyphen key to dotted action name
unittest {
    assert(keyToDetailedActionName("terminal-split-horizontal") == "terminal.split-horizontal");
    assert(keyToDetailedActionName("win-close") == "win.close");
}

/// Test: getActionNameFromKey with no hyphen
unittest {
    string prefix, id;
    getActionNameFromKey("nohyphen", prefix, id);
    assert(prefix == "");
    assert(id == "");
}

/// Test: round-trip — key -> name -> key
unittest {
    string originalKey = "session-add-right";
    string prefix, id;
    getActionNameFromKey(originalKey, prefix, id);
    string reconstructed = getActionKey(prefix, id);
    assert(reconstructed == originalKey,
        "round-trip failed: " ~ reconstructed ~ " != " ~ originalKey);
}
