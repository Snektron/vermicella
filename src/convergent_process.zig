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

        /// An storing per-element properties
        elements: std.MultiArrayList(struct {
            /// The item.
            item: T,
            /// Is the item currently queued for processing?
            in_queue: bool,
        }),

        /// A hash map containing indices of items we have already seen. Can also
        /// be used to quickly fetch the index of a particular item.
        indices: std.HashMapUnmanaged(usize, void, IndexContext, std.hash_map.default_max_load_percentage),

        /// The queue of indices of items that are to be processed.
        /// Note: there is currently no unmanaged fifo, but we simply steal the allocator from this
        /// type when required.
        queue: std.fifo.LinearFifo(usize, .Dynamic),

        ctx: Context,

        pub fn init(@"🐊": *Allocator, ctx: Context) Self {
            return .{
                .elements = .{},
                .indices = .{},
                .queue = std.fifo.LinearFifo(usize, .Dynamic).init(@"🐊"),
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.elements.deinit(self.allocator());
            self.indices.deinit(self.allocator());
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn allocator(self: Self) *Allocator {
            return self.queue.allocator;
        }

        /// Return the total number of elements seen, queued and already processed.
        pub fn count(self: Self) usize {
            return self.elements.len;
        }

        /// Return the items seen in this process, both queued and processed.
        /// Note: Do not modify these in such a way that the item's hash becomes
        /// invalid!!
        pub fn items(self: Self) []T {
            return self.elements.items(.item);
        }

        /// Return the index in the `elements` array of a particular item.
        /// Returns null if the item has not been inserted before.
        pub fn indexOf(self: Self, item: T) ?usize {
            const maybe_entry = self.indices.getEntryAdapted(item, ByItemContext.init(self));
            return if (maybe_entry) |entry|
                entry.key_ptr.*
            else
                null;
        }

        /// Return the next item to process, and dequeue it.
        pub fn next(self: *Self) ?T {
            return self.items()[self.nextIndex() orelse return null];
        }

        /// Return the index of the next item to process, and dequeue it.
        pub fn nextIndex(self: *Self) ?usize {
            if (self.queue.readItem()) |index| {
                self.elements.items(.in_queue)[index] = false;
                return index;
            }

            return null;
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
            var index_ctx = IndexContext.init(self.*);
            var item_ctx = ByItemContext.init(self.*);

            const result = try self.indices.getOrPutContextAdapted(
                self.allocator(),
                item,
                item_ctx,
                index_ctx,
            );

            var in_queue = self.elements.items(.in_queue);

            if (result.found_existing) {
                const index = result.key_ptr.*;

                if (!in_queue[index]) {
                    // Not queued, re-queue.
                    in_queue[index] = true;
                    try self.queue.writeItem(index);
                }

                return EnqueueResult{
                    .found_existing = true,
                    .index = index,
                };
            } else {
                const index = self.count();
                result.key_ptr.* = index;
                try self.elements.append(self.allocator(), .{.item = item, .in_queue = true});
                try self.queue.writeItem(index);

                return EnqueueResult{
                    .found_existing = false,
                    .index = index,
                };
            }
        }

        /// A dummy context for the indices hash map. This hash map should never be
        /// require the default context, but still required one.
        const IndexContext = struct {
            items: []const T,
            ctx: Context,

            fn init(p: Self) IndexContext {
                return .{
                    .items = p.elements.items(.item),
                    .ctx = p.ctx,
                };
            }

            pub fn hash(self: IndexContext, index: usize) u64 {
                return self.ctx.hash(self.items[index]);
            }

            pub fn eql(self: IndexContext, lhs: usize, rhs: usize) bool {
                _ = self;
                _ = lhs;
                _ = rhs;
                unreachable;
            }
        };

        /// The context type used to query the `indices` set.
        const ByItemContext = struct {
            items: []const T,
            ctx: Context,

            fn init(p: Self) ByItemContext {
                return .{
                    .items = p.elements.items(.item),
                    .ctx = p.ctx,
                };
            }

            pub fn hash(self: ByItemContext, item: T) u64 {
                return self.ctx.hash(item);
            }

            pub fn eql(self: ByItemContext, lhs: T, rhs: usize) bool {
                return self.ctx.eql(lhs, self.items[rhs]);
            }
        };
    };
}

test "" {
    const P = ConvergentProcess(
        usize,
        std.hash_map.AutoContext(usize)
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
