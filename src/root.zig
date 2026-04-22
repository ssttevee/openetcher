const std = @import("std");

const flash = @import("lib/flash.zig");
const device = @import("lib/device.zig");
const image = @import("lib/image.zig");
const range = @import("lib/range.zig");

pub const ByteRange = range.ByteRange;
pub const normalizeRanges = range.normalizeRanges;

pub const ImageInfo = image.Info;
pub const probeImage = image.probeImage;
pub const probeImageFromPath = image.probeImageFromPath;
pub const planImageFlash = image.planImageFlash;
pub const planImageFlashFromPath = image.planImageFlashFromPath;

pub const UnsupportedPolicy = flash.UnsupportedPolicy;
pub const VerifyMode = flash.VerifyMode;
pub const FlashPhase = flash.Phase;
pub const FlashProgress = flash.Progress;
pub const FlashProgressHandler = flash.ProgressHandler;
pub const FlashOptions = flash.Options;
pub const FlashReport = flash.Report;
pub const FlashPlan = flash.Plan;
pub const flashPlannedImage = flash.flashPlannedImage;
pub const flashImage = flash.flashImage;
pub const flashToPathFromPath = flash.flashToPathFromPath;
pub const device_api = device;

test {
    _ = @import("lib/range.zig");
    _ = @import("lib/flash.zig");
    _ = @import("lib/device.zig");
    _ = @import("lib/image.zig");
}
