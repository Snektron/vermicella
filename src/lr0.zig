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
            lookahead: TerminalSet,

            fn init(prod: *const Production) Config {
                return .{
                    .prod = prod,
                    .dot = 0,
                    .lookahead = .{},
                };
            }

            fn addLookahead(self: *Config, allocator: *Allocator, t: Terminal) !void {
                try self.lookahead.put(allocator, t, {});
            }

            fn successor(self: Config, allocator: *Allocator) !?Config {
                if (self.dot == self.prod.elements.len) {
                    return null;
                }

                return Config{
                    .prod = self.prod,
                    .dot = self.dot + 1,
                    .lookahead = try self.lookahead.clone(allocator),
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

            fn hash(self: Config) u64 {
                const terminal_set_hasher = comptime getHashSetHashFn(TerminalSet, std.hash_map.getAutoHashFn(Terminal));
                const lookahead_hash = terminal_set_hasher(self.lookahead);
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&self.prod));
                hasher.update(std.mem.asBytes(&self.dot));
                hasher.update(std.mem.asBytes(&lookahead_hash));
                return hasher.final();
            }

            fn eql(lhs: Config, rhs: Config) bool {
                const terminal_set_eql = comptime getHashSetEqlFn(TerminalSet, std.hash_map.getAutoEqlFn(Terminal));
                return lhs.prod == rhs.prod
                    and lhs.dot == rhs.dot
                    and terminal_set_eql(lhs.lookahead, rhs.lookahead);
            }

            pub fn format(self: Config, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.print("{} ->", .{ self.prod.lhs });

                for (self.prod.elements) |element, i| {
                    if (i == self.dot) {
                        try writer.print(" •", .{});
                    }
                    switch (element) {
                        .terminal => |t| try writer.print(" {}", .{ t }),
                        .non_terminal => |nt| try writer.print(" {}", .{ nt }),
                    }
                }

                if (self.prod.elements.len == self.dot) {
                    try writer.print(" •", .{});
                }

                var it = self.lookahead.iterator();
                var is_first = true;
                while (it.next()) |entry| {
                    if (is_first) {
                        is_first = false;
                        try writer.writeAll(", ");
                    } else {
                        try writer.writeByte('/');
                    }

                    try writer.print("{}", .{ entry.key });
                }
            }
        };

        fn dumpConfigSet(self: Self, config_set: ConfigSet) void {
            var it = config_set.iterator();
            while (it.next()) |entry| {
                const config = entry.key;
                std.debug.print("{}\n", .{ entry.key });
            }
        }

        fn first(self: *Self, symbols: []const Symbol, lookahead: Terminal) !TerminalSet {
            var set = TerminalSet{};
            var seen = std.AutoHashMap(NonTerminal, void).init(&self.arena.allocator);
            var queue = std.fifo.LinearFifo(NonTerminal, .Dynamic).init(&self.arena.allocator);

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
                    for (grammar.productions) |prod| {
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
                                if (seen.fetchPut(nt) == null) {
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

            try set.put(&self.arena.allocator, lookahead, {});
            return set;
        }

        fn initialConfigSet(self: *Self) !ConfigSet {
            var config_set = ConfigSet{};

            for (self.grammar.productions) |*prod| {
                if (prod.lhs == self.grammar.start) {
                    var config = Config.init(prod);
                    // TODO: Do something better for eof
                    try config.addLookahead(&self.arena.allocator, prod.elements[prod.elements.len - 1].terminal);
                    try config_set.put(&self.arena.allocator, config, {});
                }
            }

            try self.closure(&config_set);
            return config_set;
        }

        fn closure(self: *Self, config_set: *ConfigSet) !void {
            var queue = std.fifo.LinearFifo(Config, .Dynamic).init(&self.arena.allocator);

            var it = config_set.iterator();
            while (it.next()) |entry| try queue.writeItem(entry.key);

            while (queue.readItem()) |config| {
                var nt = config.ntAtDot() orelse continue;

                for (self.grammar.productions) |*prod| {
                    if (prod.lhs != nt) {
                        continue;
                    }

                    const new_config = Config.init(prod);
                    const result = try config_set.getOrPut(&self.arena.allocator, new_config);
                    if (!result.found_existing) {
                        try queue.writeItem(new_config);
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
                    const succ = (try entry.key.successor(&self.arena.allocator)) orelse continue;
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
                comptime getHashSetHashFn(ConfigSet, Config.hash),
                comptime getHashSetEqlFn(ConfigSet, Config.eql),
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

                var reduced = false;
                var accepted_or_shifted = false;

                var it = config_set.iterator();
                while (it.next()) |entry| {
                    const sym = entry.key.symAtDot() orelse {
                        if (std.meta.eql(entry.key.prod.lhs, self.grammar.start)) {
                            accepted_or_shifted = true;
                            std.debug.print("Action[{}, $] = accept\n", .{ i });
                        } else {
                            reduced = true;
                            std.debug.print("Action[{}, *] = reduce {}\n", .{ i, entry.key.prod });
                        }
                        continue;
                    };
                    accepted_or_shifted = true;

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

                if (reduced and accepted_or_shifted) {
                    return error.ShiftReduceConflict;
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
