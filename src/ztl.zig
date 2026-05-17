const std = @import("std");

pub const VM = @import("vm.zig").VM;
pub const Value = @import("value.zig").Value;
pub const Global = @import("template.zig").Global;
pub const Template = @import("template.zig").Template;
pub const DebugMode = @import("config.zig").DebugMode;
pub const PartialResult = @import("compiler.zig").PartialResult;
pub const ReferenceCounting = @import("config.zig").ReferenceCounting;

pub const RenderErrorReport = @import("error_report.zig").Render;
pub const CompileErrorReport = @import("error_report.zig").Compile;

pub fn Functions(comptime A: type) type {
    const App = switch (@typeInfo(A)) {
        .@"struct" => A,
        .pointer => |ptr| ptr.child,
        .void => void,
        else => @compileError("Template App must be a struct, got: " ++ @tagName(@typeInfo(A))),
    };

    if (App == void or @hasDecl(App, "ZtlFunctions") == false) {
        return @Enum(u8, .exhaustive, &.{""}, &.{0}); // HACK, std.meta.stringToEnum doesn't work on an empty enum, lol what?
    }
    const declarations = std.meta.declarations(App.ZtlFunctions);

    var names: [declarations.len][]const u8 = undefined;
    var values: [declarations.len]u16 = undefined;

    for (declarations, 0..) |d, i| {
        names[i] = d.name;
        values[i] = i;
    }

    return @Enum(u16, .exhaustive, &names, &values);
}

const t = @import("t.zig");

test {
    std.testing.refAllDecls(@This());
}
