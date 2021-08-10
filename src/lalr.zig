const std = @import("std");
const Allocator = std.mem.Allocator;

const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const Nonterminal = Grammar.Nonterminal;

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
    fn isDotAtEnd(self: Item, g: *const Grammar) bool {
        return self.dot == g.productions[self.production].rhs.len;
    }

    /// Shift the dot over to the next symbol. If the dot was currently at the end, this function
    /// returns `null`.
    fn shift(self: Item, g: *const Grammar) ?Item {
        return if (self.isDotAtEnd(g))
            null
        else
            Item{.production = self.production, .dot = self.dot + 1};
    }

    fn symAtDot(self: Item, g: *const Grammar) ?Symbol {
        return if (self.isDotAtEnd(g))
            null
        else
            g.productions[self.production].rhs[self.dot];
    }

    fn symsAfterDot(self: Item, g: *const Grammar) []const Symbol {
        return if (self.isDotAtEnd(g))
            &[_]Symbol{}
        else
            g.productions[self.production].rhs[self.dot ..];
    }

    fn nonterminalAtDot(self: Item, g: *const Grammar) ?Nonterminal {
        const sym = self.symAtDot(g) orelse return null;
        return switch (sym) {
            .terminal => null,
            .nonterminal => |nt| nt,
        };
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
    /// track of whether a nonterminal derives epsilon. We simply repurpose
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
    fn baseFirst(self: FirstSets, target: *LookaheadSet, syms: []const Symbol, g: *const Grammar) void {
        for (syms) |sym| {
            switch (sym) {
                .terminal => |t| {
                    // If the production has a terminal, it will not derive epsilon, and so we
                    // can return now.
                    target.insert(.{.terminal = t});
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
    fn first(self: *FirstSets, target: *LookaheadSet, syms: []const Symbol, lookahead: LookaheadSet, g: *const Grammar) void {
        self.baseFirst(target, syms, g);
        const epsilon = target.contains(.eof);
        target.remove(.eof);

        if (epsilon) {
            _ = target.merge(lookahead, g);
        }
    }

    fn dump(self: FirstSets, g: *const Grammar) void {
        for (self.base_sets) |lookahead_set, nt| {
            std.debug.print("{}: {}\n", .{ g.fmtNonterminal(nt), lookahead_set.fmt(g) });
        }
    }
};

pub const Generator = struct {
    const StackEntry = struct {
        item: Item,
        lookahead: LookaheadSet,
    };

    g: *const Grammar,
    arena: std.heap.ArenaAllocator,
    first_sets: FirstSets,

    /// Stack used to track which items still need to be processed
    /// while computing a closure.
    /// Cached in this struct.
    stack: std.ArrayListUnmanaged(StackEntry),

    pub fn init(backing: *Allocator, g: *const Grammar) !Generator {
        var self = Generator{
            .g = g,
            .arena = std.heap.ArenaAllocator.init(backing),
            .first_sets = undefined,
            .stack = .{},
        };

        self.first_sets = try FirstSets.init(self.allocator(), g);
        return self;
    }

    pub fn deinit(self: *Generator) void {
        self.stack.deinit(self.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    /// Compute the initial item set.
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

        try self.closure(&item_set);

        return item_set;
    }

    /// Perform a closure operation on `item_set`.
    fn closure(self: *Generator, item_set: *ItemSet) !void {
        var tmp = try LookaheadSet.init(self.allocator(), self.g);

        var it = item_set.iterator();
        while (it.next()) |entry| {
            try self.stack.append(self.allocator(), .{ .item = entry.key_ptr.*, .lookahead = entry.value_ptr.* });
        }

        while (self.stack.popOrNull()) |entry| {
            const nt = entry.item.nonterminalAtDot(self.g) orelse continue;
            const v = entry.item.shift(self.g).?.symsAfterDot(self.g);

            const j = self.g.nonterminals[nt].first_production;
            for (self.g.productionsForNonterminal(nt)) |_, i| {
                const item = Item.init(j + i);

                self.first_sets.first(&tmp, v, entry.lookahead, self.g);

                const result = try item_set.getOrPut(self.allocator(), item);
                if (result.found_existing) {
                    if (!result.value_ptr.merge(tmp, self.g))
                        continue;
                } else {
                    result.value_ptr.* = tmp;
                    tmp = try LookaheadSet.init(self.allocator(), self.g);
                }

                // The item set for this production's lhs changed or was newly inserted,
                // so everything that depends on it needs to be recomputed.
                // TODO: Keep which items are on the stack and prevent pushing those?
                try self.stack.append(self.allocator(), .{.item = item, .lookahead = result.value_ptr.*});
            }
        }
    }

    /// Compute the successor item set of `item_set`.
    fn successor(self: *Generator, item_set: ItemSet, sym: Symbol) !ItemSet {
        var result = ItemSet{};

        var it = item_set.iterator();
        while (it.next()) |entry| {
            const sym_at_dot = entry.key_ptr.symAtDot(self.g) orelse continue;
            if (!std.meta.eql(sym_at_dot, sym))
                continue;

            const item = entry.key_ptr.shift(self.g).?;
            const lookahead = try entry.value_ptr.clone(self.allocator(), self.g);

            // Entries in the original item set are unique, so these are to.
            try result.putNoClobber(self.allocator(), item, lookahead);
        }

        try self.closure(&result);
        return result;
    }

    pub fn generate(self: *Generator) !void {
        const initial = try self.initialItemSet();
        dumpItemSet(initial, self.g);

        const succ = try self.successor(initial, .{.nonterminal = 1});
        dumpItemSet(succ, self.g);

        const succ1 = try self.successor(succ, .{.terminal = 1});
        dumpItemSet(succ1, self.g);
    }

    pub fn allocator(self: *Generator) *Allocator {
        return &self.arena.allocator;
    }
};
