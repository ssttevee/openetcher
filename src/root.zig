const std = @import("std");

const flash = @import("lib/flash.zig");
const device = @import("lib/device.zig");
const image = @import("lib/image.zig");
const range = @import("lib/range.zig");
const source = @import("lib/image/source.zig");
const region = @import("lib/image/region.zig");

pub const ByteRange = range.ByteRange;
pub const Compression = source.Compression;
pub const Metadata = source.Metadata;
pub const ImageSource = source.ImageSource;
pub const Stream = source.Stream;
pub const RandomAccessReader = source.RandomAccessReader;
pub const SourceOptions = source.SourceOptions;
pub const SourcePolicy = source.SourcePolicy;
pub const Region = region.Region;
pub const Confidence = image.layout.Confidence;
pub const ProbeResult = image.layout.ProbeResult;
pub const Purpose = image.fs.Purpose;
pub const ReadRequest = image.fs.ReadRequest;
pub const Analyzer = image.fs.Analyzer;
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
pub const FlashPhase = flash.Phase;
pub const FlashProgress = flash.Progress;
pub const FlashProgressHandler = flash.ProgressHandler;
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
    _ = @import("lib/range.zig");
    _ = @import("lib/flash.zig");
    _ = @import("lib/device.zig");
    _ = @import("lib/image.zig");
}
