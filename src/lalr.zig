const std = @import("std");
const Allocator = std.mem.Allocator;

const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const Nonterminal = Grammar.Nonterminal;
const Production = Grammar.Production;

const FirstSets = @import("FirstSets.zig");
const LookaheadSet = @import("lookahead.zig").LookaheadSet;
const Item = @import("item.zig").Item;
const ItemSet = @import("item.zig").ItemSet;

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

        self.first_sets = try FirstSets.init(&self.arena, g);
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

        for (self.g.productionsForNonterminal(Grammar.start_nonterminal)) |*prod| {
            // For LALR, item sets may be merged, and so they cannot be treated as immutable. For this
            // reason, we need to make a new copy of the lookahead set with just eof for every start
            // production.
            var lookahead = try LookaheadSet.init(self.allocator(), self.g);

            // The initial item set starts with just eof as the lookahead.
            lookahead.insert(.eof);

            // i is unique for all elements we're going to insert here.
            try item_set.putNoClobber(self.allocator(), Item.init(prod), lookahead);
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
            const nt = entry.item.nonterminalAtDot() orelse continue;
            const v = entry.item.shift().?.symsAfterDot();

            for (self.g.productionsForNonterminal(nt)) |*prod| {
                const item = Item.init(prod);

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
            const sym_at_dot = entry.key_ptr.symAtDot() orelse continue;
            if (!std.meta.eql(sym_at_dot, sym))
                continue;

            const item = entry.key_ptr.shift().?;
            const lookahead = try entry.value_ptr.clone(self.allocator(), self.g);

            // Entries in the original item set are unique, so these are to.
            try result.putNoClobber(self.allocator(), item, lookahead);
        }

        try self.closure(&result);
        return result;
    }

    pub fn generate(self: *Generator) !void {
        const initial = try self.initialItemSet();
        @import("item.zig").dumpItemSet(initial, self.g);

        // const succ = try self.successor(initial, .{.nonterminal = 1});
        // dumpItemSet(succ, self.g);

        // const succ1 = try self.successor(succ, .{.terminal = 1});
        // dumpItemSet(succ1, self.g);
    }

    pub fn allocator(self: *Generator) *Allocator {
        return &self.arena.allocator;
    }
};
