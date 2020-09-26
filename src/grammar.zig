const std = @import("std");

pub fn Grammar(comptime T: type, comptime NT: type) type {
    return struct {
        const Self = @This();
        pub const Terminal = T;
        pub const NonTerminal = NT;

        pub const Symbol = union(enum) {
            terminal: Terminal,
            non_terminal: NonTerminal,
        };

        pub const Production = struct {
            lhs: NonTerminal,
            elements: []const Symbol,

            pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.print("{} ->", .{ self.lhs });

                for (self.elements) |element, i| {
                    switch (element) {
                        .terminal => |sym| try writer.print(" '{}'", .{ sym }),
                        .non_terminal => |sym| try writer.print(" {}", .{ sym }),
                    }
                }
            }
        };

        start: NonTerminal,
        eof: Terminal,
        productions: []const Production,

        pub fn init(start: NonTerminal, eof: Terminal, productions: []const Production) Self {
            return .{
                .start = start,
                .eof = eof,
                .productions = productions,
            };
        }

        pub fn nt(non_terminal: NonTerminal) Symbol {
            return .{.non_terminal = non_terminal};
        }

        pub fn t(terminal: Terminal) Symbol {
            return .{.terminal = terminal};
        }
    };
}
