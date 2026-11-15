# clappy

Declarative command-line parsing for Zig. Describe your CLI as a struct and
clappy fills it in, with help, errors and color handled for you.

- Field types decide the shape: options, flags, lists, fixed-size arrays, enums
- Subcommands as a `union(enum)`, with aliases and global options
- Environment variable fallbacks
- Generated `--help`, `--version` and "did you mean" suggestions
- Custom value parsers with errors and warnings
- Styled terminal output (`{%red,bold}error:{%}`), compiled at comptime

Requires Zig 0.17 or newer.

## Installation

```sh
zig fetch --save git+https://github.com/shreyassanthu77/clappy
```

Then in `build.zig`:

```zig
const clappy = b.dependency("clappy", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("clappy", clappy.module("clappy"));
```

## Quick start

```zig
const std = @import("std");
const clappy = @import("clappy");

const Args = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Greets people",
        .values = .{
            .name = .positional(.{ .description = "Who to greet" }),
            .times = .option(.{ .names = &.{"-n"}, .description = "How many times" }),
            .shout = .option(.{ .names = &.{"-s"}, .description = "Use capital letters" }),
        },
    };

    name: []const u8,
    times: u8 = 1,
    shout: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try clappy.parse(Args, init, .{ .version = "0.1.0" });
    for (0..args.times) |_| {
        if (args.shout) {
            std.debug.print("HELLO, {s}!\n", .{args.name});
        } else {
            std.debug.print("hello, {s}\n", .{args.name});
        }
    }
}
```

```console
$ greet world -n 2 -s
HELLO, world!
HELLO, world!

$ greet --help
Greets people

usage: greet [options] <name>

arguments:
  <name>                    Who to greet

options:
  -n, --times <times>       How many times [default: 1]
  -s, --shout               Use capital letters
  -h, --help                Print help
      --version             Print version

$ greet
error: missing argument <name>
run 'greet --help' for usage
```

`clappy.parse` prints help, the version or errors and exits by itself, so you
only get back a filled-in struct. Everything it returns lives in `init.arena`.

## How fields are read

Each field gets its value from a `.values` entry in `clappy_config`:

| Kind                  | Example                                   | Meaning                                     |
| --------------------- | ----------------------------------------- | ------------------------------------------- |
| `.option(.{...})`     | `--port 80`, `-p80`, `--port=80`          | A named option or flag                      |
| `.positional(.{...})` | `app input.txt`                           | Bare arguments, in field declaration order  |
| `.count(.{...})`      | `-vvv`                                    | How often a flag was given (integer field)  |
| `.env(.{...})`        | `API_TOKEN=... app`                       | Only read from the environment              |
| `.rest(.{...})`       | `app run script -- --raw args`            | Everything after `--` (`[]const []const u8`) |
| `.subcommands`        | `app serve`                               | A `union(enum)` of command structs          |

Fields left out of `.values` become options named after the field
(`log_level` → `--log-level`), or subcommands if they are unions. A struct
without `clappy_config` at all just works.

The field type decides the rest:

- A default value or `?T` makes it optional; otherwise it's required.
- `bool` options are flags, and get a `--no-` variant to turn them off.
- `[]const T` options can be repeated; `[]const T` positionals take any number of values.
- `[N]T` takes exactly N values, e.g. `--size 800 600`.
- Integers, floats, enums, bools and strings are parsed out of the box. Enum
  options list their choices in help: `--mode <debug|release>`.

Values from the command line win over environment variables, which win over
field defaults.

## Options, environment and custom parsers

```zig
const Serve = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .values = .{
            .port = .option(.{
                .names = &.{"-p"},
                .description = "Port to listen on",
                .env = &.{"PORT"}, // used when --port is not given
                .parse = parsePort,
            }),
            .tags = .option(.{
                .names = &.{"-t"},
                .description = "Tags, repeatable or comma separated",
                .delimiter = ',', // -t a,b -t c → { "a", "b", "c" }
            }),
            .token = .env(.{ .names = &.{"API_TOKEN"}, .description = "API token" }),
        },
    };

    port: u16 = 8080,
    tags: []const []const u8 = &.{},
    token: ?[]const u8 = null,
    mode: enum { debug, release } = .debug, // --mode release
    cache: bool = true, // --cache / --no-cache

    fn parsePort(raw: []const u8, ctx: *clappy.cmd.Context) clappy.cmd.ParseError!u16 {
        const port = try clappy.cmd.Parse.int(u16)(raw, ctx);
        if (port == 0) return ctx.fail("must be greater than 0", .{});
        if (port < 1024) try ctx.warn("{d} usually needs root", .{port});
        return port;
    }
};
```

`ctx.fail` turns into `error: invalid value '0' for --port: must be greater
than 0`, and `ctx.warn` prints a warning without stopping. The built-in parsers
live in `clappy.cmd.Parse` (`auto`, `string`, `boolean`, `int`, `float`,
`fromEnumTag`) so custom parsers can build on them.

Bool flags can be turned off with a custom name, or not at all:

```zig
.fast = .option(.{ .names = &.{"-f"}, .negate = .{ .names = &.{ "-S", "--slow" } } }),
.dry_run = .option(.{ .negate = .none }),
```

## Subcommands

```zig
const Cli = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "A tiny package manager",
        .values = .{
            .verbose = .count(.{
                .names = &.{"-v"},
                .description = "More output, repeat for more",
                .global = true, // also accepted after a subcommand
            }),
        },
    };

    verbose: u8 = 0,
    command: union(enum) {
        add: Add,
        remove: Remove,
        run: Run,
    },
};

const Add = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Add packages",
        .aliases = &.{"a"},
        .values = .{
            .packages = .positional(.{ .description = "Packages to add" }),
            .dev = .option(.{ .names = &.{"-D"}, .description = "Add as a dev dependency" }),
        },
    };

    packages: []const []const u8,
    dev: bool = false,
};

const Remove = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Remove a package",
        .values = .{ .package = .positional(.{}) },
    };

    package: []const u8,
};

const Run = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Run a script",
        .values = .{
            .script = .positional(.{ .description = "Script to run" }),
            .args = .rest(.{ .description = "Arguments for the script" }),
        },
    };

    script: []const u8,
    args: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const cli = try clappy.parse(Cli, init, .{ .name = "pkg", .version = "1.0.0" });
    switch (cli.command) {
        .add => |a| for (a.packages) |p| std.debug.print("adding {s}\n", .{p}),
        .remove => |r| std.debug.print("removing {s}\n", .{r.package}),
        .run => |r| std.debug.print("running {s} with {d} args\n", .{ r.script, r.args.len }),
    }
}
```

```console
$ pkg -v a foo bar -D
adding foo
adding bar

$ pkg run build -- --release
running build with 1 args

$ pkg add --help
Add packages

usage: pkg add [options] <packages>...

arguments:
  <packages>...             Packages to add

options:
  -D, --dev                 Add as a dev dependency
  -h, --help                Print help
      --version             Print version

global options:
  -v, --verbose             More output, repeat for more

$ pkg ad foo
error: unknown command 'ad'
did you mean add?
run 'pkg --help' for usage
```

Running `pkg` with no arguments prints its help. Make the union optional
(`command: ?union(enum) { ... }`) if a subcommand isn't required, and call
`clappy.cmd.printHelp(Cli, init, options)` to show the help yourself.

## Styled output

`clappy.fmt` adds inline style tags on top of the regular `std.Io.Writer`
format syntax. Tags are compiled away at comptime, and color is turned off
automatically when the output isn't a terminal or `NO_COLOR` is set.

```zig
const std = @import("std");
const clappy = @import("clappy");

// Optional: style tags in std.log messages too.
pub const std_options: std.Options = .{ .logFn = clappy.fmt.logFn };

pub fn main(init: std.process.Init) !void {
    try clappy.fmt.init(init); // detects color support for stdout

    try clappy.fmt.stdout("{%green,bold}done{%} wrote {%u}{s}{%}\n", .{"config.toml"});
    try clappy.fmt.stderr("{%#ff8700}heads up:{%} {d} files skipped\n", .{3});
    std.log.warn("could not open {%b}{s}{%}", .{"config.toml"});
}
```

- `{%spec}` opens a style and `{%}` closes it. Styles nest.
- `spec` is a comma-separated list of colors (`red`, `bright_blue`, `#rrggbb`),
  backgrounds (`bg:blue`) and attributes (`bold`/`b`, `dim`, `italic`/`i`,
  `underline`/`u`, `inverse`, `strike`/`s`).
- `clappy.fmt.print(writer, color, fmt, args)` writes to any writer.

To force color on or off for the whole program, declare this in your root file:

```zig
pub const clappy_options: clappy.Options = .{ .color = .never }; // .auto, .always or .never
```

## Example

[`src/main.zig`](src/main.zig) has a fuller example. Try it with:

```sh
zig build run -- --help
zig build run -- serve -p 3000 -t a,b
```

## Tests

```sh
zig build test
```
