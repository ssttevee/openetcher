const std = @import("std");
const objc = @import("objc");

fn MappedClass(comptime Declarations: fn (type) type, comptime getClass: fn (type) callconv(.@"inline") ?objc.Class) type {
    return extern struct {
        object: objc.Object,

        var class_cache: ?objc.Class = null;

        const Self = @This();

        pub fn class() objc.Class {
            if (class_cache == null) {
                class_cache = getClass(@This());
            }

            return class_cache orelse unreachable;
        }

        pub fn alloc() @This() {
            return class().msgSend(@This(), "alloc", .{});
        }

        pub fn release() @This() {
            return class().msgSend(@This(), "release", .{});
        }

        pub inline fn classMsgSend(comptime Return: type, sel_raw: anytype, args: anytype) Return {
            return class().msgSend(Return, sel_raw, args);
        }

        pub inline fn msgSend(self: Self, comptime Return: type, sel_raw: anytype, args: anytype) Return {
            return self.object.msgSend(Return, sel_raw, args);
        }

        const Decls = Declarations(Self);

        pub usingnamespace Decls;

        const ivars = if (@hasDecl(Decls, "ivars")) Decls.ivars else struct {};

        pub inline fn ivarGet(instance: Self, comptime field: std.meta.FieldEnum(ivars)) ?*std.meta.FieldType(ivars, field) {
            var value: ?*std.meta.FieldType(ivars, field) = null;
            _ = objc.c.object_getInstanceVariable(instance.object.value, @tagName(field), @ptrCast(&value));
            return value;
        }

        pub inline fn ivarSet(instance: Self, comptime field: std.meta.FieldEnum(ivars), value: ?*std.meta.FieldType(ivars, field)) void {
            _ = objc.c.object_setInstanceVariable(instance.object.value, @tagName(field), @constCast(@ptrCast(value)));
        }
    };
}

pub fn ExternalClass(comptime name: [:0]const u8, comptime Declarations: type) type {
    return MappedClass(
        struct {
            fn Decls(_: type) type {
                return Declarations;
            }
        }.Decls,
        struct {
            inline fn getClass(_: type) ?objc.Class {
                return objc.getClass(name);
            }
        }.getClass,
    );
}

pub fn CustomClass(comptime SuperClass: type, comptime Declarations: type) type {
    return MappedClass(
        struct {
            fn Decls(comptime T: type) type {
                return struct {
                    pub fn super(self: T) SuperClass {
                        return @bitCast(self);
                    }

                    pub usingnamespace Declarations;
                };
            }
        }.Decls,
        struct {
            inline fn getClass(comptime T: type) ?objc.Class {
                return objc.Class.registerStruct(T, SuperClass.class());
            }
        }.getClass,
    );
}
