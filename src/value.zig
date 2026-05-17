const std = @import("std");

const RefPool = @import("vm.zig").RefPool;

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    pub const List = std.ArrayList(Value);
    pub const Buffer = std.ArrayList(u8);
    pub const Map = std.array_hash_map.Custom(KeyValue, Value, KeyValue.Context, true);

    i64: i64,
    f64: f64,
    bool: bool,
    null: void,
    ref: *Ref,
    string: []const u8,

    pub fn format(self: Value, writer: *std.Io.Writer) !void {
        return self.write(writer, false);
    }

    pub const Ref = struct {
        count: u16 = 1,
        value: union(enum) {
            buffer: Buffer,
            map_entry: Map.Entry,
            map: Value.Map,
            list: Value.List,
            map_iterator: MapIterator,
            list_iterator: ListIterator,
        },
    };

    pub fn write(self: Value, writer: *std.Io.Writer, escape: bool) !void {
        switch (self) {
            .i64 => |v| return writer.printInt(v, 10, .lower, .{}),
            .bool => |v| return writer.writeAll(if (v) "true" else "false"),
            .f64 => |v| return writer.print("{d}", .{v}),
            .null => return writer.writeAll("null"),
            .string => |v| if (escape) try writeStringEscaped(writer, v) else try writer.writeAll(v),
            .ref => |ref| switch (ref.value) {
                .buffer => |buf| if (escape) try writeStringEscaped(writer, buf.items) else try writer.writeAll(buf.items),
                .list => |list| {
                    var items = list.items;
                    if (items.len == 0) {
                        return writer.writeAll("[]");
                    }
                    try writer.writeByte('[');
                    try items[0].write(writer, escape);
                    for (items[1..]) |v| {
                        try writer.writeAll(", ");
                        try v.write(writer, escape);
                    }
                    return writer.writeByte(']');
                },
                .map => |map| {
                    var it = map.iterator();
                    try writer.writeByte('{');
                    if (it.next()) |first| {
                        try first.key_ptr.*.write(writer, escape);
                        try writer.writeAll(": ");
                        try first.value_ptr.*.write(writer, escape);

                        while (it.next()) |kv| {
                            try writer.writeAll(", ");
                            try kv.key_ptr.*.write(writer, escape);
                            try writer.writeAll(": ");
                            try kv.value_ptr.*.write(writer, escape);
                        }
                    }
                    return writer.writeByte('}');
                },
                .list_iterator => return writer.writeAll("[...]"),
                .map_iterator => return writer.writeAll("{...}"),
                .map_entry => |entry| {
                    try entry.key_ptr.*.write(writer, escape);
                    try writer.writeAll(": ");
                    return entry.value_ptr.*.write(writer, escape);
                },
            },
        }
    }

    pub fn isTrue(self: Value) bool {
        return self == .bool and self.bool;
    }

    pub fn equal(a: Value, b: Value) error{Incompatible}!bool {
        const lhs = a.convertForEquality();
        const rhs = b.convertForEquality();

        switch (lhs) {
            .bool => |l| switch (rhs) {
                .bool => |r| return l == r,
                .null => return false,
                else => {},
            },
            .f64 => |l| switch (rhs) {
                .f64 => |r| return l == r,
                .i64 => |r| return l == @as(f64, @floatFromInt(r)),
                .null => return false,
                else => {},
            },
            .i64 => |l| switch (rhs) {
                .i64 => |r| return l == r,
                .f64 => |r| return @as(f64, @floatFromInt(l)) == r,
                .null => return false,
                else => {},
            },
            .null => return rhs == .null,
            .string => |l| switch (rhs) {
                .string => |r| return std.mem.eql(u8, l, r),
                .null => return false,
                else => {},
            },
            .ref => |ref| {
                if (ref.value == .buffer and rhs == .string) {
                    return std.mem.eql(u8, ref.value.buffer.items, rhs.string);
                }
                switch (rhs) {
                    .ref => {},
                    .null => return false,
                    else => return error.Incompatible,
                }

                switch (ref.value) {
                    .buffer => unreachable, // converted to a string above
                    .list => |l| switch (rhs.ref.value) {
                        .list => |r| {
                            if (l.items.len != r.items.len) {
                                return false;
                            }
                            for (l.items, r.items) |ll, rr| {
                                const result = equal(ll, rr) catch return false;
                                if (result == false) {
                                    return false;
                                }
                            }
                            return true;
                        },
                        else => {},
                    },
                    .map => |l| switch (rhs.ref.value) {
                        .map => |r| {
                            if (l.count() != r.count()) {
                                return false;
                            }
                            var it = l.iterator();
                            while (it.next()) |kv| {
                                const rv = r.get(kv.key_ptr.*) orelse return false;
                                if (try kv.value_ptr.equal(rv) == false) {
                                    return false;
                                }
                            }
                            return true;
                        },
                        else => {},
                    },
                    .map_entry => |l| switch (rhs.ref.value) {
                        .map_entry => |r| return l.key_ptr.equal(r.key_ptr.*) and try l.value_ptr.equal(r.value_ptr.*),
                        else => {},
                    },
                    .list_iterator, .map_iterator => return false,
                }
            },
        }
        return error.Incompatible;
    }

    pub fn friendlyName(self: Value) []const u8 {
        switch (self) {
            .i64 => return "integer",
            .f64 => return "float",
            .bool => return "boolean",
            .null => return "null",
            .string => return "string",
            .ref => |ref| switch (ref.value) {
                .buffer => return "string",
                .list => return "list",
                .map => return "map",
                .map_entry => return "map entry",
                .map_iterator => return "map iterator",
                .list_iterator => return "list iterator",
            },
        }
    }

    pub fn friendlyArticleName(self: Value) []const u8 {
        switch (self) {
            .i64 => return "an integer",
            .f64 => return "a float",
            .bool => return "a boolean",
            .null => return "null",
            .string => return "a string",
            .ref => |ref| switch (ref.value) {
                .buffer => return "a string",
                .list => return "a list",
                .map => return "a map",
                .map_entry => return "a map entry",
                .map_iterator => return "a map iterator",
                .list_iterator => return "a list iterator",
            },
        }
    }

    pub fn order(a: Value, b: Value) std.math.Order {
        const math = std.math;

        const lhs = a.convertForEquality();
        const rhs = b.convertForEquality();

        const lhs_tag = std.meta.activeTag(lhs);
        const rhs_tag = std.meta.activeTag(rhs);
        if (lhs_tag != rhs_tag) {
            switch (lhs) {
                .i64 => |l| switch (rhs) {
                    .f64 => |r| return math.order(@as(f64, @floatFromInt(l)), r),
                    else => {},
                },
                .f64 => |l| switch (rhs) {
                    .i64 => |r| return math.order(l, @as(f64, @floatFromInt(r))),
                    else => {},
                },
                else => {},
            }
            return std.math.order(@intFromEnum(lhs_tag), @intFromEnum(rhs_tag));
        }

        switch (lhs) {
            .i64 => |l| return math.order(l, rhs.i64),
            .f64 => |l| return math.order(l, rhs.f64),
            .bool => |l| {
                if (l == rhs.bool) {
                    return .eq;
                }
                return if (l == true) .gt else .lt;
            },
            .null => return .eq,
            .string => |l| return std.mem.order(u8, l, rhs.string),
            .ref => |lref| {
                const lhs_ref = lref.value;
                const rhs_ref = rhs.ref.value;
                const lhs_ref_tag = std.meta.activeTag(lhs_ref);
                const rhs_ref_tag = std.meta.activeTag(rhs_ref);

                if (lhs_ref_tag != rhs_ref_tag) {
                    return std.math.order(@intFromEnum(lhs_ref_tag), @intFromEnum(rhs_ref_tag));
                }

                switch (lhs_ref) {
                    .buffer => unreachable, // converted to a string above
                    .map_entry => |l| {
                        const key_order = l.key_ptr.*.order(rhs_ref.map_entry.key_ptr.*);
                        if (key_order != .eq) {
                            return key_order;
                        }
                        return l.value_ptr.order(rhs_ref.map_entry.value_ptr.*);
                    },
                    .map => |l| return std.math.order(l.count(), rhs_ref.map.count()),
                    .list => |l| {
                        const len_order = std.math.order(l.items.len, rhs_ref.list.items.len);
                        if (len_order != .eq) {
                            return len_order;
                        }
                        for (l.items, rhs_ref.list.items) |ll, rr| {
                            const item_order = ll.order(rr);
                            if (item_order != .eq) {
                                return item_order;
                            }
                        }
                        return .eq;
                    },
                    .map_iterator => return .lt,
                    .list_iterator => return .lt,
                }
            },
        }
    }

    fn convertForEquality(self: Value) Value {
        if (self == .ref and self.ref.value == .buffer) {
            return .{ .string = self.ref.value.buffer.items };
        }
        return self;
    }
};

pub const KeyValue = union(enum) {
    i64: i64,
    string: []const u8,

    pub fn format(self: KeyValue, writer: *std.Io.Writer) !void {
        return self.write(writer, false);
    }

    pub fn write(self: KeyValue, writer: *std.Io.Writer, escape: bool) !void {
        switch (self) {
            .i64 => |v| return writer.printInt(v, 10, .lower, .{}),
            .string => |v| if (escape) try writeStringEscaped(writer, v) else try writer.writeAll(v),
        }
    }

    pub fn toValue(self: KeyValue) Value {
        switch (self) {
            .i64 => |v| return .{ .i64 = v },
            .string => |v| return .{ .string = v },
        }
    }

    pub fn equal(lhs: KeyValue, rhs: KeyValue) bool {
        switch (lhs) {
            .i64 => |l| switch (rhs) {
                .i64 => |r| return l == r,
                .string => return false,
            },
            .string => |l| switch (rhs) {
                .string => |r| return std.mem.eql(u8, l, r),
                .i64 => return false,
            },
        }
    }

    pub fn order(lhs: KeyValue, rhs: KeyValue) std.math.Order {
        const lhs_tag = std.meta.activeTag(lhs);
        const rhs_tag = std.meta.activeTag(rhs);
        if (lhs_tag != rhs_tag) {
            return std.math.order(@intFromEnum(lhs_tag), @intFromEnum(rhs_tag));
        }

        switch (lhs) {
            .i64 => |l| return std.math.order(l, rhs.i64),
            .string => |l| return std.mem.order(u8, l, rhs.string),
        }
    }

    const Wyhash = std.hash.Wyhash;

    const Context = struct {
        pub fn hash(_: Context, key: KeyValue) u32 {
            switch (key) {
                .i64 => |v| return @as(u32, @truncate(Wyhash.hash(0, std.mem.asBytes(&v)))),
                .string => |v| return @as(u32, @truncate(Wyhash.hash(0, v))),
            }
        }

        pub fn eql(_: Context, a: KeyValue, b: KeyValue, _: usize) bool {
            switch (a) {
                .i64 => |av| switch (b) {
                    .i64 => |bv| return av == bv,
                    .string => return false,
                },
                .string => |av| switch (b) {
                    .string => |bv| return std.mem.eql(u8, av, bv),
                    .i64 => return false,
                },
            }
        }
    };
};

pub const ListIterator = struct {
    index: usize,
    list: *const Value.List,
    ref: *Value.Ref, // the Value.Ref of the list, which we need to deference when the iterator goes out of scope
};

pub const MapIterator = struct {
    inner: Value.Map.Iterator,
    ref: *Value.Ref, // the Value.Ref of the map, which we need to deference when the iterator goes out of scope
};

fn writeStringEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    var v = value;
    while (v.len > 0) {
        const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '&', '<', '>', '"', '\'' }) orelse {
            return writer.writeAll(v);
        };
        try writer.writeAll(v[0..index]);
        switch (v[index]) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&#34;"),
            '\'' => try writer.writeAll("&#39;"),
            else => unreachable,
        }
        v = v[index + 1 ..];
    }
}

const t = @import("t.zig");
test "Value: isTrue" {
    try t.expectEqual(true, (Value{ .bool = true }).isTrue());
    try t.expectEqual(false, (Value{ .bool = false }).isTrue());

    try t.expectEqual(false, (Value{ .i64 = 0 }).isTrue());
    try t.expectEqual(false, (Value{ .i64 = 100 }).isTrue());
    try t.expectEqual(false, (Value{ .f64 = 0 }).isTrue());
    try t.expectEqual(false, (Value{ .f64 = 100.00 }).isTrue());
    try t.expectEqual(false, (Value{ .null = {} }).isTrue());
}

test "Value: format" {
    defer t.reset();

    try assertFormat("0", .{ .i64 = 0 });
    try assertFormat("987654", .{ .i64 = 987654 });
    try assertFormat("-1234567", .{ .i64 = -1234567 });

    try assertFormat("1.2345678", .{ .f64 = 1.2345678 });
    try assertFormat("-0.000032", .{ .f64 = -0.000032 });

    try assertFormat("true", .{ .bool = true });
    try assertFormat("false", .{ .bool = false });

    try assertFormat("null", .{ .null = {} });

    try assertFormat("", .{ .string = "" });
    try assertFormat("hello world", .{ .string = "hello world" });

    {
        var arr = [_]Value{};
        try assertFormat("[]", t.createListRef(&arr));
    }

    var arr = [_]Value{ .{ .i64 = -3 }, .{ .bool = true }, .{ .string = "over 9000" } };
    try assertFormat("[-3, true, over 9000]", t.createListRef(&arr));

    try assertFormat("{}", t.createMapRef(&.{}, &.{}));
    try assertFormat("{name: Leto, 123: true, arr: [-3, true, over 9000]}", t.createMapRef(&.{ "name", "123", "arr" }, &.{ .{ .string = "Leto" }, .{ .bool = true }, t.createListRef(&arr) }));
}

test "Value: equal" {
    defer t.reset();

    try assertEqual(true, .{ .i64 = 0 }, .{ .i64 = 0 });
    try assertEqual(true, .{ .i64 = -10 }, .{ .i64 = -10 });
    try assertEqual(true, .{ .i64 = 99 }, .{ .f64 = 99.0 });
    try assertEqual(false, .{ .i64 = 0 }, .{ .i64 = 1 });
    try assertEqual(false, .{ .i64 = 99 }, .{ .f64 = 99.1 });
    try assertEqual(false, .{ .i64 = 0 }, .{ .null = {} });
    try assertEqual(false, .{ .i64 = 94 }, .{ .null = {} });

    try assertEqual(true, .{ .f64 = 0.32 }, .{ .f64 = 0.32 });
    try assertEqual(true, .{ .f64 = -102.32 }, .{ .f64 = -102.32 });
    try assertEqual(true, .{ .f64 = -942.0 }, .{ .i64 = -942 });
    try assertEqual(false, .{ .f64 = 0.32 }, .{ .f64 = 1.32 });
    try assertEqual(false, .{ .f64 = -942.1 }, .{ .i64 = -942 });
    try assertEqual(false, .{ .f64 = 0 }, .{ .null = {} });
    try assertEqual(false, .{ .f64 = 1.32 }, .{ .null = {} });

    try assertEqual(true, .{ .bool = true }, .{ .bool = true });
    try assertEqual(true, .{ .bool = false }, .{ .bool = false });
    try assertEqual(false, .{ .bool = true }, .{ .bool = false });
    try assertEqual(false, .{ .bool = false }, .{ .bool = true });
    try assertEqual(false, .{ .bool = true }, .{ .null = {} });
    try assertEqual(false, .{ .bool = false }, .{ .null = {} });

    try assertEqual(true, .{ .string = "" }, .{ .string = "" });
    try assertEqual(true, .{ .string = "abc123" }, .{ .string = "abc123" });
    try assertEqual(false, .{ .string = "abc123" }, .{ .string = "ABC123" });
    try assertEqual(false, .{ .string = "abc123" }, .{ .null = {} });

    try assertEqual(true, .{ .null = {} }, .{ .null = {} });
    try assertEqual(false, .{ .null = {} }, .{ .i64 = 0 });
    try assertEqual(false, .{ .null = {} }, .{ .i64 = 4 });
    try assertEqual(false, .{ .null = {} }, .{ .bool = true });
    try assertEqual(false, .{ .null = {} }, .{ .bool = false });

    try assertEqual(true, .{ .null = {} }, .{ .null = {} });
    try assertEqual(false, .{ .null = {} }, .{ .i64 = 0 });
    try assertEqual(false, .{ .null = {} }, .{ .i64 = 4 });
    try assertEqual(false, .{ .null = {} }, .{ .bool = true });
    try assertEqual(false, .{ .null = {} }, .{ .bool = false });

    var arr1 = [_]Value{
        .{ .i64 = -3 },
        .{ .bool = true },
        .{ .string = "over 9000" },
    };

    var arr2 = [_]Value{
        .{ .i64 = -3 },
        .{ .bool = true },
        .{ .string = "over 9000!!" },
    };

    var arr3 = [_]Value{
        .{ .i64 = -3 },
        .{ .bool = true },
    };

    try assertEqual(true, t.createListRef(&arr1), t.createListRef(&arr1));
    try assertEqual(false, t.createListRef(&arr1), t.createListRef(&arr2));
    try assertEqual(false, t.createListRef(&arr1), t.createListRef(&arr3));
    try assertEqual(false, t.createListRef(&arr2), t.createListRef(&arr3));
    try assertEqual(false, t.createListRef(&arr2), .{ .null = {} });
    try assertEqualIncompatible(t.createListRef(&arr2), .{ .i64 = 2 });
    try assertEqualIncompatible(t.createListRef(&arr2), .{ .f64 = -95.11 });
    try assertEqualIncompatible(t.createListRef(&arr2), .{ .string = "hello" });
    try assertEqualIncompatible(t.createListRef(&arr2), .{ .bool = true });

    const map1 = t.createMapRef(&.{ "name", "123", "arr" }, &.{ .{ .string = "Leto" }, .{ .bool = true }, t.createListRef(&arr1) });

    const map2 = t.createMapRef(&.{ "name", "123", "arr" }, &.{ .{ .string = "Leto" }, .{ .bool = true }, t.createListRef(&arr1) });

    // 122 is a different key
    const map3 = t.createMapRef(&.{ "name", "122", "arr" }, &.{ .{ .string = "Leto" }, .{ .bool = true }, t.createListRef(&arr1) });

    // LETO is a different value
    const map4 = t.createMapRef(&.{ "name", "123", "arr" }, &.{ .{ .string = "LETO" }, .{ .bool = true }, t.createListRef(&arr1) });

    // extra key
    const map5 = t.createMapRef(
        &.{ "name", "123", "arr", "more" },
        &.{ .{ .string = "LETO" }, .{ .bool = true }, t.createListRef(&arr1), .{ .f64 = 1.344 } },
    );

    try assertEqual(true, map1, map1);
    try assertEqual(true, map1, map2);
    try assertEqual(false, map1, map3);
    try assertEqual(false, map2, map3);
    try assertEqual(false, map1, map4);
    try assertEqual(false, map1, map5);
    try assertEqual(false, map1, .{ .null = {} });
    try assertEqualIncompatible(map1, .{ .i64 = 2 });
    try assertEqualIncompatible(map1, .{ .f64 = -95.11 });
    try assertEqualIncompatible(map1, .{ .string = "hello" });
    try assertEqualIncompatible(map1, .{ .bool = true });
}

test "writeStringEscaped" {
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();

    {
        try writeStringEscaped(&aw.writer, "hello world");
        try t.expectString("hello world", aw.written());
        aw.clearRetainingCapacity();
    }

    {
        try writeStringEscaped(&aw.writer, "<>\"'&");
        try t.expectString("&lt;&gt;&#34;&#39;&amp;", aw.written());
        aw.clearRetainingCapacity();
    }

    {
        try writeStringEscaped(&aw.writer, " < > \" ' & ");
        try t.expectString(" &lt; &gt; &#34; &#39; &amp; ", aw.written());
        aw.clearRetainingCapacity();
    }
}

fn assertFormat(expected: []const u8, value: Value) !void {
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();

    try aw.writer.print("{f}", .{value});
    try t.expectString(expected, aw.written());
}

fn assertEqual(expected: bool, left: Value, right: Value) !void {
    try t.expectEqual(expected, left.equal(right));
}

fn assertEqualIncompatible(left: Value, right: Value) !void {
    try t.expectError(error.Incompatible, left.equal(right));
}
