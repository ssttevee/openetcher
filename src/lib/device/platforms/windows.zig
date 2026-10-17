//! Windows has no raw-device support yet: only regular-file targets work.

const regular_file = @import("regular_file.zig");
const target_io_api = @import("target_io.zig");

pub const probeTarget = regular_file.probeTarget;
pub const openTarget = regular_file.openTarget;
pub const prepareTargetPath = regular_file.prepareTargetPath;
pub const prepareTarget = regular_file.prepareTarget;
pub const listCandidateDisks = regular_file.listCandidateDisks;
pub const resolveDiskId = regular_file.resolveDiskId;
pub const lookupDiskByPath = regular_file.lookupDiskByPath;

pub const target_io = target_io_api.positional_only;
