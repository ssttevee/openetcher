//! Command-line parsing driven by argument structs.
//!
//! A command describes its arguments as a struct, and its fields say how
//! each is spelled and parsed:
//!
//! - a `bool` field is a flag;
//! - a `?[]const u8` field is an option that takes the next argument as its
//!   value;
//! - fields named in the struct's `positionals` declaration take the bare
//!   arguments, in order. A `[]const u8` positional is required and a
//!   `?[]const u8` one optional.
//!
//! Flags and options are spelled `--` plus the field name with dashes for
//! underscores, unless the struct's `flag_names` declaration names another
//! spelling. A struct may declare `fn validate(self) bool` for constraints
//! between fields. Any argument that is not a known flag fills the next
//! positional, so an image may be named like a flag.

const std = @import("std");

pub const Error = error{InvalidArguments};

/// Parses `argv`, without the program name, into the union `Command`: the
/// first argument names the variant and the rest fill its payload.
pub fn parseCommand(comptime Command: type, argv: []const []const u8) Error!Command {
    if (argv.len == 0) return error.InvalidArguments;
    const tag = std.meta.stringToEnum(std.meta.Tag(Command), argv[0]) orelse return error.InvalidArguments;
    switch (tag) {
        inline else => |known| {
            const name = @tagName(known);
            return @unionInit(Command, name, try parse(@FieldType(Command, name), argv[1..]));
        },
    }
}

/// Parses `argv` into the argument struct `Args`. Repeated flags, options
/// without a value, missing or surplus positionals, and failed validation
/// are all `error.InvalidArguments`.
pub fn parse(comptime Args: type, argv: []const []const u8) Error!Args {
    comptime checkArgs(Args);
    const fields = @typeInfo(Args).@"struct";
    const positionals = comptime positionalNames(Args);

    var parsed: Args = undefined;
    inline for (fields.field_names, fields.field_types) |name, T| {
        if (comptime isPositional(Args, name)) continue;
        @field(parsed, name) = if (T == bool) false else null;
    }

    var seen: [fields.field_names.len]bool = @splat(false);
    var positional_count: usize = 0;
    var index: usize = 0;
    next: while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        inline for (fields.field_names, fields.field_types, 0..) |name, T, field_index| {
            if (comptime isPositional(Args, name)) continue;
            if (std.mem.eql(u8, arg, comptime flagName(Args, name))) {
                if (seen[field_index]) return error.InvalidArguments;
                seen[field_index] = true;
                if (T == bool) {
                    @field(parsed, name) = true;
                } else {
                    index += 1;
                    if (index == argv.len) return error.InvalidArguments;
                    @field(parsed, name) = argv[index];
                }
                continue :next;
            }
        }
        inline for (positionals, 0..) |name, position| {
            if (positional_count == position) {
                @field(parsed, name) = arg;
                positional_count += 1;
                continue :next;
            }
        }
        return error.InvalidArguments;
    }

    inline for (positionals, 0..) |name, position| {
        if (positional_count <= position) {
            if (@FieldType(Args, name) == []const u8) return error.InvalidArguments;
            @field(parsed, name) = null;
        }
    }
    if (@hasDecl(Args, "validate")) {
        if (!parsed.validate()) return error.InvalidArguments;
    }
    return parsed;
}

/// How the flag or option for `field` is spelled on the command line.
pub fn flagName(comptime Args: type, comptime field: []const u8) []const u8 {
    if (@hasDecl(Args, "flag_names") and @hasField(@TypeOf(Args.flag_names), field)) {
        return @field(Args.flag_names, field);
    }
    var name: [field.len]u8 = field[0..field.len].*;
    std.mem.replaceScalar(u8, &name, '_', '-');
    const spelled = name;
    return "--" ++ &spelled;
}

pub fn isPositional(comptime Args: type, comptime field: []const u8) bool {
    for (positionalNames(Args)) |name| if (std.mem.eql(u8, name, field)) return true;
    return false;
}

fn positionalNames(comptime Args: type) []const []const u8 {
    return if (@hasDecl(Args, "positionals")) Args.positionals else &.{};
}

/// Rejects argument structs the parser would misread, naming the field.
fn checkArgs(comptime Args: type) void {
    const fields = @typeInfo(Args).@"struct";
    const where = "argument struct " ++ @typeName(Args) ++ ": ";
    for (fields.field_names, fields.field_types) |name, T| {
        if (isPositional(Args, name)) {
            if (T != []const u8 and T != ?[]const u8) @compileError(where ++ "positional ." ++ name ++ " must be []const u8 or ?[]const u8");
        } else if (T != bool and T != ?[]const u8) {
            @compileError(where ++ "." ++ name ++ " must be a bool flag or a ?[]const u8 option, or be listed in positionals");
        }
    }
    var optional_seen = false;
    for (positionalNames(Args)) |name| {
        if (!@hasField(Args, name)) @compileError(where ++ "positionals names missing field ." ++ name);
        if (@FieldType(Args, name) == ?[]const u8) {
            optional_seen = true;
        } else if (optional_seen) {
            @compileError(where ++ "required positional ." ++ name ++ " follows an optional one");
        }
    }
    if (@hasDecl(Args, "flag_names")) {
        for (std.meta.fieldNames(@TypeOf(Args.flag_names))) |name| {
            if (!@hasField(Args, name) or isPositional(Args, name)) @compileError(where ++ "flag_names names no flag ." ++ name);
        }
    }
}

const TestArgs = struct {
    verbose: bool = false,
    dry_run: bool = false,
    out_dir: ?[]const u8 = null,
    input: []const u8,
    output: ?[]const u8 = null,

    pub const positionals: []const []const u8 = &.{ "input", "output" };
    pub const flag_names = .{ .verbose = "-v" };

    pub fn validate(self: TestArgs) bool {
        return !std.mem.eql(u8, self.input, "invalid");
    }
};

test "flags, options, and positionals parse in any order" {
    const parsed = try parse(TestArgs, &.{ "in", "--out-dir", "--dry-run", "-v", "out" });
    try std.testing.expect(parsed.verbose);
    try std.testing.expect(!parsed.dry_run);
    try std.testing.expectEqualStrings("--dry-run", parsed.out_dir.?);
    try std.testing.expectEqualStrings("in", parsed.input);
    try std.testing.expectEqualStrings("out", parsed.output.?);

    const minimal = try parse(TestArgs, &.{"--unknown"});
    try std.testing.expectEqualStrings("--unknown", minimal.input);
    try std.testing.expectEqual(@as(?[]const u8, null), minimal.output);
    try std.testing.expectEqual(@as(?[]const u8, null), minimal.out_dir);
    try std.testing.expect(!minimal.verbose and !minimal.dry_run);
}

test "malformed arguments are rejected" {
    const bad = [_][]const []const u8{
        &.{},
        &.{"-v"},
        &.{ "-v", "-v", "in" },
        &.{ "in", "--out-dir" },
        &.{ "--out-dir", "a", "--out-dir", "b", "in" },
        &.{ "in", "out", "extra" },
        &.{"invalid"},
        &.{ "--verbose", "in", "out" },
    };
    for (bad) |argv| try std.testing.expectError(error.InvalidArguments, parse(TestArgs, argv));
}

test "the first argument selects the command" {
    const Command = union(enum) {
        run: TestArgs,
        list: struct { all: bool = false },
    };
    const run = try parseCommand(Command, &.{ "run", "in" });
    try std.testing.expectEqualStrings("in", run.run.input);
    try std.testing.expect((try parseCommand(Command, &.{ "list", "--all" })).list.all);
    try std.testing.expectError(error.InvalidArguments, parseCommand(Command, &.{}));
    try std.testing.expectError(error.InvalidArguments, parseCommand(Command, &.{"lists"}));
    try std.testing.expectError(error.InvalidArguments, parseCommand(Command, &.{ "list", "in" }));
}
