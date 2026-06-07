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

const Allocator = std.mem.Allocator;

// Helper to compiler and render in a single call. Every call recompiles the
// template; if you're rendering the same template multiple times, create an
// explicit Template (compile) one, and render it multiple times.
// `app` is either an App instance (becomes Template(@TypeOf(app))) or `null`
// for the no-App case (becomes Template(void)). The returned slice is owned by
// the caller and must be freed with `allocator`.
pub fn render(allocator: Allocator, app: anytype, src: []const u8, data: anytype) ![]u8 {
    if (@TypeOf(app) == @TypeOf(null)) {
        return renderApp(void, allocator, {}, src, data);
    }
    return renderApp(@TypeOf(app), allocator, app, src, data);
}

// Reads the template at `path` (relative to the current working directory),
// then compiles and renders it.
pub fn renderFile(io: std.Io, allocator: Allocator, app: anytype, path: []const u8, data: anytype) ![]u8 {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(src);
    return render(allocator, app, src, data);
}

fn renderApp(comptime App: type, allocator: Allocator, app: App, src: []const u8, data: anytype) ![]u8 {
    var tmpl = Template(App).init(allocator, app);
    defer tmpl.deinit();
    try tmpl.compile(src, .{});

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try tmpl.render(&aw.writer, data, .{});
    return aw.toOwnedSlice();
}

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

test "render: no app (null)" {
    const out = try render(t.allocator, null, "<%= @name %>!", .{ .name = "Leto" });
    defer t.allocator.free(out);
    try t.expectString("Leto!", out);
}

test "render: with app" {
    const App = struct {
        pub const ZtlConfig = struct {
            pub const escape_by_default: bool = true;
        };
    };
    const out = try render(t.allocator, App{}, "<%= @name %>", .{ .name = "<h1>" });
    defer t.allocator.free(out);
    try t.expectString("&lt;h1&gt;", out);
}

test "render: propagates compile error" {
    try t.expectError(error.UnexpectedEOF, render(t.allocator, null, "<%=", .{}));
}

test "renderFile: reads and renders from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "greet.ztl", .data = "Hello <%= @name %>" });

    const path = try tmp.dir.realPathFileAlloc(t.io, "greet.ztl", t.allocator);
    defer t.allocator.free(path);

    const out = try renderFile(t.io, t.allocator, null, path, .{ .name = "Leto" });
    defer t.allocator.free(out);
    try t.expectString("Hello Leto", out);
}
