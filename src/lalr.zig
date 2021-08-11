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

const ConvergentProcess = @import("convergent_process.zig").ConvergentProcess;

pub const Generator = struct {
    g: *const Grammar,
    arena: std.heap.ArenaAllocator,
    first_sets: FirstSets,

    pub fn init(backing: *Allocator, g: *const Grammar) !Generator {
        var self = Generator{
            .g = g,
            .arena = std.heap.ArenaAllocator.init(backing),
            .first_sets = undefined,
        };

        self.first_sets = try FirstSets.init(&self.arena, g);
        return self;
    }

    pub fn deinit(self: *Generator) void {
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
            try item_set.items.append(self.allocator(), Item.init(prod, lookahead));
        }

        // Note: closure sorts for us.
        try self.closure(&item_set);

        return item_set;
    }

    /// Perform a closure operation on `item_set`.
    fn closure(self: *Generator, item_set: *ItemSet) !void {
        var tmp = try LookaheadSet.init(self.allocator(), self.g);
        var process = ConvergentProcess(Item, Item.HashContext).init(self.allocator(), .{});

        for (item_set.items.items) |item| {
            _ = try process.enqueue(item);
        }

        while (process.next()) |item| {
            const nt = item.nonterminalAtDot() orelse continue;
            const v = item.symsAfterDot()[1..];

            for (self.g.productionsForNonterminal(nt)) |*prod| {
                self.first_sets.first(&tmp, v, item.lookahead, self.g);

                const new_item = Item.init(prod, tmp);
                if (process.indexOf(new_item)) |index| {
                    // The item already exists, merge the lookaheads.
                    const changed = process.items()[index].lookahead.merge(tmp, self.g);
                    if (changed) {
                        // We're sure that the item already exists here,
                        // and so we retain ownership of tmp.
                        _ = try process.enqueue(new_item);
                    }
                } else {
                    // Item does not exist yet, enqueue new.
                    _ = try process.enqueue(new_item);
                    // The item did not exist, and so `process` now takes ownership of `tmp`.
                    tmp = try LookaheadSet.init(self.allocator(), self.g);
                }
            }
        }

        try item_set.items.resize(self.allocator(), process.count());
        std.mem.copy(Item, item_set.items.items, process.items());
        item_set.sort();
    }

    /// Compute the successor item set of `item_set`.
    fn successor(self: *Generator, item_set: ItemSet, sym: Symbol) !ItemSet {
        var result = ItemSet{};

        var it = item_set.items.iterator();
        while (it.next()) |entry| {
            const sym_at_dot = entry.key_ptr.symAtDot() orelse continue;
            if (!std.meta.eql(sym_at_dot, sym))
                continue;

            const item = entry.key_ptr.shift().?;
            const lookahead = try entry.value_ptr.clone(self.allocator(), self.g);

            // Entries in the original item set are unique, so these are to.
            try result.putNoClobber(self.allocator(), item, lookahead);
        }

        // Note: closure sorts for us.
        try self.closure(&result);
        return result;
    }

    pub fn generate(self: *Generator) !void {
        var initial = try self.initialItemSet();
        initial.dump(self.g);

        const changed = initial.mergeLookaheads(initial, self.g);
        std.debug.print("Changed: {}\n", .{ changed });
        initial.dump(self.g);
    }

    pub fn allocator(self: *Generator) *Allocator {
        return &self.arena.allocator;
    }
};

pub const ParseTable = struct {
    pub const State = usize;

    pub const Action = union(enum) {
        /// Push this state on the stack.
        shift: State,

        /// Perform a reduction, popping the top states and producing the LHS
        /// of the production.
        reduce: *const Production,

        /// Accept the input, and perform a final reduction.
        accept: *const Production,

        /// Produce an error.
        err: void,
    };

    /// The parser's action table.
    /// Maps states and lookaheads (NOT terminals) to an action to perform.
    /// Stored as 2D table, `total_states` by `Lookahead.totalIndices(g)` elements
    /// for associated grammar `g`.
    actions: []const Action,

    /// The parser's goto table.
    /// Maps states and nonterminals to other states.
    /// Stored as 2D table, `total_states` by `g.nonterminals.len` elements for
    /// associated grammar `g`.
    goto: []const usize,

    /// The total number of states in this parse table.
    total_states: usize,
};
