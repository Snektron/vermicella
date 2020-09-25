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

        allocator: *Allocator,
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

            fn deinit(self: *Config, allocator: *Allocator) void {
                self.lookahead.deinit(allocator);
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

        const ConfigSet = struct {
            const Set = std.AutoHashMapUnmanaged(Config, void);

            configs: Set = .{},

            fn initFromProductions(allocator: *Allocator, grammar: Grammar, initial: NonTerminal) !ConfigSet {
                var self = ConfigSet{};

                for (grammar.productions) |*prod| {
                    if (prod.lhs == initial) {
                        var config = Config.init(prod);
                        try config.addLookahead(allocator, prod.elements[prod.elements.len - 1].terminal);
                        try self.configs.put(allocator, config, {});
                    }
                }

                return self;
            }

            fn deinit(self: *ConfigSet, allocator: *Allocator) void {
                var it = self.configs.iterator();
                while (it.next()) |config| {
                    config.key.deinit(allocator);
                }

                self.configs.deinit(allocator);
            }

            fn closure(self: *ConfigSet, allocator: *Allocator, grammar: Grammar) !void {
                var queue = std.fifo.LinearFifo(Config, .Dynamic).init(allocator);
                defer queue.deinit();

                var it = self.configs.iterator();
                while (it.next()) |entry| try queue.writeItem(entry.key);

                while (queue.readItem()) |config| {
                    var nt = config.ntAtDot() orelse continue;

                    for (grammar.productions) |*prod| {
                        if (prod.lhs != nt) {
                            continue;
                        }

                        const new_config = Config.init(prod);
                        const result = try self.configs.getOrPut(allocator, new_config);
                        if (!result.found_existing) {
                            try queue.writeItem(new_config);
                        }
                    }
                }
            }

            fn successor(self: ConfigSet, allocator: *Allocator, grammar: Grammar, symbol: Symbol) !ConfigSet {
                var new_config_set = ConfigSet{};
                errdefer new_config_set.deinit(allocator);

                var it = self.configs.iterator();
                while (it.next()) |entry| {
                    const dot_symbol = entry.key.symAtDot() orelse continue;
                    if (std.meta.eql(dot_symbol, symbol)) {
                        try new_config_set.configs.put(allocator, (try entry.key.successor(allocator)) orelse continue, {});
                    }
                }

                return new_config_set;
            }

            fn dump(self: ConfigSet) void {
                var it = self.configs.iterator();
                while (it.next()) |entry| {
                    const config = entry.key;
                    std.debug.print("{}\n", .{ entry.key });
                }
            }

            fn hash(self: ConfigSet) u64 {
                var config_hasher = std.hash_map.getAutoHashFn(Config);
                var value: u64 = 0;
                var it = self.configs.iterator();
                while (it.next()) |entry| {
                    value ^= config_hasher(entry.key);
                }

                return value;
            }

            fn eql(lhs: ConfigSet, rhs: ConfigSet) bool {
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

        fn first(self: *Self, symbols: []const Symbol, lookahead: Terminal) !TerminalSet {
            var set = TerminalSet{};
            errdefer set.deinit(self.allocator);

            var seen = std.AutoHashMap(NonTerminal, void).init(self.allocator);
            defer seen.deinit();

            var queue = std.fifo.LinearFifo(NonTerminal, .Dynamic).init(self.allocator);
            defer queue.deinit();

            for (symbols) |sym| {
                const start_nt = switch (sym) {
                    .terminal => |t| {
                        try set.put(self.allocator, t, {});
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
                            .terminal => |t| try set.put(self.allocator, t, {}),
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

            try set.put(self.allocator, lookahead, {});
            return set;
        }

        fn generate(self: *Self) ![]ConfigSet {
            var family = std.ArrayList(ConfigSet).init(self.allocator);
            errdefer {
                for (family.items) |*config_set| config_set.deinit(self.allocator);
                family.deinit();
            }

            var seen = std.HashMap(
                ConfigSet,
                usize,
                ConfigSet.hash,
                ConfigSet.eql,
                std.hash_map.DefaultMaxLoadPercentage
            ).init(self.allocator);
            defer seen.deinit();

            {
                var initial = try ConfigSet.initFromProductions(self.allocator, self.grammar, self.grammar.start);
                try initial.closure(self.allocator, self.grammar);
                try seen.put(initial, 0);
                try family.append(initial);
            }

            var i: usize = 0;
            while (i < family.items.len) : (i += 1) {
                const config_set = family.items[i];

                var reduced = false;
                var accepted_or_shifted = false;

                var it = config_set.configs.iterator();
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

                    var new_config_set = try config_set.successor(self.allocator, self.grammar, sym);
                    errdefer new_config_set.deinit(self.allocator);
                    try new_config_set.closure(self.allocator, self.grammar);

                    const result = try seen.getOrPut(new_config_set);
                    if (result.found_existing) {
                        new_config_set.deinit(self.allocator);
                    } else {
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
        .allocator = allocator,
        .grammar = grammar,
    };

    const family = try generator.generate();
    defer {
        for (family) |*config_set| config_set.deinit(allocator);
        allocator.free(family);
    }

    for (family) |config_set, i| {
        std.debug.print("---- Configuration set {}:\n", .{ i });
        config_set.dump();
    }

   //  std.debug.print("=========\n", .{});

   // for (family) |config_set, state| {
   //      var it = config_set.configs.iterator();
   //      while (it.next()) |entry| {
   //          if (entry.value == .accept) {
   //              std.debug.print("Action[{}, $] = accept\n", .{ state });
   //              continue;
   //          } else if (entry.value == .reduce) {
   //              std.debug.print("Action[{}, *] = reduce {}\n", .{ state, entry.key.prod });
   //              continue;
   //          }

   //          const sym = entry.key.symAtDot() orelse {
   //              std.debug.print("Action[{}, $] = accept\n", .{ state });
   //              continue;
   //          };

   //          switch (sym) {
   //              .terminal => |t| std.debug.print("Action[{}, {}] = shift {}\n", .{ state, t, entry.value.shift }),
   //              .non_terminal => {},
   //          }
   //      }
   //  }

   //  for (family) |config_set, state| {
   //      var it = config_set.configs.iterator();
   //      while (it.next()) |entry| {
   //          const sym = entry.key.symAtDot() orelse continue;
   //          switch (sym) {
   //              .terminal => {},
   //              .non_terminal => |nt| std.debug.print("Goto[{}, {}] = {}\n", .{ state, nt, entry.value.shift }),
   //          }
   //      }
   //  }
}
