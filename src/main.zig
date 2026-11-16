const std = @import("std");
const clappy = @import("clappy");

pub const clappy_options: clappy.Options = .{ .color = .auto };
pub const std_options: std.Options = .{ .logFn = clappy.fmt.logFn };

const Root = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Example application using clappy",
        .values = .{
            .dev = .env(.{
                .names = &.{ "DEV", "dev" },
                .description = "Run in development mode",
            }),
            .verbose = .count(.{
                .names = &.{"-v"},
                .description = "More logging, repeat for even more",
                .global = true,
            }),
            .log_level = .option(.{
                .names = &.{"-l"},
                .description = "Set the log level",
                .env = &.{"LOG_LEVEL"},
                .global = true,
            }),
            .command = .subcommands,
        },
    };

    dev: bool = false,
    verbose: u8 = 0,
    log_level: LogLevel = .info,
    command: union(enum) {
        serve: Serve,
        copy: Copy,
        run: Run,
    },

    const LogLevel = enum { debug, info, warn, err };
};

const Serve = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Start the server",
        .aliases = &.{"s"},
        .values = .{
            .port = .option(.{
                .names = &.{"-p"},
                .description = "Port to listen on",
                .env = &.{"PORT"},
                .parse = parsePort,
            }),
            .host = .option(.{ .description = "Address to bind to" }),
            .tags = .option(.{
                .names = &.{"-t"},
                .description = "Tags to attach, repeatable or comma separated",
                .delimiter = ',',
            }),
        },
    };

    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    tags: []const []const u8 = &.{},

    fn parsePort(raw: []const u8, ctx: *clappy.cmd.Context) clappy.cmd.ParseError!u16 {
        const port = try clappy.cmd.Parse.int(u16)(raw, ctx);
        if (port == 0) return ctx.fail("port must be greater than 0", .{});
        if (port < 1024) try ctx.warn("{d} usually needs root", .{port});
        return port;
    }
};

const Copy = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Copy files into a directory",
        .values = .{
            .sources = .positional(.{ .description = "Files to copy" }),
            .dest = .positional(.{ .description = "Destination directory" }),
            .force = .option(.{ .names = &.{"-f"}, .description = "Overwrite existing files" }),
        },
    };

    sources: []const []const u8,
    dest: []const u8,
    force: bool = false,
};

const Run = struct {
    pub const clappy_config: clappy.cmd.Config(@This()) = .{
        .description = "Run a script, passing everything after it through",
        .values = .{
            .script = .positional(.{ .description = "Script to run" }),
            .args = .rest(.{ .description = "Arguments for the script" }),
        },
    };

    script: []const u8,
    args: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    try clappy.fmt.init(init);

    const args = try clappy.parse(Root, init, .{ .name = "clappy-example", .version = "1.0.0" });

    std.log.info("dev={} verbose={d} log_level={t}", .{ args.dev, args.verbose, args.log_level });
    switch (args.command) {
        .serve => |s| try clappy.fmt.stdout("serving on {%green,bold}{s}:{d}{%} tags={f}\n", .{ s.host, s.port, list(s.tags) }),
        .copy => |c| try clappy.fmt.stdout("copying {f} into {%b}{s}{%} (force={})\n", .{ list(c.sources), c.dest, c.force }),
        .run => |r| try clappy.fmt.stdout("running {%b}{s}{%} with {f}\n", .{ r.script, list(r.args) }),
    }
}

fn list(items: []const []const u8) std.fmt.Alt([]const []const u8, formatList) {
    return .{ .data = items };
}

fn formatList(items: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |item, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", item });
    try w.writeAll("]");
}
