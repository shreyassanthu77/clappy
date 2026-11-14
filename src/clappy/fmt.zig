//! Styled printing with inline style tags, compiled away at comptime.
//!
//! ```zig
//! try clappy.fmt.stderr("{%red,bold}error:{%} could not open {%#ff8700}{s}{%}\n", .{path});
//! ```
//!
//! - `{%spec}` opens a style, `{%}` closes the innermost one. Styles nest: an
//!   inner style is layered on top of the outer one, and closing it returns to
//!   the outer one. Styles still open at the end are closed automatically,
//!   before any trailing newlines.
//! - `spec` is a comma separated list of: a color name (`red`, `bright_blue`,
//!   ...) or `#rrggbb` for the foreground, `bg:<color>` for the background,
//!   and `bold`/`b`, `dim`, `italic`/`i`, `underline`/`u`, `inverse`,
//!   `strike`/`s`.
//! - Everything else is a regular `std.Io.Writer.print` format string.
//!
//! Each format string is compiled into two: one with escape codes and one
//! without. Choosing between them is the only runtime cost.
//!
//! Whether color is used:
//! - `clappy_options.color` in the root file can force it to `.always` or
//!   `.never` at comptime.
//! - Otherwise (`.auto`), `stderr` uses std's own detection, `stdout` uses the
//!   detection done by `init`, and `print` takes it as an argument.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;

const clappy = @import("../clappy.zig");

/// Prints to stderr, colored if std detected stderr supports it.
pub fn stderr(comptime fmt: []const u8, args: anytype) Writer.Error!void {
    var buffer: [64]u8 = undefined;
    const t = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    try print(t.writer, t.mode == .escape_codes, fmt, args);
}

/// A `std.log` backend that understands style tags in log messages:
///
/// ```zig
/// pub const std_options: std.Options = .{ .logFn = clappy.fmt.logFn };
/// // ...
/// std.log.err("could not open {%b}{s}{%}", .{path});
/// ```
///
/// Output matches `std.log.defaultLog`, written to stderr.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    stderr(logFormat(level, scope, format), args) catch {};
}

fn logFormat(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8) []const u8 {
    const color = switch (level) {
        .err => "red",
        .warn => "yellow",
        .info => "green",
        .debug => "magenta",
    };
    const scope_text = if (scope == .default) "" else "(" ++ escapeBraces(@tagName(scope)) ++ ")";
    return "{%" ++ color ++ ",b}" ++ level.asText() ++ "{%}{%dim,b}" ++ scope_text ++ ": {%}" ++ format ++ "\n";
}

fn escapeBraces(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| out = out ++ switch (c) {
            '{' => "{{",
            '}' => "}}",
            else => .{c},
        };
        return out;
    }
}

/// Prints to stdout, colored according to the detection done by `init`.
/// Flushes before returning.
pub fn stdout(comptime fmt: []const u8, args: anytype) Writer.Error!void {
    const target = stdout_target orelse @panic("clappy.fmt.init must be called before clappy.fmt.stdout");
    var buffer: [256]u8 = undefined;
    var w = Io.File.stdout().writer(target.io, &buffer);
    try print(&w.interface, target.color, fmt, args);
    try w.interface.flush();
}

/// Detects whether stdout supports color. Call once at the start of `main`,
/// before any other threads use `stdout`.
pub fn init(process: std.process.Init) Io.Cancelable!void {
    stdout_target = .{
        .io = process.io,
        .color = try colorEnabled(process.io, .stdout(), process.environ_map),
    };
}

var stdout_target: ?struct { io: Io, color: bool } = null;

/// Prints to any writer. `color` is ignored when `clappy_options.color` is
/// `.always` or `.never`.
pub fn print(w: *Writer, color: bool, comptime fmt: []const u8, args: anytype) Writer.Error!void {
    const compiled = comptime compile(fmt);
    const use_color = switch (clappy.options.color) {
        .always => true,
        .never => false,
        .auto => color,
    };
    return if (use_color) w.print(compiled.styled, args) else w.print(compiled.plain, args);
}

/// Whether `file` should receive escape codes. Honors `NO_COLOR` and
/// `CLICOLOR_FORCE`. Legacy Windows consoles without ANSI support count as no.
pub fn colorEnabled(io: Io, file: Io.File, env: *const std.process.Environ.Map) Io.Cancelable!bool {
    const mode = try Io.Terminal.Mode.detect(io, file, isSet(env, "NO_COLOR"), isSet(env, "CLICOLOR_FORCE"));
    return mode == .escape_codes;
}

fn isSet(env: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env.get(key) orelse return false;
    return value.len != 0;
}

const Compiled = struct { styled: []const u8, plain: []const u8 };

/// Splits `fmt` into a version with escape codes and one without.
fn compile(comptime fmt: []const u8) Compiled {
    comptime {
        @setEvalBranchQuota(2000 + fmt.len * 500);
        var styled: []const u8 = "";
        var plain: []const u8 = "";
        var stack: []const Style = &.{};

        var i = 0;
        while (i < fmt.len) {
            const c = fmt[i];
            const next = if (i + 1 < fmt.len) fmt[i + 1] else 0;

            // Escaped braces belong to std's format syntax; keep them as is.
            if ((c == '{' or c == '}') and next == c) {
                styled = styled ++ fmt[i..][0..2];
                plain = plain ++ fmt[i..][0..2];
                i += 2;
                continue;
            }

            if (c == '{' and next == '%') {
                const end = std.mem.indexOfScalarPos(u8, fmt, i, '}') orelse
                    @compileError("missing closing } in '" ++ fmt ++ "'");
                const spec = fmt[i + 2 .. end];
                if (spec.len == 0) {
                    if (stack.len == 0) @compileError("{%} without an open style in '" ++ fmt ++ "'");
                    stack = stack[0 .. stack.len - 1];
                } else {
                    const base: Style = if (stack.len == 0) .{} else stack[stack.len - 1];
                    stack = stack ++ .{base.merge(parseStyle(spec, fmt))};
                }
                const current: Style = if (stack.len == 0) .{} else stack[stack.len - 1];
                styled = styled ++ current.sgr();
                i = end + 1;
                continue;
            }

            styled = styled ++ .{c};
            plain = plain ++ .{c};
            i += 1;
        }

        // Close what is still open, before trailing newlines so styles don't
        // bleed into the next line.
        if (stack.len != 0) {
            const body_len = std.mem.trimEnd(u8, styled, "\r\n").len;
            styled = styled[0..body_len] ++ Style.sgr(.{}) ++ styled[body_len..];
        }

        const styled_final = styled[0..styled.len].*;
        const plain_final = plain[0..plain.len].*;
        return .{ .styled = &styled_final, .plain = &plain_final };
    }
}

fn parseStyle(comptime spec: []const u8, comptime fmt: []const u8) Style {
    comptime {
        var style: Style = .{};
        var it = std.mem.tokenizeAny(u8, spec, ", ");
        while (it.next()) |token| {
            if (std.mem.startsWith(u8, token, "bg:")) {
                style.bg = parseColor(token[3..], fmt);
            } else if (eqlAny(token, &.{ "bold", "b" })) {
                style.bold = true;
            } else if (eqlAny(token, &.{"dim"})) {
                style.dim = true;
            } else if (eqlAny(token, &.{ "italic", "i" })) {
                style.italic = true;
            } else if (eqlAny(token, &.{ "underline", "u" })) {
                style.underline = true;
            } else if (eqlAny(token, &.{"inverse"})) {
                style.inverse = true;
            } else if (eqlAny(token, &.{ "strike", "s" })) {
                style.strike = true;
            } else {
                style.fg = parseColor(token, fmt);
            }
        }
        return style;
    }
}

fn parseColor(comptime token: []const u8, comptime fmt: []const u8) Color {
    comptime {
        if (std.meta.stringToEnum(Color.Basic, token)) |b| return .{ .basic = b };
        if (token.len == 7 and token[0] == '#') {
            const v = std.fmt.parseInt(u24, token[1..], 16) catch
                @compileError("invalid hex color '" ++ token ++ "' in '" ++ fmt ++ "'");
            return .{ .rgb = .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) } };
        }
        @compileError("unknown style '" ++ token ++ "' in '" ++ fmt ++ "'");
    }
}

fn eqlAny(a: []const u8, comptime options: []const []const u8) bool {
    for (options) |b| if (std.mem.eql(u8, a, b)) return true;
    return false;
}

const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,

    /// `top` layered over `base`: colors are replaced if set, attributes are added.
    fn merge(base: Style, top: Style) Style {
        return .{
            .fg = top.fg orelse base.fg,
            .bg = top.bg orelse base.bg,
            .bold = base.bold or top.bold,
            .dim = base.dim or top.dim,
            .italic = base.italic or top.italic,
            .underline = base.underline or top.underline,
            .inverse = base.inverse or top.inverse,
            .strike = base.strike or top.strike,
        };
    }

    /// A single SGR sequence that resets, then applies this style.
    fn sgr(comptime style: Style) []const u8 {
        comptime {
            var out: []const u8 = "\x1b[0";
            if (style.bold) out = out ++ ";1";
            if (style.dim) out = out ++ ";2";
            if (style.italic) out = out ++ ";3";
            if (style.underline) out = out ++ ";4";
            if (style.inverse) out = out ++ ";7";
            if (style.strike) out = out ++ ";9";
            if (style.fg) |c| out = out ++ c.sgr(30);
            if (style.bg) |c| out = out ++ c.sgr(40);
            return out ++ "m";
        }
    }
};

const Color = union(enum) {
    basic: Basic,
    rgb: Rgb,

    const Basic = enum(u4) {
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
        bright_black,
        bright_red,
        bright_green,
        bright_yellow,
        bright_blue,
        bright_magenta,
        bright_cyan,
        bright_white,
    };

    const Rgb = struct { r: u8, g: u8, b: u8 };

    /// `base` is 30 for foreground, 40 for background.
    fn sgr(comptime color: Color, comptime base: u8) []const u8 {
        return switch (color) {
            .basic => |b| blk: {
                const n: u8 = @backingInt(b);
                break :blk std.fmt.comptimePrint(";{d}", .{if (n < 8) base + n else base + 60 + (n - 8)});
            },
            .rgb => |c| std.fmt.comptimePrint(";{d};2;{d};{d};{d}", .{ base + 8, c.r, c.g, c.b }),
        };
    }
};

fn expectCompiled(comptime fmt: []const u8, comptime styled: []const u8, comptime plain: []const u8) !void {
    const compiled = comptime compile(fmt);
    try std.testing.expectEqualStrings(styled, compiled.styled);
    try std.testing.expectEqualStrings(plain, compiled.plain);
}

test "open and close" {
    try expectCompiled(
        "{%red,bold}error:{%} could not open {s}",
        "\x1b[0;1;31merror:\x1b[0m could not open {s}",
        "error: could not open {s}",
    );
}

test "nesting layers styles" {
    try expectCompiled(
        "{%red}a {%b,bg:blue}b{%} c{%}",
        "\x1b[0;31ma \x1b[0;1;31;44mb\x1b[0;31m c\x1b[0m",
        "a b c",
    );
}

test "unclosed styles close before trailing newlines" {
    try expectCompiled("{%green}ok\n\n", "\x1b[0;32mok\x1b[0m\n\n", "ok\n\n");
}

test "colors and attributes" {
    try expectCompiled(
        "{%#ff8700,i,u,s,dim,inverse,bg:bright_black}x",
        "\x1b[0;2;3;4;7;9;38;2;255;135;0;100mx\x1b[0m",
        "x",
    );
}

test "std format syntax passes through" {
    try expectCompiled("{{%red}} {[name]s:>8} {0d}", "{{%red}} {[name]s:>8} {0d}", "{{%red}} {[name]s:>8} {0d}");
}

test logFn {
    try expectCompiled(
        logFormat(.err, .default, "could not open {%b}{s}{%}"),
        "\x1b[0;1;31merror\x1b[0m\x1b[0;1;2m: \x1b[0mcould not open \x1b[0;1m{s}\x1b[0m\n",
        "error: could not open {s}\n",
    );
    try expectCompiled(
        logFormat(.warn, .@"we{i}rd", "{%red}x"),
        "\x1b[0;1;33mwarning\x1b[0m\x1b[0;1;2m(we{{i}}rd): \x1b[0m\x1b[0;31mx\x1b[0m\n",
        "warning(we{{i}}rd): x\n",
    );
}

test print {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try print(&w, true, "{%bold}{s}{%} = {d}", .{ "x", 42 });
    try std.testing.expectEqualStrings("\x1b[0;1mx\x1b[0m = 42", w.buffered());

    w = .fixed(&buf);
    try print(&w, false, "{%bold}{s}{%} = {d}", .{ "x", 42 });
    try std.testing.expectEqualStrings("x = 42", w.buffered());
}
