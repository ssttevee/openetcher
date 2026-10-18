//! The slice of CoreFoundation and DiskArbitration the macOS backend uses.
//! Both frameworks are C APIs, so Zig calls them directly; `build.zig`
//! links them for macOS targets.

const std = @import("std");

pub const CFTypeRef = *const anyopaque;
pub const CFStringRef = *const opaque {};
pub const CFDictionaryRef = *const opaque {};
pub const CFNumberRef = *const opaque {};
pub const CFBooleanRef = *const opaque {};
pub const CFURLRef = *const opaque {};
pub const CFRunLoopRef = *opaque {};
pub const CFTypeID = usize;
pub const CFIndex = isize;
pub const Boolean = u8;

pub const DASessionRef = *opaque {};
pub const DADiskRef = *opaque {};
pub const DADissenterRef = *opaque {};
/// DiskArbitration's status codes, from `<DiskArbitration/DADissenter.h>`.
/// A BSD error is passed through encoded, hence the open end.
pub const DAReturn = enum(i32) {
    success = 0,
    @"error" = code(0x01),
    busy = code(0x02),
    bad_argument = code(0x03),
    exclusive_access = code(0x04),
    no_resources = code(0x05),
    not_found = code(0x06),
    not_mounted = code(0x07),
    not_permitted = code(0x08),
    not_privileged = code(0x09),
    not_ready = code(0x0A),
    not_writable = code(0x0B),
    unsupported = code(0x0C),
    _,

    /// `err_local | err_local_diskarbitration | low`.
    fn code(comptime low: u8) i32 {
        return @bitCast(@as(u32, 0xF8DA0000) | low);
    }
};

pub const kCFStringEncodingUTF8: u32 = 0x08000100;
pub const kCFNumberSInt64Type: CFIndex = 4;

pub const kDADiskUnmountOptionForce: u32 = 0x00080000;
pub const kDADiskUnmountOptionWhole: u32 = 0x00000001;

pub extern "c" fn CFRelease(cf: CFTypeRef) void;
pub extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
pub extern "c" fn CFStringGetTypeID() CFTypeID;
pub extern "c" fn CFNumberGetTypeID() CFTypeID;
pub extern "c" fn CFBooleanGetTypeID() CFTypeID;
pub extern "c" fn CFURLGetTypeID() CFTypeID;
pub extern "c" fn CFDictionaryGetTypeID() CFTypeID;
pub extern "c" fn CFDictionaryGetValue(dict: CFDictionaryRef, key: ?*const anyopaque) ?CFTypeRef;
pub extern "c" fn CFStringCreateWithCString(alloc: ?*const anyopaque, c_str: [*:0]const u8, encoding: u32) ?CFStringRef;
pub extern "c" fn CFStringGetLength(string: CFStringRef) CFIndex;
pub extern "c" fn CFStringGetMaximumSizeForEncoding(length: CFIndex, encoding: u32) CFIndex;
pub extern "c" fn CFStringGetCString(string: CFStringRef, buffer: [*]u8, buffer_size: CFIndex, encoding: u32) Boolean;
pub extern "c" fn CFNumberGetValue(number: CFNumberRef, the_type: CFIndex, value_ptr: *anyopaque) Boolean;
pub extern "c" fn CFBooleanGetValue(boolean: CFBooleanRef) Boolean;
pub extern "c" fn CFURLGetFileSystemRepresentation(url: CFURLRef, resolve_against_base: Boolean, buffer: [*]u8, max_buf_len: CFIndex) Boolean;
pub extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
pub extern "c" fn CFRunLoopRunInMode(mode: CFStringRef, seconds: f64, return_after_source_handled: Boolean) i32;
pub extern "c" fn CFRunLoopStop(rl: CFRunLoopRef) void;
pub extern "c" const kCFRunLoopDefaultMode: CFStringRef;

pub extern "c" fn DASessionCreate(allocator: ?*const anyopaque) ?DASessionRef;
pub extern "c" fn DASessionScheduleWithRunLoop(session: DASessionRef, run_loop: CFRunLoopRef, mode: CFStringRef) void;
pub extern "c" fn DASessionUnscheduleFromRunLoop(session: DASessionRef, run_loop: CFRunLoopRef, mode: CFStringRef) void;
pub extern "c" fn DADiskCreateFromBSDName(allocator: ?*const anyopaque, session: DASessionRef, name: [*:0]const u8) ?DADiskRef;
pub extern "c" fn DADiskCopyDescription(disk: DADiskRef) ?CFDictionaryRef;
pub const DADiskUnmountCallback = *const fn (disk: DADiskRef, dissenter: ?DADissenterRef, context: ?*anyopaque) callconv(.c) void;
pub extern "c" fn DADiskUnmount(disk: DADiskRef, options: u32, callback: ?DADiskUnmountCallback, context: ?*anyopaque) void;
pub extern "c" fn DADissenterGetStatus(dissenter: DADissenterRef) DAReturn;

pub extern "c" const kDADiskDescriptionBusPathKey: CFStringRef;
pub extern "c" const kDADiskDescriptionDeviceInternalKey: CFStringRef;
pub extern "c" const kDADiskDescriptionDeviceProtocolKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaBlockSizeKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaContentKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaEjectableKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaIconKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaNameKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaPathKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaRemovableKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaSizeKey: CFStringRef;
pub extern "c" const kDADiskDescriptionMediaWritableKey: CFStringRef;
pub extern "c" const kDADiskDescriptionVolumeNameKey: CFStringRef;
pub extern "c" const kDADiskDescriptionVolumePathKey: CFStringRef;

/// A disk description from `DADiskCopyDescription`, which the caller owns
/// and releases.
pub const Description = struct {
    dictionary: Dictionary,

    pub fn copy(disk: DADiskRef) ?Description {
        return .{ .dictionary = .{ .ref = DADiskCopyDescription(disk) orelse return null } };
    }

    pub fn release(self: Description) void {
        CFRelease(self.dictionary.ref);
    }
};

/// A dictionary borrowed from its owner, such as a `Description`, read
/// through typed getters that treat a missing key or a value of the wrong
/// type as absent. It must not outlive the owner, and is never released.
pub const Dictionary = struct {
    ref: CFDictionaryRef,

    fn typed(self: Dictionary, key: CFStringRef, type_id: CFTypeID) ?CFTypeRef {
        const value = CFDictionaryGetValue(self.ref, key) orelse return null;
        return if (CFGetTypeID(value) == type_id) value else null;
    }

    /// The string at `key`, copied into `arena`.
    pub fn string(self: Dictionary, arena: std.mem.Allocator, key: CFStringRef) std.mem.Allocator.Error!?[]const u8 {
        const value = self.typed(key, CFStringGetTypeID()) orelse return null;
        return copyString(arena, @ptrCast(value));
    }

    pub fn number(self: Dictionary, key: CFStringRef) ?u64 {
        const value = self.typed(key, CFNumberGetTypeID()) orelse return null;
        var result: i64 = 0;
        if (CFNumberGetValue(@ptrCast(value), kCFNumberSInt64Type, &result) == 0 or result < 0) return null;
        return @intCast(result);
    }

    pub fn boolean(self: Dictionary, key: CFStringRef) bool {
        const value = self.typed(key, CFBooleanGetTypeID()) orelse return false;
        return CFBooleanGetValue(@ptrCast(value)) != 0;
    }

    /// The dictionary at `key`, borrowed from this one's owner.
    pub fn dictionary(self: Dictionary, key: CFStringRef) ?Dictionary {
        const value = self.typed(key, CFDictionaryGetTypeID()) orelse return null;
        return .{ .ref = @ptrCast(value) };
    }

    /// The file-system path of the URL at `key`, copied into `arena`.
    pub fn path(self: Dictionary, arena: std.mem.Allocator, key: CFStringRef) std.mem.Allocator.Error!?[]const u8 {
        const value = self.typed(key, CFURLGetTypeID()) orelse return null;
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (CFURLGetFileSystemRepresentation(@ptrCast(value), 1, &buffer, buffer.len) == 0) return null;
        return try arena.dupe(u8, std.mem.sliceTo(&buffer, 0));
    }
};

/// `string` as UTF-8 in `arena`; null if it does not convert.
fn copyString(arena: std.mem.Allocator, string: CFStringRef) std.mem.Allocator.Error!?[]const u8 {
    const capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    const buffer = try arena.alloc(u8, @intCast(capacity));
    if (CFStringGetCString(string, buffer.ptr, capacity, kCFStringEncodingUTF8) == 0) return null;
    return std.mem.sliceTo(buffer, 0);
}

test "DAReturn codes match DADissenter.h" {
    try std.testing.expectEqual(@as(u32, 0xF8DA0003), @as(u32, @bitCast(@backingInt(DAReturn.bad_argument))));
    try std.testing.expectEqual(@as(u32, 0xF8DA0009), @as(u32, @bitCast(@backingInt(DAReturn.not_privileged))));
}
