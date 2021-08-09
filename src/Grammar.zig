const std = @import("std");

const Self = @This();

/// Terminals are represented by a simple integer.
pub const Terminal = usize;

/// Nonterminals are represented by a simple integer.
pub const Nonterminal = usize;

/// A slice mapping Terminal integers to their name.
terminals: []const []const u8,

/// Information about nonterminals, which applies to all productions with the same `lhs`.
/// Indexed by Nonterminal.
/// The first entry in this slice is implicitly the start rule.
/// There must be at least one nonterminal.
nonterminals: []const NonterminalInfo,

/// The productions which make up the grammar. These are sorted by `lhs` incrementing, so that productions
/// may be indexed by `first_production` for some index `i` until `first_production` for index `i + 1`
/// in the `rules` slice.
/// There must be at least one production.
productions: []const Production,

/// The index of the nonterminal where parsing starts in the `nonterminals` array.
pub const start_nonterminal: Nonterminal = 0;

/// Return all productions which correspond to a particular nonterminal.
fn productionsForNonterminal(self: Self, nt: Nonterminal) []const Production {
    const first_production = self.nonterminals[nt].first_production;
    const last_production = if (nt == self.nonterminals.len - 1)
        self.productions.len
    else
        self.nonterminals[nt + 1].first_production;

    return self.productions[first_production .. last_production];
}

/// Dump this grammar in a human-readable form.
pub fn dump(self: Self) void {
    _ = self;

    for (self.productions) |_, i| {
        std.debug.print("{t}\n", .{ self.fmtProduction(i) });
    }
}

pub const NonterminalInfo = struct {
    /// Name of the nonterminal
    name: []const u8,

    /// The first production that corresponds to this rule
    /// in the grammar's `productions` slice.
    first_production: usize,
};

pub const Production = struct {
    /// The left-hand side of this production.
    lhs: Nonterminal,

    /// The right-hand side of this production.
    rhs: []const Symbol,

    /// A human-readable tag identifying this production. Must be unique for all productions
    /// with the same left-hand side.
    tag: []const u8,
};

pub const Symbol = union(enum) {
    /// This symbol represents a nonterminal, identified by an integer.
    /// The integer is continuously allocated, and forms an index into the
    /// grammar's `nonterminal_names` slice.
    nonterminal: usize,

    /// This symbol represents a terminal, identified by an integer.
    /// The integer is continuously allocated, and forms an index into the
    /// grammar's `terminal_names` slice.
    terminal: usize,
};

const ProductionFormatter = struct {
    g: *const Self,
    prod: usize,

    pub fn format(self: ProductionFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        const prod = self.g.productions[self.prod];

        if (std.mem.eql(u8, fmt, "t")) {
            try writer.print("[{s}] ", .{prod.tag});
        }

        try writer.print("{s} ->", .{ self.g.nonterminals[prod.lhs].name });
        for (prod.rhs) |sym| {
            try writer.print(" {q}", .{ self.g.fmtSymbol(sym) });
        }
    }
};

pub fn fmtProduction(self: *const Self, prod: usize) ProductionFormatter {
    return ProductionFormatter{
        .g = self,
        .prod = prod,
    };
}

const SymbolFormatter = struct {
    g: *const Self,
    sym: Symbol,

    pub fn format(self: SymbolFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        switch (self.sym) {
            .nonterminal => |nt| try writer.print("{s}", .{ self.g.nonterminals[nt].name }),
            .terminal => |t| {
                const tfmt: []const u8 = comptime if (std.mem.eql(u8, fmt, "s")) "'{s}'" else "{s}";
                try writer.print(tfmt, .{ self.g.terminals[t] });
            },
        }
    }
};

pub fn fmtSymbol(self: *const Self, sym: Symbol) SymbolFormatter {
    return SymbolFormatter{
        .g = self,
        .sym = sym,
    };
}

pub fn fmtTerminal(self: *const Self, t: Terminal) SymbolFormatter {
    return SymbolFormatter{
        .g = self,
        .sym = .{.terminal = t},
    };
}

pub fn fmtNonterminal(self: *const Self, nt: Nonterminal) SymbolFormatter {
    return SymbolFormatter{
        .g = self,
        .sym = .{.nonterminal = nt},
    };
}
