const std = @import("std");
const Grammar = @import("Grammar.zig");
const lookahead = @import("lookahead.zig");

const Item = struct {
    /// Index of the associated production in the grammar's `productions` slice.
    production: usize,

    /// Offset of the dot.
    /// The dot sits between symbols `dot - 1` and `dot`.
    dot: usize,

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
            Item{.production = item.production, .dot = item.dot + 1};
    }
};

const ItemSet = std.AutoHashMapUnmanaged(Item, void);

pub const Generator = struct {
    g: *const Grammar,
    allocator: *std.mem.Allocator,

    pub fn generate(self: Generator) !void {
        self.g.dump();
    }
};
