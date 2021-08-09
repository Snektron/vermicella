const std = @import("std");

/// Structure representing a parsed and unvalidated grammar.
const Grammar = struct {
    /// The rules which are defined in this grammar.
    rules: []const Rule,
};

/// A structure representing a rule and its productions.
const Rule = struct {
    /// The rule's name.
    name: []const u8,

    /// A return type expression, a verbatim zig expression.
    return_type_expr: []const u8,

    /// The productions this rule declares.
    productions: []const Production,
};

/// A structure representing a production, associated to some rule.
const Production = struct {
    /// A human-readable name used to identify this production.
    /// Must be unique for all productions associated to some rule,
    /// but may be derived from the rule's name if a rule is associated
    /// with only a single production.
    tag: ?[]const u8,

    /// The symbols which make up this production, in order.
    symbols: []const Symbol,

    /// An optional parse action associated to this structure.
    /// This is a verbatim zig compound statement, including braces.
    action: ?[]const u8,
};

/// A referenced entity in productions.
const Symbol = union(enum) {
    /// The name this symbol will be bound to in the action corresponding
    /// the production.
    bind_name: ?[]const u8,

    /// The name of the symbol entity itself.
    symbol_name: []const u8,

    /// The type of this symbol.
    kind: Kind,

    const Kind = enum {
        terminal,
        nonterminal,
    };
};
