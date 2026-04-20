const std = @import("std");

const flash = @import("lib/flash.zig");
const ext4 = @import("lib/fs/ext4.zig");
const fat = @import("lib/fs/fat.zig");
const squashfs = @import("lib/fs/squashfs.zig");
const image = @import("lib/image.zig");
const range = @import("lib/range.zig");

pub const ByteRange = range.ByteRange;
pub const normalizeRanges = range.normalizeRanges;

pub const ImageInfo = image.Info;
pub const probeImage = image.probeImage;
pub const planImageFlash = image.planImageFlash;

pub const UnsupportedPolicy = flash.UnsupportedPolicy;
pub const VerifyMode = flash.VerifyMode;
pub const FlashOptions = flash.Options;
pub const FlashReport = flash.Report;
pub const FlashPlan = flash.Plan;
pub const flashPlannedImage = flash.flashPlannedImage;
pub const flashImage = flash.flashImage;
pub const flashToPath = flash.flashToPath;

test {
    _ = @import("lib/range.zig");
    _ = @import("lib/flash.zig");
    _ = @import("lib/fs/ext4.zig");
    _ = @import("lib/fs/fat.zig");
    _ = @import("lib/fs/squashfs.zig");
    _ = @import("lib/device.zig");
    _ = @import("lib/image.zig");
}
