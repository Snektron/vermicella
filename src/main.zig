const std = @import("std");
const Grammar = @import("Grammar.zig");
const lalr = @import("lalr.zig");

test "main" {
    const g = Grammar{
        .terminals = &.{ "a", "+", "(", ")" },
        .nonterminals = &.{
            .{ .name = "S", .first_production = 0 },
            .{ .name = "E", .first_production = 1 },
            .{ .name = "T", .first_production = 3 },
        },
        .productions = &.{
            .{ .lhs = 0, .rhs = &.{.{ .nonterminal = 1 }}, .tag = "start" },
            .{
                .lhs = 1,
                .rhs = &.{ .{ .nonterminal = 1 }, .{ .terminal = 1 }, .{ .nonterminal = 2 } },
                .tag = "sum_add",
            },
            .{
                .lhs = 1,
                .rhs = &.{.{ .nonterminal = 2 }},
                .tag = "sum_atom",
            },
            .{ .lhs = 2, .rhs = &.{.{ .terminal = 0 }}, .tag = "atom_id" },
            .{
                .lhs = 2,
                .rhs = &.{ .{ .terminal = 2 }, .{ .nonterminal = 1 }, .{ .terminal = 3 } },
                .tag = "atom_parens",
            },
        },
    };

    std.debug.print("\n", .{});
    var generator = try lalr.Generator.init(std.testing.allocator, &g);
    defer generator.deinit();

    var tbl = try generator.generate();
    tbl.deinit(std.testing.allocator);
}

test {
    _ = @import("convergent_process.zig");
}
