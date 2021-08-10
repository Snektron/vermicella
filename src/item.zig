const std = @import("std");
const Grammar = @import("Grammar.zig");
const Symbol = Grammar.Symbol;
const Production = Grammar.Production;
const Nonterminal = Grammar.Nonterminal;
const LookaheadSet = @import("lookahead.zig").LookaheadSet;

pub const Item = struct {
    /// Index of the associated production in the grammar's `productions` slice.
    production: *const Production,

    /// Offset of the dot.
    /// The dot sits between symbols `dot - 1` and `dot`.
    dot: usize,

    /// Initialize an item, with the dot at the start.
    pub fn init(production: *const Production) Item {
        return .{
            .production = production,
            .dot = 0,
        };
    }

    /// Tell whether the dot is at the end of the item.
    pub fn isDotAtEnd(self: Item) bool {
        return self.dot == self.production.rhs.len;
    }

    /// Shift the dot over to the next symbol. If the dot was currently at the end, this function
    /// returns `null`.
    pub fn shift(self: Item) ?Item {
        return if (self.isDotAtEnd())
            null
        else
            Item{.production = self.production, .dot = self.dot + 1};
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
};

const ItemFormatter = struct {
    item: Item,
    g: *const Grammar,

    pub fn format(self: ItemFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;

        const production = self.item.production;
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

pub const ItemSet = std.AutoHashMapUnmanaged(Item, LookaheadSet);

pub fn dumpItemSet(item_set: ItemSet, g: *const Grammar) void {
        var it = item_set.iterator();
        std.debug.print("{{[", .{});

        var first = true;
        while (it.next()) |entry| {
            if (first) {
                first = false;
            } else {
                std.debug.print("]\n [", .{});
            }
            std.debug.print("{}, {}", .{ entry.key_ptr.fmt(g), entry.value_ptr.fmt(g) });
        }

        std.debug.print("]}}\n", .{});
}

pub fn fmtItemSet(item_set: ItemSet, g: *const Grammar) ItemFormatter {
    return ItemFormatter{ .item = item_set, .g = g };
}

const ItemSetHashContext = struct {
    fn hash(self: ItemSetHashContext, item_set: ItemSet) u64 {
        _ = self;
        const item_hasher = comptime std.hash_map.getAutoHashFn(Config);

        // Item sets are hash maps themselves, and so must be hashed in an order independent way.
        var value: u64 = 0;

        var it = item_set.iterator();
        while (it.next()) |entry| {
            value ^= item_hasher(entry.key_ptr.*);
        }

        return value;
    }

    fn eql(self: ItemSetHashContext, lhs: ItemSet, rhs: ItemSet) u64 {
        _ = self;

        if (lhs.count() != rhs.count())
            return false;

        {
            var it = lhs.iterator();
            while (it.next()) |entry| {
                if (!rhs.contains(entry.key_ptr.*))
                    return false;
            }
        }

        {
            var it = rhs.iterator();
            while (it.next()) |entry| {
                if (!lhs.contains(entry.key_ptr.*))
                    return false;
            }
        }

        return true;
    }
};