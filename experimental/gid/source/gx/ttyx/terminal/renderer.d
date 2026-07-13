/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/renderer.d. Differences from GtkD:
 *  - gdk.RGBA class -> gdk.rgba.RGBA value struct: initColors() no longer
 *    allocates (assigns explicit RGBA(0,0,0,0) — giD RGBA fields default-init
 *    to NaN); dimColor() takes its output as `ref RGBA`; the `vteBG` property
 *    now returns a COPY (a snapshot), not a live shared reference.
 *  - VTE's optional color resets (setColorBold(null), setColorHighlight*(null),
 *    setColorCursor*(null)) cannot be expressed through giD's wrappers (they
 *    take RGBA by value and always pass &arg), so the reset paths call the raw
 *    C functions from vte.c.functions with a null pointer.
 *  - pango: PgFontDescription -> pango.font_description.FontDescription,
 *    PgLayout -> pango.layout.Layout, PgCairo.showLayout -> free function
 *    pangocairo.global.showLayout (needs the gid:pangocairo1 subpackage —
 *    added to dub.json, it is not in gtk3/vte2's transitive deps),
 *    PANGO_SCALE -> pango.types.SCALE, enums PascalCase in pango.types
 *    (WrapMode.WordChar, Alignment.Right).
 *  - Draw callbacks take a plain cairo.context.Context (no Scoped!Context);
 *    signatures match gtk.widget.Widget.connectDraw.
 *  - GdkRectangle -> gdk.rectangle.Rectangle (identical x/y/width/height
 *    value struct); StateFlags -> gtk.types.StateFlags (PascalCase members).
 */
module gx.ttyx.terminal.renderer;

private:

import std.algorithm : min;
import std.conv : to;
import std.experimental.logger;
import std.math : floor;

import cairo.context : Context;

import gdk.rgba : RGBA;
import gdk.rectangle : Rectangle;

import pango.font_description : FontDescription;
import pango.layout : Layout;
import pangocairo.global : showLayout;

import gtk.widget : Widget;

import pango.types : PANGO_SCALE = SCALE;

import vte.c.functions : vte_terminal_set_color_bold, vte_terminal_set_color_cursor,
    vte_terminal_set_color_cursor_foreground, vte_terminal_set_color_highlight,
    vte_terminal_set_color_highlight_foreground;
import vte.c.types : VteTerminal;

import gx.gtk.color : adjustColor, contrast;
import gx.gtk.vte : isVTEBackgroundDrawEnabled;
import gx.ttyx.preferences;
import gx.ttyx.terminal.context;
import gx.ttyx.terminal.types;

package:

/**
 * Manages terminal visual rendering: color state, badge overlay,
 * margin line, background painting, and drag highlight.
 *
 * Owns the RGBA color fields and provides methods for applying
 * color preferences from GSettings to the VTE widget.
 */
class TerminalRenderer {

private:
    ITerminalContext _ctx;

    /// Badge rendering state.
    FontDescription _badgeFont = null;
    string _badgeText;

    /// Margin rendering state.
    int _margin = 0;
    bool _marginEnabled = false;
    double[] _marginDash = [1.0, 1.0];

    /// Drag highlight state.
    DragInfo _dragInfo = DragInfo(false, DragQuadrant.LEFT);

    /// Color state.
    enum VTEColorSet { normal, dim }
    VTEColorSet _currentColorSet = VTEColorSet.normal;

    RGBA _vteFG;
    RGBA _dimFG;
    RGBA _vteBG;
    RGBA _vteHighlightFG;
    RGBA _vteHighlightBG;
    RGBA _vteCursorFG;
    RGBA _vteCursorBG;
    RGBA _vteDimBG;
    RGBA[16] _vtePalette;
    RGBA[16] _dimPalette;
    RGBA _vteBadge;
    RGBA _vteBold;
    RGBA _dimBold;
    double _dimPercent;

    enum STROKE_WIDTH = 4;
    enum BADGE_MARGIN = 10;

    /// Delegate to check if terminal widget has focus (for dim color switching).
    bool delegate() _isTerminalWidgetFocused;

    void dimColor(RGBA original, ref RGBA dim, double cf) {
        double r, g, b;
        adjustColor(cf, original, r, g, b);
        dim.red = r;
        dim.green = g;
        dim.blue = b;
        dim.alpha = original.alpha;
    }

    void updateDimColors() {
        double cf = (_vteBG.red + _vteBG.green + _vteBG.blue > 1.5) ? _dimPercent : -_dimPercent;
        dimColor(_vteFG, _dimFG, cf);
        dimColor(_vteBold, _dimBold, cf);
        foreach (i, color; _vtePalette) {
            dimColor(color, _dimPalette[i], cf);
        }
    }

    void setBoldColor(RGBA color) {
        auto gsProfile = _ctx.contextGsProfile();
        if (gsProfile.getBoolean(SETTINGS_PROFILE_USE_BOLD_COLOR_KEY)) {
            _ctx.contextVte().setColorBold(color);
        } else {
            // giD's setColorBold takes RGBA by value and cannot express NULL
            // (reset to default); call the C function directly.
            vte_terminal_set_color_bold(cast(VteTerminal*) _ctx.contextVte()._cPtr, null);
        }
    }

public:

    /**
     * Construct a TerminalRenderer.
     *
     * Params:
     *   ctx = Terminal context providing VTE widget and settings.
     *   isTerminalWidgetFocused = Callback to check if the terminal has keyboard focus.
     */
    this(ITerminalContext ctx, bool delegate() isTerminalWidgetFocused) {
        _ctx = ctx;
        _isTerminalWidgetFocused = isTerminalWidgetFocused;
        initColors();
    }

    /// Register all preference keys that the renderer handles.
    void registerPreferences(ref PreferenceRegistry registry) {
        registry.register([
            SETTINGS_PROFILE_FG_COLOR_KEY, SETTINGS_PROFILE_BG_COLOR_KEY,
            SETTINGS_PROFILE_PALETTE_COLOR_KEY, SETTINGS_PROFILE_USE_THEME_COLORS_KEY,
            SETTINGS_PROFILE_BG_TRANSPARENCY_KEY, SETTINGS_PROFILE_DIM_TRANSPARENCY_KEY
        ], &applyMainColors);

        registry.register([
            SETTINGS_PROFILE_BOLD_COLOR_KEY, SETTINGS_PROFILE_USE_BOLD_COLOR_KEY
        ], &applyBoldColor);

        registry.register([
            SETTINGS_PROFILE_USE_HIGHLIGHT_COLOR_KEY, SETTINGS_PROFILE_HIGHLIGHT_FG_COLOR_KEY,
            SETTINGS_PROFILE_HIGHLIGHT_BG_COLOR_KEY,
            SETTINGS_PROFILE_USE_CURSOR_COLOR_KEY, SETTINGS_PROFILE_CURSOR_FG_COLOR_KEY,
            SETTINGS_PROFILE_CURSOR_BG_COLOR_KEY
        ], &applySecondaryColors);

        registry.register([
            SETTINGS_PROFILE_BADGE_COLOR_KEY, SETTINGS_PROFILE_USE_BADGE_COLOR_KEY
        ], &applyBadgeColor);

        registry.register([
            SETTINGS_PROFILE_BADGE_USE_SYSTEM_FONT_KEY, SETTINGS_PROFILE_BADGE_FONT_KEY
        ], &updateBadgeFont);
    }

    /**
     * Initialize all RGBA colors. giD's RGBA is a value struct whose double
     * fields default-init to NaN, so zero them explicitly (GtkD's `new RGBA()`
     * was zero-initialized).
     */
    void initColors() {
        _vteFG = RGBA(0, 0, 0, 0);
        _dimFG = RGBA(0, 0, 0, 0);
        _vteBG = RGBA(0, 0, 0, 0);
        _vteHighlightFG = RGBA(0, 0, 0, 0);
        _vteHighlightBG = RGBA(0, 0, 0, 0);
        _vteCursorFG = RGBA(0, 0, 0, 0);
        _vteCursorBG = RGBA(0, 0, 0, 0);
        _vteDimBG = RGBA(0, 0, 0, 0);
        _vteBadge = RGBA(0, 0, 0, 0);
        _vteBold = RGBA(0, 0, 0, 0);
        _dimBold = RGBA(0, 0, 0, 0);

        _vtePalette[] = RGBA(0, 0, 0, 0);
        _dimPalette[] = RGBA(0, 0, 0, 0);
    }

    /// Apply the current color set to VTE (normal or dim).
    void setVTEColors(bool force = false) {
        auto vte = _ctx.contextVte();
        VTEColorSet desired = (_isTerminalWidgetFocused() || _dimPercent == 0) ? VTEColorSet.normal : VTEColorSet.dim;
        if (desired == _currentColorSet && !force) return;

        if (_isTerminalWidgetFocused() || _dimPercent == 0) {
            vte.setColors(_vteFG, _vteBG, _vtePalette[]);
            setBoldColor(_vteBold);
            _currentColorSet = VTEColorSet.normal;
        } else {
            vte.setColors(_dimFG, _vteBG, _dimPalette[]);
            setBoldColor(_dimBold);
            _currentColorSet = VTEColorSet.dim;
        }
        applySecondaryColors();
    }

    /// Apply highlight and cursor colors from settings.
    void applySecondaryColors() {
        auto vte = _ctx.contextVte();
        auto gsProfile = _ctx.contextGsProfile();

        if (gsProfile.getBoolean(SETTINGS_PROFILE_USE_HIGHLIGHT_COLOR_KEY)) {
            _vteHighlightFG.parse(gsProfile.getString(SETTINGS_PROFILE_HIGHLIGHT_FG_COLOR_KEY));
            _vteHighlightBG.parse(gsProfile.getString(SETTINGS_PROFILE_HIGHLIGHT_BG_COLOR_KEY));
            vte.setColorHighlightForeground(_vteHighlightFG);
            vte.setColorHighlight(_vteHighlightBG);
        } else {
            // NULL resets are not expressible through giD's by-value RGBA
            // wrappers; call the C functions directly.
            vte_terminal_set_color_highlight_foreground(cast(VteTerminal*) vte._cPtr, null);
            vte_terminal_set_color_highlight(cast(VteTerminal*) vte._cPtr, null);
        }

        if (gsProfile.getBoolean(SETTINGS_PROFILE_USE_CURSOR_COLOR_KEY)) {
            _vteCursorFG.parse(gsProfile.getString(SETTINGS_PROFILE_CURSOR_FG_COLOR_KEY));
            _vteCursorBG.parse(gsProfile.getString(SETTINGS_PROFILE_CURSOR_BG_COLOR_KEY));
            vte.setColorCursorForeground(_vteCursorFG);
            vte.setColorCursor(_vteCursorBG);
        } else {
            vte_terminal_set_color_cursor_foreground(cast(VteTerminal*) vte._cPtr, null);
            vte_terminal_set_color_cursor(cast(VteTerminal*) vte._cPtr, null);
        }
    }

    /// Read and apply main color preferences (FG, BG, palette, transparency, dim).
    void applyMainColors() {
        import gx.gtk.util : getStyleColor, getStyleBackgroundColor;
        import gtk.types : StateFlags;

        auto vte = _ctx.contextVte();
        auto gsProfile = _ctx.contextGsProfile();

        if (gsProfile.getBoolean(SETTINGS_PROFILE_USE_THEME_COLORS_KEY)) {
            getStyleColor(vte.getStyleContext(), StateFlags.Active, _vteFG);
            getStyleBackgroundColor(vte.getStyleContext(), StateFlags.Active, _vteBG);
        } else {
            if (!_vteFG.parse(gsProfile.getString(SETTINGS_PROFILE_FG_COLOR_KEY)))
                trace("Parsing foreground color failed");
            if (!_vteBG.parse(gsProfile.getString(SETTINGS_PROFILE_BG_COLOR_KEY)))
                trace("Parsing background color failed");
        }
        _vteBG.alpha = to!double(100 - gsProfile.getInt(SETTINGS_PROFILE_BG_TRANSPARENCY_KEY)) / 100.0;
        string[] colors = gsProfile.getStrv(SETTINGS_PROFILE_PALETTE_COLOR_KEY);
        foreach (i, color; colors) {
            if (!_vtePalette[i].parse(color)) {
                trace("Parsing color failed " ~ colors[i]);
            }
        }
        _dimPercent = to!double(gsProfile.getInt(SETTINGS_PROFILE_DIM_TRANSPARENCY_KEY)) / 100.0;
        updateDimColors();
        setVTEColors(true);
    }

    /// Apply bold color preference.
    void applyBoldColor() {
        auto gsProfile = _ctx.contextGsProfile();
        string boldColor = gsProfile.getString(SETTINGS_PROFILE_BOLD_COLOR_KEY);
        if (!_vteBold.parse(boldColor)) {
            error("Parsing Bold color failed");
        }
        updateDimColors();
        setVTEColors(true);
    }

    /// Apply badge color preference.
    void applyBadgeColor() {
        auto gsProfile = _ctx.contextGsProfile();
        if (isVTEBackgroundDrawEnabled()) {
            string badgeColor;
            if (gsProfile.getBoolean(SETTINGS_PROFILE_USE_BADGE_COLOR_KEY)) {
                badgeColor = gsProfile.getString(SETTINGS_PROFILE_BADGE_COLOR_KEY);
            } else {
                badgeColor = gsProfile.getString(SETTINGS_PROFILE_FG_COLOR_KEY);
            }
            if (!_vteBadge.parse(badgeColor)) tracef("Failed to parse badge color %s", badgeColor);
        }
    }

    /// Update badge font from profile settings or system font.
    void updateBadgeFont() {
        auto vte = _ctx.contextVte();
        auto gsProfile = _ctx.contextGsProfile();
        if (vte is null || !isVTEBackgroundDrawEnabled()) return;
        if (gsProfile.getBoolean(SETTINGS_PROFILE_BADGE_USE_SYSTEM_FONT_KEY)) {
            _badgeFont = vte.getFont().copy();
            _badgeFont.setSize(_badgeFont.getSize() * 2);
        } else {
            _badgeFont = FontDescription.fromString(gsProfile.getString(SETTINGS_PROFILE_BADGE_FONT_KEY));
        }
        tracef("Badge font is %s:%d", _badgeFont.getFamily(), _badgeFont.getSize());
        vte.queueDraw();
    }

    /// Set the badge text to display. Called by Terminal when badge changes.
    void setBadgeText(string text) {
        _badgeText = text;
    }

    /// Set margin column. 0 disables margin.
    void setMargin(int column) {
        _margin = column;
    }

    /// Toggle margin visibility.
    void toggleMargin() {
        _marginEnabled = !_marginEnabled;
    }

    /// Whether the margin is currently enabled.
    @property bool marginEnabled() { return _marginEnabled; }

    /// Update drag highlight state for drop zone visualization.
    void setDragInfo(DragInfo info) {
        _dragInfo = info;
    }

    /**
     * Access to background color (needed by scrollbar CSS theming in Terminal).
     * NOTE (giD): RGBA is a value struct, so this returns a snapshot COPY of
     * the current background color, not a live reference as in GtkD.
     */
    @property RGBA vteBG() { return _vteBG; }

    /// Access to dim percent (needed by focus change handlers in Terminal).
    @property double dimPercent() { return _dimPercent; }

    /**
     * Draw callback for badge text, background painting, and margin line.
     * Connect to VTE's draw signal (before the drag highlight).
     */
    bool onDrawBadge(Context cr, Widget w) {

        cr.save();
        double width = to!double(w.getAllocatedWidth());
        double height = to!double(w.getAllocatedHeight());

        auto vte = _ctx.contextVte();
        auto gsProfile = _ctx.contextGsProfile();

        // Background painting is left to VTE so OSC 11 (dynamic background)
        // works — see #47.

        // Draw margin line
        if (_margin > 0 && _marginEnabled) {
            double r, g, b;
            contrast(0.40, _vteFG, r, g, b);
            cr.setSourceRgba(r, g, b, 1.0);
            cr.setDash(_marginDash, 0.0);
            cr.moveTo(vte.getCharWidth() * _margin, 0);
            cr.lineTo(vte.getCharWidth() * _margin, height);
            cr.stroke();
        }

        // Draw badge text
        if (_badgeText.length > 0 && _badgeFont !is null) {
            cr.setSourceRgba(_vteBadge.red, _vteBadge.green, _vteBadge.blue, 1.0);

            Rectangle rect = Rectangle(BADGE_MARGIN, BADGE_MARGIN, to!int(width / 2) - BADGE_MARGIN, to!int(height / 2) - BADGE_MARGIN);
            string position = gsProfile.getString(SETTINGS_PROFILE_BADGE_POSITION_KEY);
            switch (position) {
                case SETTINGS_QUADRANT_NE_VALUE:
                    rect.x = to!int(width / 2) + BADGE_MARGIN;
                    break;
                case SETTINGS_QUADRANT_SW_VALUE:
                    rect.y = to!int(height / 2) + BADGE_MARGIN;
                    break;
                case SETTINGS_QUADRANT_SE_VALUE:
                    rect.x = to!int(width / 2) + BADGE_MARGIN;
                    rect.y = to!int(height / 2) + BADGE_MARGIN;
                    break;
                default:
            }

            import pango.types : WrapMode, Alignment;
            Layout pgl = new Layout(vte.getPangoContext());
            pgl.setFontDescription(_badgeFont);
            pgl.setText(_badgeText);
            pgl.setWidth(rect.width * PANGO_SCALE);
            pgl.setHeight(rect.height * PANGO_SCALE);

            int pw, ph;
            pgl.getPixelSize(pw, ph);
            pgl.setWrap(WrapMode.WordChar);

            switch (position) {
                case SETTINGS_QUADRANT_NE_VALUE:
                    pgl.setAlignment(Alignment.Right);
                    break;
                case SETTINGS_QUADRANT_SW_VALUE:
                    rect.y = rect.y + rect.height - ph;
                    break;
                case SETTINGS_QUADRANT_SE_VALUE:
                    rect.y = rect.y + rect.height - ph;
                    pgl.setAlignment(Alignment.Right);
                    break;
                default:
            }

            cr.rectangle(rect.x, rect.y, rect.width, rect.height);
            cr.clip();
            cr.moveTo(rect.x, rect.y);
            showLayout(cr, pgl);
            cr.resetClip();
        }
        cr.restore();
        return false;
    }

    /**
     * Draw callback for drag highlight overlay.
     * Connect to VTE's draw signal with Yes.After.
     */
    bool onDrawDragHighlight(Context cr, Widget w) {
        import gtk.types : StateFlags;
        import gx.gtk.util : getStyleBackgroundColor;

        if (!_dragInfo.isDragActive)
            return false;

        auto vte = _ctx.contextVte();
        RGBA color;
        if (!vte.getStyleContext().lookupColor("theme_selected_bg_color", color)) {
            getStyleBackgroundColor(vte.getStyleContext(), StateFlags.Selected, color);
        }
        cr.setSourceRgba(color.red, color.green, color.blue, 1.0);
        cr.setLineWidth(STROKE_WIDTH);
        int ww = w.getAllocatedWidth();
        int hh = w.getAllocatedHeight();
        int offset = STROKE_WIDTH;
        final switch (_dragInfo.dq) {
        case DragQuadrant.LEFT:
            cr.rectangle(offset, offset, ww / 2, hh - (offset * 2));
            break;
        case DragQuadrant.TOP:
            cr.rectangle(offset, offset, ww - (offset * 2), hh / 2);
            break;
        case DragQuadrant.BOTTOM:
            cr.rectangle(offset, hh / 2, ww - (offset * 2), hh / 2 - offset);
            break;
        case DragQuadrant.RIGHT:
            cr.rectangle(ww / 2, offset, ww / 2, hh - (offset * 2));
            break;
        }
        cr.strokePreserve();
        return false;
    }
}
