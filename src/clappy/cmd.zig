//! Declarative command-line parsing. A command is a struct: its fields hold
//! the parsed values and its `clappy_config` decl says where each one comes from.
//!
//! ```zig
//! const Root = struct {
//!     pub const clappy_config: clappy.cmd.Config(@This()) = .{
//!         .values = .{
//!             .verbose = .count(.{ .names = &.{"-v"}, .global = true }),
//!         },
//!     };
//!
//!     verbose: u8 = 0,
//!     command: union(enum) { serve: Serve, build: Build },
//! };
//!
//! const args = try clappy.parse(Root, init, .{ .version = "1.0.0" });
//! ```
//!
//! - Field types decide the shape: `?T` or a default makes a value optional,
//!   `bool` options are flags (with `--no-` variants), `[]const T` options
//!   repeat, `[]const T` positionals are variadic and `[N]T` takes exactly N
//!   values.
//! - Fields missing from `values` are options named after the field, or
//!   subcommands when the field is a union.
//! - Positionals are filled in field declaration order.
//! - Command line values win over environment variables, which win over
//!   field defaults.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Writer = std.Io.Writer;

const clappy = @import("../clappy.zig");

pub const Options = struct {
    /// Defaults to the basename of `argv[0]`.
    name: ?[]const u8 = null,
    /// Enables `--version` on the root command.
    version: ?[]const u8 = null,
};

/// Parses the process arguments into `T`. Prints help, version or errors and
/// exits when parsing does not produce a value. Everything returned lives in
/// `init.arena`.
pub fn parse(comptime T: type, init: std.process.Init, options: Options) !T {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var diag: Diagnostic = .{};
    const result = parseArgs(T, arena, argv, init.environ_map, options, &diag);
    for (diag.warnings.items) |warning| {
        try clappy.fmt.stderr("{%yellow,bold}warning:{%} {s}\n", .{warning});
    }
    return result catch |err| switch (err) {
        error.HelpRequested, error.VersionRequested => {
            var buffer: [1024]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buffer);
            const w = &stdout.interface;
            if (err == error.HelpRequested) {
                const color = try clappy.fmt.colorEnabled(init.io, .stdout(), init.environ_map);
                try diag.writeHelp(w, color);
            } else {
                try w.print("{s} {s}\n", .{ diag.program, options.version.? });
            }
            try w.flush();
            std.process.exit(0);
        },
        error.ParseFailed => {
            if (diag.show_help) {
                var buffer: [1024]u8 = undefined;
                const t = std.debug.lockStderr(&buffer).terminal();
                defer std.debug.unlockStderr();
                try diag.writeHelp(t.writer, t.mode == .escape_codes);
                try t.writer.flush();
                std.process.exit(2);
            }
            try clappy.fmt.stderr("{%red,bold}error:{%} {s}\n", .{diag.message});
            if (diag.suggestion) |s| try clappy.fmt.stderr("did you mean {%green}{s}{%}?\n", .{s});
            try clappy.fmt.stderr("{%dim}run '{s} --help' for usage{%}\n", .{diag.command});
            std.process.exit(2);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub const Error = error{ ParseFailed, HelpRequested, VersionRequested, OutOfMemory };

pub const Diagnostic = struct {
    message: []const u8 = "",
    /// A close match for a mistyped option or command, e.g. `--port`.
    suggestion: ?[]const u8 = null,
    /// The root command name, e.g. `app`.
    program: []const u8 = "",
    /// The command being parsed when parsing stopped, e.g. `app serve`.
    command: []const u8 = "",
    /// Set by `Context.warn`, also when parsing succeeds.
    warnings: std.ArrayList([]const u8) = .empty,
    help: ?Help = null,
    /// The failure is better explained by the command's help than by
    /// `message`, e.g. a bare `app` whose subcommand is required.
    show_help: bool = false,

    const Help = struct {
        render: HelpFn,
        show_version: bool,
    };

    /// Writes the help of `command`, requested with `--help` or `-h`, or
    /// shown because of `show_help`.
    pub fn writeHelp(diag: *const Diagnostic, w: *Writer, color: bool) Writer.Error!void {
        const help = diag.help orelse return;
        try help.render(w, color, diag.command, help.show_version);
    }
};

/// Parses `argv` (including the program name) into `T`. Everything returned
/// is allocated with `arena`.
pub fn parseArgs(
    comptime T: type,
    arena: Allocator,
    argv: []const [:0]const u8,
    env: ?*const Environ.Map,
    options: Options,
    diag: *Diagnostic,
) Error!T {
    const name = programName(argv, options);
    diag.program = name;
    diag.suggestion = null;
    diag.help = null;
    diag.show_help = false;
    var p: Parser = .{
        .arena = arena,
        .args = if (argv.len > 0) argv[1..] else argv,
        .env = env,
        .version = options.version,
        .diag = diag,
    };
    return parseCommand(T, &.{}, 0, &p, name);
}

/// Prints the help of the root command `T` to stdout, as `--help` would.
/// Useful when an optional subcommand is missing.
pub fn printHelp(comptime T: type, init: std.process.Init, options: Options) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const color = try clappy.fmt.colorEnabled(init.io, .stdout(), init.environ_map);
    try writeHelp(T, &stdout.interface, color, programName(argv, options), options.version);
    try stdout.interface.flush();
}

/// Writes the help of the root command `T`. `--version` is listed when
/// `version` is set, matching `Options.version`.
pub fn writeHelp(comptime T: type, w: *Writer, color: bool, name: []const u8, version: ?[]const u8) Writer.Error!void {
    const show_version = version != null and comptime findLong(optionEntries(T, 0), "version") == null;
    try writeCommandHelp(T, &.{}, w, color, name, show_version);
}

fn programName(argv: []const [:0]const u8, options: Options) []const u8 {
    return options.name orelse if (argv.len > 0) std.fs.path.basename(argv[0]) else "app";
}

/// The type of a command's `pub const clappy_config` decl.
pub fn Config(comptime T: type) type {
    return struct {
        description: []const u8 = "",
        /// Extra names a subcommand can be invoked by. Its main name is the
        /// union field name.
        aliases: []const []const u8 = &.{},
        values: Values(T) = .{},
    };
}

fn Values(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (info.field_types, &types, &attrs) |F, *ty, *attr| {
        ty.* = ?Value(F);
        attr.* = .{ .default_value_ptr = &@as(?Value(F), null) };
    }
    return @Struct(.auto, null, info.field_names, &types, &attrs);
}

pub const Kind = enum { option, positional, count, env, rest, subcommands };

/// How a `bool` option can be turned off again, e.g. to override an env var.
pub const Negate = union(enum) {
    /// `--no-<long>` for every long name.
    auto,
    none,
    /// `-x` and `--xyz` style names, e.g. `&.{ "-C", "--plain" }`.
    names: []const []const u8,
};

/// Where the value of a field of type `F` comes from.
pub fn Value(comptime F: type) type {
    return struct {
        kind: Kind,
        names: []const []const u8 = &.{},
        env_vars: []const []const u8 = &.{},
        description: []const u8 = "",
        parse: ?ParseFn(Elem(F)) = null,
        delimiter: ?u8 = null,
        global: bool = false,
        negate: Negate = .auto,
        require_dash_dash: bool = false,

        const Self = @This();

        pub const Option = struct {
            /// `-x` and `--xyz` style names. Without a long name, one is
            /// derived from the field name (`log_level` → `--log-level`).
            names: []const []const u8 = &.{},
            description: []const u8 = "",
            /// Checked in order when the option is not on the command line.
            env: []const []const u8 = &.{},
            /// Defaults to `Parse.auto`.
            parse: ?ParseFn(Elem(F)) = null,
            /// Splits a single value of a list or array, e.g. `--tags a,b`.
            delimiter: ?u8 = null,
            /// Also accepted after a subcommand.
            global: bool = false,
            /// Only for `bool` options.
            negate: Negate = .auto,
        };

        pub fn option(o: Option) Self {
            return .{
                .kind = .option,
                .names = o.names,
                .description = o.description,
                .env_vars = o.env,
                .parse = o.parse,
                .delimiter = o.delimiter,
                .global = o.global,
                .negate = o.negate,
            };
        }

        pub const Positional = struct {
            description: []const u8 = "",
            parse: ?ParseFn(Elem(F)) = null,
        };

        pub fn positional(o: Positional) Self {
            return .{ .kind = .positional, .description = o.description, .parse = o.parse };
        }

        pub const Count = struct {
            names: []const []const u8 = &.{},
            description: []const u8 = "",
            global: bool = false,
        };

        /// An integer counting how often a flag was given, e.g. `-vvv`.
        pub fn count(o: Count) Self {
            return .{ .kind = .count, .names = o.names, .description = o.description, .global = o.global };
        }

        pub const Env = struct {
            names: []const []const u8,
            description: []const u8 = "",
            parse: ?ParseFn(Elem(F)) = null,
            delimiter: ?u8 = null,
        };

        /// Only read from the environment.
        pub fn env(o: Env) Self {
            return .{
                .kind = .env,
                .env_vars = o.names,
                .description = o.description,
                .parse = o.parse,
                .delimiter = o.delimiter,
            };
        }

        pub const Rest = struct {
            description: []const u8 = "",
            /// Only start after `--`, so options after the last positional
            /// are still parsed, like `cargo run -- args`.
            require_dash_dash: bool = false,
        };

        /// Everything after the last positional (or the first bare argument
        /// when there are none), untouched, options included. A `--` there is
        /// skipped. Next to a list positional only `--` starts it. The field
        /// must be `[]const []const u8`.
        pub fn rest(o: Rest) Self {
            return .{ .kind = .rest, .description = o.description, .require_dash_dash = o.require_dash_dash };
        }

        /// The field must be a `union(enum)` (or an optional one) of command
        /// structs. This is the default for union fields.
        pub const subcommands: Self = .{ .kind = .subcommands };
    };
}

pub const ParseError = error{ ParseFailed, OutOfMemory };

/// Turns one raw string into a value. Fails with `ctx.fail`. A function body
/// type rather than a pointer, so parsers are always comptime-known and
/// called directly.
pub fn ParseFn(comptime T: type) type {
    return fn (raw: []const u8, ctx: *Context) ParseError!T;
}

pub const Context = struct {
    arena: Allocator,
    message: []const u8 = "",
    warnings: std.ArrayList([]const u8) = .empty,

    /// Records why the value is invalid; return the result from the parse function.
    pub fn fail(ctx: *Context, comptime fmt: []const u8, args: anytype) ParseError {
        ctx.message = try std.fmt.allocPrint(ctx.arena, fmt, args);
        return error.ParseFailed;
    }

    /// Reports a problem without failing, printed as `warning: <source>: <message>`.
    pub fn warn(ctx: *Context, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try ctx.warnings.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, fmt, args));
    }
};

/// Built-in parse functions, usable as `.parse` or called from custom ones.
pub const Parse = struct {
    /// The parser used when `.parse` is not set.
    pub fn auto(comptime T: type) ParseFn(T) {
        if (T == []const u8) return string;
        return switch (@typeInfo(T)) {
            .int => int(T),
            .float => float(T),
            .@"enum" => fromEnumTag(T),
            .bool => boolean,
            else => @compileError("no default parser for " ++ @typeName(T) ++ ", set `.parse`"),
        };
    }

    pub const string: ParseFn([]const u8) = struct {
        fn f(raw: []const u8, _: *Context) ParseError![]const u8 {
            return raw;
        }
    }.f;

    /// Accepts 1/0, true/false, yes/no and on/off. Empty is false.
    pub const boolean: ParseFn(bool) = struct {
        fn f(raw: []const u8, ctx: *Context) ParseError!bool {
            const truthy: []const []const u8 = &.{ "1", "true", "yes", "on" };
            const falsy: []const []const u8 = &.{ "0", "false", "no", "off", "" };
            for (truthy) |t| if (std.ascii.eqlIgnoreCase(raw, t)) return true;
            for (falsy) |t| if (std.ascii.eqlIgnoreCase(raw, t)) return false;
            return ctx.fail("expected true or false", .{});
        }
    }.f;

    /// Decimal, or `0x`/`0o`/`0b` prefixed.
    pub fn int(comptime T: type) ParseFn(T) {
        return struct {
            fn f(raw: []const u8, ctx: *Context) ParseError!T {
                return std.fmt.parseInt(T, raw, 0) catch |err| return switch (err) {
                    error.Overflow => ctx.fail("must be between {d} and {d}", .{ std.math.minInt(T), std.math.maxInt(T) }),
                    error.InvalidCharacter => ctx.fail("expected an integer", .{}),
                };
            }
        }.f;
    }

    pub fn float(comptime T: type) ParseFn(T) {
        return struct {
            fn f(raw: []const u8, ctx: *Context) ParseError!T {
                return std.fmt.parseFloat(T, raw) catch return ctx.fail("expected a number", .{});
            }
        }.f;
    }

    pub fn fromEnumTag(comptime E: type) ParseFn(E) {
        return struct {
            fn f(raw: []const u8, ctx: *Context) ParseError!E {
                return std.meta.stringToEnum(E, raw) orelse
                    ctx.fail("expected one of: " ++ comptime tagList(E, ", "), .{});
            }
        }.f;
    }
};

const Parser = struct {
    arena: Allocator,
    args: []const [:0]const u8,
    index: usize = 0,
    env: ?*const Environ.Map,
    version: ?[]const u8,
    diag: *Diagnostic,
    /// The slots of every command from the root to the current one, so
    /// global options are stored on the command that declared them.
    levels: std.ArrayList([]Slot) = .empty,

    fn next(p: *Parser) ?[]const u8 {
        if (p.index >= p.args.len) return null;
        defer p.index += 1;
        return p.args[p.index];
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.message = try std.fmt.allocPrint(p.arena, fmt, args);
        return error.ParseFailed;
    }

    fn slot(p: *Parser, e: Entry) *Slot {
        return &p.levels.items[e.depth][e.slot];
    }

    fn apply(p: *Parser, e: Entry, inline_value: ?[]const u8) Error!void {
        const s = p.slot(e);
        switch (e.kind) {
            .flag, .unflag, .count => {
                if (inline_value != null) return p.fail("{s} does not take a value", .{e.display});
                switch (e.kind) {
                    .flag => s.flag = true,
                    .unflag => s.flag = false,
                    .count => s.count +|= 1,
                    .value => unreachable,
                }
            },
            .value => for (0..e.arity) |n| {
                const value = (if (n == 0) inline_value else null) orelse p.next() orelse {
                    if (e.arity == 1) return p.fail("{s} needs a value", .{e.display});
                    return p.fail("{s} needs {d} values", .{ e.display, e.arity });
                };
                try s.raws.append(p.arena, value);
            },
        }
    }
};

const Slot = struct {
    raws: std.ArrayList([]const u8) = .empty,
    count: u32 = 0,
    flag: ?bool = null,
};

/// Walks the arguments for one command, recursing into a subcommand when one
/// is named, then fills in `T`. `inherited` are the global options of every
/// ancestor.
fn parseCommand(
    comptime T: type,
    comptime inherited: []const Entry,
    comptime depth: usize,
    p: *Parser,
    path: []const u8,
) Error!T {
    const info = @typeInfo(T).@"struct";
    const own = comptime optionEntries(T, depth);
    const table = comptime inherited ++ own;
    const globals = comptime inherited ++ globalEntries(own);
    const rest_field = comptime firstFieldOfKind(T, .rest);
    const rest_start = comptime restStart(T);
    const sub_field = comptime firstFieldOfKind(T, .subcommands);
    comptime validate(T, table);

    const slots = try p.arena.alloc(Slot, info.field_names.len);
    @memset(slots, .{});
    try p.levels.append(p.arena, slots);
    defer _ = p.levels.pop();
    p.diag.command = path;

    const start = p.index;
    var bare: std.ArrayList([]const u8) = .empty;
    var sub: ?Unwrap(if (sub_field) |s| info.field_types[s] else void) = null;
    var after_dash_dash = false;
    var in_rest = false;

    while (p.next()) |arg| {
        if (in_rest) {
            try slots[rest_field.?].raws.append(p.arena, arg);
            continue;
        }
        if (after_dash_dash) {
            if (rest_field) |r| {
                try slots[r].raws.append(p.arena, arg);
            } else {
                try bare.append(p.arena, arg);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_dash_dash = true;
            continue;
        }
        // Once the last positional is filled, everything after it, options
        // included, belongs to the rest field.
        if (rest_start) |n| if (n > 0 and bare.items.len == n) {
            in_rest = true;
            try slots[rest_field.?].raws.append(p.arena, arg);
            continue;
        };
        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = body[0 .. eq orelse body.len];
            const value: ?[]const u8 = if (eq) |i| body[i + 1 ..] else null;
            if (std.mem.eql(u8, name, "help")) return helpRequested(T, inherited, p);
            const e = findLong(table, name) orelse {
                // After the lookup so an option named `version` wins.
                if (p.version != null and std.mem.eql(u8, name, "version")) return error.VersionRequested;
                const flag = arg[0 .. 2 + name.len];
                p.diag.suggestion = if (p.version != null)
                    closest(comptime longFlags(table) ++ &[_][]const u8{ "--help", "--version" }, flag)
                else
                    closest(comptime longFlags(table) ++ &[_][]const u8{"--help"}, flag);
                return p.fail("unknown option '{s}'", .{flag});
            };
            try p.apply(e, value);
            continue;
        }
        if (arg.len > 1 and arg[0] == '-' and !isNegativeNumber(table, arg)) {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                const c = arg[i];
                const e = findShort(table, c) orelse {
                    if (c == 'h') return helpRequested(T, inherited, p);
                    return p.fail("unknown option '-{c}'", .{c});
                };
                if (e.kind == .value) {
                    var value = arg[i + 1 ..];
                    if (std.mem.startsWith(u8, value, "=")) value = value[1..];
                    try p.apply(e, if (i + 1 < arg.len) value else null);
                    break;
                }
                try p.apply(e, null);
            }
            continue;
        }
        if (sub_field) |s| {
            if (bare.items.len == 0) {
                if (try parseSubcommand(T, s, globals, depth, p, path, arg)) |value| {
                    sub = value;
                    break;
                }
                // With no positionals or rest to take it, a bare argument can
                // only have been meant as a command, even an optional one.
                const takes_bare = comptime fieldsOfKind(T, .positional).len > 0 or rest_start != null;
                if (@typeInfo(info.field_types[s]) != .optional or !takes_bare) {
                    p.diag.suggestion = closest(comptime commandNames(Unwrap(info.field_types[s])), arg);
                    return p.fail("unknown command '{s}'", .{arg});
                }
            }
        }
        // Without positionals, the first bare argument starts the rest.
        if (rest_start == 0) {
            in_rest = true;
            try slots[rest_field.?].raws.append(p.arena, arg);
            continue;
        }
        try bare.append(p.arena, arg);
    }

    p.diag.command = path;
    try distributePositionals(T, slots, bare.items, p);

    var out: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, F, i| {
        if (comptime valueOf(T, i).kind == .subcommands) {
            @field(out, name) = if (@typeInfo(F) == .optional)
                sub
            else
                sub orelse return missingCommand(T, inherited, p, start);
        } else {
            @field(out, name) = try finalize(T, i, &slots[i], p);
        }
    }
    return out;
}

/// How many bare arguments come before the rest field picks up the others
/// without a `--`. Null when there is no rest field, it requires `--`, or a
/// list positional would take them all.
fn restStart(comptime T: type) ?usize {
    const r = firstFieldOfKind(T, .rest) orelse return null;
    if (valueOf(T, r).require_dash_dash) return null;
    var sum: usize = 0;
    for (fieldsOfKind(T, .positional)) |i| sum += positionalWidth(@typeInfo(T).@"struct".field_types[i]) orelse return null;
    return sum;
}

/// `-5` and `-.5` are values unless a short option uses that character.
fn isNegativeNumber(table: []const Entry, arg: []const u8) bool {
    const c = arg[1];
    return (std.ascii.isDigit(c) or c == '.') and findShort(table, c) == null;
}

/// The candidate closest to `input` by edit distance, if it is within a
/// third of the input's length (at least 1). Ties go to the first candidate.
fn closest(comptime candidates: []const []const u8, input: []const u8) ?[]const u8 {
    const max_len = comptime blk: {
        var max: usize = 0;
        for (candidates) |c| max = @max(max, c.len);
        break :blk max;
    };
    var row: [max_len + 1]usize = undefined;
    var best: ?[]const u8 = null;
    var best_distance = @max(1, input.len / 3) + 1;
    for (candidates) |candidate| {
        const distance = editDistance(input, candidate, row[0 .. candidate.len + 1]);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

/// Levenshtein distance, keeping a single row of `b.len + 1` entries.
fn editDistance(a: []const u8, b: []const u8, row: []usize) usize {
    for (row, 0..) |*r, j| r.* = j;
    for (a, 1..) |ca, i| {
        var diagonal = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const above = row[j];
            const substitute = diagonal + @as(usize, if (ca == cb) 0 else 1);
            row[j] = @min(above + 1, row[j - 1] + 1, substitute);
            diagonal = above;
        }
    }
    return row[b.len];
}

/// Every long name in `table`, with dashes, negations included.
fn longFlags(comptime table: []const Entry) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (table) |e| out = out ++ prefixAll("--", e.longs);
    return out;
}

/// The names and aliases of the subcommands in union `U`.
fn commandNames(comptime U: type) []const []const u8 {
    const u = @typeInfo(U).@"union";
    var out: []const []const u8 = &.{};
    for (u.field_names, u.field_types) |name, Payload| {
        out = out ++ &[_][]const u8{kebab(name)} ++ configOf(Payload).aliases;
    }
    return out;
}

/// Parses the rest of the arguments as the subcommand named `arg`, or
/// returns null if there is no such subcommand.
fn parseSubcommand(
    comptime T: type,
    comptime field: usize,
    comptime globals: []const Entry,
    comptime depth: usize,
    p: *Parser,
    path: []const u8,
    arg: []const u8,
) Error!?Unwrap(@typeInfo(T).@"struct".field_types[field]) {
    const U = Unwrap(@typeInfo(T).@"struct".field_types[field]);
    const u = @typeInfo(U).@"union";
    inline for (u.field_names, u.field_types) |name, Payload| {
        if (commandMatches(Payload, comptime kebab(name), arg)) {
            const child_path = try std.fmt.allocPrint(p.arena, "{s} {s}", .{ path, comptime kebab(name) });
            const child = try parseCommand(Payload, globals, depth + 1, p, child_path);
            return @unionInit(U, name, child);
        }
    }
    return null;
}

fn commandMatches(comptime Payload: type, comptime name: []const u8, arg: []const u8) bool {
    if (std.mem.eql(u8, arg, name)) return true;
    inline for (comptime configOf(Payload).aliases) |alias| {
        if (std.mem.eql(u8, arg, alias)) return true;
    }
    return false;
}

/// Hands bare arguments to the positionals in order. A list positional takes
/// whatever the fixed ones before and after it leave over.
fn distributePositionals(comptime T: type, slots: []Slot, bare: []const []const u8, p: *Parser) Error!void {
    const info = @typeInfo(T).@"struct";
    const positionals = comptime fieldsOfKind(T, .positional);
    const fixed = comptime blk: {
        var sum: usize = 0;
        for (positionals) |i| sum += positionalWidth(info.field_types[i]) orelse 0;
        break :blk sum;
    };
    const spare = bare.len -| fixed;

    var cursor: usize = 0;
    inline for (positionals) |i| {
        const want = if (comptime positionalWidth(info.field_types[i])) |n| n else spare;
        const take = @min(want, bare.len - cursor);
        try slots[i].raws.appendSlice(p.arena, bare[cursor..][0..take]);
        cursor += take;
    }
    if (cursor < bare.len) return p.fail("unexpected argument '{s}'", .{bare[cursor]});
}

/// How many bare arguments a positional takes, null for all that are left.
fn positionalWidth(comptime F: type) ?usize {
    const U = Unwrap(F);
    if (isList(U)) return null;
    if (isArray(U)) return @typeInfo(U).array.len;
    return 1;
}

/// Turns the raw values collected for field `i` into its final value, falling
/// back to the environment and then the field default.
fn finalize(comptime T: type, comptime i: usize, slot: *Slot, p: *Parser) Error!@typeInfo(T).@"struct".field_types[i] {
    const info = @typeInfo(T).@"struct";
    const F = info.field_types[i];
    const U = Unwrap(F);
    const E = Elem(F);
    const value = comptime valueOf(T, i);
    const default = comptime info.field_attrs[i].defaultValue(F);
    const display = comptime displayName(T, i);

    switch (value.kind) {
        .count => return std.math.cast(F, slot.count) orelse std.math.maxInt(F),
        .rest => return try slot.raws.toOwnedSlice(p.arena),
        .subcommands => unreachable,
        .option, .positional, .env => {},
    }
    if (U == bool) if (slot.flag) |flag| return flag;

    var raws = slot.raws.items;
    var source: []const u8 = display;
    if (raws.len == 0) if (p.env) |env| for (value.env_vars) |name| {
        if (env.get(name)) |env_value| {
            raws = try p.arena.dupe([]const u8, &.{env_value});
            source = name;
            break;
        }
    };

    if (raws.len == 0) {
        if (default) |d| return d;
        if (@typeInfo(F) == .optional) return null;
        if (U == bool) return false;
        return switch (value.kind) {
            .positional => p.fail("missing argument {s}", .{display}),
            .env => p.fail("missing environment variable {s}", .{display}),
            else => p.fail("missing required option {s}", .{display}),
        };
    }

    const parse_fn = comptime value.parse orelse Parse.auto(E);
    if (comptime isList(U)) {
        var list: std.ArrayList(E) = .empty;
        for (raws) |raw| {
            if (value.delimiter) |d| {
                var it = std.mem.splitScalar(u8, raw, d);
                while (it.next()) |part| try list.append(p.arena, try parseValue(E, parse_fn, part, source, p));
            } else {
                try list.append(p.arena, try parseValue(E, parse_fn, raw, source, p));
            }
        }
        return try list.toOwnedSlice(p.arena);
    }

    if (comptime isArray(U)) {
        const n = @typeInfo(U).array.len;
        var parts: []const []const u8 = raws[raws.len -| n..];
        if (value.delimiter) |d| {
            var split: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, raws[raws.len - 1], d);
            while (it.next()) |part| try split.append(p.arena, part);
            parts = split.items;
        }
        if (parts.len != n) return p.fail("{s} needs {d} values, got {d}", .{ source, n, parts.len });
        var out: U = undefined;
        for (&out, parts) |*o, part| o.* = try parseValue(E, parse_fn, part, source, p);
        return out;
    }

    return try parseValue(E, parse_fn, raws[raws.len - 1], source, p);
}

fn parseValue(comptime E: type, comptime f: ParseFn(E), raw: []const u8, source: []const u8, p: *Parser) Error!E {
    var ctx: Context = .{ .arena = p.arena };
    const value = f(raw, &ctx) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseFailed => p.fail("invalid value '{s}' for {s}: {s}", .{ raw, source, ctx.message }),
    };
    for (ctx.warnings.items) |warning| {
        try p.diag.warnings.append(p.arena, try std.fmt.allocPrint(p.arena, "{s}: {s}", .{ source, warning }));
    }
    return value;
}

const HelpFn = *const fn (w: *Writer, color: bool, path: []const u8, show_version: bool) Writer.Error!void;

fn helpRequested(comptime T: type, comptime inherited: []const Entry, p: *Parser) Error {
    setHelp(T, inherited, p);
    return error.HelpRequested;
}

/// A required subcommand is missing. With no arguments at all for this
/// command, its help says more than an error would.
fn missingCommand(comptime T: type, comptime inherited: []const Entry, p: *Parser, start: usize) Error {
    if (p.index == start) {
        setHelp(T, inherited, p);
        p.diag.show_help = true;
    }
    return p.fail("missing command", .{});
}

fn setHelp(comptime T: type, comptime inherited: []const Entry, p: *Parser) void {
    const table = comptime inherited ++ optionEntries(T, 0);
    p.diag.help = .{
        .render = &struct {
            fn f(w: *Writer, color: bool, path: []const u8, show_version: bool) Writer.Error!void {
                return writeCommandHelp(T, inherited, w, color, path, show_version);
            }
        }.f,
        .show_version = p.version != null and comptime findLong(table, "version") == null,
    };
}

fn writeCommandHelp(
    comptime T: type,
    comptime inherited: []const Entry,
    w: *Writer,
    color: bool,
    path: []const u8,
    show_version: bool,
) Writer.Error!void {
    const info = @typeInfo(T).@"struct";
    const cfg = comptime configOf(T);
    const own = comptime optionEntries(T, 0);
    const positionals = comptime fieldsOfKind(T, .positional);
    const envs = comptime fieldsOfKind(T, .env);
    const sub_field = comptime firstFieldOfKind(T, .subcommands);
    const rest_field = comptime firstFieldOfKind(T, .rest);
    const print = clappy.fmt.print;

    if (cfg.description.len > 0) try w.print("{s}\n\n", .{cfg.description});

    try print(w, color, "{%bold}usage:{%} {s} [options]", .{path});
    inline for (positionals) |i| try w.print(" {s}", .{comptime usageName(T, i)});
    if (sub_field) |s| {
        try w.writeAll(if (@typeInfo(info.field_types[s]) == .optional) " [command]" else " <command>");
    }
    if (rest_field != null) try w.writeAll(if (comptime restStart(T) != null) " [args...]" else " [-- args...]");
    try w.writeAll("\n");

    const rest_description = if (rest_field) |r| comptime valueOf(T, r).description else "";
    if (positionals.len > 0 or rest_description.len > 0) {
        try print(w, color, "\n{%bold}arguments:{%}\n", .{});
        inline for (positionals) |i| {
            try writeRow(w, color, comptime usageName(T, i), comptime valueOf(T, i).description, "");
        }
        const rest_label = if (comptime restStart(T) != null) "<args>..." else "-- <args>...";
        if (rest_description.len > 0) try writeRow(w, color, rest_label, rest_description, "");
    }

    if (sub_field) |s| {
        try print(w, color, "\n{%bold}commands:{%}\n", .{});
        const u = @typeInfo(Unwrap(info.field_types[s])).@"union";
        inline for (u.field_names, u.field_types) |name, Payload| {
            const sub_cfg = comptime configOf(Payload);
            const label = comptime kebab(name) ++ if (sub_cfg.aliases.len > 0)
                " (" ++ join(sub_cfg.aliases, ", ") ++ ")"
            else
                "";
            try writeRow(w, color, label, sub_cfg.description, "");
        }
    }

    try print(w, color, "\n{%bold}options:{%}\n", .{});
    inline for (own) |e| if (e.kind != .unflag) try writeRow(w, color, e.label, e.description, e.extra);
    try writeRow(w, color, "-h, --help", "Print help", "");
    if (show_version) try writeRow(w, color, "    --version", "Print version", "");

    if (inherited.len > 0) {
        try print(w, color, "\n{%bold}global options:{%}\n", .{});
        inline for (inherited) |e| if (e.kind != .unflag) try writeRow(w, color, e.label, e.description, e.extra);
    }

    if (envs.len > 0) {
        try print(w, color, "\n{%bold}environment:{%}\n", .{});
        inline for (envs) |i| {
            const value = comptime valueOf(T, i);
            try writeRow(w, color, comptime join(value.env_vars, ", "), value.description, comptime defaultText(T, i));
        }
    }
}

fn writeRow(w: *Writer, color: bool, label: []const u8, description: []const u8, extra: []const u8) Writer.Error!void {
    const width = 26;
    try clappy.fmt.print(w, color, "  {%cyan}{s}{%}", .{label});
    if (label.len < width) {
        try w.splatByteAll(' ', width - label.len);
    } else {
        try w.writeAll("\n");
        try w.splatByteAll(' ', width + 2);
    }
    try w.writeAll(description);
    if (extra.len > 0) try clappy.fmt.print(w, color, "{%dim}{s}{%}", .{extra});
    try w.writeAll("\n");
}

/// A named option (`.option` or `.count`) as seen by the argument walk.
const Entry = struct {
    /// Which command declared it, 0 being the root.
    depth: usize,
    /// The field index in that command.
    slot: usize,
    /// `.unflag` entries are the negated names of a flag and are not shown
    /// in help on their own.
    kind: enum { flag, unflag, count, value },
    /// Arguments taken per occurrence by a `.value`.
    arity: usize,
    global: bool,
    shorts: []const u8,
    longs: []const []const u8,
    /// Used in error messages, e.g. `--log-level`.
    display: []const u8,
    /// The left column in help, e.g. `-l, --log-level <level>`.
    label: []const u8,
    description: []const u8,
    /// Env vars and default, shown after the description in help.
    extra: []const u8,
};

fn findLong(table: []const Entry, name: []const u8) ?Entry {
    for (table) |e| for (e.longs) |long| if (std.mem.eql(u8, long, name)) return e;
    return null;
}

fn findShort(table: []const Entry, c: u8) ?Entry {
    for (table) |e| if (std.mem.indexOfScalar(u8, e.shorts, c) != null) return e;
    return null;
}

fn optionEntries(comptime T: type, comptime depth: usize) []const Entry {
    const info = @typeInfo(T).@"struct";
    var entries: []const Entry = &.{};
    for (info.field_names, info.field_types, 0..) |name, F, i| {
        const value = valueOf(T, i);
        if (value.kind != .option and value.kind != .count) continue;

        const names = splitNames(value.names, name);
        const shorts = names.shorts;
        const longs = if (names.longs.len > 0) names.longs else &.{kebab(name)};

        const U = Unwrap(F);
        const kind = if (value.kind == .count) .count else if (U == bool) .flag else .value;
        const arity = if (isArray(U) and value.delimiter == null) @typeInfo(U).array.len else 1;
        const default = info.field_attrs[i].defaultValue(F);

        const negated: ?Names = if (kind != .flag) null else switch (value.negate) {
            .auto => .{ .shorts = "", .longs = negateLongs(longs) },
            .none => null,
            .names => |n| splitNames(n, name),
        };
        // `--no-cache` negates to `--cache`, which `--[no-]` can't express.
        const auto_has_no = value.negate == .auto and kind == .flag and anyHasNoPrefix(longs);

        var label: []const u8 = "";
        for (shorts) |c| label = label ++ "-" ++ &[_]u8{c} ++ ", ";
        if (shorts.len == 0) label = "    ";
        const show_auto = value.negate == .auto and kind == .flag and !auto_has_no and default != null and default.? == true;
        label = label ++ join(prefixAll(if (show_auto) "--[no-]" else "--", longs), ", ");
        if (kind == .value) {
            for (0..arity) |_| label = label ++ " " ++ placeholder(Elem(F), kebab(name));
        }
        if (isList(U)) label = label ++ "...";

        var extra: []const u8 = "";
        if (value.env_vars.len > 0) extra = extra ++ " [env: " ++ join(value.env_vars, ", ") ++ "]";
        if (value.negate == .names) extra = extra ++ " [off: " ++ join(value.negate.names, ", ") ++ "]";
        if (auto_has_no) extra = extra ++ " [off: " ++ join(prefixAll("--", negated.?.longs), ", ") ++ "]";
        if (kind == .value) extra = extra ++ defaultText(T, i);

        entries = entries ++ &[_]Entry{.{
            .depth = depth,
            .slot = i,
            .kind = kind,
            .arity = arity,
            .global = value.global,
            .shorts = shorts,
            .longs = longs,
            .display = "--" ++ longs[0],
            .label = label,
            .description = value.description,
            .extra = extra,
        }};
        if (negated) |n| entries = entries ++ &[_]Entry{.{
            .depth = depth,
            .slot = i,
            .kind = .unflag,
            .arity = 0,
            .global = value.global,
            .shorts = n.shorts,
            .longs = n.longs,
            .display = if (n.longs.len > 0) "--" ++ n.longs[0] else "-" ++ n.shorts[0..1],
            .label = "",
            .description = "",
            .extra = "",
        }};
    }
    return entries;
}

/// `--xyz` turns into `--no-xyz`, and `--no-xyz` into `--xyz`.
fn negateLongs(comptime longs: []const []const u8) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (longs) |long| {
        const negated = if (std.mem.startsWith(u8, long, "no-")) long[3..] else "no-" ++ long;
        out = out ++ &[_][]const u8{negated};
    }
    return out;
}

fn anyHasNoPrefix(comptime longs: []const []const u8) bool {
    for (longs) |long| if (std.mem.startsWith(u8, long, "no-")) return true;
    return false;
}

const Names = struct {
    shorts: []const u8,
    longs: []const []const u8,
};

fn splitNames(comptime names: []const []const u8, comptime field: []const u8) Names {
    var out: Names = .{ .shorts = "", .longs = &.{} };
    for (names) |n| {
        if (n.len > 2 and std.mem.startsWith(u8, n, "--")) {
            out.longs = out.longs ++ &[_][]const u8{n[2..]};
        } else if (n.len == 2 and n[0] == '-' and n[1] != '-') {
            out.shorts = out.shorts ++ n[1..2];
        } else {
            @compileError("invalid option name '" ++ n ++ "' for field '" ++ field ++ "', expected -x or --xyz");
        }
    }
    return out;
}

fn globalEntries(comptime entries: []const Entry) []const Entry {
    var globals: []const Entry = &.{};
    for (entries) |e| if (e.global) {
        globals = globals ++ &[_]Entry{e};
    };
    return globals;
}

fn fieldsOfKind(comptime T: type, comptime kind: Kind) []const usize {
    var fields: []const usize = &.{};
    for (0..@typeInfo(T).@"struct".field_names.len) |i| {
        if (valueOf(T, i).kind == kind) fields = fields ++ &[_]usize{i};
    }
    return fields;
}

fn firstFieldOfKind(comptime T: type, comptime kind: Kind) ?usize {
    const fields = fieldsOfKind(T, kind);
    return if (fields.len > 0) fields[0] else null;
}

/// Compile errors for configurations the parser can't handle unambiguously.
fn validate(comptime T: type, comptime table: []const Entry) void {
    const info = @typeInfo(T).@"struct";
    const where = " in " ++ @typeName(T);

    for (table, 0..) |a, i| {
        for (a.longs) |long| {
            if (std.mem.eql(u8, long, "help")) @compileError("--help is reserved" ++ where);
            for (table[i + 1 ..]) |b| for (b.longs) |other| if (std.mem.eql(u8, long, other))
                @compileError("--" ++ long ++ " is used by more than one option (or shadows a global one)" ++ where);
        }
        for (a.shorts) |c| {
            if (c == 'h') @compileError("-h is reserved" ++ where);
            for (table[i + 1 ..]) |b| if (std.mem.indexOfScalar(u8, b.shorts, c) != null)
                @compileError("-" ++ &[_]u8{c} ++ " is used by more than one option (or shadows a global one)" ++ where);
        }
    }

    for (info.field_names, info.field_types, 0..) |name, F, i| {
        const value = valueOf(T, i);
        const U = Unwrap(F);
        if (value.negate != .auto and (value.kind != .option or U != bool))
            @compileError("only bool options can set .negate ('" ++ name ++ "')" ++ where);
        if (value.global and value.kind != .option and value.kind != .count)
            @compileError("only options can be global ('" ++ name ++ "')" ++ where);
        if (isList(U) and isArray(@typeInfo(U).pointer.child))
            @compileError("lists of arrays are not supported ('" ++ name ++ "')" ++ where);
        if (isArray(U) and value.env_vars.len > 0 and value.delimiter == null)
            @compileError("array '" ++ name ++ "' read from the environment needs a delimiter" ++ where);
    }

    var seen_optional = false;
    var seen_list = false;
    for (fieldsOfKind(T, .positional)) |i| {
        const F = info.field_types[i];
        const name = info.field_names[i];
        if (Unwrap(F) == bool) @compileError("positional '" ++ name ++ "' can't be a bool" ++ where);
        if (isList(Unwrap(F))) {
            if (seen_list) @compileError("only one positional can be a list" ++ where);
            seen_list = true;
        } else if (@typeInfo(F) == .optional or info.field_attrs[i].default_value_ptr != null) {
            seen_optional = true;
        } else if (seen_optional) {
            @compileError("required positional '" ++ name ++ "' comes after an optional one" ++ where);
        }
    }
    if (seen_list and seen_optional) @compileError("a list positional can't be combined with optional positionals" ++ where);

    for (fieldsOfKind(T, .count)) |i| {
        if (@typeInfo(info.field_types[i]) != .int) @compileError("count '" ++ info.field_names[i] ++ "' must be an integer" ++ where);
    }
    for (fieldsOfKind(T, .env)) |i| {
        if (valueOf(T, i).env_vars.len == 0) @compileError("env '" ++ info.field_names[i] ++ "' needs at least one name" ++ where);
    }

    const rests = fieldsOfKind(T, .rest);
    if (rests.len > 1) @compileError("only one field can be .rest" ++ where);
    for (rests) |i| {
        if (info.field_types[i] != []const []const u8) @compileError(".rest field '" ++ info.field_names[i] ++ "' must be []const []const u8" ++ where);
    }

    const subs = fieldsOfKind(T, .subcommands);
    if (subs.len > 1) @compileError("only one field can be .subcommands" ++ where);
    for (subs) |i| {
        const F = info.field_types[i];
        const U = Unwrap(F);
        if (@typeInfo(U) != .@"union" or @typeInfo(U).@"union".tag_type == null)
            @compileError("subcommands field '" ++ info.field_names[i] ++ "' must be a union(enum)" ++ where);
        const u = @typeInfo(U).@"union";
        for (u.field_types) |Payload| {
            if (@typeInfo(Payload) != .@"struct") @compileError("subcommands must be structs" ++ where);
        }
        // Each name and alias, paired with the index of the command it belongs to.
        var claimed_names: []const []const u8 = &.{};
        var claimed_by: []const usize = &.{};
        for (u.field_names, u.field_types, 0..) |command, Payload, c| {
            for (&[_][]const u8{kebab(command)} ++ configOf(Payload).aliases) |name| {
                for (claimed_names, claimed_by) |other, by| if (std.mem.eql(u8, other, name))
                    @compileError("'" ++ name ++ "' names both '" ++ u.field_names[by] ++ "' and '" ++ command ++ "'" ++ where);
                claimed_names = claimed_names ++ &[_][]const u8{name};
                claimed_by = claimed_by ++ &[_]usize{c};
            }
        }
        if (@typeInfo(F) != .optional and fieldsOfKind(T, .positional).len > 0)
            @compileError("positionals next to a required subcommand are ambiguous, make the subcommand optional" ++ where);
    }
}

fn configOf(comptime T: type) Config(T) {
    return if (@hasDecl(T, "clappy_config")) T.clappy_config else .{};
}

/// The configured value for field `i`, or the inferred one when it is missing.
fn valueOf(comptime T: type, comptime i: usize) Value(@typeInfo(T).@"struct".field_types[i]) {
    const info = @typeInfo(T).@"struct";
    const F = info.field_types[i];
    return @field(configOf(T).values, info.field_names[i]) orelse switch (@typeInfo(Unwrap(F))) {
        .@"union" => .subcommands,
        else => .option(.{}),
    };
}

fn displayName(comptime T: type, comptime i: usize) []const u8 {
    const value = valueOf(T, i);
    return switch (value.kind) {
        .positional => usageName(T, i),
        .env => value.env_vars[0],
        .rest, .subcommands => kebab(@typeInfo(T).@"struct".field_names[i]),
        .option, .count => for (optionEntries(T, 0)) |e| {
            if (e.slot == i) break e.display;
        } else unreachable,
    };
}

/// `<src>`, `[dest]`, `<files>...` or `<size> <size>`.
fn usageName(comptime T: type, comptime i: usize) []const u8 {
    const info = @typeInfo(T).@"struct";
    const F = info.field_types[i];
    const U = Unwrap(F);
    const name = kebab(info.field_names[i]);
    if (isList(U)) return "<" ++ name ++ ">...";
    const one = if (@typeInfo(F) == .optional or info.field_attrs[i].default_value_ptr != null)
        "[" ++ name ++ "]"
    else
        "<" ++ name ++ ">";
    if (!isArray(U)) return one;
    var out: []const u8 = one;
    for (1..@typeInfo(U).array.len) |_| out = out ++ " " ++ one;
    return out;
}

fn placeholder(comptime E: type, comptime name: []const u8) []const u8 {
    return switch (@typeInfo(E)) {
        .@"enum" => "<" ++ tagList(E, "|") ++ ">",
        else => "<" ++ name ++ ">",
    };
}

fn defaultText(comptime T: type, comptime i: usize) []const u8 {
    const info = @typeInfo(T).@"struct";
    const F = info.field_types[i];
    const U = Unwrap(F);
    const field_default = info.field_attrs[i].defaultValue(F) orelse return "";
    // `?u16 = 5` shows 5, `?u16 = null` shows nothing.
    const default: U = if (@typeInfo(F) == .optional) field_default orelse return "" else field_default;
    return switch (@typeInfo(U)) {
        .int, .float => std.fmt.comptimePrint(" [default: {d}]", .{default}),
        .@"enum" => " [default: " ++ @tagName(default) ++ "]",
        .pointer => if (U == []const u8) " [default: \"" ++ default ++ "\"]" else "",
        .array => |a| if (@typeInfo(a.child) == .int) std.fmt.comptimePrint(" [default: {any}]", .{default}) else "",
        else => "",
    };
}

fn Unwrap(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
}

/// Slices other than strings collect every value.
fn isList(comptime F: type) bool {
    const info = @typeInfo(F);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
}

fn isArray(comptime F: type) bool {
    return @typeInfo(F) == .array;
}

/// The type a single raw value parses into.
fn Elem(comptime F: type) type {
    const U = Unwrap(F);
    if (isList(U)) return @typeInfo(U).pointer.child;
    if (isArray(U)) return @typeInfo(U).array.child;
    return U;
}

fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = name[0..name.len].*;
        for (&buf) |*c| if (c.* == '_') {
            c.* = '-';
        };
        const final = buf;
        return &final;
    }
}

fn tagList(comptime E: type, comptime separator: []const u8) []const u8 {
    return join(std.meta.fieldNames(E), separator);
}

fn join(comptime parts: anytype, comptime separator: []const u8) []const u8 {
    var out: []const u8 = "";
    for (parts, 0..) |part, i| out = out ++ (if (i > 0) separator else "") ++ part;
    return out;
}

fn prefixAll(comptime prefix: []const u8, comptime parts: []const []const u8) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (parts) |part| out = out ++ &[_][]const u8{prefix ++ part};
    return out;
}

const testing = std.testing;

const TestRoot = struct {
    pub const clappy_config: Config(@This()) = .{
        .values = .{
            .verbose = .count(.{ .names = &.{"-v"}, .global = true }),
            .color = .option(.{ .global = true, .env = &.{"APP_COLOR"} }),
        },
    };

    verbose: u8 = 0,
    color: bool = false,
    command: union(enum) {
        serve: Serve,
        copy: Copy,
        run: Run,
        resize: Resize,
    },

    const Serve = struct {
        pub const clappy_config: Config(@This()) = .{
            .aliases = &.{"s"},
            .values = .{
                .port = .option(.{ .names = &.{"-p"}, .parse = parsePort }),
                .tags = .option(.{ .names = &.{"-t"}, .delimiter = ',' }),
                .dry_run = .option(.{ .negate = .none }),
            },
        };

        port: u16 = 8080,
        level: enum { debug, info } = .info,
        tags: []const []const u8 = &.{},
        dry_run: bool = false,
        no_cache: bool = false,
        timeout: ?u32 = 30,

        fn parsePort(raw: []const u8, ctx: *Context) ParseError!u16 {
            const port = try Parse.int(u16)(raw, ctx);
            if (port == 0) return ctx.fail("must be greater than 0", .{});
            if (port < 1024) try ctx.warn("{d} is a privileged port", .{port});
            return port;
        }
    };

    const Copy = struct {
        pub const clappy_config: Config(@This()) = .{
            .values = .{
                .sources = .positional(.{}),
                .dest = .positional(.{}),
            },
        };

        sources: []const []const u8,
        dest: []const u8,
    };

    const Run = struct {
        pub const clappy_config: Config(@This()) = .{
            .values = .{
                .script = .positional(.{}),
                .args = .rest(.{ .description = "Passed to the script" }),
            },
        };

        script: []const u8,
        args: []const []const u8,
    };

    const Resize = struct {
        pub const clappy_config: Config(@This()) = .{
            .values = .{
                .size = .positional(.{}),
                .offset = .option(.{ .names = &.{"-o"}, .delimiter = ',', .env = &.{"OFFSET"} }),
                .scale = .option(.{}),
                .fast = .option(.{ .names = &.{"-f"}, .negate = .{ .names = &.{ "-S", "--slow" } } }),
            },
        };

        size: [2]i32,
        offset: [2]i32 = .{ 0, 0 },
        scale: [2]f32 = .{ 1, 1 },
        keep_ratio: bool = true,
        fast: bool = true,
    };
};

fn testParse(comptime T: type, arena: Allocator, args: []const [:0]const u8, env: ?*const Environ.Map, diag: *Diagnostic) Error!T {
    const argv = try std.mem.concat(arena, [:0]const u8, &.{ &.{"app"}, args });
    return parseArgs(T, arena, argv, env, .{ .version = "1.2.3" }, diag);
}

test "globals before and after the subcommand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, arena.allocator(), &.{ "-v", "serve", "-vv", "--color", "-p8080", "--level=debug" }, null, &diag);
    try testing.expectEqual(3, args.verbose);
    try testing.expect(args.color);
    try testing.expectEqual(8080, args.command.serve.port);
    try testing.expectEqual(.debug, args.command.serve.level);
}

test "repeated and delimited options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, arena.allocator(), &.{ "s", "-t", "a,b", "--tags", "c" }, null, &diag);
    const tags = args.command.serve.tags;
    try testing.expectEqual(3, tags.len);
    try testing.expectEqualStrings("c", tags[2]);
}

test "variadic positional before a fixed one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, a, &.{ "copy", "a", "b", "c", "out/" }, null, &diag);
    try testing.expectEqual(3, args.command.copy.sources.len);
    try testing.expectEqualStrings("out/", args.command.copy.dest);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "copy", "out/" }, null, &diag));
    try testing.expectEqualStrings("missing argument <sources>...", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"copy"}, null, &diag));
    try testing.expectEqualStrings("missing argument <sources>...", diag.message);
}

test "rest args" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, arena.allocator(), &.{ "run", "build.sh", "--", "--release", "-v" }, null, &diag);
    try testing.expectEqualStrings("build.sh", args.command.run.script);
    try testing.expectEqual(2, args.command.run.args.len);
    try testing.expectEqual(0, args.verbose);
}

test "rest args without --" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, a, &.{ "run", "-v", "build.sh", "--release", "-v", "--", "x" }, null, &diag);
    const run = args.command.run;
    try testing.expectEqualStrings("build.sh", run.script);
    try testing.expectEqual(4, run.args.len);
    try testing.expectEqualStrings("--release", run.args[0]);
    try testing.expectEqualStrings("--", run.args[2]);
    try testing.expectEqual(1, args.verbose);

    const Exec = struct {
        pub const clappy_config: Config(@This()) = .{ .values = .{ .cmd = .rest(.{}) } };
        quiet: bool = false,
        cmd: []const []const u8,
    };
    const exec = try testParse(Exec, a, &.{ "--quiet", "ls", "--quiet" }, null, &diag);
    try testing.expect(exec.quiet);
    try testing.expectEqual(2, exec.cmd.len);
    try testing.expectEqualStrings("ls", exec.cmd[0]);
}

test "rest args that require --" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    const Cargo = struct {
        pub const clappy_config: Config(@This()) = .{ .values = .{
            .bin = .positional(.{}),
            .args = .rest(.{ .description = "Passed to the binary", .require_dash_dash = true }),
        } };
        release: bool = false,
        bin: []const u8,
        args: []const []const u8,
    };
    const args = try testParse(Cargo, a, &.{ "app", "--release", "--", "--release" }, null, &diag);
    try testing.expect(args.release);
    try testing.expectEqual(1, args.args.len);

    try testing.expectError(error.ParseFailed, testParse(Cargo, a, &.{ "app", "extra" }, null, &diag));
    try testing.expectEqualStrings("unexpected argument 'extra'", diag.message);

    try testing.expectError(error.HelpRequested, testParse(Cargo, a, &.{"-h"}, null, &diag));
    const help = try renderHelp(a, &diag);
    try testing.expect(std.mem.indexOf(u8, help, "<bin> [-- args...]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "-- <args>...") != null);
}

test "arrays, negative numbers and negated flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, a, &.{ "resize", "-5", "20", "-o-1,2", "--scale", "0.5", "-.5", "--no-keep-ratio" }, null, &diag);
    const r = args.command.resize;
    try testing.expectEqual([2]i32{ -5, 20 }, r.size);
    try testing.expectEqual([2]i32{ -1, 2 }, r.offset);
    try testing.expectEqual([2]f32{ 0.5, -0.5 }, r.scale);
    try testing.expect(!r.keep_ratio);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "resize", "1", "2", "-o", "3" }, null, &diag));
    try testing.expectEqualStrings("--offset needs 2 values, got 1", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "resize", "1", "2", "--scale", "3" }, null, &diag));
    try testing.expectEqualStrings("--scale needs 2 values", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "resize", "1" }, null, &diag));
    try testing.expectEqualStrings("<size> <size> needs 2 values, got 1", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "resize", "1", "2", "3" }, null, &diag));
    try testing.expectEqualStrings("unexpected argument '3'", diag.message);
}

test "configurable negation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, a, &.{ "serve", "--dry-run" }, null, &diag);
    try testing.expect(args.command.serve.dry_run);
    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--no-dry-run" }, null, &diag));
    try testing.expectEqualStrings("unknown option '--no-dry-run'", diag.message);

    try testing.expect(!(try testParse(TestRoot, a, &.{ "resize", "1", "2", "-S" }, null, &diag)).command.resize.fast);
    try testing.expect(!(try testParse(TestRoot, a, &.{ "resize", "1", "2", "--slow" }, null, &diag)).command.resize.fast);
    try testing.expect((try testParse(TestRoot, a, &.{ "resize", "1", "2", "--slow", "-f" }, null, &diag)).command.resize.fast);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "resize", "1", "2", "--no-fast" }, null, &diag));
    try testing.expectEqualStrings("unknown option '--no-fast'", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "resize", "1", "2", "--slow=yes" }, null, &diag));
    try testing.expectEqualStrings("--slow does not take a value", diag.message);
}

test "env fallback and precedence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("APP_COLOR", "yes");
    try env.put("OFFSET", "7,8");

    const args = try testParse(TestRoot, a, &.{ "resize", "1", "2" }, &env, &diag);
    try testing.expect(args.color);
    try testing.expectEqual([2]i32{ 7, 8 }, args.command.resize.offset);

    const flagged = try testParse(TestRoot, a, &.{ "--no-color", "resize", "1", "2", "-o", "0,0" }, &env, &diag);
    try testing.expect(!flagged.color);
    try testing.expectEqual([2]i32{ 0, 0 }, flagged.command.resize.offset);

    try env.put("APP_COLOR", "nope");
    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"serve"}, &env, &diag));
    try testing.expectEqualStrings("invalid value 'nope' for APP_COLOR: expected true or false", diag.message);
}

test "warnings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const args = try testParse(TestRoot, arena.allocator(), &.{ "serve", "-p", "80" }, null, &diag);
    try testing.expectEqual(80, args.command.serve.port);
    try testing.expectEqual(1, diag.warnings.items.len);
    try testing.expectEqualStrings("--port: 80 is a privileged port", diag.warnings.items[0]);
}

test "errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{}, null, &diag));
    try testing.expectEqualStrings("missing command", diag.message);
    try testing.expect(diag.show_help);
    try testing.expect(std.mem.indexOf(u8, try renderHelp(a, &diag), "usage: app [options] <command>") != null);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"-v"}, null, &diag));
    try testing.expectEqualStrings("missing command", diag.message);
    try testing.expect(!diag.show_help);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"deploy"}, null, &diag));
    try testing.expectEqualStrings("unknown command 'deploy'", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--port", "0" }, null, &diag));
    try testing.expectEqualStrings("invalid value '0' for --port: must be greater than 0", diag.message);
    try testing.expectEqualStrings("app serve", diag.command);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--level", "loud" }, null, &diag));
    try testing.expectEqualStrings("invalid value 'loud' for --level: expected one of: debug, info", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--port" }, null, &diag));
    try testing.expectEqualStrings("--port needs a value", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "copy", "x", "--nope" }, null, &diag));
    try testing.expectEqualStrings("unknown option '--nope'", diag.message);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--no-port" }, null, &diag));
    try testing.expectEqualStrings("unknown option '--no-port'", diag.message);
}

test "help and version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    try testing.expectError(error.VersionRequested, testParse(TestRoot, a, &.{"--version"}, null, &diag));
    try testing.expectEqualStrings("app", diag.program);
    try testing.expectError(error.VersionRequested, testParse(TestRoot, a, &.{ "serve", "--version" }, null, &diag));
    try testing.expectEqualStrings("app", diag.program);

    try testing.expectError(error.HelpRequested, testParse(TestRoot, a, &.{ "resize", "-h" }, null, &diag));
    const help = try renderHelp(a, &diag);
    try testing.expect(std.mem.indexOf(u8, help, "usage: app resize [options] <size> <size>") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--[no-]keep-ratio") != null);
    try testing.expect(std.mem.indexOf(u8, help, "-f, --fast") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[off: -S, --slow]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--scale <scale> <scale>") != null);
    try testing.expect(std.mem.indexOf(u8, help, "global options:") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--version") != null);

    try testing.expectError(error.HelpRequested, testParse(TestRoot, a, &.{ "run", "-h" }, null, &diag));
    const run_help = try renderHelp(a, &diag);
    try testing.expect(std.mem.indexOf(u8, run_help, "<script> [args...]") != null);
    try testing.expect(std.mem.indexOf(u8, run_help, "Passed to the script") != null);

    try testing.expectError(error.HelpRequested, testParse(TestRoot, a, &.{ "serve", "-h" }, null, &diag));
    const serve_help = try renderHelp(a, &diag);
    try testing.expect(std.mem.indexOf(u8, serve_help, "[default: 30]") != null);
    try testing.expect(std.mem.indexOf(u8, serve_help, "    --no-cache ") != null);
    try testing.expect(std.mem.indexOf(u8, serve_help, "[off: --cache]") != null);
}

test "version option defined by the command wins" {
    const Cmd = struct {
        version: ?u8 = null,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const args = try testParse(Cmd, arena.allocator(), &.{ "--version", "3" }, null, &diag);
    try testing.expectEqual(3, args.version);
}

test "flags named no_*" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    try testing.expect((try testParse(TestRoot, a, &.{ "serve", "--no-cache" }, null, &diag)).command.serve.no_cache);
    try testing.expect(!(try testParse(TestRoot, a, &.{ "serve", "--no-cache", "--cache" }, null, &diag)).command.serve.no_cache);
    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--no-no-cache" }, null, &diag));
}

test "suggestions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--prot=80" }, null, &diag));
    try testing.expectEqualStrings("unknown option '--prot'", diag.message);
    try testing.expectEqualStrings("--port", diag.suggestion.?);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--verbos" }, null, &diag));
    try testing.expectEqualStrings("--verbose", diag.suggestion.?);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--no-colr" }, null, &diag));
    try testing.expectEqualStrings("--no-color", diag.suggestion.?);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"--verison"}, null, &diag));
    try testing.expectEqualStrings("--version", diag.suggestion.?);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"serv"}, null, &diag));
    try testing.expectEqualStrings("serve", diag.suggestion.?);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"rezise"}, null, &diag));
    try testing.expectEqualStrings("resize", diag.suggestion.?);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{"deploy"}, null, &diag));
    try testing.expect(diag.suggestion == null);

    try testing.expectError(error.ParseFailed, testParse(TestRoot, a, &.{ "serve", "--zzz" }, null, &diag));
    try testing.expect(diag.suggestion == null);
}

test "optional subcommand" {
    const Cmd = struct {
        verbose: bool = false,
        command: ?union(enum) { serve: TestRoot.Serve, run: TestRoot.Run },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    try testing.expect((try testParse(Cmd, a, &.{}, null, &diag)).command == null);
    try testing.expect((try testParse(Cmd, a, &.{"--verbose"}, null, &diag)).command == null);

    try testing.expectError(error.ParseFailed, testParse(Cmd, a, &.{"serv"}, null, &diag));
    try testing.expectEqualStrings("unknown command 'serv'", diag.message);
    try testing.expectEqualStrings("serve", diag.suggestion.?);
    try testing.expect(!diag.show_help);
}

test writeHelp {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());

    try writeHelp(TestRoot, &out.writer, false, "app", "1.2.3");
    const help = out.written();
    try testing.expect(std.mem.indexOf(u8, help, "usage: app [options] <command>") != null);
    try testing.expect(std.mem.indexOf(u8, help, "serve (s)") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--version") != null);
}

fn renderHelp(arena: Allocator, diag: *const Diagnostic) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try diag.writeHelp(&out.writer, false);
    return out.written();
}
