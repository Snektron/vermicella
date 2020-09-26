const std = @import("std");
const grammar = @import("grammar.zig");
const lalr = @import("lalr.zig");
const testing = std.testing;

const Terminal = enum {
    // id,
    // plus,
    // lparen,
    // rparen,
    // lbracket,
    // rbracket,
    a,
    b,
    eof,

    pub fn format(self: Terminal, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const text = switch (self) {
            // .id => "id",
            // .plus => "+",
            // .lparen => "(",
            // .rparen => ")",
            // .lbracket => "[",
            // .rbracket => "]",
            .a => "a",
            .b => "b",
            .eof => "$",
        };

        try writer.print("{}", .{ text });
    }
};

const NonTerminal = enum {
    S_,
    S,
    X,

    pub fn format(self: NonTerminal, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}", .{ @tagName(self) });
    }
};

test "main" {
    std.debug.print("\n", .{});

    const G = grammar.Grammar(Terminal, NonTerminal);
    const g = G.init(.S_, .eof, &[_]G.Production{
        .{.lhs = .S_, .elements = &[_]G.Symbol{ G.nt(.S) }},
        .{.lhs = .S, .elements = &[_]G.Symbol{ G.nt(.X), G.nt(.X) }},
        .{.lhs = .X, .elements = &[_]G.Symbol{ G.t(.a), G.nt(.X) }},
        .{.lhs = .X, .elements = &[_]G.Symbol{ G.t(.b) }},

        // .{.lhs = .S, .elements = &[_]G.Symbol{ G.nt(.E), G.t(.eof) }},
        // .{.lhs = .E, .elements = &[_]G.Symbol{ G.nt(.T) }},
        // .{.lhs = .E, .elements = &[_]G.Symbol{ G.nt(.E), G.t(.plus), G.nt(.T) }},
        // .{.lhs = .T, .elements = &[_]G.Symbol{ G.t(.id) }},
        // .{.lhs = .T, .elements = &[_]G.Symbol{ G.t(.lparen), G.nt(.E), G.t(.rparen) }},
        // .{.lhs = .T, .elements = &[_]G.Symbol{ G.t(.id), G.t(.lbracket), G.nt(.E), G.t(.rbracket) }},
    });

    try lalr.generate(std.testing.allocator, g);
}
