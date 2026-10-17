# openetcher

`openetcher` is a Zig library and command-line tool for flashing disk images. It plans writes from the image layout before writing, so supported filesystem images can skip unused regions while preserving the image's required on-disk structure.

The command-line tool is a thin layer over the `openetcher` library. The current real-device implementation targets macOS; the core planning and flashing library is platform-neutral.

## Contents

- [Requirements](#requirements)
- [Build and Test](#build-and-test)
- [Command-Line Interface](#command-line-interface)
- [Image Support and Planning](#image-support-and-planning)
- [Disk Discovery and Safety](#disk-discovery-and-safety)
- [Flashing Behavior](#flashing-behavior)
- [Library API](#library-api)
- [Architecture](#architecture)
- [Platform Support](#platform-support)
- [Limitations](#limitations)
- [License](#license)

## Requirements

- Zig `0.17.0`
- macOS for physical disk discovery and flashing
- `diskutil` on macOS, used for device discovery, sizing, and unmounting

The project has no third-party library dependencies.

## Build and Test

Build the executable:

```sh
zig build
```

The executable is written to `zig-out/bin/openetcher`.

Run the test suite:

```sh
zig build test
```

Image parsers read untrusted bytes, so `src/lib/image/fuzz.zig` fuzzes the whole analyzer. It starts from a small valid image per format, patches header bytes, and fails on any panic, leak, or plan that writes outside the image. `zig build test` replays only the seed images; to search, run the fuzzer with an iteration limit:

```sh
zig build test --fuzz=100K
```

A failing input is saved under `.zig-cache/f/`, and the test prints the analysis that broke an invariant.

Run the executable through the build system:

```sh
zig build run -- <command> [arguments]
```

Examples:

```sh
zig build run -- info image.img
zig build run -- disks
zig build run -- flash image.img --disk-id macos-0123456789abcdef
```

Release builds use normal Zig build options:

```sh
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

## Command-Line Interface

```text
openetcher info [--json] [--spool-dir <dir>] <image>
openetcher plan [--json] [--spool-dir <dir>] <image>
openetcher disks [--json] [--all]
openetcher flash [--force] [--spool-dir <dir>] <image> <device>
openetcher flash [--force] [--spool-dir <dir>] <image> --disk-id <id>
```

`--spool-dir` sets where compressed images are decoded; see [Compressed images](#compressed-images).

### `info`

Probes an image and prints its recognized layout, filesystem information, and partition information where applicable.

```sh
openetcher info image.img
openetcher info --json image.iso
```

The text output can include:

- `image_size`
- `layout`
- `filesystem`
- `block_size`
- `used_bytes`
- `skipped_bytes`
- `range_count`
- MBR partition metadata and per-partition planning details

`--json` produces the same information as a JSON object. Numeric byte counts are JSON numbers.

### `plan`

Builds a flash plan without writing anything.

```sh
openetcher plan image.img
openetcher plan --json image.img
```

The output reports:

- the source image size
- planned bytes: bytes that will be read, written, and verified
- skipped bytes: image bytes omitted by sparse planning
- range count
- each byte range as an offset, length, and end offset

Planning is useful for checking whether an image format is supported and for measuring the expected sparse-write reduction before a flash.

### `disks`

Lists whole physical disk candidates.

```sh
openetcher disks
openetcher disks --json
openetcher disks --all
openetcher disks --all --json
```

On macOS, the default command lists external physical disks only. `--all` includes internal physical disks as well.

Each entry has:

- `id`: best-effort macOS disk identifier accepted by `flash --disk-id`
- `device`: normal device node, for example `/dev/disk4`
- `raw`: raw device node, for example `/dev/rdisk4`
- `display_name`
- `description`
- `size`: bytes
- `protected`: whether the disk is classified as protected by the current macOS backend
- `system`: whether the disk is classified as a system disk
- `removable`
- `mountpoints`

The generated macOS `id` is not a native `/dev/disk/by-id` equivalent. It is a best-effort identifier derived from disk metadata: protocol, media name, size, and device-tree path. It can be more stable than a `diskN` number across rediscovery, but it is not a hardware serial number and should not be assumed globally unique or permanent.

### `flash`

Plans the image, prepares the target, writes planned ranges, syncs the target, and verifies written ranges by default.

Use a device path:

```sh
openetcher flash image.img /dev/disk4
```

Or use an identifier returned by `disks`:

```sh
openetcher flash image.img --disk-id macos-0123456789abcdef
```

On macOS, `/dev/diskN` is normalized to `/dev/rdiskN` for raw device I/O. The normalization is printed before flashing. If the raw device cannot be opened directly, OpenEtcher uses `/usr/libexec/authopen` to present the macOS administrator authorization dialog and receive an authorized read/write descriptor. The OpenEtcher process itself remains unprivileged.

The CLI reports progress separately for the flash and verify phases. On success it prints:

- bytes written
- write range count
- skipped bytes
- actual throughput: planned bytes divided by flash-plus-verify elapsed time
- effective throughput: full image size divided by the same elapsed time

Target preparation is explicitly logged and excluded from throughput timing. On macOS preparation unmounts the target whole disk through `diskutil unmountDisk`.

## Image Support and Planning

Image detection is content-based. File extensions, including `.iso`, do not control format detection.

| Image or filesystem | Detection | Flash plan |
| --- | --- | --- |
| Raw ext4 image | ext4 superblock | Sparse: ext4 metadata and allocated blocks |
| MBR disk image | MBR partition table | Gaps plus sparse plans for supported partitions |
| FAT16/FAT32 MBR partition | FAT boot sector | Sparse: filesystem metadata and allocated clusters |
| SquashFS MBR partition | SquashFS header | Sequential bytes through its declared `bytes_used` extent |
| ISO9660 image | Primary volume descriptor at logical block 16 (`CD001`) | Entire image, sequentially |

### ISO9660

ISO9660 is identified from its primary volume descriptor at byte offset `16 * 2048`. Its planner always writes the whole file as one range. This is deliberate: ISO9660 is read-only and the current implementation does not attempt a filesystem-level sparse reconstruction.

### MBR Images

MBR image plans preserve gaps outside partitions. For each supported partition, the filesystem-specific planner contributes ranges; gaps and partition-table-adjacent regions are retained so the resulting target preserves required disk-level layout bytes.

Unsupported non-empty partitions cause planning to fail with `UnsupportedPartitionFilesystem`. This is intentional: the library does not silently create a partially flashed image when it cannot reason about a partition's data requirements.

Empty MBR partitions are recognized but do not add filesystem write ranges.

### Sparse Planning Semantics

Sparse planning is an optimization for source image bytes that are known to be irrelevant to the supported filesystem's meaningful state. It does not promise a byte-for-byte clone of every unallocated region.

For a supported sparse plan:

- only planned source ranges are written
- only planned ranges are verified
- the target must still be at least as large as the complete source image
- `bytes_skipped` is the difference between full image size and planned bytes

For ISO9660, planned bytes equal image size and skipped bytes are zero.

## Disk Discovery and Safety

### macOS Candidate Filtering

`openetcher disks` runs:

```text
diskutil list external physical
```

`openetcher disks --all` runs:

```text
diskutil list physical
```

The backend gathers additional fields with `diskutil info`.

The current macOS backend marks a disk protected when it is internal or when macOS reports it as OS-installable. That classification is also used for the `system` field.

### Protected System Disks

Protected system disks are rejected by `flash` unless `--force` is explicitly supplied.

```sh
# Refused if /dev/disk0 is protected.
openetcher flash image.img /dev/disk0

# Explicitly permits the protected target check to be bypassed.
openetcher flash --force image.img /dev/disk0
```

The same guard applies when a system disk is selected with `--disk-id`.

`--force` only bypasses the project's protected-disk gate. It does not bypass OS permissions, device locking, unmount failures, or target-size checks. Writing a disk is destructive; confirm the selected device and its size before running `flash`.

### Direct Device Paths

Direct device paths are supported in addition to discovered ids. The macOS backend normalizes `/dev/diskN` to `/dev/rdiskN` for I/O, while `diskutil` continues to be used with the normal `/dev/diskN` form for whole-disk operations.

Regular files can be used as targets. They are useful for tests and development and are not classified as protected disks.

## Flashing Behavior

The flash implementation operates in these stages:

1. Build an image flash plan.
2. Check target safety in the CLI.
3. Probe the target and confirm it is large enough for the full image.
4. Prepare the target. On macOS, this unmounts the whole disk.
5. Write each planned range in chunks.
6. Sync the target.
7. Verify each planned range against the source image, unless verification is disabled through the library API.

### Compressed images

Planning needs random access to the decoded image, so a compressed image is decoded once into a sparse temporary file (the spool) in `--spool-dir`, which defaults to `$TMPDIR`, `$TMP`, or `$TEMP`. All-zero chunks are left as holes, so the spool usually occupies about as much disk as the data that will be written. Planning, writing, and source verification all read the spool, so the image is decompressed only once.

On macOS and Linux the spool is unlinked as soon as it is created, so an interrupted run leaves nothing behind. If the spool directory is full, `flash` fails before writing anything; pass a larger `--spool-dir`, or use `--force` to stream straight from the decoder without a plan.

Uncompressed images are analyzed in place and need no spool.

Default chunk size is 1 MiB. Device writes use the backend's alignment requirement. The macOS backend uses 512-byte device alignment and pads a non-aligned final chunk as needed for raw device I/O.

The implementation uses positional I/O for regular files. For device targets, it uses seek-and-stream I/O with direct POSIX reads and writes to avoid inappropriate threaded file-I/O behavior for raw devices.

### Verification

The default verification mode is `written`:

- source bytes are reread from each planned range
- target bytes are reread from the same offsets
- a mismatch or short read fails with `VerificationFailed`

Unplanned sparse regions are not verified because they are intentionally not written.

## Library API

The public module is `openetcher`, rooted at `src/root.zig`.

```zig
const openetcher = @import("openetcher");
```

The library never creates global I/O state. Callers provide both an allocator and `std.Io` where required.

### Image APIs

```zig
pub const ImageInfo = openetcher.ImageInfo;
pub const FlashPlan = openetcher.FlashPlan;

pub fn probeImage(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
) !ImageInfo;

pub fn probeImageFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
) !ImageInfo;

pub fn planImageFlash(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
) !FlashPlan;

pub fn planImageFlashFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
) !FlashPlan;
```

`ImageInfo` and `FlashPlan` may own allocations. Release them with:

```zig
defer info.deinit(allocator);
defer plan.deinit(allocator);
```

### Flash APIs

```zig
pub const FlashOptions = openetcher.FlashOptions;
pub const FlashReport = openetcher.FlashReport;

pub fn flashPlannedImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    destination_path: []const u8,
    options: FlashOptions,
) !FlashReport;

pub fn flashToPathFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    destination_path: []const u8,
    image_size: u64,
    ranges: []const openetcher.ByteRange,
    options: FlashOptions,
) !FlashReport;

pub fn flashImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.Io.File,
    destination: std.Io.File,
    image_size: u64,
    ranges: []const openetcher.ByteRange,
    options: FlashOptions,
) !FlashReport;
```

`FlashOptions` fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `block_size` | `1024 * 1024` | Transfer chunk size. Must be non-zero. |
| `verify` | `.written` | `.written` verifies planned ranges; `.none` disables verification. |
| `unsupported` | `.fail` | Unsupported layout policy. Only fail-hard behavior exists currently. |
| `progress_handler` | `null` | Optional phase progress callback. |
| `prepare_target` | `true` | Prepare a path target before opening it. |

The progress handler receives `FlashProgress` values:

```zig
pub const FlashProgress = struct {
    phase: enum { flash, verify },
    completed_bytes: u64,
    total_bytes: u64,
};
```

An example callback setup:

```zig
fn onProgress(context: *anyopaque, progress: openetcher.FlashProgress) !void {
    _ = context;
    _ = progress;
}

const options: openetcher.FlashOptions = .{
    .progress_handler = .{
        .context = state,
        .callback = onProgress,
    },
};
```

`FlashReport` contains the full image size, source bytes read, bytes written, skipped bytes, and range count.

### Device APIs

The device API is exposed as `openetcher.device_api`.

```zig
const device = openetcher.device_api;

const disks = try device.listCandidateDisks(allocator, io, .{});
defer disks.deinit(allocator);

const device_path = try device.resolveDiskId(
    allocator,
    io,
    "macos-0123456789abcdef",
    .{},
);
defer allocator.free(device_path);
```

Useful types include:

- `DeviceCandidateDisk`
- `DeviceCandidateDiskList`
- `DeviceListOptions`
- `DeviceResolveDiskIdOptions`
- `DeviceMountPoint`

`CandidateDisk` values own their strings and mount-point data; use `deinit(allocator)` when retaining an individually returned value. `CandidateDiskList.deinit(allocator)` releases all entries.

## Architecture

```text
src/
  main.zig                       CLI rendering, argument parsing, safety flow
  root.zig                       Public library module
  lib/
    flash.zig                    Single write engine: planned writing, sync, verification, progress
    image.zig                    Shared analyzer over Reader; entry points
    range.zig                    Byte-range normalization and merging
    device.zig                   Device abstraction, comptime platform selection, TargetIo contract
    device/platforms/            macOS backend, Linux/Windows placeholders, shared target-I/O backends
    image/reader.zig             Random-access Reader plus file-region, buffer, and slice sources
    image/layout/mbr.zig         MBR parsing, partition spans, layout driver
    image/layout/driver.zig      Disk-layout driver contract and registry
    image/fs/driver.zig          Filesystem driver contract and registry
    image/fs/ext4.zig            ext4 sparse planner and driver
    image/fs/fat.zig             FAT16/FAT32 sparse planner and driver
    image/fs/squashfs.zig        SquashFS extent planner and driver
    image/fs/iso9660.zig         ISO9660 signature probe and full-image planner and driver
    image/compression.zig        Compression codec registry facade
    image/compression/codec.zig  Codec contract, magic detection, codec table
    image/compression/gzip.zig   gzip streaming decoder adapter
    image/compression/xz.zig     xz streaming decoder adapter
    image/compression/zstd.zig   zstd streaming decoder adapter
    image/compression/bzip2.zig  bzip2 process-based fallback decoder
```

### Design Rules

- Library-first: the CLI delegates probing, planning, and flashing to the public module.
- Callers provide `std.Io` and allocators. There is no global library I/O state or global allocator.
- One analyzer serves every input. `image.zig` analyzes any random-access `Reader`; open files wrap in a region source, decoded bytes wrap in a buffer source. There are no parallel probe pipelines.
- Format drivers are resolved at compile time. Each filesystem, disk layout, and compression codec is a module exposing a fixed set of `pub` declarations, listed in a comptime tuple in `image/fs/driver.zig`, `image/layout/driver.zig`, or `image/compression/codec.zig`. Callers dispatch with `inline for`, so there are no vtables, and each registry checks its entries at compile time: missing declarations, wrong signatures, two drivers claiming one MBR type, overlapping codec magic, or a `Compression` tag without a codec all fail the build with a message naming the contract.
- Detection precedence lives in one documented place per registry. The whole-image chain is ISO9660, then partitioned layouts, then raw ext4.
- Target I/O lives in the platform backend. The flash engine calls only `target_io.writeAt`, `readAt`, and `sync`, resolved at compile time; alignment padding and syscall strategy belong to macOS/Linux shared POSIX code, not the engine.
- File-handle APIs use `std.Io.File` values. Path variants are named with a `FromPath` suffix.
- Platform code lives under `src/lib/device/platforms/` and is selected at compile time using `@import("builtin").target.os.tag`.
- The image layer fails hard when an unsupported non-empty partition would make a sparse plan unsafe.
- The device layer exposes capabilities such as kind, size, alignment, I/O pattern, and verification-read support.

### Extending

| Goal | Work required |
| --- | --- |
| New filesystem | One module under `image/fs/` exposing `name`, `unrecognized`, `detect`, `probeRegion`, `collectRanges`, and optionally `mbr_types` or `raw_layout` with `filesystem` and `blockSize`; one line in `fs/driver.zig`; tests beside the module |
| New disk layout such as GPT | One module under `image/layout/` exposing `layout`, `detect`, and `collectSpans`; one line in `layout/driver.zig` and one tag in `Info.Layout` |
| New compression codec | One module under `image/compression/` exposing `id`, `magic`, and `open`; one line in `compression/codec.zig` and one tag in `Compression` |
| New platform | One backend under `device/platforms/` implementing the seven device functions plus a `target_io` dispatcher, one line in the OS switch in `device.zig` |

### Range Normalization

`ByteRange` values are normalized before MBR plans are returned. Overlapping and adjacent ranges are merged. This prevents duplicated writes and makes planned-byte accounting deterministic.

### Filesystem Responsibilities

- ext4 collects required filesystem metadata plus allocated data blocks.
- FAT collects metadata and allocated clusters from the FAT.
- SquashFS treats the used image extent as sequential data based on its superblock.
- ISO9660 uses a single full-image range.

Each filesystem ships one parser that serves both open-file and in-memory inputs through the shared `Reader` interface. The same parser backs `info`, `plan`, and flash planning, so the two paths cannot disagree.

## Platform Support

| Capability | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Image probing and planning | Yes | Yes | Yes |
| Flashing to regular files | Yes | Yes | Yes |
| Physical-disk discovery | Yes | No | No |
| Physical-disk preparation | Yes | No | No |
| Physical-disk flashing | Yes | No | No |
| Disk ids | Best effort | No | No |

Linux and Windows device backends currently delegate to the regular-file backend. They are architecture placeholders, not real physical-device implementations.

## Limitations

- GPT partition tables are not supported.
- Only MBR partitioned disk images are supported at the disk-layout layer.
- Unsupported non-empty MBR partition filesystems fail planning.
- ISO support is ISO9660 signature detection and full-image writing; UDF-specific detection and optimization are not implemented.
- SquashFS planning currently uses its declared used extent rather than a block-level allocation map.
- macOS disk ids are synthetic best-effort ids, not durable hardware serial identifiers.
- Candidate-disk protection is a safety layer, not a replacement for manual target verification.
- The CLI does not prompt for confirmation; protected system disks require `--force`, and other disks can still be destructive targets.
- macOS raw-device access uses `authopen` when direct access is denied. Authorization requires an interactive graphical login session and may not work over SSH or in other headless environments.

## License

MIT
