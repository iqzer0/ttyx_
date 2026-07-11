/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/i18n/l10n.d.
 *
 * GtkD wrapped gettext in a `glib.Internationalization` class
 * (`Internationalization.dgettext` / `.dpgettext2`); giD exposes the same
 * calls as free functions in `glib.global`.
 */
module gx.i18n.l10n;

import glib.global : dgettext, dpgettext2;

void textdomain(string domain) {
    _textdomain = domain;
}

/**
 * Localize text using GLib integration with GNU gettext
 * and po files for translation
 */
string _(string text) {
    return dgettext(_textdomain, text);
}

/**
 * Uses gettext to get the translation for text in the given context.
 */
string C_(string context, string text) {
    return dpgettext2(_textdomain, context, text);
}

/**
 * Only marks a string for translation; returns it unchanged. Call _() at
 * runtime to get the translation.
 */
string N_(string text) {
    return text;
}

private:
string _textdomain;
