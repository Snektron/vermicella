const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Generator(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        const Terminal = Grammar.Terminal;
        const NonTerminal = Grammar.NonTerminal;
        const Symbol = Grammar.Symbol;
        const Production = Grammar.Production;
        const TerminalSet = std.AutoHashMapUnmanaged(Terminal, void);

        const ConfigData = struct {
            lookahead_set: TerminalSet,
            action: ParseTable(Grammar).Action,
        };

        const ConfigSet = std.AutoHashMapUnmanaged(Config, ConfigData);

        arena: std.heap.ArenaAllocator,
        grammar: Grammar,

        const Config = struct {
            prod: *const Production,
            dot: usize,

            fn init(prod: *const Production) Config {
                return .{
                    .prod = prod,
                    .dot = 0,
                };
            }

            fn successor(self: Config) ?Config {
                if (self.dot == self.prod.elements.len) {
                    return null;
                }

                return Config{
                    .prod = self.prod,
                    .dot = self.dot + 1,
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
            }
        };

        fn dumpConfigSet(self: Self, config_set: ConfigSet) void {
            var it = config_set.iterator();
            while (it.next()) |entry| {
                const config = entry.key;
                std.debug.print("{}, ", .{ entry.key });
                var lookahead_it = entry.value.lookahead_set.iterator();
                var is_first = true;
                while (lookahead_it.next()) |lookahead| {
                    if (is_first) {
                        is_first = false;
                    } else {
                        std.debug.print("/", .{});
                    }
                    std.debug.print("{}", .{ lookahead.key });
                }
                std.debug.print("\n", .{});
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

            try set.put(&self.arena.allocator, lookahead, {});
            return set;
        }

        fn putConfig(self: *Self, config_set: *ConfigSet, config: Config, lookahead: Terminal) !bool {
            const result = try config_set.getOrPut(&self.arena.allocator, config);
            const config_data = &result.entry.value;
            if (!result.found_existing) {
                config_data.* = .{.lookahead_set = .{}, .action = undefined};
            }
            const lookahead_result = try config_data.lookahead_set.getOrPut(&self.arena.allocator, lookahead);
            return lookahead_result.found_existing;
        }

        fn initialConfigSet(self: *Self) !ConfigSet {
            var config_set = ConfigSet{};

            for (self.grammar.productions) |*prod| {
                if (prod.lhs == self.grammar.start) {
                    // TODO: Do something better for eof
                    _ = try self.putConfig(&config_set, Config.init(prod), self.grammar.eof);
                }
            }

            try self.closure(&config_set);
            return config_set;
        }

        fn closure(self: *Self, config_set: *ConfigSet) !void {
            const QueueItem = struct {
                config: Config,
                lookahead: Terminal,
            };

            var queue = std.fifo.LinearFifo(QueueItem, .Dynamic).init(&self.arena.allocator);

            {
                var it = config_set.iterator();
                while (it.next()) |entry| {
                    var lookahead_it = entry.value.lookahead_set.iterator();
                    while (lookahead_it.next()) |lookahead| {
                        try queue.writeItem(.{.config = entry.key, .lookahead = lookahead.key});
                    }
                }
            }

            while (queue.readItem()) |item| {
                const config = item.config;
                const nt = config.ntAtDot() orelse continue;
                const first_set = try self.first(config.prod.elements[config.dot + 1 ..], item.lookahead);
                var it = first_set.iterator();
                while (it.next()) |lookahead| {
                    for (self.grammar.productions) |*prod| {
                        if (prod.lhs != nt) {
                            continue;
                        }

                        const new_config = Config.init(prod);
                        const found_existing = try self.putConfig(config_set, Config.init(prod), lookahead.key);
                        if (!found_existing) {
                            try queue.writeItem(.{.config = new_config, .lookahead = lookahead.key});
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
                    var lookahead_it = entry.value.lookahead_set.iterator();
                    while (lookahead_it.next()) |lookahead| {
                        _ = try self.putConfig(&new_config_set, succ, lookahead.key);
                    }
                }
            }

            try self.closure(&new_config_set);
            return new_config_set;
        }

        fn mergeConfigSets(self: *Self, into: *ConfigSet, from: *const ConfigSet) !bool {
            var changed = false;
            var it = from.iterator();
            while (it.next()) |entry| {
                var lookahead_it = entry.value.lookahead_set.iterator();
                while (lookahead_it.next()) |lookahead| {
                    const found_existing = try self.putConfig(into, entry.key, lookahead.key);
                    if (!found_existing) {
                        changed = true;
                    }
                }
            }
            return changed;
        }

        fn configSetHash(config_set: ConfigSet) u64 {
            const config_hasher = comptime std.hash_map.getAutoHashFn(Config);

            var value: u64 = 0;
            var it = config_set.iterator();
            while (it.next()) |entry| {
                value ^= config_hasher(entry.key);
            }

            return value;
        }

        fn configSetEql(lhs: ConfigSet, rhs: ConfigSet) bool {
            if (lhs.count() != rhs.count()) {
                return false;
            }

            {
                var it = lhs.iterator();
                while (it.next()) |entry| {
                    if (!rhs.contains(entry.key)) {
                        return false;
                    }
                }
            }

            {
                var it = rhs.iterator();
                while (it.next()) |entry| {
                    if (!lhs.contains(entry.key)) {
                        return false;
                    }
                }
            }

            return true;
        }

        fn generate(self: *Self) !ParseTable(Grammar) {
            var parse_table = ParseTable(Grammar){};
            var family = std.ArrayList(ConfigSet).init(&self.arena.allocator);
            var queue = std.fifo.LinearFifo(usize, .Dynamic).init(&self.arena.allocator);

            var seen = std.HashMap(
                ConfigSet,
                usize,
                configSetHash,
                configSetEql,
                std.hash_map.DefaultMaxLoadPercentage
            ).init(&self.arena.allocator);

            {
                const initial = try self.initialConfigSet();
                try seen.put(initial, family.items.len);
                try queue.writeItem(family.items.len);
                try family.append(initial);
            }

            while (queue.readItem()) |config_set_index| {
                const config_set = family.items[config_set_index];
                var it = config_set.iterator();
                while (it.next()) |entry| {
                    const config = entry.key;
                    const config_data = &entry.value;

                    const sym = config.symAtDot() orelse {
                        if (std.meta.eql(config.prod.lhs, self.grammar.start)) {
                            config_data.action = .{.accept = config.prod};
                        } else {
                            config_data.action = .{.reduce = config.prod};
                        }
                        continue;
                    };

                    const new_config_set = try self.successor(&config_set, sym);
                    const result = try seen.getOrPut(new_config_set);
                    if (result.found_existing) {
                        const existing_index = result.entry.value;
                        if (existing_index != config_set_index) {
                            const changed = try self.mergeConfigSets(&family.items[existing_index], &new_config_set);
                            if (changed) {
                                try queue.writeItem(existing_index);
                            }
                        }
                    } else {
                        result.entry.value = family.items.len;
                        try queue.writeItem(family.items.len);
                        try family.append(new_config_set);
                    }

                    const new_state = result.entry.value;
                    config_data.action = .{.shift = new_state};
                }
            }

            for (family.items) |config_set, j| {
                std.debug.print("---- config set {}:\n", .{ j });
                self.dumpConfigSet(config_set);
            }

            for (family.items) |config_set, state| {
                var it = config_set.iterator();
                while (it.next()) |entry| {
                    const config = entry.key;
                    const lookahead_set = entry.value.lookahead_set;
                    const action = entry.value.action;

                    switch (action) {
                        .accept => |prod| {
                            std.debug.print("Action[{}, $] = accept {}\n", .{ state, prod });
                            try parse_table.putAction(self.arena.child_allocator, state, self.grammar.eof, action);
                        },
                        .reduce => |prod| {
                            var lookahead_it = lookahead_set.iterator();
                            while (lookahead_it.next()) |lookahead| {
                                std.debug.print("Action[{}, {}] = reduce {}\n", .{ state, lookahead.key, prod });
                                try parse_table.putAction(self.arena.child_allocator, state, lookahead.key, action);
                            }
                        },
                        .shift => |new_state| {
                            const sym = config.symAtDot().?;
                            switch (sym) {
                                .terminal => |t| {
                                    std.debug.print("Action[{}, {}] = shift {}\n", .{ state, t, new_state });
                                    try parse_table.putAction(self.arena.child_allocator, state, t, action);
                                },
                                .non_terminal => |nt| {
                                    std.debug.print("Goto[{}, {}] = {}\n", .{ state, nt, new_state });
                                    try parse_table.putGoto(self.arena.child_allocator, state, nt, new_state);
                                }
                            }
                        },
                    }
                }
            }

            return parse_table;
        }
    };
}

fn ensureSize(comptime Item: type, allocator: *Allocator, array_list: *std.ArrayListUnmanaged(Item), size: usize, default: Item) !void {
    if (array_list.items.len < size) {
        const prev_size = array_list.items.len;
        try array_list.resize(allocator, size);
        for (array_list.items[prev_size ..]) |*item| {
            item.* = default;
        }
    }
}

pub fn ParseTable(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        pub const Action = union(enum) {
            shift: usize,
            reduce: *const Grammar.Production,
            accept: *const Grammar.Production,
        };

        pub const ActionMap = std.AutoHashMapUnmanaged(Grammar.Terminal, Action);
        pub const GotoMap = std.AutoHashMapUnmanaged(Grammar.NonTerminal, usize);

        action: std.ArrayListUnmanaged(ActionMap) = .{},
        goto: std.ArrayListUnmanaged(GotoMap) = .{},

        fn putAction(self: *Self, allocator: *Allocator, state: usize, terminal: Grammar.Terminal, action: Action) !void {
            try ensureSize(ActionMap, allocator, &self.action, state + 1, .{});

            const action_map = &self.action.items[state];
            const result = try action_map.getOrPut(allocator, terminal);
            if (result.found_existing) {
                if (!std.meta.eql(result.entry.value, action)) {
                    return error.Conflict;
                }
            } else {
                result.entry.value = action;
            }
        }

        fn putGoto(self: *Self, allocator: *Allocator, state: usize, non_terminal: Grammar.NonTerminal, new_state: usize) !void {
            try ensureSize(GotoMap, allocator, &self.goto, state + 1, .{});

            const goto_map = &self.goto.items[state];
            const result = try goto_map.getOrPut(allocator, non_terminal);
            if (result.found_existing) {
                if (result.entry.value != new_state) {
                    return error.Conflict;
                }
            } else {
                result.entry.value = new_state;
            }
        }

        pub fn getAction(self: Self, state: usize, terminal: Grammar.Terminal) ?Action {
            return self.action.items[state].get(terminal);
        }

        pub fn getGoto(self: Self, state: usize, non_terminal: Grammar.NonTerminal) ?usize {
            return self.goto.items[state].get(non_terminal);
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            for (self.action.items) |*action_map| action_map.deinit(allocator);
            for (self.goto.items) |*goto_map| goto_map.deinit(allocator);
            self.action.deinit(allocator);
            self.goto.deinit(allocator);
        }
    };
}

pub fn generate(comptime Grammar: type, allocator: *Allocator, grammar: Grammar) !ParseTable(Grammar) {
    var generator = Generator(Grammar){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .grammar = grammar,
    };
    defer generator.arena.deinit();

    return try generator.generate();
}

pub fn Parser(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        pub const Action = ParseTable(Grammar).Action;

        parse_table: *const ParseTable(Grammar),
        state_stack: std.ArrayList(usize),

        pub fn init(allocator: *Allocator, parse_table: *const ParseTable(Grammar)) !Self {
            var self = Self{
                .parse_table = parse_table,
                .state_stack = std.ArrayList(usize).init(allocator),
            };

            try self.state_stack.append(0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.state_stack.deinit();
        }

        pub fn feed(self: *Self, terminal: Grammar.Terminal) !Action {
            for (self.state_stack.items) |state| {
                std.debug.print("{} ", .{ state });
            }
            std.debug.print(": {}\n", .{ terminal });

            const state = self.state_stack.items[self.state_stack.items.len - 1];
            const action = self.parse_table.getAction(state, terminal) orelse return error.ParseError;

            switch (action) {
                .shift => |new_state| try self.state_stack.append(new_state),
                .reduce => |prod| {
                    self.state_stack.items.len -= prod.elements.len;
                    const prev_state = self.state_stack.items[self.state_stack.items.len - 1];
                    const new_state = self.parse_table.getGoto(prev_state, prod.lhs) orelse return error.ParseError;
                    try self.state_stack.append(new_state);
                },
                .accept => {},
            }

            return action;
        }
    };
}
