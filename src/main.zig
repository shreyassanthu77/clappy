const std = @import("std");
const clappy = @import("clappy");

pub const clappy_options: clappy.Options = .{ .color = .auto };
pub const std_options: std.Options = .{ .logFn = clappy.fmt.logFn };

pub fn main(init: std.process.Init) !void {
    try clappy.fmt.init(init);

    try clappy.fmt.stderr("{%red,bold}error:{%} could not open {%#ff8700,i}{s}{%}\n", .{"config.zon"});
    try clappy.fmt.stdout("hello {%green,bold}this is bold and green, {%u}underlined too{%}!\n", .{});
    try clappy.fmt.stdout("usage: clappy-example {%dim}[options] <path>{%}\n", .{});

    std.log.info("loaded {%b}{d}{%} plugins", .{3});
    std.log.scoped(.net).warn("retrying {%yellow}{s}{%}", .{"example.com"});
}
