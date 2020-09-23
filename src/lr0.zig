const std = @import("std");
const Allocator = std.mem.Allocator;

fn Config(comptime Grammar: type) type {
    return struct {
        const Self = @This();

        prod: *const Grammar.Production,
        dot: usize,

        fn init(prod: *const Grammar.Production) Self {
            return .{.prod = prod, .dot = 0};
        }

        fn successor(self: Self) ?Self {
            if (self.dot == self.prod.elements.len) {
                return null;
            }

            return Self{.prod = self.prod, .dot = self.dot + 1};
        }

        fn isDotAtEnd(self: Self) bool {
            return self.dot == self.prod.elements.len;
        }

        fn symAtDot(self: Self) ?Grammar.Symbol {
            return if (self.isDotAtEnd())
                    null
                else
                    self.prod.elements[self.dot];
        }

        fn ntAtDot(self: Self) ?Grammar.NonTerminal {
            const sym = self.symAtDot() orelse return null;
            return switch (sym) {
                .terminal => null,
                .non_terminal => |nt| nt,
            };
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{} -> ", .{ self.prod.lhs });

            for (self.prod.elements) |element, i| {
                if (i == self.dot) {
                    try writer.print("• ", .{});
                }
                switch (element) {
                    .terminal => |t| try writer.print("{} ", .{ t }),
                    .non_terminal => |nt| try writer.print("{} ", .{ nt }),
                }
            }
            if (self.prod.elements.len == self.dot) {
                try writer.print("• ", .{});
            }
        }
    };
}

fn ConfigSet(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        pub const Successor = union(enum) {
            accept,
            reduce,
            shift: usize,
        };

        const Set = std.AutoHashMapUnmanaged(Config(Grammar), Successor);

        configs: Set = .{},

        fn initFromProductions(allocator: *Allocator, grammar: Grammar, initial: Grammar.NonTerminal) !Self {
            var self = Self{};

            for (grammar.productions) |*prod| {
                if (prod.lhs == initial) {
                    try self.configs.put(allocator, Config(Grammar).init(prod), undefined);
                }
            }

            return self;
        }


        fn deinit(self: *Self, allocator: *Allocator) void {
            self.configs.deinit(allocator);
        }

        fn closure(self: *Self, allocator: *Allocator, grammar: Grammar) !void {
            var queue = std.fifo.LinearFifo(Config(Grammar), .Dynamic).init(allocator);
            defer queue.deinit();

            var it = self.configs.iterator();
            while (it.next()) |entry| try queue.writeItem(entry.key);

            while (queue.readItem()) |config| {
                var nt = config.ntAtDot() orelse continue;

                for (grammar.productions) |*prod| {
                    if (prod.lhs != nt) {
                        continue;
                    }

                    const new_config = Config(Grammar).init(prod);
                    const result = try self.configs.getOrPut(allocator, new_config);
                    if (!result.found_existing) {
                        try queue.writeItem(new_config);
                    }
                }
            }
        }

        fn successor(self: Self, allocator: *Allocator, grammar: Grammar, symbol: Grammar.Symbol) !Self {
            var new_config_set = Self{};
            errdefer new_config_set.deinit(allocator);

            var it = self.configs.iterator();
            while (it.next()) |entry| {
                const dot_symbol = entry.key.symAtDot() orelse continue;
                if (std.meta.eql(dot_symbol, symbol)) {
                    try new_config_set.configs.put(allocator, entry.key.successor() orelse continue, undefined);
                }
            }

            return new_config_set;
        }

        fn dump(self: Self, with_successors: bool) void {
            var it = self.configs.iterator();
            while (it.next()) |entry| {
                const config = entry.key;
                std.debug.print("{}", .{ entry.key });

                if (with_successors) {
                    switch (entry.value) {
                        .accept => std.debug.print(" => accept", .{}),
                        .reduce => std.debug.print(" => reduce", .{}),
                        .shift => |config_set_index| std.debug.print(" => {}", .{config_set_index}),
                    }
                }

                std.debug.print("\n", .{});
            }
        }

        fn hash(self: Self) u64 {
            var config_hasher = std.hash_map.getAutoHashFn(Config(Grammar));
            var value: u64 = 0;
            var it = self.configs.iterator();
            while (it.next()) |entry| {
                value ^= config_hasher(entry.key);
            }

            return value;
        }

        fn eql(lhs: Self, rhs: Self) bool {
            if (lhs.configs.count() != rhs.configs.count()) {
                return false;
            }

            var it = lhs.configs.iterator();
            while (it.next()) |entry| {
                if (!rhs.configs.contains(entry.key)) {
                    return false;
                }
            }

            return true;
        }
    };
}

fn lr0Family(comptime Grammar: type, allocator: *Allocator, grammar: Grammar, start_symbol: Grammar.NonTerminal) ![]ConfigSet(Grammar) {
    var family = std.ArrayList(ConfigSet(Grammar)).init(allocator);
    errdefer family.deinit();

    var seen = std.HashMap(
        ConfigSet(Grammar),
        usize,
        ConfigSet(Grammar).hash,
        ConfigSet(Grammar).eql,
        std.hash_map.DefaultMaxLoadPercentage
    ).init(allocator);
    defer seen.deinit();

    // var seen_syms = std.AutoHashMap(Grammar.Symbol, void).init(allocator);
    // defer seen_syms.deinit();

    {
        var initial = try ConfigSet(Grammar).initFromProductions(allocator, grammar, start_symbol);
        try initial.closure(allocator, grammar);
        try seen.put(initial, 0);
        try family.append(initial);
    }

    var i: usize = 0;
    while (i < family.items.len) : (i += 1) {
        const config_set = family.items[i];
        // seen_syms.clearRetainingCapacity();

        var reduced = false;
        var accepted_or_shifted = false;

        var it = config_set.configs.iterator();
        while (it.next()) |entry| {
            const sym = entry.key.symAtDot() orelse {
                if (std.meta.eql(entry.key.prod.lhs, start_symbol)) {
                    accepted_or_shifted = true;
                    entry.value = .accept;
                } else {
                    reduced = true;
                    entry.value = .reduce;
                }
                continue;
            };
            accepted_or_shifted = true;

            // TODO: Fix
            // if ((try seen_syms.getOrPut(sym)).found_existing) {
            //     continue;
            // }

            var new_config_set = try config_set.successor(allocator, grammar, sym);
            try new_config_set.closure(allocator, grammar);

            const result = try seen.getOrPut(new_config_set);
            if (result.found_existing) {
                new_config_set.deinit(allocator);
            } else {
                result.entry.value = family.items.len;
                try family.append(new_config_set);
            }

            entry.value = .{.shift = result.entry.value};
        }

        if (reduced and accepted_or_shifted) {
            return error.ShiftReduceConflict;
        }
    }

    return family.toOwnedSlice();
}

pub fn generate(allocator: *Allocator, grammar: anytype, start_symbol: @TypeOf(grammar).NonTerminal) !void {
    const family = try lr0Family(@TypeOf(grammar), allocator, grammar, start_symbol);
    defer {
        for (family) |*config_set| config_set.deinit(allocator);
        allocator.free(family);
    }

    for (family) |config_set, i| {
        std.debug.print("---- Configuration set {}:\n", .{ i });
        config_set.dump(true);
    }

    std.debug.print("=========\n", .{});

   for (family) |config_set, state| {
        var it = config_set.configs.iterator();
        while (it.next()) |entry| {
            if (entry.value == .accept) {
                std.debug.print("Action[{}, $] = accept\n", .{ state });
                continue;
            } else if (entry.value == .reduce) {
                std.debug.print("Action[{}, *] = reduce {}\n", .{ state, entry.key.prod });
                continue;
            }

            const sym = entry.key.symAtDot() orelse {
                std.debug.print("Action[{}, $] = accept\n", .{ state });
                continue;
            };

            switch (sym) {
                .terminal => |t| std.debug.print("Action[{}, {}] = shift {}\n", .{ state, t, entry.value.shift }),
                .non_terminal => {},
            }
        }
    }

    for (family) |config_set, state| {
        var it = config_set.configs.iterator();
        while (it.next()) |entry| {
            const sym = entry.key.symAtDot() orelse continue;
            switch (sym) {
                .terminal => {},
                .non_terminal => |nt| std.debug.print("Goto[{}, {}] = {}\n", .{ state, nt, entry.value.shift }),
            }
        }
    }
}
