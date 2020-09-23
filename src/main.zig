const std = @import("std");
const grammar = @import("grammar.zig");
const lr0 = @import("lr0.zig");
const testing = std.testing;

const Terminal = enum {
    id,
    plus,
    lparen,
    rparen,

    pub fn format(self: Terminal, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const text = switch (self) {
            .id => "id",
            .plus => "+",
            .lparen => "(",
            .rparen => ")",
        };

        try writer.print("'{}'", .{ text });
    }
};

const NonTerminal = enum {
    S,
    E,
    T,

    pub fn format(self: NonTerminal, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}", .{ @tagName(self) });
    }
};

test "main" {
    std.debug.print("\n", .{});

    const G = grammar.Grammar(Terminal, NonTerminal);
    const g = G.init(&[_]G.Production{
        .{.lhs = .S, .elements = &[_]G.Symbol{ G.nt(.E) }},
        .{.lhs = .E, .elements = &[_]G.Symbol{ G.nt(.T) }},
        .{.lhs = .E, .elements = &[_]G.Symbol{ G.nt(.E), G.t(.plus), G.nt(.T) }},
        .{.lhs = .T, .elements = &[_]G.Symbol{ G.t(.id) }},
        .{.lhs = .T, .elements = &[_]G.Symbol{ G.t(.lparen), G.nt(.E), G.t(.rparen) }},
    });

    try lr0.generate(std.testing.allocator, g, .S);
}
