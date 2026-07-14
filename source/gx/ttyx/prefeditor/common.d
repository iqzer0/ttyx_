/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/prefeditor/common.d. Differences from GtkD:
 *   - snake_case module imports; enums PascalCase in gtk.types
 *     (GtkAlign.START → Align.Start, ResponseType.APPLY → ResponseType.Apply).
 *   - new Button(label) → Button.newWithLabel(label);
 *     addOnClicked(delegate(Button){...}) → connectClicked(delegate(){...}).
 *   - gtk.Version.checkVersion (GtkD static class method) →
 *     gtk.global.checkVersion free function; returns null (not "") when
 *     compatible, so the `.length == 0` compatibility check carries over.
 *   - grid.getToplevel() returns the most-derived giD wrapper, so the plain
 *     cast(Window) downcast carries over unchanged.
 *   - Everything else (Grid.attach, GSettings.getStrv/setStrv, Dialog
 *     run/destroy/showAll, Label setters) is bound 1:1 by giD.
 */
module gx.ttyx.prefeditor.common;

import std.format;
import std.experimental.logger;

import gio.settings : GSettings = Settings;

import gtk.box : Box;
import gtk.button : Button;
import gtk.global : checkVersion;
import gtk.grid : Grid;
import gtk.label : Label;
import gtk.types : Align, ResponseType;
import gtk.window : Window;

import gx.gtk.vte;
import gx.i18n.l10n;

import gx.ttyx.preferences;
import gx.ttyx.prefeditor.advdialog;


/**
 * Creates the advanced UI (custom links, triggers) that is shared between
 * the preference and profile editor.
 *
 * Note need to use a delegate to get settings because in profile advdialog
 * the same UI is re-used but the profile settings object is switched. If we
 * don't use a delegate the references to the event handlers become pinned to
 * one object instance.
 */
void createAdvancedUI(Grid grid, ref uint row, GSettings delegate() scb, bool showTriggerLineSettings = false) {
    // Custom Links Section
    Label lblCustomLinks = new Label(format("<b>%s</b>", _("Custom Links")));
    lblCustomLinks.setUseMarkup(true);
    lblCustomLinks.setHalign(Align.Start);
    grid.attach(lblCustomLinks, 0, row, 3, 1);
    row++;

    string customLinksDescription = _("A list of user defined links that can be clicked on in the terminal based on regular expression definitions. Warning: clicked links execute shell commands with captured text substituted in. Under SSH or any remote session that text is attacker-controlled — only configure custom links for hosts you trust, and review templates for unquoted match-group substitutions.");
    grid.attach(createDescriptionLabel(customLinksDescription), 0, row, 2, 1);

    Button btnEditLink = Button.newWithLabel(_("Edit"));
    btnEditLink.setHalign(Align.Fill);
    btnEditLink.setValign(Align.Center);

    btnEditLink.connectClicked(delegate() {
        GSettings gs = scb();
        string[] links = gs.getStrv(SETTINGS_ALL_CUSTOM_HYPERLINK_KEY);
        EditCustomLinksDialog dlg = new EditCustomLinksDialog(cast(Window) grid.getToplevel(), links);
        scope (exit) {
            dlg.destroy();
        }
        dlg.showAll();
        if (dlg.run() == ResponseType.Apply) {
            gs.setStrv(SETTINGS_ALL_CUSTOM_HYPERLINK_KEY, dlg.getLinks());
        }
    });
    grid.attach(btnEditLink, 2, row, 1, 1);
    row++;

    if (checkVTEFeature(TerminalFeature.EVENT_SCREEN_CHANGED)) {
        // Triggers Section
        Label lblTriggers = new Label(format("<b>%s</b>", _("Triggers")));
        lblTriggers.setUseMarkup(true);
        lblTriggers.setHalign(Align.Start);
        lblTriggers.setMarginTop(12);
        grid.attach(lblTriggers, 0, row, 3, 1);
        row++;

        string triggersDescription = _("Triggers are regular expressions that are used to check against output text in the terminal. When a match is detected the configured action is executed. Warning: ExecuteCommand and RunProcess actions run shell commands with captured groups substituted in. Under SSH or any remote session terminal output is attacker-controlled — only configure these actions for hosts you trust.");
        grid.attach(createDescriptionLabel(triggersDescription), 0, row, 2, 1);

        Button btnEditTriggers = Button.newWithLabel(_("Edit"));
        btnEditTriggers.setHalign(Align.Fill);
        btnEditTriggers.setValign(Align.Center);

        btnEditTriggers.connectClicked(delegate() {
            GSettings gs = scb();
            EditTriggersDialog dlg = new EditTriggersDialog(cast(Window) grid.getToplevel(), gs, showTriggerLineSettings);
            scope (exit) {
                dlg.destroy();
            }
            dlg.showAll();
            if (dlg.run() == ResponseType.Apply) {
                gs.setStrv(SETTINGS_ALL_TRIGGERS_KEY, dlg.getTriggers());
            }
        });
        grid.attach(btnEditTriggers, 2, row, 1, 1);
        row++;
    }
}

/**
 * Create a description label that handles long lines
 */
Label createDescriptionLabel(string desc) {
    Label lblDescription = new Label(desc);
    lblDescription.setUseMarkup(true);
    lblDescription.setSensitive(false);
    lblDescription.setLineWrap(true);
    lblDescription.setHalign(Align.Start);
    // giD checkVersion returns null (not "") when compatible; .length == 0
    // covers both, matching the GtkD check.
    if (checkVersion(3, 16, 0).length == 0) {
        lblDescription.setXalign(0.0);
    }
    lblDescription.setMaxWidthChars(70);
    return lblDescription;
}
