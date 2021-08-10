const std = @import("std");
const Allocator = std.mem.Allocator;
const Grammar = @import("Grammar.zig");

/// Elements which can be a lookahead of a particular item in an item set.
pub const Lookahead = union(enum) {
    eof,
    terminal: Grammar.Terminal,

    pub fn fmt(self: Lookahead, g: *const Grammar) LookaheadFormatter {
        return LookaheadFormatter{
            .lookahead = self,
            .g = g,
        };
    }
};

const LookaheadFormatter = struct {
    lookahead: Lookahead,
    g: *const Grammar,

    pub fn format(self: LookaheadFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;

        return switch (self.lookahead) {
            .eof => writer.writeAll("<eof>"),
            .terminal => |t| writer.print("{q}", .{self.g.fmtTerminal(t)}),
        };
    }
};

/// A set of lookaheads.
pub const LookaheadSet = struct {
    /// The words backing the bits in this lookahead set.
    const MaskInt = usize;

    /// The int used to shift the masks around.
    const ShiftInt = std.math.Log2Int(MaskInt);

    /// A bit set representing which elements are part of this set,
    /// each bit corresponds with a lookahead by the `lookaheadToBit` and
    /// `bitToLookeahd` functions.
    /// Note that the number of bits in this lookahead set is
    /// implicitly given by the grammar associated to it.
    masks: [*]MaskInt,

    /// Initialize a lookahead set.
    pub fn init(allocator: *Allocator, g: *const Grammar) !LookaheadSet {
        const masks = try allocator.alloc(MaskInt, requiredMasks(g));
        std.mem.set(MaskInt, masks, 0);
        return LookaheadSet{.masks = masks.ptr};
    }

    /// Deinitialize this set, freeing all internal memory.
    pub fn deinit(self: *LookaheadSet, allocator: *Allocator, g: *const Grammar) void {
        allocator.free(self.masks[0 .. requiredMasks(g)]);
        self.* = undefined;
    }

    /// Return the total amount of bits in the memory backing this lookahead set.
    fn requiredBits(g: *const Grammar) usize {
        return g.terminals.len + 1; // Add one for eof
    }

    /// Return the total amount of masks in the memory backing this lookahead set.
    fn requiredMasks(g: *const Grammar) usize {
        return (requiredBits(g) + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
    }

    /// Return the index in the bitset of a particular lookahead item.
    fn lookaheadToBit(lookahead: Lookahead) usize {
        // Allocate index 0 to eof so that we do not have to know the total number of
        // bits here.
        return switch (lookahead) {
            .eof => 0,
            .terminal => |t| t + 1,
        };
    }

    /// Return the lookahead corresponding to a certain bit.
    fn bitToLookahead(bit: usize) Lookahead {
        return switch (bit) {
            0 => .eof,
            else => .{.terminal = bit - 1},
        };
    }

    /// Return the word offset backing the bit.
    fn maskIndex(bit: usize) usize {
        return bit / @bitSizeOf(MaskInt);
    }

    /// Return the bit offset in the word backing the bit.
    fn maskOffset(bit: usize) ShiftInt {
        return @intCast(ShiftInt, bit % @bitSizeOf(MaskInt));
    }

    /// Iterate over all lookaheads in this set.
    fn iterator(self: LookaheadSet, g: *const Grammar) LookaheadSetIterator {
        return LookaheadSetIterator{
            .masks = self.masks,
            .bit = 0,
            .total = requiredBits(g),
        };
    }

    /// Insert `lookahead` into the set.
    pub fn insert(self: *LookaheadSet, lookahead: Lookahead) void {
        const bit = lookaheadToBit(lookahead);
        self.masks[maskIndex(bit)] |= @as(MaskInt, 1) << maskOffset(bit);
    }

    /// Remove `lookahead` from the set.
    pub fn remove(self: *LookaheadSet, lookahead: Lookahead) void {
        const bit = lookaheadToBit(lookahead);
        self.masks[maskIndex(bit)] &= ~(@as(MaskInt, 1) << maskOffset(bit));
    }

    /// Test whether `lookahead` is in the set.
    pub fn contains(self: LookaheadSet, lookahead: Lookahead) bool {
        const bit = lookaheadToBit(lookahead);
        return (self.masks[maskIndex(bit)] >> maskOffset(bit)) & 1 != 0;
    }

    /// Merge the elements from the other set into this set. Returns whether this set has changed.
    pub fn merge(self: *LookaheadSet, other: LookaheadSet, g: *const Grammar) bool {
        var changed = false;
        for (self.masks[0 .. requiredMasks(g)]) |*mask, i| {
            if (mask.* | other.masks[i] != mask.*)
                changed = true;
            mask.* |= other.masks[i];
        }

        return changed;
    }

    // Remove all entries from this set.
    pub fn clear(self: LookaheadSet, g: *const Grammar) void {
        std.mem.set(MaskInt, self.masks[0 .. requiredMasks(g)], 0);
    }

    pub fn fmt(self: LookaheadSet, g: *const Grammar) LookaheadSetFormatter {
        return LookaheadSetFormatter {
            .lookahead_set = self,
            .g = g,
        };
    }
};

/// An iterator over elements in a lookahead set.
const LookaheadSetIterator = struct {
    masks: [*]const LookaheadSet.MaskInt,
    bit: usize,
    total: usize,

    /// Return the next element in the corresponding `LookaheadSet`.
    pub fn next(self: *LookaheadSetIterator) ?Lookahead {
        while (self.bit < self.total) {
            // If we are starting a new word, check if its zero. If so, we can skip it in its entirety.
            if (self.bit % @bitSizeOf(LookaheadSet.MaskInt) == 0) {
                while (self.bit < self.total and self.masks[LookaheadSet.maskIndex(self.bit)] == 0) {
                    self.bit += @bitSizeOf(LookaheadSet.MaskInt);
                }

                // The previous loop might have exceeded the bounds, so check this again.
                if (self.bit >= self.total)
                    return null;
            }

            // Iterate over the bits in the current word.
            // TODO: Use ctz-based solution.
            const current = self.masks[LookaheadSet.maskIndex(self.bit)];
            var i = @as(usize, LookaheadSet.maskOffset(self.bit));
            while (self.bit < self.total and i < @bitSizeOf(LookaheadSet.MaskInt)) {
                self.bit += 1;

                // Bit set, return that bit
                if ((current >> @intCast(LookaheadSet.ShiftInt, i)) & 1 != 0) {
                    return LookaheadSet.bitToLookahead(self.bit - 1);
                }

                i += 1;
            }

            // No bit found in the current word. We should be at a boundary now (unless we reached the end).
            std.debug.assert(self.bit == self.total or self.bit % @bitSizeOf(LookaheadSet.MaskInt) == 0);
        }

        return null;
    }
};

const LookaheadSetFormatter = struct {
    lookahead_set: LookaheadSet,
    g: *const Grammar,

    pub fn format(self: LookaheadSetFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;

        var first = true;
        var it = self.lookahead_set.iterator(self.g);
        while (it.next()) |lookahead| {
            if (first) {
                first = false;
            } else {
                try writer.writeByte('/');
            }

            try writer.print("{}", .{lookahead.fmt(self.g)});
        }
    }
};
