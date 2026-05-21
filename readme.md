# Zig Template Language

```zig
const std = @import("std");
const ztl = @import("ztl");

const Product = struct {
    name: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var template = ztl.Template(void).init(allocator, {});
    defer template.deinit();

    var compile_error_report = ztl.CompileErrorReport{};

    // The templating language is erb-inspired
    template.compile(
        \\ <h2>Products</h2>
        \\ <% foreach (@products) |product| { -%>
        \\     <%= escape product["name"] %>
        \\ <% } %>
    , .{ .error_report = &compile_error_report }) catch |err| {
        std.debug.print("{}\n", .{compile_error_report});
        return err;
    };

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var render_error_report = ztl.RenderErrorReport{};

    // The render method is thread-safe.
    template.render(&aw.writer, .{
        .products = [_]Product{
            .{ .name = "Keemun" },
            .{ .name = "Silver Needle" },
        },
    }, .{ .error_report = &render_error_report }) catch |err| {
        defer render_error_report.deinit();
        std.debug.print("{}\n", .{render_error_report});
        return err;
    };

    std.debug.print("{s}\n", .{aw.written()});
}
```

## Project Status
The project is in early development and has not seen much dogfooding. Looking for feature requests and bug reports.

## Template Overview
Output tags, `<%= %>`, support space trimming via `<%-=` and `-%>`. 

By default, output is not escaped. You can use the `escape` keyword to apply basic HTML encoding:

```
<%= escape product["name"] %>
```

Alternatively, you can set `ZtlConfig.escape_by_default` (see [customization](#customization)) to true to have escape on by default. In this case the special `escape` is invalid, however the `safe` keyword can be used to output the value as-is.

### Types
The language supports the following types:
* i64
* f64
* bool
* null
* string
* list
* map

```js
var i = 0;
var active = true;
var tags = [1, 1.2, null];

// Map keys must be strings or integers
// In a map initialization, the quotes around simple string keys are optional
var lookup = %{tea: 9, 123: null};
```

Strings are wrapped in single-quotes, double-quotes or backticks (\`hello\`). Backticks do not require escaping.

There are only a few properties:
* `len` - get the length of a list or map
* `key` - get the key of a map entry (only valid in a `foreach`)
* `value` - get the value of a map entry (only valid in a `foreach`)

There are currently only a few methods:
* `pop` - return and remove the last value from a list (or `null`)
* `last` - return the last value from a list (or `null`)
* `first` - return the first value from a list (or `null`)
* `append` - add a value to a list
* `remove` - remove the given value from a list (O(n)) or a map
* `remove_at` - remove the value from a list at the given index (supports negative indexes)
* `contains` - returns true/false if the value exists in a list (O(n)) or map
* `index_of` - returns the index of (or null) of the first instance of the value in a list (O(n))
* `sort` - sorts the list in-place
* `concat` - appends one array to another, mutating the original

```js
var list = [3, 2, 1].sort();
for (list) |item| {
    <%= item %>
}
```

### Control Flow
Supported control flow:
* if / else if / else 
* while
* for (;;)
* foreach
* orelse
* ternary (`?;`)
* break / continue

Foreach works over lists and maps only. Multiple values can be given. Iterations stops once any of the values is done:

```js
// this will only do 2 iterations
// since the map only has 2 entries
foreach([1, 2, 3], %{a: 1, b: 2}) |a, b| {
    <%= a + b.value %> 
}
```

(Internally, a `foreach` makes use of 3 extra types: list_iterator, map_iterator and map_entry, but there's no way to create these explicitly).

`break` and `continue` take an optional integer operand to control how many level to break/continue:

```js
for (var i = 0; i < arr1.len; i++) {
    for (var j = 0; j < arr2.len; j++) {
        if (arr2[j] > arr1[i]) break 2;
    }
}
```

### Functions
Templates can contain functions:

```js
add(1, 2);

// can be declared before or after usage
fn add(a, b) {
    return a + b;
}
```

## Zig Usage
You can get an error report on failed compile by passing in a `*ztl.CompileErrorReport`:

```zig
var template = ztl.Template(void).init(allocator, {});
defer template.deinit();

var error_report = ztl.CompileErrorReport{};
template.compile("<% 1.invalid() %>", .{.error_report = &error_report}) catch |err| {
    std.debug.print("{}\n", .{error_report});
    return err;
};
```

The `template.render` method is thread-safe. The general intention is that a template is compiled once and rendered multiple times. The `render` method takes an optional `RenderOption` argument.

The first optional field is `*ztl.RenderErorrReport`. When set, a description of the runtime error can be retreived. When set, you must call `deinit` on the error report on error:

```zig
var error_report = ztl.RenderErrorReport{};
template.render(buf.writer(), .{}, .{.error_report = &error_report}) catch |err| {
    defer error_report.deinit();
    std.debug.print("Runtime error: {}\n", .{error_report});
};
```

The second optional field is `allocator`. When omitted, the allocator given to `Template.init` is used. This allows the template as whole to have a long-lived allocator, but the `render` method to have a specific short-term allocator. For example, if you're rendering an HTML response, the render allocator might be tied to a request arena. For example, using [http.zig](https://www.github.com/karlseguin/http.zig):

```zig
try template.render(res.writer(), .{}, .{
    .allocator = res.arena,
});
```

## Customization
`ztl.Template` is a generic. The generic serves two purposes: to configure ztl and to provide custom functions.

For simple cases, `void` can be passed. 

To configure ZTL, to add custom functions or to support the `@include` builtin, a custom type must be passed.


```zig
const MyAppsTemplate = struct {

    // Low level configuration
    pub const ZtlConfig = struct {
        // default values:

        pub const debug: DebugMode = .none; // .minimal or .full
        pub const max_locals: u16 = 256;
        pub const max_call_frames: u8 = 255;
        pub const initial_code_size: u32 = 512;
        pub const initial_data_size: u32 = 512;
        pub const deduplicate_string_literals: bool = true;
        pub const escape_by_default: bool = false;
        pub const reference_counting: ReferenceCounting = .none; // .loose or .strict
    };

    // Defines the function and the number of arguments they take
    // Must also define a `call` method (below)
    pub const ZtlFunctions = struct {
        pub const add = 2; // takes 2 parameters
        pub const double = 1;  // takes 1 parameter
    };

    // must also have a ZtlFunction struct (above) with each function and their arity
    pub fn call(self: *MyAppsTemplate, vm: *ztl.VM(*@This()), function: ztl.Functions(@This()), values: []ztl.Value) !ztl.Value {
        _ = vm;

        switch (function) {
            .add => return .{.i64 = values[0].i64 + values[1].i64},
            .double => return .{.i64 = values[0].i64 * 2 + self.id},
        }
    }

    // see #include documentation
    pub fn partial(self: *MyAppsTemplate, _: Allocator, template_key: []const u8, include_key: []const u8) !?ztl.PartialResult {
        _ = template_key;
        if (std.mem.eql(u8, include_key, "header")) {
            return .{.src = "Welcome <%= @name %>"}
        }

        return null;
    }
}
```

### Extending with Zig
The combination of `ZtlFunctions` and the `call` function allows custom Zig code to be exposed as a template function. With the above `MyAppsTemplate`, templates can call `add(a, b)` and `double(123)`.

However, do note that the above implementation of `call` is unsafe. The # of parameters is guaranteed to be right, but not the types. In other words, when `function == .add` then `values.len == 2`, but the type of `values[0]` and `values[1]` is not guaranteed to be an `i64`.

The first parameter to `call` is the instance of `MyAppsTemplate` passed into `Template.init`. This could be used, for example, to write a custom function that can access a database.

## Builtins
There are a few built-in functions. 

### @print
The `@print()` builtin function prints the value(s) to stderr.

```js
@print(value, 1, "hello");
```

### @include
A template can `@include` another. 

```
// header
Hello <%= @name %>

// main template
<% @include('header', %{name: "Leto"}) %>
```

For this to work, the `partial` method must be defined, as seen above in `MyAppsTemplate`. The `partial` method takes 4 parameters:

* `self` - The instance of T passed into Template.init()
* `allocator` - An [arena] allocator. For example, if you're going to read the partial using `file.readToEndAlloc`, you should use this allocator.
* `template_key` - When `template.compile` is called, you can specify a `key: []const u8 = ""` in the options. This value is passed back into `partial` (to help you identify which template is being compiled)
* `include_key` - The first parameter passed to `@include`. In the little snippet above, this would be "header".
