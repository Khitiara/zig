const std = @import("std.zig");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;

/// A contiguous, growable list of items in memory.
/// This is a wrapper around an array of T values. Initialize with `init`.
pub fn ArrayList(comptime T: type) type {
    return ArrayListAligned(T, null);
}

pub fn ArrayListAligned(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return ArrayListAligned(T, null);
        }
    }
    return struct {
        const Self = @This();

        /// Content of the ArrayList
        items: Slice,
        capacity: usize,
        allocator: *Allocator,

        pub const Slice = if (alignment) |a| ([]align(a) T) else []T;
        pub const SliceConst = if (alignment) |a| ([]align(a) const T) else []const T;

        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn init(allocator: *Allocator) Self {
            return Self{
                .items = &[_]T{},
                .capacity = 0,
                .allocator = allocator,
            };
        }

        /// Initialize with capacity to hold at least num elements.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn initCapacity(allocator: *Allocator, num: usize) !Self {
            var self = Self.init(allocator);
            try self.ensureCapacity(num);
            return self;
        }

        /// Release all allocated memory.
        pub fn deinit(self: Self) void {
            self.allocator.free(self.allocatedSlice());
        }

        /// Deprecated: use `items` field directly.
        /// Return contents as a slice. Only valid while the list
        /// doesn't change size.
        pub fn span(self: var) @TypeOf(self.items) {
            return self.items;
        }

        pub const toSlice = @compileError("deprecated: use `items` field directly");
        pub const toSliceConst = @compileError("deprecated: use `items` field directly");
        pub const at = @compileError("deprecated: use `list.items[i]`");
        pub const ptrAt = @compileError("deprecated: use `&list.items[i]`");
        pub const setOrError = @compileError("deprecated: use `if (i >= list.items.len) return error.OutOfBounds else list.items[i] = item`");
        pub const set = @compileError("deprecated: use `list.items[i] = item`");
        pub const swapRemoveOrError = @compileError("deprecated: use `if (i >= list.items.len) return error.OutOfBounds else list.swapRemove(i)`");

        /// ArrayList takes ownership of the passed in slice. The slice must have been
        /// allocated with `allocator`.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn fromOwnedSlice(allocator: *Allocator, slice: Slice) Self {
            return Self{
                .items = slice,
                .capacity = slice.len,
                .allocator = allocator,
            };
        }

        pub fn toUnmanaged(self: Self) ArrayListAlignedUnmanaged(T, alignment) {
            return .{ .items = self.items, .capacity = self.capacity };
        }

        /// The caller owns the returned memory. ArrayList becomes empty.
        pub fn toOwnedSlice(self: *Self) Slice {
            const allocator = self.allocator;
            const result = allocator.shrink(self.allocatedSlice(), self.items.len);
            self.* = init(allocator);
            return result;
        }

        /// Insert `item` at index `n` by moving `list[n .. list.len]` to make room.
        /// This operation is O(N).
        pub fn insert(self: *Self, n: usize, item: T) !void {
            try self.ensureCapacity(self.items.len + 1);
            self.items.len += 1;

            mem.copyBackwards(T, self.items[n + 1 .. self.items.len], self.items[n .. self.items.len - 1]);
            self.items[n] = item;
        }

        /// Insert slice `items` at index `i` by moving `list[i .. list.len]` to make room.
        /// This operation is O(N).
        pub fn insertSlice(self: *Self, i: usize, items: SliceConst) !void {
            try self.ensureCapacity(self.items.len + items.len);
            self.items.len += items.len;

            mem.copyBackwards(T, self.items[i + items.len .. self.items.len], self.items[i .. self.items.len - items.len]);
            mem.copy(T, self.items[i .. i + items.len], items);
        }

        /// Extend the list by 1 element. Allocates more memory as necessary.
        pub fn append(self: *Self, item: T) !void {
            const new_item_ptr = try self.addOne();
            new_item_ptr.* = item;
        }

        /// Extend the list by 1 element, but asserting `self.capacity`
        /// is sufficient to hold an additional item.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// Remove the element at index `i` from the list and return its value.
        /// Asserts the array has at least one item.
        /// This operation is O(N).
        pub fn orderedRemove(self: *Self, i: usize) T {
            const newlen = self.items.len - 1;
            if (newlen == i) return self.pop();

            const old_item = self.items[i];
            for (self.items[i..newlen]) |*b, j| b.* = self.items[i + 1 + j];
            self.items[newlen] = undefined;
            self.items.len = newlen;
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the list.
        /// This operation is O(1).
        pub fn swapRemove(self: *Self, i: usize) T {
            if (self.items.len - 1 == i) return self.pop();

            const old_item = self.items[i];
            self.items[i] = self.pop();
            return old_item;
        }

        /// Append the slice of items to the list. Allocates more
        /// memory as necessary.
        pub fn appendSlice(self: *Self, items: SliceConst) !void {
            try self.ensureCapacity(self.items.len + items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the list, asserting the capacity is already
        /// enough to store the new items.
        pub fn appendSliceAssumeCapacity(self: *Self, items: SliceConst) void {
            const oldlen = self.items.len;
            const newlen = self.items.len + items.len;
            self.items.len = newlen;
            mem.copy(T, self.items[oldlen..], items);
        }

        pub usingnamespace if (T != u8) struct {} else struct {
            pub const Writer = std.io.Writer(*Self, error{OutOfMemory}, appendWrite);

            /// Initializes a Writer which will append to the list.
            pub fn writer(self: *Self) Writer {
                return .{ .context = self };
            }

            /// Deprecated: use `writer`
            pub const outStream = writer;

            /// Same as `append` except it returns the number of bytes written, which is always the same
            /// as `m.len`. The purpose of this function existing is to match `std.io.Writer` API.
            fn appendWrite(self: *Self, m: []const u8) !usize {
                try self.appendSlice(m);
                return m.len;
            }
        };

        /// Append a value to the list `n` times.
        /// Allocates more memory as necessary.
        pub fn appendNTimes(self: *Self, value: T, n: usize) !void {
            const old_len = self.items.len;
            try self.resize(self.items.len + n);
            mem.set(T, self.items[old_len..self.items.len], value);
        }

        /// Adjust the list's length to `new_len`.
        /// Does not initialize added items if any.
        pub fn resize(self: *Self, new_len: usize) !void {
            try self.ensureCapacity(new_len);
            self.items.len = new_len;
        }

        /// Reduce allocated capacity to `new_len`.
        /// Invalidates element pointers.
        pub fn shrink(self: *Self, new_len: usize) void {
            assert(new_len <= self.items.len);

            self.items = self.allocator.realloc(self.allocatedSlice(), new_len) catch |e| switch (e) {
                error.OutOfMemory => { // no problem, capacity is still correct then.
                    self.items.len = new_len;
                    return;
                },
            };
            self.capacity = new_len;
        }

        /// Reduce length to `new_len`.
        /// Invalidates element pointers.
        /// Keeps capacity the same.
        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.items.len);
            self.items.len = new_len;
        }

        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            var better_capacity = self.capacity;
            if (better_capacity >= new_capacity) return;

            while (true) {
                better_capacity += better_capacity / 2 + 8;
                if (better_capacity >= new_capacity) break;
            }

            const new_memory = try self.allocator.reallocAtLeast(self.allocatedSlice(), better_capacity);
            self.items.ptr = new_memory.ptr;
            self.capacity = new_memory.len;
        }

        /// Increases the array's length to match the full capacity that is already allocated.
        /// The new elements have `undefined` values. This operation does not invalidate any
        /// element pointers.
        pub fn expandToCapacity(self: *Self) void {
            self.items.len = self.capacity;
        }

        /// Increase length by 1, returning pointer to the new item.
        /// The returned pointer becomes invalid when the list is resized.
        pub fn addOne(self: *Self) !*T {
            const newlen = self.items.len + 1;
            try self.ensureCapacity(newlen);
            return self.addOneAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item.
        /// Asserts that there is already space for the new item without allocating more.
        /// The returned pointer becomes invalid when the list is resized.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            assert(self.items.len < self.capacity);

            self.items.len += 1;
            return &self.items[self.items.len - 1];
        }

        /// Resize the array, adding `n` new elements, which have `undefined` values.
        /// The return value is an array pointing to the newly allocated elements.
        pub fn addManyAsArray(self: *Self, comptime n: usize) !*[n]T {
            const prev_len = self.items.len;
            try self.resize(self.items.len + n);
            return self.items[prev_len..][0..n];
        }

        /// Resize the array, adding `n` new elements, which have `undefined` values.
        /// The return value is an array pointing to the newly allocated elements.
        /// Asserts that there is already space for the new item without allocating more.
        pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.capacity);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }

        /// Remove and return the last element from the list.
        /// Asserts the list has at least one item.
        pub fn pop(self: *Self) T {
            const val = self.items[self.items.len - 1];
            self.items.len -= 1;
            return val;
        }

        /// Remove and return the last element from the list.
        /// If the list is empty, returns `null`.
        pub fn popOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            return self.pop();
        }

        // For a nicer API, `items.len` is the length, not the capacity.
        // This requires "unsafe" slicing.
        fn allocatedSlice(self: Self) Slice {
            return self.items.ptr[0..self.capacity];
        }
    };
}

/// Bring-your-own allocator with every function call.
/// Initialize directly and deinitialize with `deinit` or use `toOwnedSlice`.
pub fn ArrayListUnmanaged(comptime T: type) type {
    return ArrayListAlignedUnmanaged(T, null);
}

pub fn ArrayListAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return ArrayListAlignedUnmanaged(T, null);
        }
    }
    return struct {
        const Self = @This();

        /// Content of the ArrayList.
        items: Slice = &[_]T{},
        capacity: usize = 0,

        pub const Slice = if (alignment) |a| ([]align(a) T) else []T;
        pub const SliceConst = if (alignment) |a| ([]align(a) const T) else []const T;

        /// Initialize with capacity to hold at least num elements.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn initCapacity(allocator: *Allocator, num: usize) !Self {
            var self = Self{};
            try self.ensureCapacity(allocator, num);
            return self;
        }

        /// Release all allocated memory.
        pub fn deinit(self: *Self, allocator: *Allocator) void {
            allocator.free(self.allocatedSlice());
            self.* = undefined;
        }

        pub fn toManaged(self: *Self, allocator: *Allocator) ArrayListAligned(T, alignment) {
            return .{ .items = self.items, .capacity = self.capacity, .allocator = allocator };
        }

        /// The caller owns the returned memory. ArrayList becomes empty.
        pub fn toOwnedSlice(self: *Self, allocator: *Allocator) Slice {
            const result = allocator.shrink(self.allocatedSlice(), self.items.len);
            self.* = Self{};
            return result;
        }

        /// Insert `item` at index `n`. Moves `list[n .. list.len]`
        /// to make room.
        pub fn insert(self: *Self, allocator: *Allocator, n: usize, item: T) !void {
            try self.ensureCapacity(allocator, self.items.len + 1);
            self.items.len += 1;

            mem.copyBackwards(T, self.items[n + 1 .. self.items.len], self.items[n .. self.items.len - 1]);
            self.items[n] = item;
        }

        /// Insert slice `items` at index `i`. Moves
        /// `list[i .. list.len]` to make room.
        /// This operation is O(N).
        pub fn insertSlice(self: *Self, allocator: *Allocator, i: usize, items: SliceConst) !void {
            try self.ensureCapacity(allocator, self.items.len + items.len);
            self.items.len += items.len;

            mem.copyBackwards(T, self.items[i + items.len .. self.items.len], self.items[i .. self.items.len - items.len]);
            mem.copy(T, self.items[i .. i + items.len], items);
        }

        /// Extend the list by 1 element. Allocates more memory as necessary.
        pub fn append(self: *Self, allocator: *Allocator, item: T) !void {
            const new_item_ptr = try self.addOne(allocator);
            new_item_ptr.* = item;
        }

        /// Extend the list by 1 element, but asserting `self.capacity`
        /// is sufficient to hold an additional item.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// Remove the element at index `i` from the list and return its value.
        /// Asserts the array has at least one item.
        /// This operation is O(N).
        pub fn orderedRemove(self: *Self, i: usize) T {
            const newlen = self.items.len - 1;
            if (newlen == i) return self.pop();

            const old_item = self.items[i];
            for (self.items[i..newlen]) |*b, j| b.* = self.items[i + 1 + j];
            self.items[newlen] = undefined;
            self.items.len = newlen;
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the list.
        /// This operation is O(1).
        pub fn swapRemove(self: *Self, i: usize) T {
            if (self.items.len - 1 == i) return self.pop();

            const old_item = self.items[i];
            self.items[i] = self.pop();
            return old_item;
        }

        /// Append the slice of items to the list. Allocates more
        /// memory as necessary.
        pub fn appendSlice(self: *Self, allocator: *Allocator, items: SliceConst) !void {
            try self.ensureCapacity(allocator, self.items.len + items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the list, asserting the capacity is enough
        /// to store the new items.
        pub fn appendSliceAssumeCapacity(self: *Self, items: SliceConst) void {
            const oldlen = self.items.len;
            const newlen = self.items.len + items.len;

            self.items.len = newlen;
            mem.copy(T, self.items[oldlen..], items);
        }

        /// Same as `append` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.io.OutStream` API.
        /// This function may be called only when `T` is `u8`.
        fn appendWrite(self: *Self, allocator: *Allocator, m: []const u8) !usize {
            try self.appendSlice(allocator, m);
            return m.len;
        }

        /// Append a value to the list `n` times.
        /// Allocates more memory as necessary.
        pub fn appendNTimes(self: *Self, allocator: *Allocator, value: T, n: usize) !void {
            const old_len = self.items.len;
            try self.resize(allocator, self.items.len + n);
            mem.set(T, self.items[old_len..self.items.len], value);
        }

        /// Adjust the list's length to `new_len`.
        /// Does not initialize added items if any.
        pub fn resize(self: *Self, allocator: *Allocator, new_len: usize) !void {
            try self.ensureCapacity(allocator, new_len);
            self.items.len = new_len;
        }

        /// Reduce allocated capacity to `new_len`.
        /// Invalidates element pointers.
        pub fn shrink(self: *Self, allocator: *Allocator, new_len: usize) void {
            assert(new_len <= self.items.len);

            self.items = allocator.realloc(self.allocatedSlice(), new_len) catch |e| switch (e) {
                error.OutOfMemory => { // no problem, capacity is still correct then.
                    self.items.len = new_len;
                    return;
                },
            };
            self.capacity = new_len;
        }

        /// Reduce length to `new_len`.
        /// Invalidates element pointers.
        /// Keeps capacity the same.
        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.items.len);
            self.items.len = new_len;
        }

        pub fn ensureCapacity(self: *Self, allocator: *Allocator, new_capacity: usize) !void {
            var better_capacity = self.capacity;
            if (better_capacity >= new_capacity) return;

            while (true) {
                better_capacity += better_capacity / 2 + 8;
                if (better_capacity >= new_capacity) break;
            }

            const new_memory = try allocator.reallocAtLeast(self.allocatedSlice(), better_capacity);
            self.items.ptr = new_memory.ptr;
            self.capacity = new_memory.len;
        }

        /// Increases the array's length to match the full capacity that is already allocated.
        /// The new elements have `undefined` values.
        /// This operation does not invalidate any element pointers.
        pub fn expandToCapacity(self: *Self) void {
            self.items.len = self.capacity;
        }

        /// Increase length by 1, returning pointer to the new item.
        /// The returned pointer becomes invalid when the list is resized.
        pub fn addOne(self: *Self, allocator: *Allocator) !*T {
            const newlen = self.items.len + 1;
            try self.ensureCapacity(allocator, newlen);
            return self.addOneAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item.
        /// Asserts that there is already space for the new item without allocating more.
        /// The returned pointer becomes invalid when the list is resized.
        /// This operation does not invalidate any element pointers.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            assert(self.items.len < self.capacity);

            self.items.len += 1;
            return &self.items[self.items.len - 1];
        }

        /// Resize the array, adding `n` new elements, which have `undefined` values.
        /// The return value is an array pointing to the newly allocated elements.
        pub fn addManyAsArray(self: *Self, allocator: *Allocator, comptime n: usize) !*[n]T {
            const prev_len = self.items.len;
            try self.resize(allocator, self.items.len + n);
            return self.items[prev_len..][0..n];
        }

        /// Resize the array, adding `n` new elements, which have `undefined` values.
        /// The return value is an array pointing to the newly allocated elements.
        /// Asserts that there is already space for the new item without allocating more.
        pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.capacity);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }

        /// Remove and return the last element from the list.
        /// Asserts the list has at least one item.
        /// This operation does not invalidate any element pointers.
        pub fn pop(self: *Self) T {
            const val = self.items[self.items.len - 1];
            self.items.len -= 1;
            return val;
        }

        /// Remove and return the last element from the list.
        /// If the list is empty, returns `null`.
        /// This operation does not invalidate any element pointers.
        pub fn popOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            return self.pop();
        }

        /// For a nicer API, `items.len` is the length, not the capacity.
        /// This requires "unsafe" slicing.
        fn allocatedSlice(self: Self) Slice {
            return self.items.ptr[0..self.capacity];
        }
    };
}

test "std.ArrayList.init" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    testing.expect(list.items.len == 0);
    testing.expect(list.capacity == 0);
}

test "std.ArrayList.initCapacity" {
    var list = try ArrayList(i8).initCapacity(testing.allocator, 200);
    defer list.deinit();
    testing.expect(list.items.len == 0);
    testing.expect(list.capacity >= 200);
}

test "std.ArrayList.basic" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    {
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            list.append(@intCast(i32, i + 1)) catch unreachable;
        }
    }

    {
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            testing.expect(list.items[i] == @intCast(i32, i + 1));
        }
    }

    for (list.items) |v, i| {
        testing.expect(v == @intCast(i32, i + 1));
    }

    testing.expect(list.pop() == 10);
    testing.expect(list.items.len == 9);

    list.appendSlice(&[_]i32{ 1, 2, 3 }) catch unreachable;
    testing.expect(list.items.len == 12);
    testing.expect(list.pop() == 3);
    testing.expect(list.pop() == 2);
    testing.expect(list.pop() == 1);
    testing.expect(list.items.len == 9);

    list.appendSlice(&[_]i32{}) catch unreachable;
    testing.expect(list.items.len == 9);

    // can only set on indices < self.items.len
    list.items[7] = 33;
    list.items[8] = 42;

    testing.expect(list.pop() == 42);
    testing.expect(list.pop() == 33);
}

test "std.ArrayList.appendNTimes" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    try list.appendNTimes(2, 10);
    testing.expectEqual(@as(usize, 10), list.items.len);
    for (list.items) |element| {
        testing.expectEqual(@as(i32, 2), element);
    }
}

test "std.ArrayList.appendNTimes with failing allocator" {
    var list = ArrayList(i32).init(testing.failing_allocator);
    defer list.deinit();
    testing.expectError(error.OutOfMemory, list.appendNTimes(2, 10));
}

test "std.ArrayList.orderedRemove" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.append(5);
    try list.append(6);
    try list.append(7);

    //remove from middle
    testing.expectEqual(@as(i32, 4), list.orderedRemove(3));
    testing.expectEqual(@as(i32, 5), list.items[3]);
    testing.expectEqual(@as(usize, 6), list.items.len);

    //remove from end
    testing.expectEqual(@as(i32, 7), list.orderedRemove(5));
    testing.expectEqual(@as(usize, 5), list.items.len);

    //remove from front
    testing.expectEqual(@as(i32, 1), list.orderedRemove(0));
    testing.expectEqual(@as(i32, 2), list.items[0]);
    testing.expectEqual(@as(usize, 4), list.items.len);
}

test "std.ArrayList.swapRemove" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.append(5);
    try list.append(6);
    try list.append(7);

    //remove from middle
    testing.expect(list.swapRemove(3) == 4);
    testing.expect(list.items[3] == 7);
    testing.expect(list.items.len == 6);

    //remove from end
    testing.expect(list.swapRemove(5) == 6);
    testing.expect(list.items.len == 5);

    //remove from front
    testing.expect(list.swapRemove(0) == 1);
    testing.expect(list.items[0] == 5);
    testing.expect(list.items.len == 4);
}

test "std.ArrayList.insert" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.insert(0, 5);
    testing.expect(list.items[0] == 5);
    testing.expect(list.items[1] == 1);
    testing.expect(list.items[2] == 2);
    testing.expect(list.items[3] == 3);
}

test "std.ArrayList.insertSlice" {
    var list = ArrayList(i32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.insertSlice(1, &[_]i32{ 9, 8 });
    testing.expect(list.items[0] == 1);
    testing.expect(list.items[1] == 9);
    testing.expect(list.items[2] == 8);
    testing.expect(list.items[3] == 2);
    testing.expect(list.items[4] == 3);
    testing.expect(list.items[5] == 4);

    const items = [_]i32{1};
    try list.insertSlice(0, items[0..0]);
    testing.expect(list.items.len == 6);
    testing.expect(list.items[0] == 1);
}

const Item = struct {
    integer: i32,
    sub_items: ArrayList(Item),
};

test "std.ArrayList: ArrayList(T) of struct T" {
    var root = Item{ .integer = 1, .sub_items = ArrayList(Item).init(testing.allocator) };
    defer root.sub_items.deinit();
    try root.sub_items.append(Item{ .integer = 42, .sub_items = ArrayList(Item).init(testing.allocator) });
    testing.expect(root.sub_items.items[0].integer == 42);
}

test "std.ArrayList(u8) implements outStream" {
    var buffer = ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const x: i32 = 42;
    const y: i32 = 1234;
    try buffer.outStream().print("x: {}\ny: {}\n", .{ x, y });

    testing.expectEqualSlices(u8, "x: 42\ny: 1234\n", buffer.span());
}

test "std.ArrayList.shrink still sets length on error.OutOfMemory" {
    // use an arena allocator to make sure realloc returns error.OutOfMemory
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var list = ArrayList(i32).init(&arena.allocator);

    try list.append(1);
    try list.append(2);
    try list.append(3);

    list.shrink(1);
    testing.expect(list.items.len == 1);
}

test "std.ArrayList.writer" {
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const writer = list.writer();
    try writer.writeAll("a");
    try writer.writeAll("bc");
    try writer.writeAll("d");
    try writer.writeAll("efg");
    testing.expectEqualSlices(u8, list.items, "abcdefg");
}

test "addManyAsArray" {
    const a = std.testing.allocator;
    {
        var list = ArrayList(u8).init(a);
        defer list.deinit();

        (try list.addManyAsArray(4)).* = "aoeu".*;
        try list.ensureCapacity(8);
        list.addManyAsArrayAssumeCapacity(4).* = "asdf".*;

        testing.expectEqualSlices(u8, list.items, "aoeuasdf");
    }
    {
        var list = ArrayListUnmanaged(u8){};
        defer list.deinit(a);

        (try list.addManyAsArray(a, 4)).* = "aoeu".*;
        try list.ensureCapacity(a, 8);
        list.addManyAsArrayAssumeCapacity(4).* = "asdf".*;

        testing.expectEqualSlices(u8, list.items, "aoeuasdf");
    }
}
