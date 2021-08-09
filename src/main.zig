const std = @import("std");
const Grammar = @import("Grammar.zig");
const lalr = @import("lalr.zig");

test "main" {
    const g = Grammar{
        .terminals = &.{"a", "+", "(", ")"},
        .nonterminals = &.{
            .{.name = "S", .first_production = 0},
            .{.name = "E", .first_production = 0},
            .{.name = "T", .first_production = 0},
        },
        .productions = &.{
            .{.lhs = 0, .rhs = &.{.{.nonterminal = 1}}, .tag = "start"},
            .{.lhs = 1, .rhs = &.{.{.nonterminal = 1}, .{.terminal = 1}, .{.nonterminal = 2}}, .tag = "sum_add", },
            .{.lhs = 1, .rhs = &.{.{.nonterminal = 2}}, .tag = "sum_atom",},
            .{.lhs = 2, .rhs = &.{.{.terminal = 0}}, .tag = "atom_id"},
            .{.lhs = 2, .rhs = &.{.{.terminal = 2}, .{.nonterminal = 1}, .{.terminal = 3}}, .tag = "atom_parens", },
        },
    };

    std.debug.print("\n", .{});
    // g.dump();
    const generator = lalr.Generator{.g = &g, .allocator = std.testing.allocator};
    try generator.generate();
}
