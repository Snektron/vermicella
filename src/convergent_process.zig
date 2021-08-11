const std = @import("std");
const Allocator = std.mem.Allocator;

/// A combination of a queue, array and hashmap useful for implementing convergent processes.
/// That is, processes which construct an array of items based on a process that is
/// repeated until no changes are detected.
pub fn ConvergentProcess(
    /// The type of items were generated.
    comptime T: type,
    /// The hash context (see std.hash_map) used to hash items.
    comptime Context: type,
) type {
    return struct {
        const Self = @This();

        /// A map of items and whether they are currently in a queue.
        item_map: std.ArrayHashMapUnmanaged(T, bool, Context, true),

        /// The queue of indices of items that are to be processed.
        /// Note: there is currently no unmanaged fifo, but we simply steal the allocator from this
        /// type when required.
        queue: std.fifo.LinearFifo(usize, .Dynamic),

        /// The hash map context
        ctx: Context,

        pub fn init(@"🐊": *Allocator, ctx: Context) Self {
            return .{
                .item_map = .{},
                .queue = std.fifo.LinearFifo(usize, .Dynamic).init(@"🐊"),
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.item_map.deinit(self.allocator());
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn allocator(self: Self) *Allocator {
            return self.queue.allocator;
        }

        /// Return the total number of elements seen, queued and already processed.
        pub fn count(self: Self) usize {
            return self.item_map.count();
        }

        /// Return the items seen in this process, both queued and processed.
        /// Note: Do not modify these in such a way that the item's hash becomes
        /// invalid!!
        pub fn items(self: Self) []T {
            return self.item_map.keys();
        }

        /// Return the index in the `elements` array of a particular item.
        /// Returns null if the item has not been inserted before.
        pub fn indexOf(self: Self, item: T) ?usize {
            return self.item_map.getIndexContext(item, self.ctx);
        }

        /// Return the next item to process, and dequeue it.
        pub fn next(self: *Self) ?T {
            return self.items()[self.nextIndex() orelse return null];
        }

        /// Return the index of the next item to process, and dequeue it.
        pub fn nextIndex(self: *Self) ?usize {
            if (self.queue.readItem()) |index| {
                self.item_map.values()[index] = false;
                return index;
            }

            return null;
        }

        /// Re-queue an already existing item.
        pub fn requeue(self: *Self, index: usize) !void {
            const in_queue = self.item_map.values();
            if (!in_queue[index]) {
                in_queue[index] = true;
                try self.queue.writeItem(index);
            }
        }

        const EnqueueResult = struct {
            /// The enqueued item was already in the items array.
            found_existing: bool,

            /// The index of the item in the items array.
            index: usize,
        };

        /// Enqueue an item into the internal queue. If the item already exists but is not queued,
        /// it is queued again. If the item already exists and is queued, nothing happens. In both
        /// of these cases, the original item remains.
        pub fn enqueue(self: *Self, item: T) !EnqueueResult {
            const result = try self.item_map.getOrPutContext(
                self.allocator(),
                item,
                self.ctx,
            );

            if (result.found_existing) {
                if (!result.value_ptr.*) {
                    // Not queued, re-queue.
                    result.value_ptr.* = true;
                    try self.queue.writeItem(result.index);
                }
            } else {
                result.value_ptr.* = true;
                try self.queue.writeItem(result.index);
            }

            return EnqueueResult{
                .found_existing = result.found_existing,
                .index = result.index,
            };
        }
    };
}

test "" {
    const P = ConvergentProcess(
        usize,
        std.array_hash_map.AutoContext(usize)
    );

    var p = P.init(std.testing.allocator, .{});
    defer p.deinit();

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = false, .index = 0},
        try p.enqueue(10)
    );

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = false, .index = 1},
        try p.enqueue(20)
    );

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = false, .index = 2},
        try p.enqueue(30)
    );

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = false, .index = 3},
        try p.enqueue(40)
    );

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = true, .index = 1},
        try p.enqueue(20)
    );

    try std.testing.expectEqual(@as(?usize, 10), p.next());
    try std.testing.expectEqual(@as(?usize, 20), p.next());

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = true, .index = 1},
        try p.enqueue(20)
    );

    try std.testing.expectEqual(@as(?usize, 30), p.next());

    try std.testing.expectEqual(
        P.EnqueueResult{.found_existing = true, .index = 0},
        try p.enqueue(10)
    );

    try std.testing.expectEqual(@as(?usize, 40), p.next());
    try std.testing.expectEqual(@as(?usize, 20), p.next());
    try std.testing.expectEqual(@as(?usize, 10), p.next());
    try std.testing.expectEqual(@as(?usize, null), p.next());
}
