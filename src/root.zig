const flash = @import("lib/flash.zig");
const ext4 = @import("lib/fs/ext4.zig");
const fat = @import("lib/fs/fat.zig");
const squashfs = @import("lib/fs/squashfs.zig");
const image = @import("lib/image.zig");
const range = @import("lib/range.zig");
const types = @import("lib/types.zig");

pub const ByteRange = types.ByteRange;
pub const FlashOptions = types.FlashOptions;
pub const FlashPlan = types.FlashPlan;
pub const FlashReport = types.FlashReport;
pub const ImageInfo = types.ImageInfo;
pub const UnsupportedPolicy = types.UnsupportedPolicy;
pub const VerifyMode = types.VerifyMode;

pub const normalizeRanges = range.normalizeRanges;
pub const freeRanges = range.freeRanges;

pub const collectExt4Ranges = ext4.collectExt4Ranges;
pub const probeExt4Image = ext4.probeExt4Image;
pub const probeImage = image.probeImage;
pub const planImageFlash = image.planImageFlash;

pub const flashExt4Image = flash.flashExt4Image;
pub const flashPlannedImage = flash.flashPlannedImage;
pub const flashImage = flash.flashImage;
pub const flashToPath = flash.flashToPath;

test {
    _ = @import("lib/types.zig");
    _ = @import("lib/range.zig");
    _ = @import("lib/flash.zig");
    _ = @import("lib/fs/ext4.zig");
    _ = @import("lib/fs/fat.zig");
    _ = @import("lib/fs/squashfs.zig");
    _ = @import("lib/image.zig");
}
