const std = @import("std");

pub const Style = struct {
    color: ?Color = null,
    bold: ?bool = null,

    pub fn format(self: Style, w: *std.Io.Writer) !void {
        _ = self;
        try w.writeAll("Hello World!");
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub inline fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub const green = rgb(0x00, 0x9f, 0x00);
};
