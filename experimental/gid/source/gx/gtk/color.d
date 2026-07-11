/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/color.d — the first module ported in the Phase 2a
 * GtkD -> giD migration. See ../../../docs/gid-migration.md.
 *
 * Translation from GtkD:
 *   - import gdk.RGBA  ->  import gdk.rgba
 *   - RGBA is a value STRUCT with plain `double red/green/blue/alpha` fields,
 *     not a class with `.red()` accessors. So `new RGBA(r,g,b,a)` becomes the
 *     struct literal `RGBA(r,g,b,a)`, and `color.red()` becomes `color.red`.
 * The color math and the unit tests are otherwise unchanged.
 */
module gx.gtk.color;

import std.conv;
import std.experimental.logger;
import std.format;

import gdk.rgba;

public:

/**
 * Converts an RGBA structure to a 8 bit HEX string, i.e #2E3436
 */
string rgbaTo8bitHex(RGBA color, bool includeAlpha = false, bool includeHash = false) {
    string prepend = includeHash ? "#" : "";
    int red = to!(int)(color.red * 255);
    int green = to!(int)(color.green * 255);
    int blue = to!(int)(color.blue * 255);
    if (includeAlpha) {
        int alpha = to!(int)(color.alpha * 255);
        return prepend ~ format("%02X%02X%02X%02X", red, green, blue, alpha);
    } else {
        return prepend ~ format("%02X%02X%02X", red, green, blue);
    }
}

/**
 * Converts an RGBA structure to a 16 bit HEX string, i.e #2E2E34343636
 * Right now this just takes an 8 bit string and repeats each channel
 */
string rgbaTo16bitHex(RGBA color, bool includeAlpha = false, bool includeHash = false) {
    string prepend = includeHash ? "#" : "";
    int red = to!(int)(color.red * 255);
    int green = to!(int)(color.green * 255);
    int blue = to!(int)(color.blue * 255);
    if (includeAlpha) {
        int alpha = to!(int)(color.alpha * 255);
        return prepend ~ format("%02X%02X%02X%02X%02X%02X%02X%02X", red, red, green, green, blue, blue, alpha, alpha);
    } else {
        return prepend ~ format("%02X%02X%02X%02X%02X%02X", red, red, green, green, blue, blue);
    }
}

RGBA getOppositeColor(RGBA rgba) {
    RGBA result = RGBA(1.0 - rgba.red, 1 - rgba.green, 1 - rgba.blue, rgba.alpha);
    tracef("Original: %s, New: %s", rgbaTo8bitHex(rgba, true, true), rgbaTo8bitHex(result, true, true));
    return result;
}

void contrast(double percent, RGBA rgba, out double r, out double g, out double b) {
    double brightness = ((rgba.red * 299.0) + (rgba.green * 587.0) + (rgba.blue * 114.0)) / 1000;
    if (brightness > 0.5) darken(percent, rgba, r, g, b);
    else lighten(percent, rgba, r, g, b);
}

void lighten(double percent, RGBA rgba, out double r, out double g, out double b) {
    adjustColor(percent, rgba, r, g, b);
}

void darken(double percent, RGBA rgba, out double r, out double g, out double b) {
    adjustColor(-percent, rgba, r, g, b);
}

void adjustColor(double cf, RGBA rgba, out double r, out double g, out double b) {
    if (cf < 0) {
        cf = 1 + cf;
        r = rgba.red * cf;
        g = rgba.green * cf;
        b = rgba.blue * cf;
    } else {
        r = (1 - rgba.red) * cf + rgba.red;
        g = (1 - rgba.green) * cf + rgba.green;
        b = (1 - rgba.blue) * cf + rgba.blue;
    }
}

void desaturate(double percent, RGBA rgba, out double r, out double g, out double b) {
    tracef("desaturate: %f, %f, %f, %f", percent, rgba.red, rgba.green, rgba.blue);
    double L = 0.3 * rgba.red + 0.6 * rgba.green + 0.1 * rgba.blue;
    r = rgba.red + percent * (L - rgba.red);
    g = rgba.green + percent * (L - rgba.green);
    b = rgba.blue + percent * (L - rgba.blue);
    tracef("Desaturated color: %f, %f, %f", r, g, b);
}

// --------------------------------------------------------------------------
// Unit tests for color utilities
// --------------------------------------------------------------------------

/// Helper: compare doubles with a tolerance.
private bool approx(double a, double b, double eps = 0.01) {
    import std.math : abs;
    return abs(a - b) < eps;
}

/// Test: rgbaTo8bitHex basic conversion
unittest {
    auto red = RGBA(1.0, 0.0, 0.0, 1.0);
    assert(rgbaTo8bitHex(red) == "FF0000");
    assert(rgbaTo8bitHex(red, false, true) == "#FF0000");
    assert(rgbaTo8bitHex(red, true, true) == "#FF0000FF");
}

/// Test: rgbaTo8bitHex with mid-range colors
unittest {
    auto grey = RGBA(0.5, 0.5, 0.5, 1.0);
    string hex = rgbaTo8bitHex(grey, false, true);
    assert(hex == "#7F7F7F", "got: " ~ hex);
}

/// Test: rgbaTo8bitHex black and white
unittest {
    auto black = RGBA(0.0, 0.0, 0.0, 1.0);
    assert(rgbaTo8bitHex(black, false, true) == "#000000");

    auto white = RGBA(1.0, 1.0, 1.0, 1.0);
    assert(rgbaTo8bitHex(white, false, true) == "#FFFFFF");
}

/// Test: rgbaTo16bitHex doubles each byte
unittest {
    auto red = RGBA(1.0, 0.0, 0.0, 1.0);
    assert(rgbaTo16bitHex(red, false, true) == "#FFFF00000000");
}

/// Test: getOppositeColor inverts RGB, preserves alpha
unittest {
    auto color = RGBA(0.2, 0.3, 0.4, 0.8);
    auto opposite = getOppositeColor(color);

    assert(approx(opposite.red, 0.8));
    assert(approx(opposite.green, 0.7));
    assert(approx(opposite.blue, 0.6));
    assert(approx(opposite.alpha, 0.8));
}

/// Test: lighten increases RGB values toward 1.0
unittest {
    auto color = RGBA(0.4, 0.2, 0.6, 1.0);
    double r, g, b;
    lighten(0.5, color, r, g, b);

    assert(approx(r, 0.7));
    assert(approx(g, 0.6));
    assert(approx(b, 0.8));
}

/// Test: darken decreases RGB values toward 0.0
unittest {
    auto color = RGBA(0.4, 0.2, 0.6, 1.0);
    double r, g, b;
    darken(0.5, color, r, g, b);

    assert(approx(r, 0.2));
    assert(approx(g, 0.1));
    assert(approx(b, 0.3));
}

/// Test: contrast auto-selects lighten or darken based on brightness
unittest {
    auto dark = RGBA(0.1, 0.1, 0.1, 1.0);
    double r, g, b;
    contrast(0.3, dark, r, g, b);
    assert(r > 0.1 && g > 0.1 && b > 0.1, "dark color should be lightened");

    auto light = RGBA(0.9, 0.9, 0.9, 1.0);
    contrast(0.3, light, r, g, b);
    assert(r < 0.9 && g < 0.9 && b < 0.9, "light color should be darkened");
}

/// Test: desaturate moves colors toward grey
unittest {
    auto color = RGBA(1.0, 0.0, 0.0, 1.0);
    double r, g, b;
    desaturate(1.0, color, r, g, b);

    assert(approx(r, 0.3));
    assert(approx(g, 0.3));
    assert(approx(b, 0.3));
}

/// Test: desaturate at 0% leaves color unchanged
unittest {
    auto color = RGBA(0.8, 0.4, 0.2, 1.0);
    double r, g, b;
    desaturate(0.0, color, r, g, b);

    assert(approx(r, 0.8));
    assert(approx(g, 0.4));
    assert(approx(b, 0.2));
}
