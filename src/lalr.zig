const std = @import("std");
const Allocator = std.mem.Allocator;
const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const LookaheadSet = @import("lookahead.zig").LookaheadSet;

const Item = struct {
    /// Index of the associated production in the grammar's `productions` slice.
    production: usize,

    /// Offset of the dot.
    /// The dot sits between symbols `dot - 1` and `dot`.
    dot: usize,

    /// Initialize an item, with the dot at the start.
    fn init(production: usize) Item {
        return .{
            .production = production,
            .dot = 0,
        };
    }

    /// Tell whether the dot is at the end of the item.
    fn isDotAtEnd(self: Item, g: Grammar) bool {
        return self.dot == g.productions[self.production].rhs.len;
    }

    /// Shift the dot over to the next symbol. If the dot was currently at the end, this function
    /// returns `null`.
    fn shift(self: Item, g: Grammar) ?Item {
        return if (self.isDotAtEnd(g))
            null
        else
            Item{.production = self.production, .dot = self.dot + 1};
    }

    fn fmt(self: Item, g: *const Grammar) ItemFormatter {
        return ItemFormatter{ .item = self, .g = g, };
    }
};

const ItemFormatter = struct {
    item: Item,
    g: *const Grammar,

    pub fn format(self: ItemFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;

        const production = self.g.productions[self.item.production];
        try writer.print("{s} ->", .{ self.g.nonterminals[production.lhs].name });
        for (production.rhs) |sym, i| {
            if (self.item.dot == i)
                try writer.writeAll(" •");
            try writer.print(" {q}", .{ sym.fmt(self.g) });
        }

        if (self.item.dot == production.rhs.len) {
            try writer.writeAll(" •");
        }
    }
};

fn fmtItem(item: Item, g: *const Grammar) ItemFormatter {
    return ItemFormatter{ .item = item, .g = g };
}

const ItemSet = std.AutoHashMapUnmanaged(Item, LookaheadSet);

fn dumpItemSet(item_set: ItemSet, g: *const Grammar) void {
        var it = item_set.iterator();
        std.debug.print("{{[", .{});

        var first = true;
        while (it.next()) |entry| {
            if (first) {
                first = false;
            } else {
                std.debug.print("]\n [", .{});
            }
            std.debug.print("{}, {}", .{ fmtItem(entry.key_ptr.*, g), entry.value_ptr.fmt(g) });
        }

        std.debug.print("]}}\n", .{});
}

fn fmtItemSet(item_set: ItemSet, g: *const Grammar) ItemFormatter {
    return ItemFormatter{ .item = item_set, .g = g };
}

const FirstSets = struct {
    /// A slice mapping each nonterminal to it's lookahead set.
    /// Note: These sets will never contain eof, but do require is to keep
    /// track of whether a nonterminal derives lambda. We simply repurpose
    /// the eof bit to keep track of that instead.
    base_sets: []LookaheadSet,

    /// Initialize the first sets corresponding to each nonterminal in the grammar.
    /// Depending on the grammar, this function could be slow.
    fn init(allocator: *Allocator, g: *const Grammar) !FirstSets {
        // Note: allocator is always going to be an arena allocator, so we don't need to
        // (err)defer here.
        var self = FirstSets{
            .base_sets = try allocator.alloc(LookaheadSet, g.nonterminals.len),
        };

        for (self.base_sets) |*set| {
            set.* = try LookaheadSet.init(allocator, g);
        }

        var tmp = try LookaheadSet.init(allocator, g);

        var changed = true;
        while (changed) {
            changed = false;

            for (g.productions) |prod| {
                tmp.clear(g);
                self.first(&tmp, prod.rhs, g);

                if (self.base_sets[prod.lhs].merge(tmp, g))
                    changed = true;
            }
        }

        return self;
    }

    fn first(self: FirstSets, lookahead_set: *LookaheadSet, syms: []const Symbol, g: *const Grammar) void {
        for (syms) |sym| {
            switch (sym) {
                .terminal => |t| {
                    // If the production has a terminal, it will not derive lambda, and so we
                    // can return now.
                    lookahead_set.insert(.{.terminal = t});
                    return;
                },
                .nonterminal => |nt| {
                    const other = self.base_sets[nt];

                    // Add the productions from the other set. Note, during construction,
                    // the other set might not be complete yet, and so addProduction needs to be
                    // called until no change is detected.
                    _ = lookahead_set.merge(other, g);

                    // The other production might derive lambda, but that does not mean this
                    // production derives lambda!
                    lookahead_set.remove(.eof);

                    // If the other production doesn't derive lambda, this production won't either
                    if (!other.contains(.eof))
                        return;
                },
            }
        }

        lookahead_set.insert(.eof);
    }

    fn dump(self: FirstSets, g: *const Grammar) void {
        for (self.base_sets) |lookahead_set, nt| {
            std.debug.print("{}: {}\n", .{ g.fmtNonterminal(nt), lookahead_set.fmt(g) });
        }
    }
};

pub const Generator = struct {
    g: *const Grammar,
    arena: std.heap.ArenaAllocator,

    fn initialItemSet(self: *Generator) !ItemSet {
        var item_set = ItemSet{};

        for (self.g.productionsForNonterminal(Grammar.start_nonterminal)) |_, i| {
            // For LALR, item sets may be merged, and so they cannot be treated as immutable. For this
            // reason, we need to make a new copy of the lookahead set with just eof for every start
            // production.
            var lookahead = try LookaheadSet.init(self.allocator(), self.g);

            // The initial item set starts with just eof as the lookahead.
            lookahead.insert(.eof);

            // i is unique for all elements we're going to insert here.
            try item_set.putNoClobber(self.allocator(), Item.init(i), lookahead);
        }

        return item_set;
    }

    pub fn generate(self: *Generator) !void {
        // const initial = try self.initialItemSet();
        // dumpItemSet(initial, &self.g);

        const first_sets = try FirstSets.init(self.allocator(), self.g);

        first_sets.dump(self.g);

        // self.g.dump();
        // std.debug.print("{}\n", .{ Item.init(0).shift(self.g).?.fmt(&self.g) });
    }

    pub fn allocator(self: *Generator) *Allocator {
        return &self.arena.allocator;
    }
};
