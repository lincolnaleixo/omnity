const std = @import("std");

const key = @import("key.zig");
const Config = @import("Config.zig");
const Color = Config.Color;
const fontpkg = @import("../font/main.zig");
const Key = key.Key;
const Value = key.Value;

// Omnity: C views of the font settings that the macOS window switcher preview
// draws with (macos/Sources/Features/Window Switcher). See include/ghostty.h.
const string_list_max = 16;

/// ghostty_config_string_list_s: the first entries of a RepeatableString
/// (font-family, font-feature, ...); the strings live as long as the config.
pub const StringList = extern struct {
    len: usize,
    items: [string_list_max]?[*:0]const u8,
};

/// ghostty_config_font_style_s: kind 0 = default, 1 = false, 2 = name.
pub const FontStyleC = extern struct {
    kind: u8,
    name: ?[*:0]const u8,
};

/// ghostty_config_bold_color_s: kind 0 = bright, 1 = color.
pub const BoldColorC = extern struct {
    kind: u8,
    color: Color.C,
};

/// ghostty_config_metric_modifier_s: `value` is a size factor (1.2 = +20%)
/// or, when `absolute`, a number of pixels.
pub const MetricModifierC = extern struct {
    absolute: bool,
    value: f64,
};

/// Get a value from the config by key into the given pointer. This is
/// specifically for C-compatible APIs. If you're using Zig, just access
/// the configuration directly.
///
/// The return value is false if the given key is not supported by the
/// C API yet. This is a fixable problem so if it is important to support
/// some key, please open an issue.
pub fn get(config: *const Config, k: Key, ptr_raw: *anyopaque) bool {
    @setEvalBranchQuota(10_000);
    switch (k) {
        inline else => |tag| {
            const value = fieldByKey(config, tag);
            return getValue(ptr_raw, value);
        },
    }
}

/// Get the value anytype and put it into the pointer. Returns false if
/// the type is not supported by the C API yet or the value is null.
fn getValue(ptr_raw: *anyopaque, value: anytype) bool {
    switch (@TypeOf(value)) {
        ?[:0]const u8 => {
            const ptr: *?[*:0]const u8 = @ptrCast(@alignCast(ptr_raw));
            ptr.* = if (value) |slice| @ptrCast(slice.ptr) else null;
        },

        bool => {
            const ptr: *bool = @ptrCast(@alignCast(ptr_raw));
            ptr.* = value;
        },

        u8, u32 => {
            const ptr: *c_uint = @ptrCast(@alignCast(ptr_raw));
            ptr.* = @intCast(value);
        },

        i16 => {
            const ptr: *c_short = @ptrCast(@alignCast(ptr_raw));
            ptr.* = @intCast(value);
        },

        f32, f64 => |Float| {
            const ptr: *Float = @ptrCast(@alignCast(ptr_raw));
            ptr.* = @floatCast(value);
        },

        // Omnity: font settings for the window switcher preview.
        Config.RepeatableString => {
            const ptr: *StringList = @ptrCast(@alignCast(ptr_raw));
            ptr.* = .{ .len = 0, .items = @splat(null) };
            for (value.list.items[0..@min(value.list.items.len, string_list_max)]) |item| {
                ptr.items[ptr.len] = item.ptr;
                ptr.len += 1;
            }
        },
        Config.FontStyle => {
            const ptr: *FontStyleC = @ptrCast(@alignCast(ptr_raw));
            ptr.* = switch (value) {
                .default => .{ .kind = 0, .name = null },
                .false => .{ .kind = 1, .name = null },
                .name => |name| .{ .kind = 2, .name = name.ptr },
            };
        },
        Config.BoldColor => {
            const ptr: *BoldColorC = @ptrCast(@alignCast(ptr_raw));
            ptr.* = switch (value) {
                .bright => .{ .kind = 0, .color = .{ .r = 0, .g = 0, .b = 0 } },
                .color => |color| .{ .kind = 1, .color = color.cval() },
            };
        },
        fontpkg.Metrics.Modifier => {
            const ptr: *MetricModifierC = @ptrCast(@alignCast(ptr_raw));
            ptr.* = switch (value) {
                .percent => |factor| .{ .absolute = false, .value = factor },
                .absolute => |px| .{ .absolute = true, .value = @floatFromInt(px) },
            };
        },
        else => |T| switch (@typeInfo(T)) {
            .optional => {
                // If an optional has no value we return false.
                const unwrapped = value orelse return false;
                return getValue(ptr_raw, unwrapped);
            },

            .@"enum" => {
                const ptr: *[*:0]const u8 = @ptrCast(@alignCast(ptr_raw));
                ptr.* = @tagName(value);
            },

            .@"struct" => |info| {
                // If the struct implements cval then we call then.
                if (@hasDecl(T, "cval")) {
                    const PtrT = @typeInfo(@TypeOf(T.cval)).@"fn".return_type.?;
                    const ptr: *PtrT = @ptrCast(@alignCast(ptr_raw));
                    ptr.* = value.cval();
                    return true;
                }

                // Packed structs that are less than or equal to the
                // size of a C int can be passed directly as their
                // bit representation.
                if (info.layout != .@"packed") return false;
                const Backing = info.backing_integer orelse return false;
                if (@bitSizeOf(Backing) > @bitSizeOf(c_uint)) return false;

                const ptr: *c_uint = @ptrCast(@alignCast(ptr_raw));
                ptr.* = @intCast(@as(Backing, @bitCast(value)));
            },

            .@"union" => {
                if (@hasDecl(T, "cval")) {
                    const PtrT = @typeInfo(@TypeOf(T.cval)).@"fn".return_type.?;
                    const ptr: *PtrT = @ptrCast(@alignCast(ptr_raw));
                    ptr.* = value.cval();
                    return true;
                }

                return false;
            },

            else => return false,
        },
    }

    return true;
}

/// Get a value from the config by key.
fn fieldByKey(self: *const Config, comptime k: Key) Value(k) {
    const field = comptime field: {
        const fields = std.meta.fields(Config);
        for (fields) |field| {
            if (@field(Key, field.name) == k) {
                break :field field;
            }
        }

        unreachable;
    };

    return @field(self, field.name);
}

test "c_get: u8" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();
    c.@"font-size" = 24;

    var cval: f32 = undefined;
    try testing.expect(get(&c, .@"font-size", &cval));
    try testing.expectEqual(@as(f32, 24), cval);
}

test "c_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();
    c.@"window-theme" = .dark;

    var cval: [*:0]u8 = undefined;
    try testing.expect(get(&c, .@"window-theme", @ptrCast(&cval)));

    const str = std.mem.sliceTo(cval, 0);
    try testing.expectEqualStrings("dark", str);
}

test "c_get: color" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();
    c.background = .{ .r = 255, .g = 0, .b = 0 };

    var cval: Color.C = undefined;
    try testing.expect(get(&c, .background, @ptrCast(&cval)));
    try testing.expectEqual(255, cval.r);
    try testing.expectEqual(0, cval.g);
    try testing.expectEqual(0, cval.b);
}

test "c_get: optional" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();

    {
        c.@"unfocused-split-fill" = null;
        var cval: Color.C = undefined;
        try testing.expect(!get(&c, .@"unfocused-split-fill", @ptrCast(&cval)));
    }

    {
        c.@"unfocused-split-fill" = .{ .r = 255, .g = 0, .b = 0 };
        var cval: Color.C = undefined;
        try testing.expect(get(&c, .@"unfocused-split-fill", @ptrCast(&cval)));
        try testing.expectEqual(255, cval.r);
        try testing.expectEqual(0, cval.g);
        try testing.expectEqual(0, cval.b);
    }
}

test "c_get: background-blur" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();

    {
        c.@"background-blur" = .false;
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(0, cval);
    }
    {
        c.@"background-blur" = .true;
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(20, cval);
    }
    {
        c.@"background-blur" = .{ .radius = 42 };
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(42, cval);
    }
    {
        c.@"background-blur" = .@"macos-glass-regular";
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(-1, cval);
    }
    {
        c.@"background-blur" = .@"macos-glass-clear";
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(-2, cval);
    }
}

test "c_get: split-preserve-zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();

    var bits: c_uint = undefined;
    try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
    try testing.expectEqual(@as(c_uint, 0), bits);

    c.@"split-preserve-zoom".navigation = true;
    try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
    try testing.expectEqual(@as(c_uint, 1), bits);
}

// Omnity: tests for the font settings read by the window switcher preview.
test "c_get: font-family list" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    var cval: StringList = undefined;
    try testing.expect(get(&c, .@"font-family", @ptrCast(&cval)));
    try testing.expectEqual(@as(usize, 0), cval.len);
    try c.@"font-family".parseCLI(c._arena.?.allocator(), "MesloLGS NF");
    try c.@"font-family".parseCLI(c._arena.?.allocator(), "Menlo");
    try testing.expect(get(&c, .@"font-family", @ptrCast(&cval)));
    try testing.expectEqual(@as(usize, 2), cval.len);
    try testing.expectEqualStrings("MesloLGS NF", std.mem.sliceTo(cval.items[0].?, 0));
    try testing.expectEqualStrings("Menlo", std.mem.sliceTo(cval.items[1].?, 0));
    try testing.expect(cval.items[2] == null);
}
test "c_get: font-style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    var cval: FontStyleC = undefined;
    try testing.expect(get(&c, .@"font-style", @ptrCast(&cval)));
    try testing.expectEqual(@as(u8, 0), cval.kind);
    c.@"font-style-bold" = .{ .false = {} };
    try testing.expect(get(&c, .@"font-style-bold", @ptrCast(&cval)));
    try testing.expectEqual(@as(u8, 1), cval.kind);
    c.@"font-style-italic" = .{ .name = "Light Italic" };
    try testing.expect(get(&c, .@"font-style-italic", @ptrCast(&cval)));
    try testing.expectEqual(@as(u8, 2), cval.kind);
    try testing.expectEqualStrings("Light Italic", std.mem.sliceTo(cval.name.?, 0));
}
test "c_get: bold-color" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    var cval: BoldColorC = undefined;
    try testing.expect(!get(&c, .@"bold-color", @ptrCast(&cval)));
    c.@"bold-color" = .bright;
    try testing.expect(get(&c, .@"bold-color", @ptrCast(&cval)));
    try testing.expectEqual(@as(u8, 0), cval.kind);
    c.@"bold-color" = .{ .color = .{ .r = 1, .g = 2, .b = 3 } };
    try testing.expect(get(&c, .@"bold-color", @ptrCast(&cval)));
    try testing.expectEqual(@as(u8, 1), cval.kind);
    try testing.expectEqual(@as(u8, 3), cval.color.b);
}
test "c_get: adjust-cell-height" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    var cval: MetricModifierC = undefined;
    try testing.expect(!get(&c, .@"adjust-cell-height", @ptrCast(&cval)));
    c.@"adjust-cell-height" = .{ .percent = 1.2 };
    try testing.expect(get(&c, .@"adjust-cell-height", @ptrCast(&cval)));
    try testing.expect(!cval.absolute);
    try testing.expectEqual(@as(f64, 1.2), cval.value);
    c.@"adjust-cell-height" = .{ .absolute = -2 };
    try testing.expect(get(&c, .@"adjust-cell-height", @ptrCast(&cval)));
    try testing.expect(cval.absolute);
    try testing.expectEqual(@as(f64, -2), cval.value);
}
