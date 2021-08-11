const std = @import("std");
const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const Production = Grammar.Production;
const Nonterminal = Grammar.Nonterminal;
const LookaheadSet = @import("lookahead.zig").LookaheadSet;
const State = @import("lalr.zig").State;

/// Similar to lalr.Action, except that we don't need to store the
/// production (it will always be equal to the item's production).
const Action = union(enum) {
    shift: usize,
    reduce,
    accept,
};

pub const Item = struct {
    /// Index of the associated production in the grammar's `productions` slice.
    production: *const Production,

    /// Offset of the dot.
    /// The dot sits between symbols `dot - 1` and `dot`.
    dot: usize,

    /// The lookahead corresponding to this item.
    lookahead: LookaheadSet,

    /// The action associated to this item.
    /// Note: this will be unused for much of the generation process, and so
    /// is usually undefined.
    action: Action,

    /// Initialize an item, with the dot at the start.
    pub fn init(production: *const Production, lookahead: LookaheadSet) Item {
        return .{
            .production = production,
            .dot = 0,
            .lookahead = lookahead,
            .action = undefined,
        };
    }

    /// Tell whether the dot is at the end of the item.
    pub fn isDotAtEnd(self: Item) bool {
        return self.dot == self.production.rhs.len;
    }

    /// Shift the dot over to the next symbol. If the dot was currently at the end, this function
    /// returns `null`.
    pub fn shift(self: Item, allocator: *std.mem.Allocator, g: *const Grammar) !?Item {
        return if (self.isDotAtEnd())
            null
        else
            Item{
                .production = self.production,
                .dot = self.dot + 1,
                .lookahead = try self.lookahead.clone(allocator, g),
                .action = undefined,
            };
    }

    pub fn symAtDot(self: Item) ?Symbol {
        return if (self.isDotAtEnd())
            null
        else
            self.production.rhs[self.dot];
    }

    pub fn symsAfterDot(self: Item) []const Symbol {
        return if (self.isDotAtEnd())
            &[_]Symbol{}
        else
            self.production.rhs[self.dot ..];
    }

    pub fn nonterminalAtDot(self: Item) ?Nonterminal {
        const sym = self.symAtDot() orelse return null;
        return switch (sym) {
            .terminal => null,
            .nonterminal => |nt| nt,
        };
    }

    fn fmt(self: Item, g: *const Grammar) ItemFormatter {
        return ItemFormatter{ .item = self, .g = g, };
    }

    /// Order item sets.
    /// Note: only the production and dot participate in order checks.
    pub fn order(lhs: Item, rhs: Item) std.math.Order {
        const production_cmp = std.math.order(@ptrToInt(lhs.production), @ptrToInt(rhs.production));
        if (production_cmp != .eq)
            return production_cmp;

        return std.math.order(lhs.dot, rhs.dot);
    }

    pub const HashContext = struct {
        /// Note: only the production and dot participate in the hash.
        pub fn hash(self: HashContext, item: Item) u32 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&item.production));
            hasher.update(std.mem.asBytes(&item.dot));
            return @truncate(u32, hasher.final());
        }

        pub fn eql(self: HashContext, lhs: Item, rhs: Item) bool {
            _ = self;
            return order(lhs, rhs) == .eq;
        }
    };
};

const ItemFormatter = struct {
    item: Item,
    g: *const Grammar,

    pub fn format(self: ItemFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        const production = self.item.production;
        try writer.print("[{s} ->", .{ self.g.nonterminals[production.lhs].name });
        for (production.rhs) |sym, i| {
            if (self.item.dot == i)
                try writer.writeAll(" •");
            try writer.print(" {q}", .{ sym.fmt(self.g) });
        }

        if (self.item.dot == production.rhs.len) {
            try writer.writeAll(" •");
        }

        try writer.print(", {}", .{ self.item.lookahead.fmt(self.g) });

        if (std.mem.eql(u8, fmt, "a")) {
            switch (self.item.action) {
                .shift => |target| try writer.print(", shift {}", .{target}),
                .reduce => try writer.writeAll(", reduce"),
                .accept => try writer.writeAll(", accept"),
            }
        }

        try writer.writeByte(']');
    }
};

pub const ItemSet = struct {
    /// The items in this set. Should be ordered, and no duplicates should exist.
    /// TODO: Replace with MultiArrayList.
    items: std.ArrayListUnmanaged(Item) = .{},

    /// Merge the lookaheads of another item set with those in this item set.
    /// Both item sets are expected to have the same items.
    /// Returns whether any of the lookaheads in this item set were changed.
    pub fn mergeLookaheads(self: *ItemSet, other: ItemSet, g: *const Grammar) bool {
        std.debug.assert(self.items.items.len == other.items.items.len);

        var changed = false;

        for (self.items.items) |*item, i| {
            std.debug.assert(item.order(other.items.items[i]) == .eq);
            if (item.lookahead.merge(other.items.items[i].lookahead, g))
                changed = true;
        }

        return changed;
    }

    /// Order the items according to Item.order.
    /// Note: the item set should only contain unique items.
    pub fn sort(self: *ItemSet) void {
        const lessThan = struct {
            fn lessThan(ctx: void, lhs: Item, rhs: Item) bool {
                _ = ctx;
                return Item.order(lhs, rhs) == .lt;
            }
        }.lessThan;

        std.sort.sort(Item, self.items.items, {}, lessThan);
    }

    pub fn dump(self: ItemSet, dump_actions: bool, g: *const Grammar) void {
        std.debug.print("{{", .{});

        for (self.items.items) |item, i| {
            if (i != 0) {
                std.debug.print("\n ", .{});
            }

            if (dump_actions) {
                std.debug.print("{a}", .{item.fmt(g)});
            } else {
                std.debug.print("{}", .{item.fmt(g)});
            }
        }

        std.debug.print("}}\n", .{});
    }

    pub const HashContext = struct {
        pub fn hash(self: HashContext, item_set: ItemSet) u32 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);

            // Items are supposed to be in a sorted order so this hash is stable.
            for (item_set.items.items) |item| {
                const item_hash = (Item.HashContext{}).hash(item);
                hasher.update(std.mem.asBytes(&item_hash));
            }

            return @truncate(u32, hasher.final());
        }

        pub fn eql(self: HashContext, lhs: ItemSet, rhs: ItemSet) bool {
            _ = self;
            if (lhs.items.items.len != rhs.items.items.len)
                return false;

            for (lhs.items.items) |item, i| {
                if (item.order(rhs.items.items[i]) != .eq)
                    return false;
            }

            return true;
        }
    };
};
