/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/settings.d. GtkD -> giD:
 *  - GSettingsBindFlags (gtkc.giotypes) -> gio.types.SettingsBindFlags
 *  - gobject.ObjectG -> gobject.object.ObjectWrap
 *  - Settings.unbind is a STATIC method in giD (was an instance call)
 *  - the wrapper-validity probe getObjectGStruct() -> _cPtr
 */
module gx.gtk.settings;

import gio.types : SettingsBindFlags;
import gobject.object : ObjectWrap;
import gio.settings : GSettings = Settings;

/**
 * Bookkeeping class that keeps track of objects which are bound to a GSettings
 * object so they can be unbound later. It also supports deferred bindings where
 * a binding can be added but is not actually attached to a Settings object
 * until one is set.
 */
class BindingHelper {

private:
    Binding[] bindings;
    GSettings _settings;

    void bindAll() {
        if (_settings !is null) {
            foreach(binding; bindings) {
                _settings.bind(binding.key, binding.object, binding.property, binding.flags);
            }
        }
    }

    /**
     * Adds a binding to the list
     */
    void addBind(string key, ObjectWrap object, string property, SettingsBindFlags flags) {
        bindings ~= Binding(key, object, property, flags);
    }

public:

    this() {
    }

    this(GSettings settings) {
        this();
        _settings = settings;
    }

    /**
     * The current Settings object being used.
     */
    @property GSettings settings() {
        return _settings;
    }

    /**
     * Setting a new GSettings object will cause this class to unbind
     * previously set bindings and re-bind to the new settings automatically.
     */
    @property void settings(GSettings value) {
        if (value !is _settings) {
            if (_settings !is null && bindings.length > 0) unbind();
            _settings = value;
            if (_settings !is null) bindAll();
        }
    }

    /**
     * Add a binding to list and binds to Settings if it is set.
     */
    void bind(string key, ObjectWrap object, string property, SettingsBindFlags flags) {
        addBind(key, object, property, flags);
        if (settings !is null) {
            _settings.bind(key, object, property, flags);
        }
    }

    /**
     * Unbinds all added binds from settings object.
     * Checks that the bound object's GObject is still valid before
     * calling unbind, to avoid crashes during GTK dispose cascades
     * when widgets have already been finalized.
     */
    void unbind() {
        import core.memory : GC;

        if (_settings is null) return;
        // Disable GC during unbind: a defensive carry-over from the GtkD
        // version, where the D GC could finalize a wrapper mid-iteration and
        // leave its internal GObject pointer corrupt on GLib 2.84+.
        GC.disable();
        scope(exit) GC.enable();
        foreach(binding; bindings) {
            if (binding.object is null) continue;
            // Skip if the underlying GObject pointer is no longer set.
            if (binding.object._cPtr is null) continue;
            GSettings.unbind(binding.object, binding.property);
        }
    }

    /**
     * Unbinds all bindings and clears list of bindings.
     */
    void clear() {
        unbind();
        bindings.length = 0;
    }
}

private:

struct Binding {
    string key;
    ObjectWrap object;
    string property;
    SettingsBindFlags flags;
}
