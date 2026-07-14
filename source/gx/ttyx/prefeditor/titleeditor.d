/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/prefeditor/titleeditor.d. GtkD -> giD notes:
 *  - gio.Menu/gio.SimpleAction(Group) -> snake_case modules; GMenu.append and
 *    appendSection are unchanged; SimpleActionGroup.insert carries over (giD
 *    still binds the deprecated g_simple_action_group_insert).
 *  - SimpleAction activate signal: addOnActivate -> connectActivate with the
 *    same void(Variant, SimpleAction) delegate shape.
 *  - Editable.insertText drops GtkD's explicit newTextLength parameter and
 *    takes the position by ref: insertText(value, position).
 *  - new Image(name, IconSize.MENU) -> static Image.newFromIconName(name,
 *    IconSize.Menu) (enums PascalCase in gtk.types).
 *  - MountOperation.showUri(null, uri, ts) + Main.getCurrentEventTime ->
 *    gtk.global.showUri(null, uri, gtk.global.getCurrentEventTime()).
 *  - addOnMap/addOnClosed/addOnDestroy -> connectMap/connectClosed/
 *    connectDestroy; ConnectFlags.AFTER -> Yes.After; unused Widget callback
 *    parameters dropped (giD accepts zero-arg delegates).
 */
module gx.ttyx.prefeditor.titleeditor;

import std.conv;
import std.experimental.logger;
import std.format;
import std.typecons : Yes;

import gio.simple_action : SimpleAction;
import gio.simple_action_group : SimpleActionGroup;
import gio.menu : GMenu = Menu;

import glib.variant : GVariant = Variant;

import gtk.box : Box;
import gtk.entry : Entry;
import gtk.global : getCurrentEventTime, showUri;
import gtk.image : Image;
import gtk.menu_button : MenuButton;
import gtk.popover_menu : PopoverMenu;
import gtk.types : IconSize, Orientation;

import gx.gtk.actions;

import gx.i18n.l10n;

import gx.ttyx.common;
import gx.ttyx.constants;

/**
 * Scope of the title to be edited
 */
enum TitleEditScope {WINDOW, SESSION, TERMINAL}

/**
 * Wraps an entry into a box that includes other
 * helper widgets to edit the title.
 */
TitleEditBox createTitleEditHelper(Entry entry, TitleEditScope tes) {
    return new TitleEditBox(entry, tes);
}


/**
 * Wraps an entry with helpers for editing various titles
 * like terminal title, window title, etc where variables can be used.
 *
 * Note that this editor is not supported in GTK 3.14 so version check it
 * before using it.
 */
class TitleEditBox: Box {
private:
    Entry entry;
    SimpleActionGroup sagVariables;

    enum ACTION_PREFIX = "variables";

    void createUI(TitleEditScope tes) {
        sagVariables = new SimpleActionGroup();
        this.insertActionGroup(ACTION_PREFIX, sagVariables);

        add(entry);

        MenuButton mbVariables = new MenuButton();
        mbVariables.add(Image.newFromIconName("pan-down-symbolic", IconSize.Menu));
        mbVariables.setFocusOnClick(false);
        mbVariables.setPopover(createPopover(tes));
        add(mbVariables);
    }

    /**
     * Create menu items from array for each section (window, session, terminal)
     */
    GMenu createItems(immutable(string[]) localized, immutable(string[]) values, string actionPrefix) {
        GMenu section = new GMenu();
        foreach(index, variable; localized) {
            string actionName = format("%s-%02d", actionPrefix, index);
            SimpleAction action = new SimpleAction(actionName, null);
            action.connectActivate(delegate(GVariant gv, SimpleAction sa) {
                string name = sa.getName();
                int i = to!int("" ~ name[$-2 .. $]);
                int position = entry.getPosition();
                string value = values[i];
                entry.insertText(value, position);
            });
            sagVariables.insert(action);
            section.append(_(variable), getActionDetailedName(ACTION_PREFIX, actionName));
        }
        return section;
    }

    /**
     * Create all menu items in popover to help editing menu items
     */
    PopoverMenu createPopover(TitleEditScope tes) {
        GMenu model = new GMenu();

        // Terminal items
        GMenu terminalSection = createItems(VARIABLE_TERMINAL_LOCALIZED, VARIABLE_TERMINAL_VALUES, "terminal");
        model.appendSection(_("Terminal"), terminalSection);

        //Session menu items
        if (tes == TitleEditScope.SESSION || tes == TitleEditScope.WINDOW) {
            GMenu sessionSection = createItems(VARIABLE_SESSION_LOCALIZED, VARIABLE_SESSION_VALUES, "session");
            model.appendSection(_("Session"), sessionSection);
        }

        //App menu items
        if (tes == TitleEditScope.WINDOW) {
            GMenu windowSection = createItems(VARIABLE_WINDOW_LOCALIZED, VARIABLE_WINDOW_VALUES, "window");
            model.appendSection(_("Window"), windowSection);
        }

        // Help Menu Item
        GMenu helpSection = new GMenu();
        SimpleAction saHelp = new SimpleAction("help", null);
        saHelp.connectActivate(delegate(GVariant gv, SimpleAction sa) {
            showUri(null, "https://gnunn1.github.io/tilix-web/manual/title/", getCurrentEventTime());
        });
        sagVariables.insert(saHelp);
        helpSection.append(_("Help"), getActionDetailedName(ACTION_PREFIX, "help"));
        model.appendSection(_("Help"), helpSection);

        PopoverMenu pm = new PopoverMenu();
        pm.connectMap(delegate() {
            onPopoverShow.emit();
        });
        pm.connectClosed(delegate() {
            entry.grabFocus();
            onPopoverClosed.emit();
        }, Yes.After);

        pm.bindModel(model, null);
        return pm;
    }


public:
    this(Entry entry, TitleEditScope tes) {
        super(Orientation.Horizontal, 0);
        this.entry = entry;
        getStyleContext().addClass("linked");
        setHexpand(true);
        createUI(tes);
        connectDestroy(delegate() {
            sagVariables.destroy();
            sagVariables = null;
        });
    }

    GenericEvent!() onPopoverShow;

    GenericEvent!() onPopoverClosed;

}
