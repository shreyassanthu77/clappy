const std = @import("std");
const clappy = @import("clappy");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    const s = clappy.fmt.Style{
        .color = .green,
        .bold = true,
    };
    std.log.info("Hello {f}this is bold and green!", .{s});
}
