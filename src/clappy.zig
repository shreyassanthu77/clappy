const std = @import("std");
const root = @import("root");

pub const fmt = @import("clappy/fmt.zig");
pub const cmd = @import("clappy/cmd.zig");

pub const parse = cmd.parse;

/// Set by declaring `pub const clappy_options: clappy.Options = .{ ... };` in
/// the root source file.
pub const Options = struct {
    color: ColorChoice = .auto,

    pub const ColorChoice = enum {
        /// Detect per stream at runtime.
        auto,
        always,
        never,
    };
};

pub const options: Options = if (@hasDecl(root, "clappy_options")) root.clappy_options else .{};

test {
    std.testing.refAllDecls(@This());
}
