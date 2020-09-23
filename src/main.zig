const std = @import("std");
const grammar = @import("grammar.zig");
const lr0 = @import("lr0.zig");
const testing = std.testing;

test "main" {
    std.debug.print("\n", .{});
    const Terminal = enum {
        id,
        plus,
        lparen,
        rparen,
    };

    const NonTerminal = enum {
        S,
        E,
        T,
    };

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
