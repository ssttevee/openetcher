//! Compile-time checks for the module contracts that registries and
//! platform backends implement. A module that drifts from its contract
//! fails the build with the contract's wording, not a downstream type error.

const std = @import("std");

/// Requires `Owner` to declare every name in `decls`, naming `what` (for
/// example "filesystem driver") in the error.
pub fn expectDecls(comptime Owner: type, comptime what: []const u8, comptime decls: []const []const u8) void {
    for (decls) |decl| {
        if (!@hasDecl(Owner, decl)) @compileError(@typeName(Owner) ++ ": " ++ what ++ " is missing `pub " ++ decl ++ "`");
    }
}

/// Requires `Owner.decl` to take exactly `params` and return `payload`,
/// either directly or inside an error union.
pub fn expectFn(comptime Owner: type, comptime decl: []const u8, comptime params: []const type, comptime payload: type) void {
    const where = @typeName(Owner) ++ "." ++ decl;
    if (!@hasDecl(Owner, decl)) @compileError(where ++ " is required");
    const info = switch (@typeInfo(@TypeOf(@field(Owner, decl)))) {
        .@"fn" => |info| info,
        else => @compileError(where ++ " must be a function"),
    };
    if (info.param_types.len != params.len) @compileError(where ++ " has the wrong number of parameters");
    for (info.param_types, params) |param, expected| {
        if (param != expected) @compileError(where ++ " expects a parameter of type " ++ @typeName(expected));
    }
    const returned = info.return_type.?;
    const actual = switch (@typeInfo(returned)) {
        .error_union => |error_union| error_union.payload,
        else => returned,
    };
    if (actual != payload) @compileError(where ++ " must return " ++ @typeName(payload));
}

/// The error set `function` returns.
pub fn ErrorSetOf(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}
