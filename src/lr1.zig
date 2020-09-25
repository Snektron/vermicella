const std = @import("std");
const Allocator = std.mem.Allocator;

fn getHashSetHashFn(comptime HashSet: type, comptime child_hasher: anytype) (fn (HashSet) u64) {
    return struct {
        fn hash(hash_set: HashSet) u64 {
            var value: u64 = 0;
            var it = hash_set.iterator();
            while (it.next()) |entry| {
                value ^= child_hasher(entry.key);
            }

            return value;
        }
    }.hash;
}

fn getHashSetEqlFn(comptime HashSet: type, comptime child_hasher: anytype) (fn (HashSet, HashSet) bool) {
    return struct {
        fn eql(lhs: HashSet, rhs: HashSet) bool {
            if (lhs.count() != rhs.count()) {
                return false;
            }

            var it = lhs.iterator();
            while (it.next()) |entry| {
                if (!rhs.contains(entry.key)) {
                    return false;
                }
            }

            return true;
        }
    }.eql;
}

pub fn Generator(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        const Terminal = Grammar.Terminal;
        const NonTerminal = Grammar.NonTerminal;
        const Symbol = Grammar.Symbol;
        const Production = Grammar.Production;
        const TerminalSet = std.AutoHashMapUnmanaged(Terminal, void);
        const ConfigSet = std.AutoHashMapUnmanaged(Config, void);

        arena: std.heap.ArenaAllocator,
        grammar: Grammar,

        const Config = struct {
            prod: *const Production,
            dot: usize,
            lookahead: Terminal,

            fn init(prod: *const Production, lookahead: Terminal) Config {
                return .{
                    .prod = prod,
                    .dot = 0,
                    .lookahead = lookahead,
                };
            }

            fn successor(self: Config) ?Config {
                if (self.dot == self.prod.elements.len) {
                    return null;
                }

                return Config{
                    .prod = self.prod,
                    .dot = self.dot + 1,
                    .lookahead = self.lookahead,
                };
            }

            fn isDotAtEnd(self: Config) bool {
                return self.dot == self.prod.elements.len;
            }

            fn symAtDot(self: Config) ?Symbol {
                return if (self.isDotAtEnd())
                        null
                    else
                        self.prod.elements[self.dot];
            }

            fn ntAtDot(self: Config) ?NonTerminal {
                const sym = self.symAtDot() orelse return null;
                return switch (sym) {
                    .terminal => null,
                    .non_terminal => |nt| nt,
                };
            }

            pub fn format(self: Config, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.print("{} ->", .{ self.prod.lhs });

                for (self.prod.elements) |element, i| {
                    if (i == self.dot) {
                        try writer.print(" •", .{});
                    }
                    switch (element) {
                        .terminal => |t| try writer.print(" '{}'", .{ t }),
                        .non_terminal => |nt| try writer.print(" {}", .{ nt }),
                    }
                }

                if (self.prod.elements.len == self.dot) {
                    try writer.print(" •", .{});
                }

                try writer.print(", {}", .{ self.lookahead });
            }
        };

        fn dumpConfigSet(self: Self, config_set: ConfigSet) void {
            var it = config_set.iterator();
            while (it.next()) |entry| {
                const config = entry.key;
                std.debug.print("{}\n", .{ entry.key });
            }
        }

        fn first(self: *Self, config: Config) !TerminalSet {
            var set = TerminalSet{};
            var seen = std.AutoHashMap(NonTerminal, void).init(&self.arena.allocator);
            var queue = std.fifo.LinearFifo(NonTerminal, .Dynamic).init(&self.arena.allocator);
            const symbols = config.prod.elements[config.dot..];

            for (symbols) |sym| {
                const start_nt = switch (sym) {
                    .terminal => |t| {
                        try set.put(&self.arena.allocator, t, {});
                        return set;
                    },
                    .non_terminal => |start_nt| start_nt
                };

                try queue.writeItem(start_nt);
                var has_empty = false;

                while (queue.readItem()) |current_nt| {
                    for (self.grammar.productions) |prod| {
                        if (prod.lhs != current_nt) {
                            continue;
                        }

                        if (prod.elements.len == 0) {
                            has_empty = true;
                            continue;
                        }

                        switch (prod.elements[0]) {
                            .terminal => |t| try set.put(&self.arena.allocator, t, {}),
                            .non_terminal => |nt| {
                                const result = try seen.getOrPut(nt);
                                if (!result.found_existing) {
                                    try queue.writeItem(nt);
                                }
                            }
                        }
                    }
                }

                if (!has_empty) {
                    return set;
                }
            }

            try set.put(&self.arena.allocator, config.lookahead, {});
            return set;
        }

        fn initialConfigSet(self: *Self) !ConfigSet {
            var config_set = ConfigSet{};

            for (self.grammar.productions) |*prod| {
                if (prod.lhs == self.grammar.start) {
                    // TODO: Do something better for eof
                    var config = Config.init(prod, self.grammar.eof);
                    try config_set.put(&self.arena.allocator, config, {});
                }
            }

            try self.closure(&config_set);
            return config_set;
        }

        fn closure(self: *Self, config_set: *ConfigSet) !void {
            var queue = std.fifo.LinearFifo(Config, .Dynamic).init(&self.arena.allocator);

            {
                var it = config_set.iterator();
                while (it.next()) |entry| try queue.writeItem(entry.key);
            }

            while (queue.readItem()) |config| {
                const nt = config.ntAtDot() orelse continue;
                const first_set = try self.first(config.successor().?);
                var it = first_set.iterator();
                while (it.next()) |lookahead| {
                    for (self.grammar.productions) |*prod| {
                        if (prod.lhs != nt) {
                            continue;
                        }

                        const new_config = Config.init(prod, lookahead.key);
                        const result = try config_set.getOrPut(&self.arena.allocator, new_config);
                        if (!result.found_existing) {
                            try queue.writeItem(new_config);
                        }
                    }
                }
            }
        }

        fn successor(self: *Self, config_set: *const ConfigSet, symbol: Symbol) !ConfigSet {
            var new_config_set = ConfigSet{};

            var it = config_set.iterator();
            while (it.next()) |entry| {
                const dot_symbol = entry.key.symAtDot() orelse continue;
                if (std.meta.eql(dot_symbol, symbol)) {
                    const succ = entry.key.successor() orelse continue;
                    try new_config_set.put(&self.arena.allocator, succ, {});
                }
            }

            try self.closure(&new_config_set);
            return new_config_set;
        }

        fn generate(self: *Self) ![]ConfigSet {
            var family = std.ArrayList(ConfigSet).init(&self.arena.allocator);

            var seen = std.HashMap(
                ConfigSet,
                usize,
                comptime getHashSetHashFn(ConfigSet, comptime std.hash_map.getAutoHashFn(Config)),
                comptime getHashSetEqlFn(ConfigSet, comptime std.hash_map.getAutoEqlFn(Config)),
                std.hash_map.DefaultMaxLoadPercentage
            ).init(&self.arena.allocator);

            {
                const initial = try self.initialConfigSet();
                try seen.put(initial, family.items.len);
                try family.append(initial);
            }

            var i: usize = 0;
            while (i < family.items.len) : (i += 1) {
                const config_set = family.items[i];

                var it = config_set.iterator();
                while (it.next()) |entry| {
                    const sym = entry.key.symAtDot() orelse {
                        if (std.meta.eql(entry.key.prod.lhs, self.grammar.start)) {
                            std.debug.print("Action[{}, $] = accept\n", .{ i });
                        } else {
                            std.debug.print("Action[{}, {}] = reduce {}\n", .{ i, entry.key.lookahead, entry.key.prod });
                        }
                        continue;
                    };
                    const new_config_set = try self.successor(&config_set, sym);
                    const result = try seen.getOrPut(new_config_set);
                    if (!result.found_existing) {
                        result.entry.value = family.items.len;
                        try family.append(new_config_set);
                    }

                    switch (sym) {
                        .terminal => |t| std.debug.print("Action[{}, {}] = shift {}\n", .{ i, t, result.entry.value }),
                        .non_terminal => |nt| std.debug.print("Goto[{}, {}] = {}\n", .{ i, nt, result.entry.value })
                    }
                }
            }

            return family.toOwnedSlice();
        }
    };
}

pub fn generate(allocator: *Allocator, grammar: anytype) !void {
    var generator = Generator(@TypeOf(grammar)){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .grammar = grammar,
    };
    defer generator.arena.deinit();

    const family = try generator.generate();
    for (family) |config_set, i| {
        std.debug.print("---- Configuration set {}:\n", .{ i });
        generator.dumpConfigSet(config_set);
    }
}
