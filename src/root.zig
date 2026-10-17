const std = @import("std");

const flash = @import("lib/flash.zig");
const device = @import("lib/device.zig");
const image = @import("lib/image.zig");
const progress_units = @import("lib/progress.zig");
const range = @import("lib/range.zig");
const source = @import("lib/image/source.zig");
const region = @import("lib/image/region.zig");

pub const ByteRange = range.ByteRange;
pub const Compression = source.Compression;
pub const Metadata = source.Metadata;
pub const ImageSource = source.ImageSource;
pub const Stream = source.Stream;
pub const SourceOptions = source.SourceOptions;
pub const Region = region.Region;
pub const Reader = image.reader.Reader;
pub const Observer = image.observer.Observer;
pub const deliverObserver = image.observer.deliver;
pub const openImageSourceFromPath = source.openImageSourceFromPath;
pub const openImageSource = source.openImageSource;
pub const detectCompression = source.detectCompression;
pub const normalizeRanges = range.normalizeRanges;

pub const Info = image.Info;
pub const ImageInfo = image.Info;
pub const probeImage = image.probeImage;
pub const probeImageFromPath = image.probeImageFromPath;
pub const planImageFlash = image.planImageFlash;
pub const planImageFlashFromPath = image.planImageFlashFromPath;
pub const probeImageSource = image.probeImageSource;
pub const probeImageSourceFromPath = image.probeImageSourceFromPath;
pub const planImageFlashSource = image.planImageFlashSource;
pub const planImageFlashSourceFromPath = image.planImageFlashSourceFromPath;
pub const ProbeOptions = image.ProbeOptions;
pub const PlanOptions = image.PlanOptions;

pub const UnsupportedPolicy = flash.UnsupportedPolicy;
pub const Strategy = flash.Strategy;
pub const PrepareOptions = flash.PrepareOptions;
pub const VerifyMode = flash.VerifyMode;
/// Bytes per count in every `std.Progress` node the library reports.
pub const progress_unit_bytes = progress_units.bytes_per_unit;
pub const FlashOptions = flash.Options;
pub const FlashReport = flash.Report;
pub const Plan = flash.Plan;
pub const FlashPlan = flash.Plan;
pub const flashSource = flash.flashSource;
pub const flashPlannedSource = flash.flashPlannedSource;
pub const flashPlannedImage = flash.flashPlannedImage;
pub const flashImage = flash.flashImage;
pub const flashToPathFromPath = flash.flashToPathFromPath;
pub const DeviceMountPoint = device.MountPoint;
pub const DeviceCandidateDisk = device.CandidateDisk;
pub const DeviceCandidateDiskList = device.CandidateDiskList;
pub const DeviceListOptions = device.ListOptions;
pub const DeviceResolveDiskIdOptions = device.ResolveDiskIdOptions;
pub const device_api = device;

test {
    // Zig only analyzes what something references, so public API that no
    // test calls would otherwise go uncompiled. Referencing every public
    // declaration makes it compile on each target `scripts/test-targets.sh`
    // runs.
    inline for (.{
        @This(),
        @import("lib/contract.zig"),
        @import("lib/progress.zig"),
        @import("lib/range.zig"),
        @import("lib/scan.zig"),
        @import("lib/flash.zig"),
        @import("lib/device.zig"),
        @import("lib/image.zig"),
        @import("lib/image/source.zig"),
        @import("lib/image/reader.zig"),
        @import("lib/image/region.zig"),
        @import("lib/image/observer.zig"),
        @import("lib/image/ondisk.zig"),
        @import("lib/image/fs.zig"),
        @import("lib/image/fs/driver.zig"),
        @import("lib/image/fs/ext4.zig"),
        @import("lib/image/fs/fat.zig"),
        @import("lib/image/fs/iso9660.zig"),
        @import("lib/image/fs/squashfs.zig"),
        @import("lib/image/layout.zig"),
        @import("lib/image/layout/driver.zig"),
        @import("lib/image/layout/mbr.zig"),
        @import("lib/image/compression.zig"),
        @import("lib/image/compression/codec.zig"),
        @import("lib/device.zig").target_io,
    }) |T| std.testing.refAllDecls(T);

    _ = @import("lib/range.zig");
    _ = @import("lib/scan.zig");
    _ = @import("lib/flash.zig");
    _ = @import("lib/device.zig");
    _ = @import("lib/image.zig");
}
