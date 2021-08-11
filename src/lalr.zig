const std = @import("std");
const Allocator = std.mem.Allocator;

const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const Nonterminal = Grammar.Nonterminal;
const Production = Grammar.Production;

const FirstSets = @import("FirstSets.zig");
const Lookahead = @import("lookahead.zig").Lookahead;
const LookaheadSet = @import("lookahead.zig").LookaheadSet;
const Item = @import("item.zig").Item;
const ItemSet = @import("item.zig").ItemSet;

const ConvergentProcess = @import("convergent_process.zig").ConvergentProcess;

/// An index representing a particular state in the final state machine.
pub const State = usize;

/// Actions that a LALR parser performs during parsing.
pub const Action = union(enum) {
    /// Push this state on the stack.
    shift: State,

    /// Perform a reduction, popping the top states and producing the LHS
    /// of the production.
    reduce: *const Production,

    /// Accept the input, and perform a final reduction.
    accept: *const Production,

    /// Produce an error.
    err,
};

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
                        try process.requeue(index);
                    }
                    // Note: we've never actually transferred ownership of `tmp` in this branch, so
                    // we don't need to allocate a new `tmp`.
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

        for (item_set.items.items) |item| {
            const sym_at_dot = item.symAtDot() orelse continue;
            if (!std.meta.eql(sym_at_dot, sym))
                continue;

            const new_item = (try item.shift(self.allocator(), self.g)).?;
            try result.items.append(self.allocator(), new_item);
        }

        // Note: closure sorts for us.
        try self.closure(&result);
        return result;
    }

    fn buildFamily(self: *Generator) ![]ItemSet {
        var process = ConvergentProcess(ItemSet, ItemSet.HashContext).init(self.allocator(), .{});
        _ = try process.enqueue(try self.initialItemSet());

        while (process.next()) |item_set| {
            for (item_set.items.items) |*item| {
                const sym = item.symAtDot() orelse {
                    item.action = if (item.production.lhs == Grammar.start_nonterminal)
                        .accept
                    else
                        .reduce;

                    continue;
                };

                const succ = try self.successor(item_set, sym);
                if (process.indexOf(succ)) |index| {
                    // Found an existing item set, try to merge per LALR.
                    const changed = process.items()[index].mergeLookaheads(succ, self.g);

                    // Re-queue to account for the changed item set.
                    if (changed)
                        try process.requeue(index);
                    item.action = .{.shift = index};
                } else {
                    // This is a new item set
                    const result = try process.enqueue(succ);
                    item.action = .{.shift = result.index};
                }
            }
        }

        return process.items();
    }

    pub fn generate(self: *Generator) !ParseTable {
        const family = try self.buildFamily();

        for (family) |item_set, i| {
            std.debug.print("i{}:\n", .{i});
            item_set.dump(true, self.g);
        }

        // Allocate this using the original allocator so that it is not bound to this generator's lifetime.
        var parse_table = try ParseTable.init(self.arena.child_allocator, self.g, family.len);
        errdefer parse_table.deinit(self.arena.child_allocator);

        return parse_table;
    }

    pub fn allocator(self: *Generator) *Allocator {
        return &self.arena.allocator;
    }
};

pub const ParseTable = struct {
    /// The parser's action table.
    /// Maps states and lookaheads (NOT terminals) to an action to perform.
    /// Stored as 2D table, `total_states` by `Lookahead.totalIndices(g)` elements
    /// for associated grammar `g`.
    actions: []Action,

    /// The parser's goto table.
    /// Maps states and nonterminals to other states.
    /// Stored as 2D table, `total_states` by `g.nonterminals.len` elements for
    /// associated grammar `g`.
    gotos: []?usize,

    /// The total number of states in this parse table.
    states: usize,

    fn init(allocator: *Allocator, g: *const Grammar, states: usize) !ParseTable {
        const actions = try allocator.alloc(Action, Lookahead.totalIndices(g) * states);
        const gotos = try allocator.alloc(?usize, g.nonterminals.len * states);

        std.mem.set(Action, actions, .err);
        std.mem.set(?usize, gotos, null);

        return ParseTable{
            .actions = actions,
            .gotos = gotos,
            .states = states,
        };
    }

    fn gotoIndex(g: *const Grammar, state: usize, nt: Nonterminal) usize {
        return g.nonterminals.len * state + nt;
    }

    fn actionIndex(g: *const Grammar, state: usize, lookahead: Lookahead) usize {
        return Lookahead.totalIndices(g) * state + lookahead.toIndex();
    }

    pub fn deinit(self: *ParseTable, allocator: *Allocator) void {
        allocator.free(self.actions);
        allocator.free(self.gotos);
        self.* = undefined;
    }
};
