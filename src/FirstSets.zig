const std = @import("std");
const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const LookaheadSet = @import("lookahead.zig").LookaheadSet;

const Self = @This();

/// A slice mapping each nonterminal to it's lookahead set.
/// Note: These sets will never contain eof, but do require is to keep
/// track of whether a nonterminal derives epsilon. We simply repurpose
/// the eof bit to keep track of that instead.
base_sets: []LookaheadSet,

/// Initialize the first sets corresponding to each nonterminal in the grammar.
/// Depending on the grammar, this function could be slow.
pub fn init(arena: *std.heap.ArenaAllocator, g: *const Grammar) !Self {
    // Note: allocator is always going to be an arena allocator, so we don't need to
    // (err)defer here.
    var self = Self{
        .base_sets = try arena.allocator().alloc(LookaheadSet, g.nonterminals.len),
    };

    for (self.base_sets) |*set| {
        set.* = try LookaheadSet.init(arena.allocator(), g);
    }

    var tmp = try LookaheadSet.init(arena.allocator(), g);
    var changed = true;
    while (changed) {
        changed = false;

        for (g.productions) |prod| {
            tmp.clear(g);
            self.baseFirst(&tmp, prod.rhs, g);

            if (self.base_sets[prod.lhs].merge(tmp, g))
                changed = true;
        }
    }

    return self;
}

/// Compute the first set according to the currently stored base sets, and store it in `lookahead_set`.
/// Note: In this function, and in the result, `eof` means epsilon.
/// Assumes target is cleared.
fn baseFirst(self: Self, target: *LookaheadSet, syms: []const Symbol, g: *const Grammar) void {
    for (syms) |sym| {
        switch (sym) {
            .terminal => |t| {
                // If the production has a terminal, it will not derive epsilon, and so we
                // can return now.
                target.insert(.{ .terminal = t });
                return;
            },
            .nonterminal => |nt| {
                const other = self.base_sets[nt];

                // Add the productions from the other set. Note, during construction,
                // the other set might not be complete yet, and so addProduction needs to be
                // called until no change is detected.
                _ = target.merge(other, g);

                // The other production might derive epsilon, but that does not mean this
                // production derives epsilon!
                target.remove(.eof);

                // If the other production doesn't derive epsilon, this production won't either
                if (!other.contains(.eof))
                    return;
            },
        }
    }

    target.insert(.eof);
}

/// Compute the proper first set for a sequence of symbols and a particular lookahead.
/// In the result, `eof` really means `eof`.
/// Assumes `target` is cleared.
pub fn first(self: *Self, target: *LookaheadSet, syms: []const Symbol, lookahead: LookaheadSet, g: *const Grammar) void {
    self.baseFirst(target, syms, g);
    const epsilon = target.contains(.eof);
    target.remove(.eof);

    if (epsilon) {
        _ = target.merge(lookahead, g);
    }
}

pub fn dump(self: Self, g: *const Grammar) void {
    for (self.base_sets, 0..) |lookahead_set, nt| {
        std.debug.print("{}: {}\n", .{ g.fmtNonterminal(nt), lookahead_set.fmt(g) });
    }
}
