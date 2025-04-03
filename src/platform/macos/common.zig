const ExternalClass = @import("objc.zig").ExternalClass;

pub const NSString = ExternalClass(
    "NSString",
    struct {
        pub fn UTF8String(self: NSString) [*c]const u8 {
            return self.msgSend([*c]const u8, "UTF8String", .{});
        }

        pub fn stringWithUTF8String(text: [:0]const u8) NSString {
            return NSString.class().msgSend(NSString, "stringWithUTF8String:", .{text});
        }
    },
);

pub const NSNumber = ExternalClass(
    "NSNumber",
    struct {
        pub inline fn numberWithBool(value: bool) NSNumber {
            return NSNumber.class().msgSend(NSNumber, "numberWithBool:", .{value});
        }

        pub fn boolValue(self: NSNumber) bool {
            return self.msgSend(bool, "boolValue", .{});
        }

        pub fn unsignedIntValue(self: NSNumber) c_uint {
            return self.msgSend(c_uint, "unsignedIntValue", .{});
        }

        pub fn unsignedLongValue(self: NSNumber) c_ulong {
            return self.msgSend(c_ulong, "unsignedLongValue", .{});
        }

        pub fn unsignedLongLongValue(self: NSNumber) c_ulonglong {
            return self.msgSend(c_ulonglong, "unsignedLongLongValue", .{});
        }
    },
);

pub const NSArray = ExternalClass(
    "NSArray",
    struct {
        pub const Iterator = struct {
            arr: NSArray,
            pos: u32,

            pub fn next(self: *Iterator, T: type) ?T {
                if (self.arr.count() <= self.pos) {
                    return null;
                }

                defer self.pos += 1;

                return self.arr.objectAtIndex(T, self.pos);
            }
        };

        pub fn arrayWithObjects(objects: []const @import("objc").Object) NSArray {
            return NSArray.class().msgSend(NSArray, "arrayWithObjects:count:", .{ objects.ptr, objects.len });
        }

        pub fn count(self: NSArray) u32 {
            return self.msgSend(u32, "count", .{});
        }

        pub fn objectAtIndex(self: NSArray, T: type, index: u32) T {
            return self.msgSend(T, "objectAtIndex:", .{index});
        }

        pub fn iterator(self: NSArray) Iterator {
            return .{
                .arr = self,
                .pos = 0,
            };
        }
    },
);

pub const NSURL = ExternalClass(
    "NSURL",
    struct {
        pub fn getResourceValue(self: NSURL, key: NSString) ?*anyopaque {
            var out: ?*anyopaque = undefined;
            self.msgSend(void, "getResourceValue:forKey:error:", .{ &out, key, null });
            return out;
        }

        pub fn path(self: NSURL) NSString {
            return self.msgSend(NSString, "path", .{});
        }
    },
);
