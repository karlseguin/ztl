const std = @import("std");

const Value = @import("value.zig").Value;
const KeyValue = @import("value.zig").KeyValue;

const Allocator = std.mem.Allocator;
pub const io = std.testing.io;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectSlice = std.testing.expectEqualSlices;
pub const expectString = std.testing.expectEqualStrings;

pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub fn createListRef(values: []Value) Value {
    const ref = arena.allocator().create(Value.Ref) catch unreachable;
    ref.* = .{ .value = .{ .list = .fromOwnedSlice(values) } };
    return .{ .ref = ref };
}

pub fn createMapRef(names: []const []const u8, values: []const Value) Value {
    var map: Value.Map = .{};
    map.ensureTotalCapacity(arena.allocator(), names.len) catch unreachable;

    for (names, values) |n, v| {
        if (std.fmt.parseInt(i64, n, 10)) |as_int| {
            map.putAssumeCapacity(.{ .i64 = as_int }, v);
        } else |_| {
            map.putAssumeCapacity(.{ .string = n }, v);
        }
    }

    const ref = arena.allocator().create(Value.Ref) catch unreachable;
    ref.* = .{ .value = .{ .map = map } };
    return .{ .ref = ref };
}
