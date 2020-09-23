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

        fn symAtDot(self: Self) ?Grammar.Symbol {
            return if (self.dot == self.prod.elements.len)
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
    };
}

fn ConfigSet(comptime Grammar: type) type {
    return struct {
        const Self = @This();
        const Set = std.AutoHashMap(Config(Grammar), void);

        configs: Set,

        fn init(allocator: *Allocator) Self {
            return .{
                .configs = Set.init(allocator),
            };
        }

        fn initFromProductions(allocator: *Allocator, grammar: Grammar, initial: Grammar.NonTerminal) !Self {
            var self = Self.init(allocator);

            for (grammar.productions) |*prod| {
                if (prod.lhs == initial) {
                    try self.configs.put(Config(Grammar).init(prod), {});
                }
            }

            return self;
        }


        fn deinit(self: *Self) void {
            self.configs.deinit();
        }

        fn closure(self: *Self, grammar: Grammar) !void {
            var queue = std.fifo.LinearFifo(Config(Grammar), .Dynamic).init(self.configs.allocator);
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
                    const result = try self.configs.getOrPut(new_config);
                    if (!result.found_existing) {
                        try queue.writeItem(new_config);
                    }
                }
            }
        }

        fn successor(self: Self, grammar: Grammar, symbol: Grammar.Symbol) !Self {
            var new_config_set = Self.init(self.configs.allocator);
            errdefer new_config_set.deinit();

            var it = self.configs.iterator();
            while (it.next()) |entry| {
                const dot_symbol = entry.key.symAtDot() orelse continue;
                if (std.meta.eql(dot_symbol, symbol)) {
                    try new_config_set.configs.put(entry.key.successor() orelse continue, {});
                }
            }

            return new_config_set;
        }

        fn dump(self: Self) void {
            var it = self.configs.iterator();
            while (it.next()) |entry| {
                const config = entry.key;
                std.debug.print("{} => ", .{ config.prod.lhs });

                for (config.prod.elements) |element, i| {
                    if (i == config.dot) {
                        std.debug.print("• ", .{});
                    }
                    switch (element) {
                        .terminal => |t| std.debug.print("{} ", .{ t }),
                        .non_terminal => |nt| std.debug.print("{} ", .{ nt }),
                    }
                }
                if (config.prod.elements.len == config.dot) {
                    std.debug.print("•", .{});
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

fn lr0Family(comptime Grammar: type, allocator: *Allocator, grammar: Grammar, start_symbol: Grammar.NonTerminal) !void {
    var queue = std.fifo.LinearFifo(ConfigSet(Grammar), .Dynamic).init(allocator);
    defer queue.deinit();

    var seen = std.HashMap(
        ConfigSet(Grammar),
        void,
        ConfigSet(Grammar).hash,
        ConfigSet(Grammar).eql,
        std.hash_map.DefaultMaxLoadPercentage
    ).init(allocator);
    defer seen.deinit();

    var seen_syms = std.AutoHashMap(Grammar.Symbol, void).init(allocator);
    defer seen_syms.deinit();

    {
        var initial = try ConfigSet(Grammar).initFromProductions(allocator, grammar, start_symbol);
        try initial.closure(grammar);
        try seen.put(initial, {});
        try queue.writeItem(initial);
    }

    while (queue.readItem()) |config_set| {
        std.debug.print("----\n", .{});
        config_set.dump();

        seen_syms.clearRetainingCapacity();

        var it = config_set.configs.iterator();
        while (it.next()) |entry| {
            const sym = entry.key.symAtDot() orelse continue;
            if ((try seen_syms.getOrPut(sym)).found_existing) {
                continue;
            }

            var new_config_set = try config_set.successor(grammar, sym);
            try new_config_set.closure(grammar);

            const result = try seen.getOrPut(new_config_set);
            if (!result.found_existing) {
                try queue.writeItem(new_config_set);
            }
        }
    }
}

pub fn generate(allocator: *Allocator, grammar: anytype, start_symbol: @TypeOf(grammar).NonTerminal) !void {
    try lr0Family(@TypeOf(grammar), allocator, grammar, start_symbol);
}
