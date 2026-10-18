//! Unicoder: std.unicode, but good
//!
//! This library covers the same basic ground as std.unicode, but is
//! consistently faster (or in a few cases, at least identical), and is
//! organized by namespace, instead of smashing namespaces into exceptionally
//! long function names.
//!
//! It also provides several varieties of operation: error-producing is the
//! default, `lossy` uses the replacement character in the event of errors, and
//! `valid` assumes you know what you're doing and does the fastest possible
//! thing which will give the correct result if you actually do.

const u8dfa = dfa.utf8.dfa;
const w8dfa = dfa.wtf8.dfa;
const st_dfa = dfa.utf8.state;
const c_mask = dfa.utf8.mask;
const UTF_ACCEPT = dfa.utf8.accept;
const UTF_REJECT = dfa.utf8.reject;

const utf8_uffd = [3]u8{ 0xEF, 0xBF, 0xBD };

const Surrogates = enum {
    no_surrogate,
    allow_surrogate,
};

/// Kind of error strategy used by an iterator.  These
/// match the libraries, with `exact` as the default
/// strategy.
const ErrorStrategyKind = enum {
    /// Return an error when errors are encountered.
    exact,
    /// Replace the maximal subpart of errors with U+FFFD.
    lossy,
    /// Errors?  What errors.  It's encoded right, I promise.
    assume_valid,
};

const Xf8Kind = enum {
    utf8,
    wtf8,
};

/// Detailed WTF-8 decoding diagnostics mirrored from `std.unicode`,
/// plus the framing errors needed by these wrapper helpers.
pub const Wtf8DiagnoseError = error{
    Utf8InvalidStartByte,
    TruncatedInput,
    Utf8ExpectedContinuation,
    Utf8OverlongEncoding,
    Utf8CodepointTooLarge,
};

/// Detailed UTF-8 decoding diagnostics mirrored from `std.unicode`.
pub const Utf8DiagnoseError = Wtf8DiagnoseError || error{Utf8EncodesSurrogateHalf};

/// Operations on Unicode codepoints.
pub const codepoint = struct {
    /// Error returned when a codepoint cannot be encoded as UTF-8.
    pub const Utf8EncodeError = error{ Utf8CannotEncodeSurrogateHalf, CodepointTooLarge };

    /// Error returned when a codepoint cannot be encoded as WTF-8.
    pub const Wtf8EncodeError = error{CodepointTooLarge};

    /// Error returned when a codepoint cannot be encoded as UTF-16.
    pub const Utf16EncodeError = error{ Utf16CannotEncodeSurrogateHalf, CodepointTooLarge };

    /// Error returned when a codepoint cannot be encoded as WTF-16.
    pub const Wtf16EncodeError = error{CodepointTooLarge};

    /// Return the number of bytes required to encode `c` as UTF-8.
    pub fn utf8Width(c: u21) error{CodepointTooLarge}!u3 {
        return xtf8CodepointWidth(c);
    }

    /// Return the number of bytes required to encode `c` as WTF-8.
    pub fn wtf8Width(c: u21) error{CodepointTooLarge}!u3 {
        return xtf8CodepointWidth(c);
    }

    /// Return the number of UTF-16 code units required to encode `c`.
    pub fn utf16Width(c: u21) error{CodepointTooLarge}!u2 {
        return utf16CodepointSequenceLengthImpl(c);
    }

    /// Return the number of WTF-16 code units required to encode `c`.
    pub fn wtf16Width(c: u21) error{CodepointTooLarge}!u2 {
        return utf16CodepointSequenceLengthImpl(c);
    }

    /// Encode `c` as UTF-8 into `out`.
    pub fn toUtf8(c: u21, out: []u8) Utf8EncodeError!u3 {
        return xtf8Encode(c, out, .no_surrogate);
    }

    /// Encode `c` as WTF-8 into `out`.
    pub fn toWtf8(c: u21, out: []u8) Wtf8EncodeError!u3 {
        return xtf8Encode(c, out, .allow_surrogate);
    }

    /// Encode `c` as UTF-16 into `out`.
    pub fn toUtf16(c: u21, out: []u16) Utf16EncodeError!u2 {
        return xtf16Encode(c, out, .no_surrogate);
    }

    /// Encode `c` as WTF-16 into `out`.
    pub fn toWtf16(c: u21, out: []u16) Wtf16EncodeError!u2 {
        return xtf16Encode(c, out, .allow_surrogate);
    }

    /// Return whether `value` is a valid Unicode codepoint.
    pub fn isValidUnicode(value: u21) bool {
        return utf8ValidCodepoint(value);
    }

    /// Return whether `value` is a valid WTF-8 codepoint.
    pub fn isValidWtf(value: u21) bool {
        return wtf8ValidCodepoint(value);
    }

    /// Return whether `c` is a surrogate half.
    pub fn isSurrogate(c: u21) bool {
        return isSurrogateImpl(c);
    }
};

pub const utf8 = struct {
    /// Error returned when invalid Unicode is encountered.
    pub const Error = error{InvalidUtf8};

    /// A "view" into a Utf8 string.  Comes in several kinds.
    pub const Utf8View = Xf8View(.utf8);

    /// The strategy for error handling of a given Utf8View.
    pub const ErrorStrategy = ErrorStrategyKind;

    /// The "lossy" version of the library.  Same functionality
    /// as the base, but errors are handled using Substitution of
    /// Maximal Subparts, returning U+FFFD for the offending region.
    pub const lossy = utf8_lossy;

    /// The "valid" version of the library.  Same functionality
    /// as the base, but assumes inputs are already valid UTF-8.
    /// Bad things will reliably happen if this assumption is not
    /// correct.  See: `utf8.validate`.
    pub const valid = utf8_assume_valid;

    /// Wrap a byte slice as a UTF-8 view specialized to the selected error strategy.
    pub fn iterator(slice: []const u8, comptime strategy: ErrorStrategy) Utf8View(strategy) {
        return Utf8View(strategy).init(slice);
    }

    /// Return the length in bytes of the codepoint beginning with `first_byte`.
    pub fn byteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
        return utf8ByteLength(first_byte);
    }

    /// Decode the codepoint at `slice[0]`.
    /// Assumes that `slice.len > 0`.
    pub fn decode(slice: []const u8) Error!u21 {
        return decodeUtf8(slice);
    }

    /// Decode the codepoint at `slice[cursor.*]`.
    /// The cursor is advanced to one index past the decoded codepoint,
    /// which may include `slice.len`. On error, the cursor points to
    /// the first invalid byte in the sequence. Asserts that `cursor.*`
    /// indexes `slice`.
    pub fn decodeCursor(slice: []const u8, cursor: *usize) Error!u21 {
        return decodeUtf8Cursor(slice, cursor);
    }

    /// Return whether `slice` is valid UTF-8.
    pub fn validate(slice: []const u8) bool {
        return validateUtf8(slice);
    }

    /// Return whether `slice` is valid UTF-8.
    /// On success, `cursor` is advanced to `slice.len`. On failure,
    /// it points to the first rejected byte.
    pub fn validateCursor(slice: []const u8, cursor: *usize) bool {
        return validateUtf8Cursor(slice, cursor);
    }

    pub const diagnoseError = utfDiagnoseAtIndex;

    /// Count the number of UTF-8 codepoints in `slice`.
    pub fn countCodepoints(slice: []const u8) Error!usize {
        return countUtf8(slice);
    }

    /// Transcode `utf_8` into UTF-16LE, writing into `utf_16`.
    /// Assumes that `utf_16` has sufficient capacity.
    pub fn toUtf16Le(utf_16: []u16, utf_8: []const u8) utf16.FromUtf8Error!usize {
        return utf8_to_utf16.toUtf16Le(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16BE, writing into `utf_16`.
    /// Assumes that `utf_16` has sufficient capacity.
    pub fn toUtf16Be(utf_16: []u16, utf_8: []const u8) utf16.FromUtf8Error!usize {
        return utf8_to_utf16.toUtf16Be(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16LE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    pub fn toUtf16LeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) utf16.FromUtf8Error!void {
        return utf8_to_utf16.toUtf16LeCursor(utf_16, utf_8, i_16, i_8);
    }

    /// Transcode `utf_8` into UTF-16BE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    pub fn toUtf16BeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) utf16.FromUtf8Error!void {
        return utf8_to_utf16.toUtf16BeCursor(utf_16, utf_8, i_16, i_8);
    }

    /// Count the number of UTF-16 code units required to transcode `utf_8` into UTF-16.
    pub fn countUtf16Units(utf_8: []const u8) utf16.FromUtf8Error!usize {
        return calcUtf16LeLenXtf8(utf_8);
    }
};

/// Operations onto, and out of, the wtf8 encoding.  See:
/// https://wtf-8.codeberg.page/
/// Transcoders live with the source encoding, so WTF-8 to WTF-16
/// entry points are exposed here as `toWtf16Le` and friends.
pub const wtf8 = struct {
    /// Error returned when invalid Unicode is encountered.
    pub const Error = error{InvalidWtf8};

    /// A "view" into a Wtf8 string.  Comes in several kinds.
    pub const Wtf8View = Xf8View(.wtf8);

    /// The strategy for error handling of a given Wtf8View.
    pub const ErrorStrategy = ErrorStrategyKind;

    /// The "lossy" version of the library.  Same functionality
    /// as the base, but errors are handled using Substitution of
    /// Maximal Subparts, returning U+FFFD for the offending region.
    pub const lossy = wtf8_lossy;

    /// The "valid" version of the library.  Same functionality
    /// as the base, but assumes inputs are already valid WTF-8.
    /// Bad things will reliably happen if this assumption is not
    /// correct.  See: `wtf8.validate`.
    pub const valid = wtf8_assume_valid;

    /// Wrap a byte slice as a WTF-8 view specialized to the selected error strategy.
    pub fn iterator(slice: []const u8, comptime strategy: ErrorStrategy) Wtf8View(strategy) {
        return Wtf8View(strategy).init(slice);
    }

    /// Return the length in bytes of the codepoint beginning with `first_byte`.
    pub fn byteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
        return utf8ByteLength(first_byte);
    }

    /// Decode the codepoint at `slice[0]`.
    /// Assumes that `slice.len > 0`.
    pub fn decode(slice: []const u8) Error!u21 {
        var cursor: usize = 0;
        return decodeCursor(slice, &cursor);
    }

    /// Decode the codepoint at `slice[cursor.*]`.
    /// The cursor is advanced to one index past the decoded codepoint,
    /// which may include `slice.len`. On error, the cursor points to
    /// the first invalid byte in the sequence. Asserts that `cursor.*`
    /// indexes `slice`.
    pub fn decodeCursor(slice: []const u8, cursor: *usize) Error!u21 {
        return decodeAnyXtf8Cursor(w8dfa, st_dfa, c_mask, slice, cursor) catch {
            return error.InvalidWtf8;
        };
    }

    /// Return whether `slice` is valid WTF-8.
    pub fn validate(slice: []const u8) bool {
        return validateWtf8(slice);
    }

    /// Return whether `slice` is valid WTF-8.
    /// On success, `cursor` is advanced to `slice.len`. On failure,
    /// it points to the first rejected byte.
    pub fn validateCursor(slice: []const u8, cursor: *usize) bool {
        return validateWtf8Cursor(slice, cursor);
    }

    pub const diagnoseError = wtfDiagnoseAtIndex;

    /// Count the number of WTF-8 codepoints in `slice`.
    pub fn countCodepoints(slice: []const u8) Error!usize {
        return countWtf8(slice) catch {
            return error.InvalidWtf8;
        };
    }

    /// Transcode `wtf_8` into WTF-16LE, writing into `wtf_16`.
    /// Assumes that `wtf_16` has sufficient capacity.
    pub fn toWtf16Le(wtf_16: []u16, wtf_8: []const u8) wtf16.FromWtf8Error!usize {
        return wtf8_to_wtf16.toWtf16Le(wtf_16, wtf_8);
    }

    /// Transcode `wtf_8` into WTF-16BE, writing into `wtf_16`.
    /// Assumes that `wtf_16` has sufficient capacity.
    pub fn toWtf16Be(wtf_16: []u16, wtf_8: []const u8) wtf16.FromWtf8Error!usize {
        return wtf8_to_wtf16.toWtf16Be(wtf_16, wtf_8);
    }

    /// Transcode `wtf_8` into WTF-16LE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    pub fn toWtf16LeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) wtf16.FromWtf8Error!void {
        return wtf8_to_wtf16.toWtf16LeCursor(wtf_16, wtf_8, i_16, i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    pub fn toWtf16BeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) wtf16.FromWtf8Error!void {
        return wtf8_to_wtf16.toWtf16BeCursor(wtf_16, wtf_8, i_16, i_8);
    }

    /// Count the number of WTF-16 code units required to transcode `wtf_8` into WTF-16.
    pub fn countWtf16Units(wtf_8: []const u8) wtf16.FromWtf8Error!usize {
        return calcWtf16LeLenXtf8(wtf_8);
    }
};

/// Operations onto, and out of, the UTF-16 encoding.  Mostly, this expects
/// the Le variant, which is mostly all you'll ever see.  In-place conversion
/// from big-endian UTF-16 is made available.
pub const utf16 = struct {
    /// Error returned when transcoding UTF-16 into UTF-8 fails.
    pub const ToUtf8Error = Utf16LeIterator.NextCodepointError || codepoint.Utf8EncodeError;

    /// Error returned when invalid UTF-8 is encountered while producing UTF-16.
    pub const FromUtf8Error = error{InvalidUtf8};

    /// Error returned when surrogate-pair decoding is requested on malformed UTF-16.
    pub const DecodePairError = Utf16DecodePairError;

    /// Iterate over the codepoints of a UTF-16LE slice.
    pub const Utf16LeIterator = Utf16LeIteratorImpl();

    /// Return whether `c` is a high surrogate half.
    pub fn isHighSurrogate(c: u16) bool {
        return utf16IsHighSurrogateImpl(c);
    }

    /// Return whether `c` is a low surrogate half.
    pub fn isLowSurrogate(c: u16) bool {
        return utf16IsLowSurrogateImpl(c);
    }

    /// Return the number of UTF-16 code units in the codepoint beginning with `first_code_unit`.
    pub fn codeUnitWidth(first_code_unit: u16) error{Utf16InvalidStartCodeUnit}!u2 {
        return utf16CodeUnitSequenceLengthImpl(first_code_unit);
    }

    /// Convert UTF-16BE code units to UTF-16LE in-place.
    pub fn normalizeBe(utf16be: []u16) void {
        normalizeUtf16Be(utf16be);
    }

    /// Decode the surrogate pair beginning at `surrogate_pair[0]`.
    pub fn decodePair(surrogate_pair: []const u16) DecodePairError!u21 {
        return utf16DecodeSurrogatePairImpl(surrogate_pair);
    }

    /// Count the number of codepoints in `utf16le`.
    pub fn countCodepoints(utf16le: []const u16) Utf16LeIterator.NextCodepointError!usize {
        return utf16CountCodepointsImpl(utf16le);
    }

    /// Transcode `utf16le` into UTF-8, writing into `utf_8`.
    /// Assumes that `utf_8` has sufficient capacity.
    pub fn toUtf8(utf_8: []u8, utf16le: []const u16) ToUtf8Error!usize {
        return utf16LeToUtf8Impl(utf_8, utf16le);
    }

    /// Return the number of bytes required to transcode `utf16le` into UTF-8.
    pub fn calcUtf8Len(utf16le: []const u16) Utf16LeIterator.NextCodepointError!usize {
        return calcUtf8LenImpl(utf16le);
    }
};

/// Operations onto, and out of, the WTF-16 encoding.  Mostly, this expects
/// the Le variant, which is mostly all you'll ever see.  In-place conversion
/// from big-endian WTF-16 is made available.
pub const wtf16 = struct {
    /// Error returned when invalid WTF-8 is encountered while producing WTF-16.
    pub const FromWtf8Error = error{InvalidWtf8};

    /// Error returned when surrogate-pair decoding is requested on malformed WTF-16.
    pub const DecodePairError = Utf16DecodePairError;

    /// Iterate over the codepoints of a WTF-16LE slice.
    pub const Wtf16LeIterator = Wtf16LeIteratorImpl();

    /// Return whether `c` is a high surrogate half.
    pub fn isHighSurrogate(c: u16) bool {
        return utf16IsHighSurrogateImpl(c);
    }

    /// Return whether `c` is a low surrogate half.
    pub fn isLowSurrogate(c: u16) bool {
        return utf16IsLowSurrogateImpl(c);
    }

    /// Return the number of WTF-16 code units in the codepoint beginning with `first_code_unit`.
    pub fn codeUnitWidth(first_code_unit: u16) error{Utf16InvalidStartCodeUnit}!u2 {
        return utf16CodeUnitSequenceLengthImpl(first_code_unit);
    }

    /// Convert WTF-16BE code units to WTF-16LE in place.
    pub fn normalizeBe(wtf16be: []u16) void {
        normalizeUtf16Be(wtf16be);
    }

    /// Decode the surrogate pair beginning at `surrogate_pair[0]`.
    pub fn decodePair(surrogate_pair: []const u16) DecodePairError!u21 {
        return utf16DecodeSurrogatePairImpl(surrogate_pair);
    }

    /// Count the number of codepoints in `wtf16le`.
    pub fn countCodepoints(wtf16le: []const u16) usize {
        return wtf16CountCodepointsImpl(wtf16le);
    }

    /// Transcode `wtf16le` into WTF-8, writing into `wtf_8`.
    /// Assumes that `wtf_8` has sufficient capacity.
    pub fn toWtf8(wtf_8: []u8, wtf16le: []const u16) usize {
        return wtf16LeToWtf8Impl(wtf_8, wtf16le);
    }

    /// Return the number of bytes required to transcode `wtf16le` into WTF-8.
    pub fn calcWtf8Len(wtf16le: []const u16) usize {
        return calcWtf8LenImpl(wtf16le);
    }
};

const utf8_lossy = struct {
    /// A "view" into a UTF-8 string using lossy error handling.
    pub const Utf8View = utf8.Utf8View(.lossy);

    /// The strategy for error handling of a given Utf8View.
    pub const ErrorStrategy = utf8.ErrorStrategy;

    /// Wrap a byte slice as a UTF-8 view using lossy error handling.
    pub fn iterator(slice: []const u8) Utf8View {
        return Utf8View.init(slice);
    }

    /// Return the length in bytes of the codepoint beginning with `first_byte`.
    pub fn byteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
        return utf8.byteLength(first_byte);
    }

    /// Decode the codepoint at `slice[0]`, substituting U+FFFD for malformed input.
    /// `slice.len` must not be `0`.
    pub fn decode(slice: []const u8) u21 {
        var cursor: usize = 0;
        return decodeCursor(slice, &cursor);
    }

    /// Decode the codepoint at `slice[cursor.*]`, substituting U+FFFD for malformed input.
    /// The cursor advances to the next possible codepoint, or slice.len.
    pub fn decodeCursor(slice: []const u8, cursor: *usize) u21 {
        return decodeAnyLossyXtf8Cursor(u8dfa, st_dfa, c_mask, slice, cursor);
    }

    /// Return whether `slice` is valid UTF-8.
    pub const validate = utf8.validate;

    /// Return whether `slice` is valid UTF-8.
    /// On success, `cursor` is advanced to `slice.len`. On failure,
    /// it points to the first rejected byte.
    pub const validateCursor = utf8.validateCursor;

    pub const diagnoseError = utfDiagnoseBeforeIndex;

    /// Count the number of codepoints emitted by lossy UTF-8 decoding.
    pub fn countCodepoints(slice: []const u8) usize {
        return countAnyLossyCps(u8dfa, slice);
    }

    /// Transcode `utf_8` into UTF-16LE, substituting U+FFFD for malformed input.
    pub fn toUtf16Le(utf_16: []u16, utf_8: []const u8) usize {
        return utf8_lossy_to_utf16.toUtf16Le(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16BE, substituting U+FFFD for malformed input.
    pub fn toUtf16Be(utf_16: []u16, utf_8: []const u8) usize {
        return utf8_lossy_to_utf16.toUtf16Be(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16LE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    pub fn toUtf16LeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        utf8_lossy_to_utf16.toUtf16LeCursor(utf_16, utf_8, i_16, i_8);
    }

    /// Transcode `utf_8` into UTF-16BE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    pub fn toUtf16BeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        utf8_lossy_to_utf16.toUtf16BeCursor(utf_16, utf_8, i_16, i_8);
    }
};

const wtf8_lossy = struct {
    /// A "view" into a Wtf8 string using lossy error handling.
    pub const Wtf8View = wtf8.Wtf8View(.lossy);

    /// The strategy for error handling of a given Wtf8View.
    pub const ErrorStrategy = wtf8.ErrorStrategy;

    /// Wrap a byte slice as a WTF-8 view using lossy error handling.
    pub fn iterator(slice: []const u8) Wtf8View {
        return Wtf8View.init(slice);
    }

    /// Return the length in bytes of the codepoint beginning with `first_byte`.
    pub fn byteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
        return wtf8.byteLength(first_byte);
    }

    /// Decode the codepoint at `slice[0]`, substituting U+FFFD for malformed input.
    /// `slice.len` must not be `0`.
    pub fn decode(slice: []const u8) u21 {
        var cursor: usize = 0;
        return decodeCursor(slice, &cursor);
    }

    /// Decode the codepoint at `slice[cursor.*]`, substituting U+FFFD for malformed input.
    /// The cursor advances to the next possible codepoint, or slice.len.
    pub fn decodeCursor(slice: []const u8, cursor: *usize) u21 {
        return decodeAnyLossyXtf8Cursor(w8dfa, st_dfa, c_mask, slice, cursor);
    }

    /// Return whether `slice` is valid WTF-8.
    pub const validate = wtf8.validate;

    /// Return whether `slice` is valid WTF-8.
    /// On success, `cursor` is advanced to `slice.len`. On failure,
    /// it points to the first rejected byte.
    pub const validateCursor = wtf8.validateCursor;

    pub const diagnoseError = wtfDiagnoseBeforeIndex;

    /// Count the number of codepoints emitted by lossy WTF-8 decoding.
    pub fn countCodepoints(slice: []const u8) usize {
        return countAnyLossyCps(w8dfa, slice);
    }

    /// Transcode `wtf_8` into WTF-16LE, substituting U+FFFD for malformed input.
    pub fn toWtf16Le(wtf_16: []u16, wtf_8: []const u8) usize {
        return wtf8_lossy_to_wtf16.toWtf16Le(wtf_16, wtf_8);
    }

    /// Transcode `wtf_8` into WTF-16BE, substituting U+FFFD for malformed input.
    pub fn toWtf16Be(wtf_16: []u16, wtf_8: []const u8) usize {
        return wtf8_lossy_to_wtf16.toWtf16Be(wtf_16, wtf_8);
    }

    /// Transcode `wtf_8` into WTF-16LE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    pub fn toWtf16LeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        wtf8_lossy_to_wtf16.toWtf16LeCursor(wtf_16, wtf_8, i_16, i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    pub fn toWtf16BeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        wtf8_lossy_to_wtf16.toWtf16BeCursor(wtf_16, wtf_8, i_16, i_8);
    }
};

const utf8_assume_valid = struct {
    /// A "view" into a Utf8 string assuming valid UTF-8 input.
    pub const Utf8View = utf8.Utf8View(.assume_valid);

    /// The strategy for error handling of a given Utf8View.
    pub const ErrorStrategy = utf8.ErrorStrategy;

    /// Wrap a byte slice as a UTF-8 view assuming valid UTF-8 input.
    /// In .Debug modes, it will also assert this property.
    pub fn iterator(slice: []const u8) Utf8View {
        if (is_debug) {
            assert(utf8.validate(slice));
        }
        return Utf8View.init(slice);
    }

    /// Return the length in bytes of the codepoint beginning with `first_byte`.
    pub fn byteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
        return utf8.byteLength(first_byte);
    }

    /// Decode the codepoint at `slice[0]`.
    /// Assumes that `slice` begins with a valid UTF-8 codepoint.
    pub fn decode(slice: []const u8) u21 {
        return decodeXtf8AssumeValid(slice);
    }

    /// Decode the codepoint at `slice[cursor.*]`.
    /// Assumes that `cursor` points at a valid UTF-8 codepoint.
    pub fn decodeCursor(slice: []const u8, cursor: *usize) u21 {
        return decodeAnyXtf8AssumeValidCursor(u8dfa, c_mask, slice, cursor);
    }

    /// Return whether `slice` is valid UTF-8.
    pub const validate = utf8.validate;

    /// Return whether `slice` is valid UTF-8.
    /// On success, `cursor` is advanced to `slice.len`. On failure,
    /// it points to the first rejected byte.
    pub const validateCursor = utf8.validateCursor;

    /// Count the number of UTF-8 codepoints in `slice`.
    /// Assumes that `slice` is already valid UTF-8.
    pub fn countCodepoints(slice: []const u8) usize {
        return countCodepointsAssumeValid(slice);
    }

    /// Transcode `utf_8` into UTF-16LE, assuming that `utf_8` is already valid UTF-8.
    pub fn toUtf16Le(utf_16: []u16, utf_8: []const u8) usize {
        return utf8_valid_to_utf16.toUtf16Le(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16BE, assuming that `utf_8` is already valid UTF-8.
    pub fn toUtf16Be(utf_16: []u16, utf_8: []const u8) usize {
        return utf8_valid_to_utf16.toUtf16Be(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16LE using explicit source and destination cursors.
    /// Assumes that `utf_8` is already valid UTF-8.
    pub fn toUtf16LeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        utf8_valid_to_utf16.toUtf16LeCursor(utf_16, utf_8, i_16, i_8);
    }

    /// Transcode `utf_8` into UTF-16BE using explicit source and destination cursors.
    /// Assumes that `utf_8` is already valid UTF-8.
    pub fn toUtf16BeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        utf8_valid_to_utf16.toUtf16BeCursor(utf_16, utf_8, i_16, i_8);
    }
};

const wtf8_assume_valid = struct {
    /// A "view" into a Wtf8 string assuming valid WTF-8 input.
    pub const Wtf8View = wtf8.Wtf8View(.assume_valid);

    /// The strategy for error handling of a given Wtf8View.
    pub const ErrorStrategy = wtf8.ErrorStrategy;

    /// Wrap a byte slice as a WTF-8 view assuming valid WTF-8 input.
    /// In .Debug mode this also asserts that validity.
    pub fn iterator(slice: []const u8) Wtf8View {
        if (is_debug) {
            assert(wtf8.validate(slice));
        }
        return Wtf8View.init(slice);
    }

    /// Return the length in bytes of the codepoint beginning with `first_byte`.
    pub fn byteLength(first_byte: u8) u3 {
        return wtf8.byteLength(first_byte) catch {
            return 1;
        };
    }

    /// Decode the codepoint at `slice[0]`.
    /// Assumes that `slice` begins with a valid WTF-8 codepoint.
    pub fn decode(slice: []const u8) u21 {
        var cursor: usize = 0;
        return decodeCursor(slice, &cursor);
    }

    /// Decode the codepoint at `slice[cursor.*]`.
    /// Assumes that `cursor` points at a valid WTF-8 codepoint.
    pub fn decodeCursor(slice: []const u8, cursor: *usize) u21 {
        return decodeAnyXtf8AssumeValidCursor(w8dfa, c_mask, slice, cursor);
    }

    /// Return whether `slice` is valid WTF-8.
    pub const validate = wtf8.validate;

    /// Return whether `slice` is valid WTF-8.
    /// On success, `cursor` is advanced to `slice.len`. On failure,
    /// it points to the first rejected byte.
    pub const validateCursor = wtf8.validateCursor;

    /// Count the number of WTF-8 codepoints in `slice`.
    /// Assumes that `slice` is already valid WTF-8.
    pub fn countCodepoints(slice: []const u8) usize {
        return countCodepointsAssumeValid(slice);
    }

    /// Transcode `wtf_8` into WTF-16LE, assuming that `wtf_8` is already valid WTF-8.
    pub fn toWtf16Le(wtf_16: []u16, wtf_8: []const u8) usize {
        return wtf8_valid_to_wtf16.toWtf16Le(wtf_16, wtf_8);
    }

    /// Transcode `wtf_8` into WTF-16BE, assuming that `wtf_8` is already valid WTF-8.
    pub fn toWtf16Be(wtf_16: []u16, wtf_8: []const u8) usize {
        return wtf8_valid_to_wtf16.toWtf16Be(wtf_16, wtf_8);
    }

    /// Transcode `wtf_8` into WTF-16LE using explicit source and destination cursors.
    /// Assumes that `wtf_8` is already valid WTF-8.
    pub fn toWtf16LeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        wtf8_valid_to_wtf16.toWtf16LeCursor(wtf_16, wtf_8, i_16, i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE using explicit source and destination cursors.
    /// Assumes that `wtf_8` is already valid WTF-8.
    pub fn toWtf16BeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        wtf8_valid_to_wtf16.toWtf16BeCursor(wtf_16, wtf_8, i_16, i_8);
    }
};

const utf8_to_utf16 = struct {
    /// Transcode `utf_8` into UTF-16LE, writing into `utf_16`.
    /// Assumes that `utf_16` has sufficient capacity.
    inline fn toUtf16Le(utf_16: []u16, utf_8: []const u8) utf16.FromUtf8Error!usize {
        return utf8ToUtf16Le(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16BE, writing into `utf_16`.
    /// Assumes that `utf_16` has sufficient capacity.
    inline fn toUtf16Be(utf_16: []u16, utf_8: []const u8) utf16.FromUtf8Error!usize {
        return utf8ToUtf16Be(utf_16, utf_8);
    }

    /// Transcode `utf_8` into UTF-16LE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    inline fn toUtf16LeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) utf16.FromUtf8Error!void {
        return utf8ToUtf16LeCursor(utf_16, utf_8, i_16, i_8);
    }

    /// Transcode `utf_8` into UTF-16BE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    inline fn toUtf16BeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) utf16.FromUtf8Error!void {
        return utf8ToUtf16BeCursor(utf_16, utf_8, i_16, i_8);
    }
};

const wtf8_to_wtf16 = struct {
    /// Transcode `wtf_8` into WTF-16LE, writing into `wtf_16`.
    /// Assumes that `wtf_16` has sufficient capacity.
    inline fn toWtf16Le(wtf_16: []u16, wtf_8: []const u8) wtf16.FromWtf8Error!usize {
        return wtf8ToWtf16Le(wtf_16, wtf_8) catch return error.InvalidWtf8;
    }

    /// Transcode `wtf_8` into WTF-16BE, writing into `wtf_16`.
    /// Assumes that `wtf_16` has sufficient capacity.
    inline fn toWtf16Be(wtf_16: []u16, wtf_8: []const u8) wtf16.FromWtf8Error!usize {
        return wtf8ToWtf16Be(wtf_16, wtf_8) catch return error.InvalidWtf8;
    }

    /// Transcode `wtf_8` into WTF-16LE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    inline fn toWtf16LeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) wtf16.FromWtf8Error!void {
        return wtf8ToWtf16LeCursor(wtf_16, wtf_8, i_16, i_8) catch return error.InvalidWtf8;
    }

    /// Transcode `wtf_8` into WTF-16BE using explicit source and destination cursors.
    /// On failure, `i_16` points one past the last written code unit and `i_8`
    /// points to the first invalid source byte.
    inline fn toWtf16BeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) wtf16.FromWtf8Error!void {
        return wtf8ToWtf16BeCursor(wtf_16, wtf_8, i_16, i_8) catch return error.InvalidWtf8;
    }
};

const utf8_lossy_to_utf16 = struct {
    /// Transcode `utf_8` into UTF-16LE, substituting U+FFFD for malformed input.
    inline fn toUtf16Le(utf_16: []u16, utf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8LossyToXtf16(true, u8dfa, st_dfa, c_mask, utf_16, utf_8, &i_16, &i_8);
    }

    /// Transcode `utf_8` into UTF-16BE, substituting U+FFFD for malformed input.
    inline fn toUtf16Be(utf_16: []u16, utf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8LossyToXtf16(false, u8dfa, st_dfa, c_mask, utf_16, utf_8, &i_16, &i_8);
    }

    /// Transcode `utf_8` into UTF-16LE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    inline fn toUtf16LeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8LossyToXtf16(true, u8dfa, st_dfa, c_mask, utf_16, utf_8, i_16, i_8);
    }

    /// Transcode `utf_8` into UTF-16BE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    inline fn toUtf16BeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8LossyToXtf16(false, u8dfa, st_dfa, c_mask, utf_16, utf_8, i_16, i_8);
    }
};

const wtf8_lossy_to_wtf16 = struct {
    /// Transcode `wtf_8` into WTF-16LE, substituting U+FFFD for malformed input.
    inline fn toWtf16Le(wtf_16: []u16, wtf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8LossyToXtf16(true, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, &i_16, &i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE, substituting U+FFFD for malformed input.
    inline fn toWtf16Be(wtf_16: []u16, wtf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8LossyToXtf16(false, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, &i_16, &i_8);
    }

    /// Transcode `wtf_8` into WTF-16LE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    inline fn toWtf16LeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8LossyToXtf16(true, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, i_16, i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE using explicit source and destination cursors.
    /// Malformed input is replaced with U+FFFD.
    inline fn toWtf16BeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8LossyToXtf16(false, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, i_16, i_8);
    }
};

const utf8_valid_to_utf16 = struct {
    /// Transcode `utf_8` into UTF-16LE, assuming that `utf_8` is already valid UTF-8.
    inline fn toUtf16Le(utf_16: []u16, utf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8AssumeValidToXtf16(true, u8dfa, c_mask, utf_16, utf_8, &i_16, &i_8);
    }

    /// Transcode `utf_8` into UTF-16BE, assuming that `utf_8` is already valid UTF-8.
    inline fn toUtf16Be(utf_16: []u16, utf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8AssumeValidToXtf16(false, u8dfa, c_mask, utf_16, utf_8, &i_16, &i_8);
    }

    /// Transcode `utf_8` into UTF-16LE using explicit source and destination cursors.
    /// Assumes that `utf_8` is already valid UTF-8.
    inline fn toUtf16LeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8AssumeValidToXtf16(true, u8dfa, c_mask, utf_16, utf_8, i_16, i_8);
    }

    /// Transcode `utf_8` into UTF-16BE using explicit source and destination cursors.
    /// Assumes that `utf_8` is already valid UTF-8.
    inline fn toUtf16BeCursor(utf_16: []u16, utf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8AssumeValidToXtf16(false, u8dfa, c_mask, utf_16, utf_8, i_16, i_8);
    }
};

const wtf8_valid_to_wtf16 = struct {
    /// Transcode `wtf_8` into WTF-16LE, assuming that `wtf_8` is already valid WTF-8.
    inline fn toWtf16Le(wtf_16: []u16, wtf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8AssumeValidToXtf16(true, w8dfa, c_mask, wtf_16, wtf_8, &i_16, &i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE, assuming that `wtf_8` is already valid WTF-8.
    inline fn toWtf16Be(wtf_16: []u16, wtf_8: []const u8) usize {
        var i_8: usize = 0;
        var i_16: usize = 0;
        return xtf8AssumeValidToXtf16(false, w8dfa, c_mask, wtf_16, wtf_8, &i_16, &i_8);
    }

    /// Transcode `wtf_8` into WTF-16LE using explicit source and destination cursors.
    /// Assumes that `wtf_8` is already valid WTF-8.
    inline fn toWtf16LeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8AssumeValidToXtf16(true, w8dfa, c_mask, wtf_16, wtf_8, i_16, i_8);
    }

    /// Transcode `wtf_8` into WTF-16BE using explicit source and destination cursors.
    /// Assumes that `wtf_8` is already valid WTF-8.
    inline fn toWtf16BeCursor(wtf_16: []u16, wtf_8: []const u8, i_16: *usize, i_8: *usize) void {
        _ = xtf8AssumeValidToXtf16(false, w8dfa, c_mask, wtf_16, wtf_8, i_16, i_8);
    }
};

/// Diagnose the UTF-8 sequence beginning at `idx` using `std.unicode`.  This
/// will be the cursor location when the baseline / exact library is used.
/// Returns any decoding error that `std.unicode` reports. If `idx` does not
/// index `str`, or if no UTF-8 decoding error is seen at `idx`, returns `void`.
fn utfDiagnoseAtIndex(str: []const u8, idx: usize) Utf8DiagnoseError!void {
    if (idx >= str.len) return;

    const cp_len = try std.unicode.utf8ByteSequenceLength(str[idx]);
    if (idx + cp_len > str.len) return error.TruncatedInput;

    switch (cp_len) {
        1 => return,
        2 => _ = try std.unicode.utf8Decode2(str[idx..][0..2].*),
        3 => _ = try std.unicode.utf8Decode3(str[idx..][0..3].*),
        4 => _ = try std.unicode.utf8Decode4(str[idx..][0..4].*),
        else => unreachable,
    }
}

/// Diagnose the malformed UTF-8 sequence immediately before `idx`.  This is
/// intended for lossy cursors, after they have advanced past a malformed
/// maximal subpart. If no UTF-8 decoding error is found immediately before
/// `idx`, returns `void`.
fn utfDiagnoseBeforeIndex(str: []const u8, idx: usize) Utf8DiagnoseError!void {
    const end = @min(str.len, idx);
    if (end == 0) return;

    const start = end -| 3;
    for (start..end) |i| {
        var cursor = i;
        _ = utf8.lossy.decodeCursor(str, &cursor);
        if (cursor != end) continue;

        utfDiagnoseAtIndex(str, i) catch |err| return err;
        return;
    }
}

/// Diagnose the WTF-8 sequence beginning at `idx` using `std.unicode`.  This
/// will be the cursor location when the baseline / exact library is used.
/// Returns any decoding error that `std.unicode` reports. If `idx` does not
/// index `str`, or if no WTF-8 decoding error is seen at `idx`, returns `void`.
fn wtfDiagnoseAtIndex(str: []const u8, idx: usize) Wtf8DiagnoseError!void {
    if (idx >= str.len) return;

    const cp_len = try std.unicode.utf8ByteSequenceLength(str[idx]);
    if (idx + cp_len > str.len) return error.TruncatedInput;

    switch (cp_len) {
        1 => return,
        2 => _ = try std.unicode.utf8Decode2(str[idx..][0..2].*),
        3 => _ = try std.unicode.utf8Decode3AllowSurrogateHalf(str[idx..][0..3].*),
        4 => _ = try std.unicode.utf8Decode4(str[idx..][0..4].*),
        else => unreachable,
    }
}

/// Diagnose the malformed WTF-8 sequence immediately before `idx`.
/// This is intended for lossy cursors, after they have advanced past a
/// malformed maximal subpart. If no WTF-8 decoding error is found immediately
/// before `idx`, returns `void`.
fn wtfDiagnoseBeforeIndex(str: []const u8, idx: usize) Wtf8DiagnoseError!void {
    const end = @min(str.len, idx);
    if (end == 0) return;

    const start = end -| 3;
    for (start..end) |i| {
        var cursor = i;
        _ = wtf8.lossy.decodeCursor(str, &cursor);
        if (cursor != end) continue;

        wtfDiagnoseAtIndex(str, i) catch |err| return err;
        return;
    }
}

fn Xf8View(comptime xf8_kind: Xf8Kind) fn (comptime ErrorStrategyKind) type {
    const byte_dfa = switch (xf8_kind) {
        .utf8 => u8dfa,
        .wtf8 => w8dfa,
    };
    const invalid_error = switch (xf8_kind) {
        .utf8 => error.InvalidUtf8,
        .wtf8 => error.InvalidWtf8,
    };
    const exact_diagnose = switch (xf8_kind) {
        .utf8 => utfDiagnoseAtIndex,
        .wtf8 => wtfDiagnoseAtIndex,
    };
    const lossy_diagnose = switch (xf8_kind) {
        .utf8 => utfDiagnoseBeforeIndex,
        .wtf8 => wtfDiagnoseBeforeIndex,
    };

    return struct {
        fn view(comptime strategy: ErrorStrategyKind) type {
            return Xf8ViewImpl(strategy, byte_dfa, invalid_error, exact_diagnose, lossy_diagnose);
        }
    }.view;
}

fn Xf8ViewImpl(
    comptime strategy: ErrorStrategyKind,
    comptime byte_dfa: anytype,
    comptime invalid_error: anytype,
    comptime exact_diagnose: anytype,
    comptime lossy_diagnose: anytype,
) type {
    return switch (strategy) {
        .exact => ExactCpIteratorImpl(byte_dfa, invalid_error, exact_diagnose),
        .lossy => LossyCpIteratorImpl(byte_dfa, lossy_diagnose),
        .assume_valid => AssumeValidCpIteratorImpl(byte_dfa, c_mask),
    };
}

fn xtf8CodepointWidth(c: u21) error{CodepointTooLarge}!u3 {
    if (c < 0x80) return @as(u3, 1);
    if (c < 0x800) return @as(u3, 2);
    if (c < 0x10000) return @as(u3, 3);
    if (c < 0x110000) return @as(u3, 4);
    return error.CodepointTooLarge;
}

fn utf8ByteLength(first_byte: u8) error{Utf8InvalidStartByte}!u3 {
    return switch (first_byte) {
        0b0000_0000...0b0111_1111 => 1,
        0b1100_0000...0b1101_1111 => 2,
        0b1110_0000...0b1110_1111 => 3,
        0b1111_0000...0b1111_0111 => 4,
        else => error.Utf8InvalidStartByte,
    };
}

fn xtf8Encode(c: u21, out: []u8, comptime surrogates: Surrogates) !u3 {
    const length = try xtf8CodepointWidth(c);
    assert(out.len >= length);
    switch (length) {
        1 => out[0] = @as(u8, @intCast(c)),
        2 => {
            out[0] = @as(u8, @intCast(0b1100_0000 | (c >> 6)));
            out[1] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        3 => {
            if (surrogates == .no_surrogate and isSurrogateImpl(c)) {
                return error.Utf8CannotEncodeSurrogateHalf;
            }
            out[0] = @as(u8, @intCast(0b1110_0000 | (c >> 12)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((c >> 6) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        4 => {
            out[0] = @as(u8, @intCast(0b1111_0000 | (c >> 18)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((c >> 12) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | ((c >> 6) & 0b0011_1111)));
            out[3] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        else => unreachable,
    }
    return length;
}

fn xtf16Encode(c: u21, out: []u16, comptime surrogates: Surrogates) !u2 {
    const length = try utf16CodepointSequenceLengthImpl(c);
    assert(out.len >= length);
    switch (length) {
        1 => {
            if (surrogates == .no_surrogate and isSurrogateImpl(c)) {
                return error.Utf16CannotEncodeSurrogateHalf;
            }
            out[0] = @intCast(c);
        },
        2 => {
            const cp = c - 0x10000;
            out[0] = @as(u16, @intCast(0xD800 + (cp >> 10)));
            out[1] = @as(u16, @intCast(0xDC00 + (cp & 0x03FF)));
        },
        else => unreachable,
    }
    return length;
}

fn isSurrogateImpl(c: u21) bool {
    return switch (c) {
        0xD800...0xDFFF => true,
        else => false,
    };
}

fn utf8ValidCodepoint(value: u21) bool {
    return switch (value) {
        0xD800...0xDFFF => false,
        0x110000...0x1FFFFF => false,
        else => true,
    };
}

fn wtf8ValidCodepoint(value: u21) bool {
    return switch (value) {
        0x110000...0x1FFFFF => false,
        else => true,
    };
}

fn utf16IsHighSurrogateImpl(c: u16) bool {
    return c & ~@as(u16, 0x03FF) == 0xD800;
}

fn utf16IsLowSurrogateImpl(c: u16) bool {
    return c & ~@as(u16, 0x03FF) == 0xDC00;
}

fn utf16CodepointSequenceLengthImpl(c: u21) error{CodepointTooLarge}!u2 {
    if (c <= 0xFFFF) return 1;
    if (c <= 0x10FFFF) return 2;
    return error.CodepointTooLarge;
}

fn utf16CodeUnitSequenceLengthImpl(first_code_unit: u16) error{Utf16InvalidStartCodeUnit}!u2 {
    if (utf16IsHighSurrogateImpl(first_code_unit)) return 2;
    if (utf16IsLowSurrogateImpl(first_code_unit)) return error.Utf16InvalidStartCodeUnit;
    return 1;
}

const Utf16DecodePairError = error{
    MissingSecondCodeUnit,
    ExpectedFirstSurrogateHalf,
    ExpectedSecondSurrogateHalf,
};

fn utf16DecodeCheckedSurrogatePairImpl(high_half: u16, low_half: u16) error{ExpectedSecondSurrogateHalf}!u21 {
    if (!utf16IsLowSurrogateImpl(low_half)) return error.ExpectedSecondSurrogateHalf;
    const high_half_u21: u21 = high_half;
    const low_half_u21: u21 = low_half;
    return 0x10000 + ((high_half_u21 & 0x03FF) << 10) | (low_half_u21 & 0x03FF);
}

fn utf16DecodeSurrogatePairImpl(surrogate_pair: []const u16) Utf16DecodePairError!u21 {
    if (surrogate_pair.len < 2) return error.MissingSecondCodeUnit;
    const high_half = surrogate_pair[0];
    if (!utf16IsHighSurrogateImpl(high_half)) return error.ExpectedFirstSurrogateHalf;
    const low_half = surrogate_pair[1];
    return utf16DecodeCheckedSurrogatePairImpl(high_half, low_half);
}

fn Utf16LeIteratorImpl() type {
    return struct {
        bytes: []const u8,
        i: usize,

        pub const NextCodepointError = error{
            DanglingSurrogateHalf,
            ExpectedSecondSurrogateHalf,
            UnexpectedSecondSurrogateHalf,
        };

        pub fn init(s: []const u16) @This() {
            return .{
                .bytes = std.mem.sliceAsBytes(s),
                .i = 0,
            };
        }

        pub fn nextCodepoint(iter: *@This()) NextCodepointError!?u21 {
            assert(iter.i <= iter.bytes.len);
            if (iter.i == iter.bytes.len) return null;
            var code_units: [2]u16 = undefined;
            code_units[0] = std.mem.readInt(u16, iter.bytes[iter.i..][0..2], .little);
            iter.i += 2;
            if (utf16IsHighSurrogateImpl(code_units[0])) {
                if (iter.i >= iter.bytes.len) return error.DanglingSurrogateHalf;
                code_units[1] = std.mem.readInt(u16, iter.bytes[iter.i..][0..2], .little);
                const cp = try utf16DecodeCheckedSurrogatePairImpl(code_units[0], code_units[1]);
                iter.i += 2;
                return cp;
            } else if (utf16IsLowSurrogateImpl(code_units[0])) {
                return error.UnexpectedSecondSurrogateHalf;
            } else {
                return code_units[0];
            }
        }
    };
}

fn Wtf16LeIteratorImpl() type {
    return struct {
        bytes: []const u8,
        i: usize,

        pub fn init(s: []const u16) @This() {
            return .{
                .bytes = std.mem.sliceAsBytes(s),
                .i = 0,
            };
        }

        pub fn nextCodepoint(iter: *@This()) ?u21 {
            assert(iter.i <= iter.bytes.len);
            if (iter.i == iter.bytes.len) return null;
            var code_units: [2]u16 = undefined;
            code_units[0] = std.mem.readInt(u16, iter.bytes[iter.i..][0..2], .little);
            iter.i += 2;
            surrogate_pair: {
                if (utf16IsHighSurrogateImpl(code_units[0])) {
                    if (iter.i >= iter.bytes.len) break :surrogate_pair;
                    code_units[1] = std.mem.readInt(u16, iter.bytes[iter.i..][0..2], .little);
                    const cp = utf16DecodeCheckedSurrogatePairImpl(code_units[0], code_units[1]) catch break :surrogate_pair;
                    iter.i += 2;
                    return cp;
                }
            }
            return code_units[0];
        }
    };
}

fn utf16CountCodepointsImpl(utf16le: []const u16) Utf16LeIteratorImpl().NextCodepointError!usize {
    var len: usize = 0;
    var iter = Utf16LeIteratorImpl().init(utf16le);
    while (try iter.nextCodepoint()) |_| len += 1;
    return len;
}

fn wtf16CountCodepointsImpl(wtf16le: []const u16) usize {
    var len: usize = 0;
    var iter = Wtf16LeIteratorImpl().init(wtf16le);
    while (iter.nextCodepoint()) |_| len += 1;
    return len;
}

fn utf16LeToUtf8Impl(utf_8: []u8, utf16le: []const u16) !usize {
    var dest_i: usize = 0;
    var iter = Utf16LeIteratorImpl().init(utf16le);
    while (try iter.nextCodepoint()) |cp| {
        dest_i += try xtf8Encode(cp, utf_8[dest_i..], .no_surrogate);
    }
    return dest_i;
}

fn wtf16LeToWtf8Impl(wtf_8: []u8, wtf16le: []const u16) usize {
    var dest_i: usize = 0;
    var iter = Wtf16LeIteratorImpl().init(wtf16le);
    while (iter.nextCodepoint()) |cp| {
        dest_i += encodeWtf8FromWtf16(cp, wtf_8[dest_i..]);
    }
    return dest_i;
}

fn calcWtf8LenImpl(wtf16le: []const u16) usize {
    var iter = Wtf16LeIteratorImpl().init(wtf16le);
    var len: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        len += wtf8WidthFromWtf16(cp);
    }
    return len;
}

fn calcUtf8LenImpl(utf16le: []const u16) Utf16LeIteratorImpl().NextCodepointError!usize {
    var iter = Utf16LeIteratorImpl().init(utf16le);
    var len: usize = 0;
    while (try iter.nextCodepoint()) |cp| {
        len += utf8WidthFromUtf16(cp);
    }
    return len;
}

fn utf8WidthFromUtf16(cp: u21) usize {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

fn wtf8WidthFromWtf16(cp: u21) usize {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

fn encodeWtf8FromWtf16(cp: u21, out: []u8) usize {
    const len = wtf8WidthFromWtf16(cp);
    assert(out.len >= len);
    switch (len) {
        1 => out[0] = @as(u8, @intCast(cp)),
        2 => {
            out[0] = @as(u8, @intCast(0b1100_0000 | (cp >> 6)));
            out[1] = @as(u8, @intCast(0b1000_0000 | (cp & 0b0011_1111)));
        },
        3 => {
            out[0] = @as(u8, @intCast(0b1110_0000 | (cp >> 12)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((cp >> 6) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | (cp & 0b0011_1111)));
        },
        4 => {
            out[0] = @as(u8, @intCast(0b1111_0000 | (cp >> 18)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((cp >> 12) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | ((cp >> 6) & 0b0011_1111)));
            out[3] = @as(u8, @intCast(0b1000_0000 | (cp & 0b0011_1111)));
        },
        else => unreachable,
    }
    return len;
}

fn calcUtf16LeLenXtf8(utf_8: []const u8) !usize {
    var cursor: usize = 0;
    var len: usize = 0;
    while (cursor < utf_8.len) {
        const cp = try decodeUtf8Cursor(utf_8, &cursor);
        len += if (cp < 0x10000) 1 else 2;
    }
    return len;
}

fn calcWtf16LeLenXtf8(wtf_8: []const u8) !usize {
    var cursor: usize = 0;
    var len: usize = 0;
    while (cursor < wtf_8.len) {
        const cp = try wtf8.decodeCursor(wtf_8, &cursor);
        len += if (cp < 0x10000) 1 else 2;
    }
    return len;
}

// NOTE: We'll expose this later
//
/// Count codepoints in a slice that is already known to be valid UTF-8 or WTF-8.
fn countCodepointsAssumeValid(slice: []const u8) usize {
    return countValidXtf8(slice);
}

/// Decode the codepoint at `slice[0]`.  Assumes that `slice.len > 0`.
fn decodeUtf8(slice: []const u8) !u21 {
    var cursor: usize = 0;
    return decodeUtf8Cursor(slice, &cursor);
}

/// Decode the codepoint at `slice[0]`. Assumes that `slice` begins with
/// a valid UTF-8 codepoint and that any multibyte sequence is not truncated.
fn decodeXtf8AssumeValid(slice: []const u8) u21 {
    var cursor: usize = 0;
    return decodeAnyXtf8AssumeValidCursor(u8dfa, c_mask, slice, &cursor);
}

/// Decode the codepoint at `slice[cursor.*]`.  The cursor will be advanced to
/// one index past the decoded codepoint, which may include `slice.len`.  If
/// an error is thrown the cursor will point to the first invalid byte
/// in the sequence.  Asserts that `slice` is indexable at `cursor.*`.
fn decodeUtf8Cursor(slice: []const u8, cursor: *usize) !u21 {
    return decodeAnyXtf8Cursor(u8dfa, st_dfa, c_mask, slice, cursor);
}

fn decodeAnyXtf8Cursor(
    cu_dfa: anytype,
    state_dfa: anytype,
    class_mask: anytype,
    slice: []const u8,
    i: *usize,
) !u21 {
    assert(i.* < slice.len);
    var byte: u16 = slice[i.*];
    if (byte < 0x80) {
        i.* += 1;
        return byte;
    }
    // Multibyte
    var class: u4 = @intCast(cu_dfa[byte]);
    var st: u32 = state_dfa[class];
    var cp: u32 = byte & class_mask[class];
    if (st == UTF_REJECT) return error.InvalidUtf8;
    i.* += 1;
    switch (class) {
        2, 12 => if (i.* + 1 > slice.len) {
            return error.InvalidUtf8;
        },
        10, 3, 4 => if (i.* + 2 > slice.len) {
            return error.InvalidUtf8;
        },
        11, 6, 5 => if (i.* + 3 > slice.len) {
            return error.InvalidUtf8;
        }, // Remaining states are ACCEPT or produce REJECT here
        else => unreachable,
    }
    // Byte 2
    byte = slice[i.*];
    class = @intCast(cu_dfa[byte]);
    st = state_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    if (st == UTF_REJECT) return error.InvalidUtf8;
    i.* += 1;
    if (st == UTF_ACCEPT) return @intCast(cp);
    // Byte 3
    byte = slice[i.*];
    class = @intCast(cu_dfa[byte]);
    st = state_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    if (st == UTF_REJECT) return error.InvalidUtf8;
    i.* += 1;
    if (st == UTF_ACCEPT) return @intCast(cp);
    // Byte 4
    byte = slice[i.*];
    class = @intCast(cu_dfa[byte]);
    st = state_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    if (st != UTF_ACCEPT) return error.InvalidUtf8;
    i.* += 1;
    return @intCast(cp);
}

fn decodeAnyXtf8AssumeValidCursor(
    cu_dfa: anytype,
    class_mask: anytype,
    slice: []const u8,
    i: *usize,
) u21 {
    // NOTE: I think the ASCII check is still an optimization
    // here, but we should test that assumption.
    var byte: u16 = slice[i.*];
    i.* += 1;
    if (byte < 0x80) return byte;
    var class: u4 = @intCast(cu_dfa[byte]);
    var st: u32 = st_dfa[class];
    var cp: u32 = byte & class_mask[class];
    byte = slice[i.*];
    class = @intCast(cu_dfa[byte]);
    st = st_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    i.* += 1;
    if (st == UTF_ACCEPT) {
        return @intCast(cp);
    }
    byte = slice[i.*];
    class = @intCast(cu_dfa[byte]);
    st = st_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    i.* += 1;
    if (st == UTF_ACCEPT) {
        return @intCast(cp);
    }
    byte = slice[i.*];
    cp = (byte & 0x3f) | (cp << 6);
    i.* += 1;
    return @intCast(cp);
}

fn decodeAnyLossyXtf8Cursor(
    cu_dfa: anytype,
    state_dfa: anytype,
    class_mask: anytype,
    slice: []const u8,
    cursor: *usize,
) u21 {
    assert(cursor.* < slice.len);

    const this_off = cursor.*;
    cursor.* += 1;

    var byte = slice[this_off];
    if (byte < 0x80) return byte;

    var class: u4 = @intCast(cu_dfa[byte]);
    var st: u32 = state_dfa[class];
    if (st == UTF_REJECT or cursor.* == slice.len) {
        @branchHint(.cold);
        return 0xfffd;
    }
    var cp: u32 = byte & class_mask[class];
    byte = slice[cursor.*];
    class = @intCast(cu_dfa[byte]);
    st = state_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    cursor.* += 1;
    if (st == UTF_ACCEPT) {
        return @intCast(cp);
    }
    if (st == UTF_REJECT or cursor.* == slice.len) {
        @branchHint(.cold);
        cursor.* -= @intFromBool(st == UTF_REJECT);
        return 0xfffd;
    }

    byte = slice[cursor.*];
    class = @intCast(cu_dfa[byte]);
    st = state_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    cursor.* += 1;
    if (st == UTF_ACCEPT) {
        return @intCast(cp);
    }
    if (st == UTF_REJECT or cursor.* == slice.len) {
        @branchHint(.cold);
        cursor.* -= @intFromBool(st == UTF_REJECT);
        return 0xfffd;
    }

    byte = slice[cursor.*];
    class = @intCast(cu_dfa[byte]);
    st = state_dfa[st + class];
    cp = (byte & 0x3f) | (cp << 6);
    cursor.* += 1;
    if (st == UTF_REJECT) {
        @branchHint(.cold);
        cursor.* -= 1;
        return 0xfffd;
    }
    assert(st == UTF_ACCEPT);
    return @intCast(cp);
}

fn ExactCpIteratorImpl(comptime cu_dfa: anytype, comptime invalid_error: anytype, comptime diagnose_error: anytype) type {
    return struct {
        bytes: []const u8,
        i: usize = 0,

        pub fn init(slice: []const u8) @This() {
            return .{ .bytes = slice };
        }

        /// Return the next codepoint, or `null` at end of input.
        pub fn nextCodepoint(iter: *@This()) @TypeOf(invalid_error)!?u21 {
            if (iter.i >= iter.bytes.len) return null;
            return decodeAnyXtf8Cursor(cu_dfa, st_dfa, c_mask, iter.bytes, &iter.i) catch {
                return invalid_error;
            };
        }

        /// Return the byte slice for the next codepoint, or `null` at end of input.
        pub fn nextCodepointSlice(iter: *@This()) @TypeOf(invalid_error)!?[]const u8 {
            if (iter.i >= iter.bytes.len) return null;
            const start = iter.i;
            _ = decodeAnyXtf8Cursor(cu_dfa, st_dfa, c_mask, iter.bytes, &iter.i) catch {
                return invalid_error;
            };
            return iter.bytes[start..iter.i];
        }

        /// Look ahead at the next `n` codepoints without advancing the iterator.
        /// If fewer than `n` codepoints remain, return the remainder of the slice.
        pub fn peek(iter: *@This(), n: usize) @TypeOf(invalid_error)![]const u8 {
            var remaining = n;
            var i = iter.i;
            while (remaining > 0 and i < iter.bytes.len) : (remaining -= 1) {
                _ = decodeAnyXtf8Cursor(cu_dfa, st_dfa, c_mask, iter.bytes, &i) catch {
                    return invalid_error;
                };
            }
            return iter.bytes[iter.i..i];
        }

        pub fn diagnoseError(iter: *@This()) @TypeOf(diagnose_error("", 0)) {
            return diagnose_error(iter.bytes, iter.i);
        }
    };
}

fn LossyCpIteratorImpl(comptime cu_dfa: anytype, comptime diagnose_error: anytype) type {
    return struct {
        bytes: []const u8,
        i: usize = 0,

        pub fn init(slice: []const u8) @This() {
            return .{ .bytes = slice };
        }

        /// Return the next codepoint, substituting U+FFFD for malformed input.
        pub fn nextCodepoint(iter: *@This()) ?u21 {
            if (iter.i >= iter.bytes.len) return null;
            return decodeAnyLossyXtf8Cursor(cu_dfa, st_dfa, c_mask, iter.bytes, &iter.i);
        }

        /// Return the byte slice consumed for the next codepoint or maximal subpart.
        pub fn nextCodepointSlice(iter: *@This()) ?[]const u8 {
            if (iter.i >= iter.bytes.len) return null;
            const start = iter.i;
            if (decodeAnyLossyXtf8Cursor(cu_dfa, st_dfa, c_mask, iter.bytes, &iter.i) == '\u{fffd}') {
                return &utf8_uffd;
            }
            return iter.bytes[start..iter.i];
        }

        /// Look ahead at the next codepoint without advancing the iterator.
        pub fn peek(iter: *@This()) []const u8 {
            const this_i = iter.i;
            defer iter.i = this_i;
            return iter.nextCodepointSlice() orelse return "";
        }

        pub fn diagnoseError(iter: *@This()) @TypeOf(diagnose_error("", 0)) {
            return diagnose_error(iter.bytes, iter.i);
        }
    };
}

fn AssumeValidCpIteratorImpl(comptime cu_dfa: anytype, comptime class_mask: anytype) type {
    return struct {
        bytes: []const u8,
        i: usize = 0,

        pub fn init(slice: []const u8) @This() {
            return .{ .bytes = slice };
        }

        /// Return the next codepoint, assuming the remaining input is valid.
        pub fn nextCodepoint(iter: *@This()) ?u21 {
            if (iter.i >= iter.bytes.len) return null;
            return decodeAnyXtf8AssumeValidCursor(cu_dfa, class_mask, iter.bytes, &iter.i);
        }

        /// Return the byte slice for the next codepoint, assuming the
        /// remaining input is valid.
        pub fn nextCodepointSlice(iter: *@This()) ?[]const u8 {
            if (iter.i >= iter.bytes.len) return null;
            const start = iter.i;
            iter.i += xtf8CpLengthAssumeValid(iter.bytes[iter.i]);
            return iter.bytes[start..iter.i];
        }

        /// Look ahead at the next `n` codepoints without advancing the iterator.
        pub fn peek(iter: *@This(), n: usize) []const u8 {
            var remaining = n;
            var i = iter.i;
            while (remaining > 0 and i < iter.bytes.len) : (remaining -= 1) {
                i += xtf8CpLengthAssumeValid(iter.bytes[i]);
            }
            return iter.bytes[iter.i..i];
        }
    };
}

fn xtf8CpLengthAssumeValid(byte: u8) usize {
    return switch (byte) {
        0...0x7f => 1,
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => unreachable,
    };
}

fn countAnyLossyCps(cu_dfa: anytype, slice: []const u8) usize {
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < slice.len) {
        _ = decodeAnyLossyXtf8Cursor(cu_dfa, st_dfa, c_mask, slice, &cursor);
        count += 1;
    }
    return count;
}

fn countUtf8(slice: []const u8) !usize {
    return countAnyXtf8(u8dfa, st_dfa, slice);
}

fn countWtf8(slice: []const u8) !usize {
    return countAnyXtf8(w8dfa, st_dfa, slice);
}

fn countAnyXtf8(cu_dfa: anytype, state_dfa: anytype, slice: []const u8) !usize {
    var st: u32 = 0;
    var i: usize = 0;
    var class: u8 = 0;
    var count: usize = 0;
    while (i < slice.len) : (i += 1) {
        assert(st == UTF_ACCEPT);
        count += 1;
        const b = slice[i];
        if (b < 0x80) continue;
        class = cu_dfa[b];
        st = state_dfa[class];
        if (st == UTF_REJECT) return error.InvalidUtf8;
        switch (class) {
            2, 12 => if (i + 2 > slice.len) {
                return error.InvalidUtf8;
            },
            10, 3, 4 => if (i + 3 > slice.len) {
                return error.InvalidUtf8;
            },
            11, 6, 5 => if (i + 4 > slice.len) {
                return error.InvalidUtf8;
            }, // Remaining states are ACCEPT or produce REJECT here
            else => unreachable,
        }
        i += 1;
        st = state_dfa[st + cu_dfa[slice[i]]];
        if (st == UTF_ACCEPT) continue;
        if (st == UTF_REJECT) return error.InvalidUtf8;
        i += 1;
        st = state_dfa[st + cu_dfa[slice[i]]];
        if (st == UTF_ACCEPT) continue;
        if (st == UTF_REJECT) return error.InvalidUtf8;
        i += 1;
        st = state_dfa[st + cu_dfa[slice[i]]];
        if (st == UTF_REJECT) return error.InvalidUtf8;
    }
    return count;
}

const weight: [4]u8 = .{ 1, 1, 0, 1 };

/// Count the number of codepoints in an assumed-valid slice.  This gives correct
/// answers for either of WTF-8 or UTF-8, provided that the string is valid by
/// either standard.  Invalid data will give a spurious answer, but is otherwise
/// safe to provide.
fn countValidXtf8(slice: []const u8) usize {
    var c: usize = 0;
    for (slice) |b| {
        c += weight[b >> 6];
    }
    return c;
}

/// Validate that a slice is composed only of valid codepoints in the
/// UTF-8 encoding.
fn validateUtf8(slice: []const u8) bool {
    var i: usize = 0;
    return validateAnyXtf8WithCursor(u8dfa, st_dfa, slice, &i);
}

/// Validate that a slice is composed only of valid codepoints in the
/// WTF-8 encoding.
fn validateWtf8(slice: []const u8) bool {
    var i: usize = 0;
    return validateAnyXtf8WithCursor(w8dfa, st_dfa, slice, &i);
}

/// UTF-8 encoding.  Must be passed a cursor, by pointer: this
/// will point to slice.len when the return value is `true`, and
/// to the first rejected byte when `false`.
fn validateUtf8Cursor(slice: []const u8, i: *usize) bool {
    return validateAnyXtf8WithCursor(u8dfa, st_dfa, slice, i);
}

/// Validate that a slice is composed only of valid runes in the
/// WTF-8 encoding.  Must be passed a cursor, by pointer: this
/// will point to slice.len when the return value is `true`, and
/// to the first rejected byte when `false`.
fn validateWtf8Cursor(slice: []const u8, i: *usize) bool {
    return validateAnyXtf8WithCursor(w8dfa, st_dfa, slice, i);
}

fn validateAnyXtf8WithCursor(
    cu_dfa: anytype,
    state_dfa: anytype,
    slice: []const u8,
    i: *usize,
) bool {
    var st: u32 = 0;
    var class: u8 = 0;
    while (i.* < slice.len) : (i.* += 1) {
        assert(st == UTF_ACCEPT);
        const b = slice[i.*];
        if (b < 0x80) continue;
        class = cu_dfa[b];
        st = state_dfa[class];
        if (st == UTF_REJECT) return false;
        switch (class) {
            0, 1 => unreachable,
            2, 12 => if (i.* + 2 > slice.len) {
                return false;
            },
            10, 3, 4 => if (i.* + 3 > slice.len) {
                return false;
            },
            11, 6, 5 => if (i.* + 4 > slice.len) {
                return false;
            },
            else => unreachable,
        }
        i.* += 1;
        st = state_dfa[st + cu_dfa[slice[i.*]]];
        if (st == UTF_ACCEPT) continue;
        if (st == UTF_REJECT) return false;
        i.* += 1;
        st = state_dfa[st + cu_dfa[slice[i.*]]];
        if (st == UTF_ACCEPT) continue;
        if (st == UTF_REJECT) return false;
        i.* += 1;
        st = state_dfa[st + cu_dfa[slice[i.*]]];
        if (st == UTF_REJECT) return false;
    }
    return true;
}

/// Transcode utf_8 source into utf_16 destination, returning the
/// length of a slice of utf_16 containing the transcoded points.
/// Assumes that the destination has sufficient room for the transcoding.
fn utf8ToUtf16Le(utf_16: []u16, utf_8: []const u8) !usize {
    var i_8: usize = 0;
    var i_16: usize = 0;
    return xtf8ToXtf16(true, u8dfa, st_dfa, c_mask, utf_16, utf_8, &i_16, &i_8);
}

/// Transcode utf_8 source into utf_16 destination, returning the
/// length of a slice of utf_16 containing the transcoded points.
/// Assumes that the destination has sufficient room for the transcoding.
fn utf8ToUtf16Be(utf_16: []u16, utf_8: []const u8) !usize {
    var i_8: usize = 0;
    var i_16: usize = 0;
    return xtf8ToXtf16(false, u8dfa, st_dfa, c_mask, utf_16, utf_8, &i_16, &i_8);
}

/// Transcode utf_8 source into utf_16 destination Assumes that the
/// destination has sufficient room for the transcoding.
/// Takes two cursors: if an error is thrown, the i_16 cursor points to
/// the index past the last transcoded point, and the i_8 cursor points to
/// the source of the error.  Success means that i_16 points to the point
/// in utf_16 which may be sliced to obtain the result.
fn utf8ToUtf16LeCursor(
    utf_16: []u16,
    utf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) !void {
    _ = try xtf8ToXtf16(true, u8dfa, st_dfa, c_mask, utf_16, utf_8, i_16, i_8);
}

/// Transcode utf_8 source into utf_16 destination Assumes that the
/// destination has sufficient room for the transcoding.
/// Takes two cursors: if an error is thrown, the i_16 cursor points to
/// the index past the last transcoded point, and the i_8 cursor points to
/// the source of the error.  Success means that i_16 points to the point
/// in utf_16 which may be sliced to obtain the result.
fn utf8ToUtf16BeCursor(
    utf_16: []u16,
    utf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) !void {
    _ = try xtf8ToXtf16(false, u8dfa, st_dfa, c_mask, utf_16, utf_8, i_16, i_8);
}

fn normalizeUtf16Be(utf_16be: []u16) void {
    for (utf_16be) |*code_unit| {
        code_unit.* = @byteSwap(code_unit.*);
    }
}

/// Transcode wtf_8 source into wtf_16 destination, returning the
/// length of a slice of wtf_16 containing the transcoded points.
/// Assumes that the destination has sufficient room for the transcoding.
fn wtf8ToWtf16Le(wtf_16: []u16, wtf_8: []const u8) !usize {
    var i_8: usize = 0;
    var i_16: usize = 0;
    return xtf8ToXtf16(true, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, &i_16, &i_8);
}

/// Transcode wtf_8 source into wtf_16 destination, returning the
/// length of a slice of wtf_16 containing the transcoded points.
/// Assumes that the destination has sufficient room for the transcoding.
fn wtf8ToWtf16Be(wtf_16: []u16, wtf_8: []const u8) !usize {
    var i_8: usize = 0;
    var i_16: usize = 0;
    return xtf8ToXtf16(false, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, &i_16, &i_8);
}

/// Transcode wtf_8 source into wtf_16 destination.  Assumes that the
/// destination has sufficient room for the transcoding.
/// Takes two cursors: if an error is thrown, the i_16 cursor points to
/// the index past the last transcoded point, and the i_8 cursor points to
/// the source of the error.  Success means that i_16 points to the point
/// in wtf_16 which may be sliced to obtain the result.
fn wtf8ToWtf16LeCursor(
    wtf_16: []u16,
    wtf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) !void {
    _ = try xtf8ToXtf16(true, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, i_16, i_8);
}

/// Transcode wtf_8 source into wtf_16 destination.  Assumes that the
/// destination has sufficient room for the transcoding.
/// Takes two cursors: if an error is thrown, the i_16 cursor points to
/// the index past the last transcoded point, and the i_8 cursor points to
/// the source of the error.  Success means that i_16 points to the point
/// in wtf_16 which may be sliced to obtain the result.
fn wtf8ToWtf16BeCursor(
    wtf_16: []u16,
    wtf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) !void {
    _ = try xtf8ToXtf16(false, w8dfa, st_dfa, c_mask, wtf_16, wtf_8, i_16, i_8);
}

fn xtf8ToXtf16(
    comptime little_endian: bool,
    cu_dfa: anytype,
    state_dfa: anytype,
    class_mask: anytype,
    utf_16: []u16,
    utf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) !usize {
    const nativeToEndian = if (little_endian)
        std.mem.nativeToLittle
    else
        std.mem.nativeToBig;
    var st: u32 = 0;
    var cp: u32 = 0;
    while (i_8.* < utf_8.len) : (i_8.* += 1) {
        const b = utf_8[i_8.*];
        if (st == UTF_ACCEPT) {
            if (b < 0x80) {
                utf_16[i_16.*] = nativeToEndian(u16, b);
                i_16.* += 1;
            } else {
                const class = cu_dfa[b];
                st = state_dfa[class];
                cp = b & class_mask[class];
            }
            continue;
        }
        st = state_dfa[st + cu_dfa[b]];
        cp = (b & 0x3f) | (cp << 6);
        if (st == UTF_REJECT) {
            @branchHint(.cold);
            return error.InvalidUtf8;
        } else if (st == UTF_ACCEPT) {
            if (cp < 0x10000) {
                utf_16[i_16.*] = nativeToEndian(u16, @intCast(cp));
                i_16.* += 1;
            } else {
                const high = @as(u16, @intCast((cp - 0x10000) >> 10)) + 0xD800;
                const low = @as(u16, @intCast(cp & 0x3FF)) + 0xDC00;
                utf_16[i_16.*] = nativeToEndian(u16, high);
                i_16.* += 1;
                utf_16[i_16.*] = nativeToEndian(u16, low);
                i_16.* += 1;
            }
        }
    }
    return i_16.*;
}

fn xtf8LossyToXtf16(
    comptime little_endian: bool,
    cu_dfa: anytype,
    state_dfa: anytype,
    class_mask: anytype,
    utf_16: []u16,
    utf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) usize {
    _ = state_dfa;
    _ = class_mask;
    const nativeToEndian = if (little_endian)
        std.mem.nativeToLittle
    else
        std.mem.nativeToBig;

    while (i_8.* < utf_8.len) {
        const cp = decodeAnyLossyXtf8Cursor(cu_dfa, st_dfa, c_mask, utf_8, i_8);
        if (cp < 0x10000) {
            utf_16[i_16.*] = nativeToEndian(u16, @intCast(cp));
            i_16.* += 1;
        } else {
            const high = @as(u16, @intCast((cp - 0x10000) >> 10)) + 0xD800;
            const low = @as(u16, @intCast(cp & 0x3FF)) + 0xDC00;
            utf_16[i_16.*] = nativeToEndian(u16, high);
            i_16.* += 1;
            utf_16[i_16.*] = nativeToEndian(u16, low);
            i_16.* += 1;
        }
    }
    return i_16.*;
}

fn xtf8AssumeValidToXtf16(
    comptime little_endian: bool,
    cu_dfa: anytype,
    class_mask: anytype,
    utf_16: []u16,
    utf_8: []const u8,
    i_16: *usize,
    i_8: *usize,
) usize {
    const nativeToEndian = if (little_endian)
        std.mem.nativeToLittle
    else
        std.mem.nativeToBig;

    while (i_8.* < utf_8.len) {
        const cp = decodeAnyXtf8AssumeValidCursor(cu_dfa, class_mask, utf_8, i_8);
        if (cp < 0x10000) {
            utf_16[i_16.*] = nativeToEndian(u16, @intCast(cp));
            i_16.* += 1;
        } else {
            const high = @as(u16, @intCast((cp - 0x10000) >> 10)) + 0xD800;
            const low = @as(u16, @intCast(cp & 0x3FF)) + 0xDC00;
            utf_16[i_16.*] = nativeToEndian(u16, high);
            i_16.* += 1;
            utf_16[i_16.*] = nativeToEndian(u16, low);
            i_16.* += 1;
        }
    }
    return i_16.*;
}

fn expectBigEndianUtf16(expected_native: []const u16, actual_big_endian: []const u16) !void {
    try testing.expectEqual(expected_native.len, actual_big_endian.len);
    for (expected_native, actual_big_endian) |expected, actual| {
        try testing.expectEqual(std.mem.nativeToBig(u16, expected), actual);
    }
}

const ascii = "abcde";
const greek = "αβγδε";
const mixed = "aβ∅🤓";
const maths = "∅⊄⊅⊆⊇";
const emotes = "🤓😎🥸🤩🤯";
test "utf8.decode handles ascii and multibyte codepoints" {
    try testing.expectEqual(@as(u21, 'a'), try utf8.decode("abc"));
    try testing.expectEqual(@as(u21, 0x03B1), try utf8.decode("α"));
    try testing.expectEqual(@as(u21, 0x2205), try utf8.decode("∅"));
    try testing.expectEqual(@as(u21, 0x1F913), try utf8.decode("🤓"));
}

test "utf8.decodeCursor advances through a string" {
    var cursor: usize = 0;

    try testing.expectEqual(@as(u21, 'a'), try utf8.decodeCursor(mixed, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
    try testing.expectEqual(@as(u21, 0x03B2), try utf8.decodeCursor(mixed, &cursor));
    try testing.expectEqual(@as(usize, 3), cursor);
    try testing.expectEqual(@as(u21, 0x2205), try utf8.decodeCursor(mixed, &cursor));
    try testing.expectEqual(@as(usize, 6), cursor);
    try testing.expectEqual(@as(u21, 0x1F913), try utf8.decodeCursor(mixed, &cursor));
    try testing.expectEqual(mixed.len, cursor);
}

test "utf8.validate and countCodepoints accept valid input" {
    try testing.expect(utf8.validate(ascii));
    try testing.expect(utf8.validate(greek));
    try testing.expect(utf8.validate(mixed));

    try testing.expectEqual(@as(usize, 5), try utf8.countCodepoints(ascii));
    try testing.expectEqual(@as(usize, 5), try utf8.countCodepoints(greek));
    try testing.expectEqual(@as(usize, 4), try utf8.countCodepoints(mixed));
}

test "utf8 invalid data reports the first bad byte" {
    const invalid = "a\xf0\x28\x8c\xbc";

    var validate_cursor: usize = 0;
    try testing.expect(!utf8.validateCursor(invalid, &validate_cursor));
    try testing.expectEqual(@as(usize, 2), validate_cursor);

    var decode_cursor: usize = 1;
    try testing.expectError(error.InvalidUtf8, utf8.decodeCursor(invalid, &decode_cursor));
    try testing.expectEqual(@as(usize, 2), decode_cursor);
}

test "utf8 rejects truncated sequences" {
    const truncated = "\xf0\x9f\x92";

    try testing.expect(!utf8.validate(truncated));
    try testing.expectError(error.InvalidUtf8, utf8.countCodepoints(truncated));

    var cursor: usize = 0;
    try testing.expectError(error.InvalidUtf8, utf8.decodeCursor(truncated, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
}

test "wtf8 namespace matches shared valid utf8 behavior" {
    try testing.expect(wtf8.validate(greek));
    try testing.expectEqual(@as(usize, 5), try wtf8.countCodepoints(greek));
    try testing.expectEqual(@as(u21, 0x03B1), try wtf8.decode("α"));

    var cursor: usize = 0;
    try testing.expectEqual(@as(u21, 'a'), try wtf8.decodeCursor(mixed, &cursor));
    try testing.expectEqual(@as(usize, 1), cursor);
}

test "wtf8 exact decode accepts surrogate-form codepoints" {
    try testing.expectEqual(@as(u21, 0xD800), try wtf8.decode("\xed\xa0\x80"));
}

test "countCodepointsAssumeValid matches valid utf8 and wtf8 slices" {
    try testing.expectEqual(try utf8.countCodepoints(greek), countCodepointsAssumeValid(greek));
    try testing.expectEqual(try utf8.countCodepoints(mixed), countCodepointsAssumeValid(mixed));
    try testing.expectEqual(try wtf8.countCodepoints(greek), countCodepointsAssumeValid(greek));
}

test "wtf8 wrappers remap malformed input to InvalidWtf8" {
    const invalid = "\xf0\x28\x8c\xbc";

    try testing.expect(!wtf8.validate(invalid));
    try testing.expectError(error.InvalidWtf8, wtf8.countCodepoints(invalid));

    var cursor: usize = 0;
    try testing.expectError(error.InvalidWtf8, wtf8.decodeCursor(invalid, &cursor));
}

test "codepoint helpers match encoding expectations" {
    var out: [4]u8 = undefined;
    var out_16: [2]u16 = undefined;

    try testing.expectEqual(@as(u3, 1), try codepoint.utf8Width('a'));
    try testing.expectEqual(@as(u3, 2), try codepoint.utf8Width(0x03B1));
    try testing.expectEqual(@as(u3, 3), try codepoint.utf8Width(0x2205));
    try testing.expectEqual(@as(u3, 4), try codepoint.utf8Width(0x1F913));
    try testing.expectEqual(@as(u3, 3), try codepoint.wtf8Width(0xD800));
    try testing.expectEqual(@as(u2, 2), try codepoint.utf16Width(0x1F913));
    try testing.expectEqual(@as(u2, 2), try codepoint.wtf16Width(0x1F913));
    try testing.expectEqual(@as(u3, 3), try utf8.byteLength("∅"[0]));
    try testing.expect(codepoint.isValidUnicode(0x10FFFF));
    try testing.expect(!codepoint.isValidUnicode(0xD800));
    try testing.expect(codepoint.isValidWtf(0xD800));
    try testing.expect(codepoint.isSurrogate(0xD800));
    try testing.expectEqualSlices(u8, "🤓", out[0..try codepoint.toUtf8(0x1F913, &out)]);
    try testing.expectError(error.Utf8CannotEncodeSurrogateHalf, codepoint.toUtf8(0xD800, &out));
    try testing.expectEqualSlices(u8, "\xed\xa0\x80", out[0..try codepoint.toWtf8(0xD800, &out)]);
    try testing.expectEqual(@as(u2, 2), try codepoint.toUtf16(0x1F913, &out_16));
    try testing.expectEqualSlices(u16, &.{ 0xD83E, 0xDD13 }, out_16[0..2]);
    try testing.expectError(error.Utf16CannotEncodeSurrogateHalf, codepoint.toUtf16(0xD800, &out_16));
    try testing.expectEqual(@as(u2, 1), try codepoint.toWtf16(0xD800, &out_16));
    try testing.expectEqualSlices(u16, &.{0xD800}, out_16[0..1]);
}

test "utf16 helpers identify surrogate structure" {
    try testing.expect(utf16.isHighSurrogate(0xD800));
    try testing.expect(!utf16.isHighSurrogate('a'));
    try testing.expect(utf16.isLowSurrogate(0xDC00));
    try testing.expect(!utf16.isLowSurrogate('a'));
    try testing.expectEqual(@as(u2, 2), try utf16.codeUnitWidth(0xD800));
    try testing.expectError(error.Utf16InvalidStartCodeUnit, utf16.codeUnitWidth(0xDC00));
    try testing.expectEqual(@as(u21, 0x1F913), try utf16.decodePair(&.{ 0xD83E, 0xDD13 }));
    try testing.expectError(error.MissingSecondCodeUnit, utf16.decodePair(&.{0xD83E}));
    try testing.expectError(error.ExpectedFirstSurrogateHalf, utf16.decodePair(&.{ 0x0061, 0xDD13 }));
    try testing.expectError(error.ExpectedSecondSurrogateHalf, utf16.decodePair(&.{ 0xD83E, 0x0061 }));
}

test "wtf16 decodePair matches utf16 exact error behavior" {
    try testing.expectEqual(@as(u21, 0x1F913), try wtf16.decodePair(&.{ 0xD83E, 0xDD13 }));
    try testing.expectError(error.MissingSecondCodeUnit, wtf16.decodePair(&.{0xD83E}));
    try testing.expectError(error.ExpectedFirstSurrogateHalf, wtf16.decodePair(&.{ 0x0061, 0xDD13 }));
    try testing.expectError(error.ExpectedSecondSurrogateHalf, wtf16.decodePair(&.{ 0xD83E, 0x0061 }));
}

test "Utf16LeIterator and utf16CountCodepoints handle valid and invalid input" {
    var utf16_buf: [8]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&utf16_buf, mixed);

    var iter = utf16.Utf16LeIterator.init(utf16_buf[0..len]);
    try testing.expectEqual(@as(u21, 'a'), (try iter.nextCodepoint()).?);
    try testing.expectEqual(@as(u21, 0x03B2), (try iter.nextCodepoint()).?);
    try testing.expectEqual(@as(usize, 4), try utf16.countCodepoints(utf16_buf[0..len]));
    try testing.expectEqual(@as(usize, mixed.len), try utf16.calcUtf8Len(utf16_buf[0..len]));

    var dangling = [_]u16{std.mem.nativeToLittle(u16, 0xD800)};
    iter = utf16.Utf16LeIterator.init(&dangling);
    try testing.expectError(error.DanglingSurrogateHalf, iter.nextCodepoint());

    var low = [_]u16{std.mem.nativeToLittle(u16, 0xDC00)};
    iter = utf16.Utf16LeIterator.init(&low);
    try testing.expectError(error.UnexpectedSecondSurrogateHalf, iter.nextCodepoint());
}

test "Wtf16LeIterator and wtf16CountCodepoints handle surrogate halves" {
    var wtf16_buf = [_]u16{
        std.mem.nativeToLittle(u16, 0xD800),
        std.mem.nativeToLittle(u16, ' '),
        std.mem.nativeToLittle(u16, 0xDC00),
    };

    var iter = wtf16.Wtf16LeIterator.init(&wtf16_buf);
    try testing.expectEqual(@as(u21, 0xD800), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, ' '), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xDC00), iter.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), iter.nextCodepoint());
    try testing.expectEqual(@as(usize, 3), wtf16.countCodepoints(&wtf16_buf));
}

test "utf16LeToUtf8 and wtf16LeToWtf8 transcode correctly" {
    var utf16_buf: [10]u16 = undefined;
    const utf16_len = try std.unicode.utf8ToUtf16Le(&utf16_buf, emotes);
    var out_utf8: [32]u8 = undefined;
    const utf8_len = try utf16.toUtf8(&out_utf8, utf16_buf[0..utf16_len]);
    try testing.expectEqualStrings(emotes, out_utf8[0..utf8_len]);

    var wtf16_buf = [_]u16{
        std.mem.nativeToLittle(u16, 0xD800),
        std.mem.nativeToLittle(u16, 0xDC00),
        std.mem.nativeToLittle(u16, 'a'),
    };
    var out_wtf8: [16]u8 = undefined;
    const wtf8_len = wtf16.toWtf8(&out_wtf8, &wtf16_buf);
    try testing.expectEqualStrings("\xf0\x90\x80\x80a", out_wtf8[0..wtf8_len]);

    var dangling = [_]u16{std.mem.nativeToLittle(u16, 0xD800)};
    try testing.expectError(error.DanglingSurrogateHalf, utf16.toUtf8(&out_utf8, &dangling));
}

test "utf8 and wtf8 count utf16 units needed for transcoding" {
    try testing.expectEqual(@as(usize, 5), try utf8.countUtf16Units(greek));
    try testing.expectEqual(@as(usize, 10), try utf8.countUtf16Units(emotes));

    var wtf16_buf = [_]u16{
        std.mem.nativeToLittle(u16, 0xD800),
        std.mem.nativeToLittle(u16, ' '),
        std.mem.nativeToLittle(u16, 0xDC00),
    };
    var out_wtf8: [16]u8 = undefined;
    const wtf8_len = wtf16.toWtf8(&out_wtf8, &wtf16_buf);
    try testing.expectEqual(wtf8_len, wtf16.calcWtf8Len(&wtf16_buf));
    try testing.expectEqual(@as(usize, 1), try wtf8.countWtf16Units("\xed\xa0\x80"));
}

test "utf16 exact utf8 export errors on malformed surrogate structure" {
    var out_utf8: [16]u8 = undefined;

    var dangling = [_]u16{std.mem.nativeToLittle(u16, 0xD800)};
    try testing.expectError(error.DanglingSurrogateHalf, utf16.toUtf8(&out_utf8, &dangling));
    try testing.expectError(error.DanglingSurrogateHalf, utf16.calcUtf8Len(&dangling));

    var low = [_]u16{std.mem.nativeToLittle(u16, 0xDC00)};
    try testing.expectError(error.UnexpectedSecondSurrogateHalf, utf16.toUtf8(&out_utf8, &low));
    try testing.expectError(error.UnexpectedSecondSurrogateHalf, utf16.calcUtf8Len(&low));
}

test "wtf16 exact utf8 export stays total for lone surrogate halves" {
    var out_utf8: [16]u8 = undefined;

    var high = [_]u16{std.mem.nativeToLittle(u16, 0xD800)};
    const high_len = wtf16.toWtf8(&out_utf8, &high);
    try testing.expectEqualStrings("\xed\xa0\x80", out_utf8[0..high_len]);
    try testing.expectEqual(@as(usize, 3), wtf16.calcWtf8Len(&high));

    var low = [_]u16{std.mem.nativeToLittle(u16, 0xDC00)};
    const low_len = wtf16.toWtf8(&out_utf8, &low);
    try testing.expectEqualStrings("\xed\xb0\x80", out_utf8[0..low_len]);
    try testing.expectEqual(@as(usize, 3), wtf16.calcWtf8Len(&low));

    var mixed_wtf16 = [_]u16{
        std.mem.nativeToLittle(u16, 0xD800),
        std.mem.nativeToLittle(u16, 'a'),
        std.mem.nativeToLittle(u16, 0xDC00),
    };
    const mixed_len = wtf16.toWtf8(&out_utf8, &mixed_wtf16);
    try testing.expectEqualStrings("\xed\xa0\x80\x61\xed\xb0\x80", out_utf8[0..mixed_len]);
    try testing.expectEqual(mixed_len, wtf16.calcWtf8Len(&mixed_wtf16));
}

test "utf8.assume_valid matches exact behavior on valid input" {
    try testing.expectEqual(try utf8.decode("α"), utf8.valid.decode("α"));

    var exact_cursor: usize = 0;
    var assume_cursor: usize = 0;
    try testing.expectEqual(try utf8.decodeCursor(mixed, &exact_cursor), utf8.valid.decodeCursor(mixed, &assume_cursor));
    try testing.expectEqual(exact_cursor, assume_cursor);

    try testing.expectEqual(try utf8.countCodepoints(mixed), utf8.valid.countCodepoints(mixed));

    var out_exact_le: [10]u16 = undefined;
    var out_assume_le: [10]u16 = undefined;
    const exact_le_len = try utf8.toUtf16Le(&out_exact_le, emotes);
    const assume_le_len = utf8.valid.toUtf16Le(&out_assume_le, emotes);
    try testing.expectEqual(exact_le_len, assume_le_len);
    try testing.expectEqualSlices(u16, out_exact_le[0..exact_le_len], out_assume_le[0..assume_le_len]);

    var out_exact_be: [10]u16 = undefined;
    var out_assume_be: [10]u16 = undefined;
    const exact_be_len = try utf8.toUtf16Be(&out_exact_be, emotes);
    const assume_be_len = utf8.valid.toUtf16Be(&out_assume_be, emotes);
    try testing.expectEqual(exact_be_len, assume_be_len);
    try testing.expectEqualSlices(u16, out_exact_be[0..exact_be_len], out_assume_be[0..assume_be_len]);

    var exact_i_16: usize = 0;
    var exact_i_8: usize = 0;
    var assume_i_16: usize = 0;
    var assume_i_8: usize = 0;
    try utf8.toUtf16LeCursor(&out_exact_le, mixed, &exact_i_16, &exact_i_8);
    utf8.valid.toUtf16LeCursor(&out_assume_le, mixed, &assume_i_16, &assume_i_8);
    try testing.expectEqual(exact_i_16, assume_i_16);
    try testing.expectEqual(exact_i_8, assume_i_8);
    try testing.expectEqualSlices(u16, out_exact_le[0..exact_i_16], out_assume_le[0..assume_i_16]);
}

test "wtf8.assume_valid matches exact behavior on valid input" {
    try testing.expectEqual(try wtf8.decode("α"), wtf8.valid.decode("α"));

    var exact_cursor: usize = 0;
    var assume_cursor: usize = 0;
    try testing.expectEqual(try wtf8.decodeCursor(mixed, &exact_cursor), wtf8.valid.decodeCursor(mixed, &assume_cursor));
    try testing.expectEqual(exact_cursor, assume_cursor);

    try testing.expectEqual(try wtf8.countCodepoints(mixed), wtf8.valid.countCodepoints(mixed));

    var out_exact_le: [10]u16 = undefined;
    var out_assume_le: [10]u16 = undefined;
    const exact_le_len = try wtf8.toWtf16Le(&out_exact_le, emotes);
    const assume_le_len = wtf8.valid.toWtf16Le(&out_assume_le, emotes);
    try testing.expectEqual(exact_le_len, assume_le_len);
    try testing.expectEqualSlices(u16, out_exact_le[0..exact_le_len], out_assume_le[0..assume_le_len]);

    var out_exact_be: [10]u16 = undefined;
    var out_assume_be: [10]u16 = undefined;
    const exact_be_len = try wtf8.toWtf16Be(&out_exact_be, emotes);
    const assume_be_len = wtf8.valid.toWtf16Be(&out_assume_be, emotes);
    try testing.expectEqual(exact_be_len, assume_be_len);
    try testing.expectEqualSlices(u16, out_exact_be[0..exact_be_len], out_assume_be[0..assume_be_len]);

    var exact_i_16: usize = 0;
    var exact_i_8: usize = 0;
    var assume_i_16: usize = 0;
    var assume_i_8: usize = 0;
    try wtf8.toWtf16LeCursor(&out_exact_le, mixed, &exact_i_16, &exact_i_8);
    wtf8.valid.toWtf16LeCursor(&out_assume_le, mixed, &assume_i_16, &assume_i_8);
    try testing.expectEqual(exact_i_16, assume_i_16);
    try testing.expectEqual(exact_i_8, assume_i_8);
    try testing.expectEqualSlices(u16, out_exact_le[0..exact_i_16], out_assume_le[0..assume_i_16]);
}

test "utf8.toUtf16Le matches std.unicode" {
    var out_std: [10]u16 = undefined;
    var out_unicode: [10]u16 = undefined;
    {
        _ = try std.unicode.utf8ToUtf16Le(&out_std, greek);
        const count = try utf8.toUtf16Le(&out_unicode, greek);
        try testing.expectEqual(@as(usize, 5), count);
        try testing.expectEqualSlices(u16, out_std[0..5], out_unicode[0..5]);
    }
    {
        _ = try std.unicode.utf8ToUtf16Le(&out_std, maths);
        const count = try utf8.toUtf16Le(&out_unicode, maths);
        try testing.expectEqual(@as(usize, 5), count);
        try testing.expectEqualSlices(u16, out_std[0..5], out_unicode[0..5]);
    }
    {
        _ = try std.unicode.utf8ToUtf16Le(&out_std, emotes);
        const count = try utf8.toUtf16Le(&out_unicode, emotes);
        try testing.expectEqual(@as(usize, 10), count);
        try testing.expectEqualSlices(u16, &out_std, &out_unicode);
    }
}

test "utf8.toUtf16Be matches std.unicode with big-endian words" {
    var out_std: [10]u16 = undefined;
    var out_unicode: [10]u16 = undefined;
    {
        _ = try std.unicode.utf8ToUtf16Le(&out_std, greek);
        const count = try utf8.toUtf16Be(&out_unicode, greek);
        try testing.expectEqual(@as(usize, 5), count);
        try expectBigEndianUtf16(out_std[0..5], out_unicode[0..5]);
    }
    {
        _ = try std.unicode.utf8ToUtf16Le(&out_std, maths);
        const count = try utf8.toUtf16Be(&out_unicode, maths);
        try testing.expectEqual(@as(usize, 5), count);
        try expectBigEndianUtf16(out_std[0..5], out_unicode[0..5]);
    }
    {
        _ = try std.unicode.utf8ToUtf16Le(&out_std, emotes);
        const count = try utf8.toUtf16Be(&out_unicode, emotes);
        try testing.expectEqual(@as(usize, 10), count);
        try expectBigEndianUtf16(&out_std, &out_unicode);
    }
}

test "utf16.normalizeBe converts big-endian words in place" {
    var expected_native: [10]u16 = undefined;
    var out_be: [10]u16 = undefined;

    _ = try std.unicode.utf8ToUtf16Le(&expected_native, emotes);
    const count = try utf8.toUtf16Be(&out_be, emotes);

    utf16.normalizeBe(out_be[0..count]);
    try testing.expectEqualSlices(u16, expected_native[0..count], out_be[0..count]);
}

test "wtf16.normalizeBe converts big-endian words in place" {
    var expected_native = [_]u16{ 0xD800, 'a', 0xDC00 };
    var out_be = [_]u16{
        @byteSwap(@as(u16, 0xD800)),
        @byteSwap(@as(u16, 'a')),
        @byteSwap(@as(u16, 0xDC00)),
    };

    wtf16.normalizeBe(&out_be);
    try testing.expectEqualSlices(u16, &expected_native, &out_be);
}

test "utf8.toUtf16LeCursor advances source and destination cursors" {
    var out: [10]u16 = undefined;
    var i_16: usize = 0;
    var i_8: usize = 0;

    try utf8.toUtf16LeCursor(&out, mixed, &i_16, &i_8);
    try testing.expectEqual(@as(usize, 5), i_16);
    try testing.expectEqual(mixed.len, i_8);
}

test "utf8.toUtf16BeCursor advances source and destination cursors" {
    var out: [10]u16 = undefined;
    var i_16: usize = 0;
    var i_8: usize = 0;

    try utf8.toUtf16BeCursor(&out, mixed, &i_16, &i_8);
    try testing.expectEqual(@as(usize, 5), i_16);
    try testing.expectEqual(mixed.len, i_8);
}

test "utf8.toUtf16LeCursor preserves partial progress on malformed input" {
    const invalid = "a\xf0\x28\x8c\xbc";
    var out: [10]u16 = undefined;
    var i_16: usize = 0;
    var i_8: usize = 0;

    try testing.expectError(error.InvalidUtf8, utf8.toUtf16LeCursor(&out, invalid, &i_16, &i_8));
    try testing.expectEqual(@as(usize, 1), i_16);
    try testing.expectEqual(@as(usize, 2), i_8);
}

test "wtf8 transcoding wrappers remap malformed input to InvalidWtf8" {
    const invalid = "\xf0\x28\x8c\xbc";
    var out: [10]u16 = undefined;
    var i_16: usize = 0;
    var i_8: usize = 0;

    try testing.expectError(error.InvalidWtf8, wtf8.toWtf16Le(&out, invalid));
    try testing.expectError(error.InvalidWtf8, wtf8.toWtf16LeCursor(&out, invalid, &i_16, &i_8));
    try testing.expectEqual(@as(usize, 0), i_16);
    try testing.expectEqual(@as(usize, 1), i_8);
}

test "diagnoseAtIndex reports detailed utf8 errors and ignores misses" {
    try utfDiagnoseAtIndex(mixed, mixed.len);
    try utfDiagnoseAtIndex(mixed, mixed.len + 4);
    try utfDiagnoseAtIndex(mixed, 0);

    try testing.expectError(error.Utf8ExpectedContinuation, utfDiagnoseAtIndex("\xf0\x28\x8c\xbc", 0));
    try testing.expectError(error.TruncatedInput, utfDiagnoseAtIndex("\xf0\x9f\x92", 0));
    try testing.expectError(error.Utf8InvalidStartByte, utfDiagnoseAtIndex("a\x80b", 1));
}

test "diagnoseBeforeIndex synchronizes from lossy cursors" {
    {
        const invalid = "a\xf0\x28\x8c\xbcz";
        var cursor: usize = 1;
        _ = utf8.lossy.decodeCursor(invalid, &cursor);
        try testing.expectEqual(@as(usize, 2), cursor);
        try testing.expectError(error.Utf8ExpectedContinuation, utfDiagnoseBeforeIndex(invalid, cursor));
    }
    {
        const stray = "🤓\x80";
        var cursor: usize = "🤓".len;
        _ = utf8.lossy.decodeCursor(stray, &cursor);
        try testing.expectEqual(stray.len, cursor);
        try testing.expectError(error.Utf8InvalidStartByte, utfDiagnoseBeforeIndex(stray, cursor));
    }

    try utfDiagnoseBeforeIndex(mixed, 0);
    try utfDiagnoseBeforeIndex(mixed, 1);
}

test "wtf diagnostics allow surrogate-form sequences" {
    try wtfDiagnoseAtIndex("\xed\xa0\x80", 0);
    try testing.expectError(error.Utf8EncodesSurrogateHalf, utfDiagnoseAtIndex("\xed\xa0\x80", 0));
}

test "wtf diagnostics report malformed input and synchronize from lossy cursors" {
    try wtfDiagnoseAtIndex(mixed, mixed.len);
    try testing.expectError(error.Utf8ExpectedContinuation, wtfDiagnoseAtIndex("\xf0\x28\x8c\xbc", 0));
    try testing.expectError(error.TruncatedInput, wtfDiagnoseAtIndex("\xf0\x9f\x92", 0));
    try testing.expectError(error.Utf8InvalidStartByte, wtfDiagnoseAtIndex("a\x80b", 1));

    {
        const invalid = "a\xf0\x28\x8c\xbcz";
        var cursor: usize = 1;
        _ = wtf8.lossy.decodeCursor(invalid, &cursor);
        try testing.expectEqual(@as(usize, 2), cursor);
        try testing.expectError(error.Utf8ExpectedContinuation, wtfDiagnoseBeforeIndex(invalid, cursor));
    }
    {
        const surrogate = "a\xed\xa0\x80z";
        var cursor: usize = 1;
        _ = wtf8.lossy.decodeCursor(surrogate, &cursor);
        try testing.expectEqual(@as(usize, 4), cursor);
        try wtfDiagnoseBeforeIndex(surrogate, cursor);
    }

    try wtfDiagnoseBeforeIndex(mixed, 0);
    try wtfDiagnoseBeforeIndex(mixed, 1);
}

test "exact iterators expose diagnoseError at the current cursor" {
    {
        var iter = utf8.iterator("a\xf0\x28\x8c\xbc", .exact);
        try testing.expectEqual(@as(u21, 'a'), (try iter.nextCodepoint()).?);
        try testing.expectError(error.Utf8ExpectedContinuation, iter.diagnoseError());
    }
    {
        var iter = wtf8.iterator("a\xf0\x28\x8c\xbc", .exact);
        try testing.expectEqual(@as(u21, 'a'), (try iter.nextCodepoint()).?);
        try testing.expectError(error.Utf8ExpectedContinuation, iter.diagnoseError());
    }
}

test "lossy iterators expose diagnoseError for the previous malformed subpart" {
    {
        var iter = utf8.iterator("a\xf0\x28\x8c\xbcz", .lossy);
        try testing.expectEqual(@as(u21, 'a'), iter.nextCodepoint().?);
        try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
        try testing.expectError(error.Utf8ExpectedContinuation, iter.diagnoseError());
    }
    {
        var iter = wtf8.iterator("a\xf0\x28\x8c\xbcz", .lossy);
        try testing.expectEqual(@as(u21, 'a'), iter.nextCodepoint().?);
        try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
        try testing.expectError(error.Utf8ExpectedContinuation, iter.diagnoseError());
    }
    {
        var iter = wtf8.iterator("a\xed\xa0\x80z", .lossy);
        try testing.expectEqual(@as(u21, 'a'), iter.nextCodepoint().?);
        try testing.expectEqual(@as(u21, 0xD800), iter.nextCodepoint().?);
        try iter.diagnoseError();
    }
}

test "source namespaces expose utf16 transcoding entry points" {
    _ = utf8.toUtf16Le;
    _ = utf8.lossy.toUtf16Le;
    _ = utf8.valid.toUtf16Be;
    _ = wtf8.toWtf16Le;
    _ = wtf8.lossy.toWtf16Be;
    _ = wtf8.valid.toWtf16LeCursor;
}

fn testUtf8ViewNextCp(slice: []const u8) !void {
    var iter = utf8.iterator(slice, .exact);
    var cursor: usize = 0;
    while (try iter.nextCodepoint()) |cp| {
        const expected = try utf8.decodeCursor(slice, &cursor);
        try testing.expectEqual(expected, cp);
    }
    try testing.expectEqual(slice.len, cursor);
}

fn testUtf8ViewNextCpSlice(slice: []const u8) !void {
    var iter = utf8.Utf8View(.exact).init(slice);
    var cursor: usize = 0;
    while (try iter.nextCodepointSlice()) |cp_slice| {
        const start = cursor;
        _ = try utf8.decodeCursor(slice, &cursor);
        try testing.expectEqualStrings(slice[start..cursor], cp_slice);
    }
    try testing.expectEqual(slice.len, cursor);
}

fn testWtf8ViewNextCp(slice: []const u8) !void {
    var iter = wtf8.iterator(slice, .exact);
    var cursor: usize = 0;
    while (try iter.nextCodepoint()) |cp| {
        const expected = try wtf8.decodeCursor(slice, &cursor);
        try testing.expectEqual(expected, cp);
    }
    try testing.expectEqual(slice.len, cursor);
}

fn testWtf8ViewNextCpSlice(slice: []const u8) !void {
    var iter = wtf8.Wtf8View(.exact).init(slice);
    var cursor: usize = 0;
    while (try iter.nextCodepointSlice()) |cp_slice| {
        const start = cursor;
        _ = try wtf8.decodeCursor(slice, &cursor);
        try testing.expectEqualStrings(slice[start..cursor], cp_slice);
    }
    try testing.expectEqual(slice.len, cursor);
}

fn prefixAfterNCps(slice: []const u8, n: usize) ![]const u8 {
    var cursor: usize = 0;
    var remaining = n;
    while (remaining > 0 and cursor < slice.len) : (remaining -= 1) {
        _ = try utf8.decodeCursor(slice, &cursor);
    }
    return slice[0..cursor];
}

fn prefixAfterNLossyCps(cu_dfa: anytype, slice: []const u8, n: usize) []const u8 {
    var cursor: usize = 0;
    var remaining = n;
    while (remaining > 0 and cursor < slice.len) : (remaining -= 1) {
        _ = decodeAnyLossyXtf8Cursor(cu_dfa, st_dfa, c_mask, slice, &cursor);
    }
    return slice[0..cursor];
}

fn expectUtf8LossyDecode(bytes: []const u8, expected_cps: []const u21, expected_lens: []const usize) !void {
    try testing.expectEqual(expected_cps.len, expected_lens.len);
    var cursor: usize = 0;
    for (expected_cps, expected_lens) |expected_cp, expected_len| {
        const start = cursor;
        try testing.expectEqual(expected_cp, utf8.lossy.decodeCursor(bytes, &cursor));
        try testing.expectEqual(expected_len, cursor - start);
    }
    try testing.expectEqual(bytes.len, cursor);
}

fn expectWtf8LossyDecode(bytes: []const u8, expected_cps: []const u21, expected_lens: []const usize) !void {
    try testing.expectEqual(expected_cps.len, expected_lens.len);
    var cursor: usize = 0;
    for (expected_cps, expected_lens) |expected_cp, expected_len| {
        const start = cursor;
        try testing.expectEqual(expected_cp, wtf8.lossy.decodeCursor(bytes, &cursor));
        try testing.expectEqual(expected_len, cursor - start);
    }
    try testing.expectEqual(bytes.len, cursor);
}

fn expectUtf8LossyIteratorSlices(bytes: []const u8, expected_slices: []const []const u8) !void {
    var iter = utf8.iterator(bytes, .lossy);
    for (expected_slices) |expected_slice| {
        const slice = iter.nextCodepointSlice().?;
        try testing.expectEqualStrings(expected_slice, slice);
    }
    try testing.expectEqual(@as(?[]const u8, null), iter.nextCodepointSlice());
}

fn expectWtf8LossyIteratorSlices(bytes: []const u8, expected_slices: []const []const u8) !void {
    var iter = wtf8.iterator(bytes, .lossy);
    for (expected_slices) |expected_slice| {
        const slice = iter.nextCodepointSlice().?;
        try testing.expectEqualStrings(expected_slice, slice);
    }
    try testing.expectEqual(@as(?[]const u8, null), iter.nextCodepointSlice());
}

test "Utf8View iterator exact nextCodepoint matches decodeCursor" {
    try testUtf8ViewNextCp(ascii);
    try testUtf8ViewNextCp(greek);
    try testUtf8ViewNextCp(maths);
    try testUtf8ViewNextCp(emotes);
}

test "Utf8View iterator exact nextCodepointSlice matches input slices" {
    try testUtf8ViewNextCpSlice(ascii);
    try testUtf8ViewNextCpSlice(greek);
    try testUtf8ViewNextCpSlice(maths);
    try testUtf8ViewNextCpSlice(emotes);
}

test "Utf8View iterator exact peek returns prefix without advancing" {
    var iter = utf8.Utf8View(.exact).init(emotes);
    const expected = try prefixAfterNCps(emotes, 3);
    try testing.expectEqualStrings(expected, try iter.peek(3));
    try testing.expectEqual(@as(usize, 0), iter.i);
}

test "Utf8View iterator exact reports end of input" {
    var iter = utf8.Utf8View(.exact).init(ascii);
    while (try iter.nextCodepoint()) |_| {}
    try testing.expectEqual(@as(?u21, null), try iter.nextCodepoint());
    try testing.expectEqual(@as(?[]const u8, null), try iter.nextCodepointSlice());
}

test "Utf8View iterator exact reports malformed input" {
    const invalid = "a\xf0\x28\x8c\xbc";
    const truncated = "\xf0\x9f\x92";

    {
        var iter = utf8.Utf8View(.exact).init(invalid);
        try testing.expectEqual(@as(u21, 'a'), (try iter.nextCodepoint()).?);
        try testing.expectError(error.InvalidUtf8, iter.nextCodepoint());
    }
    {
        var iter = utf8.Utf8View(.exact).init(invalid);
        _ = try iter.nextCodepointSlice();
        try testing.expectError(error.InvalidUtf8, iter.nextCodepointSlice());
    }
    {
        var iter = utf8.Utf8View(.exact).init(invalid);
        try testing.expectError(error.InvalidUtf8, iter.peek(3));
        try testing.expectEqual(@as(usize, 0), iter.i);
    }
    {
        var iter = utf8.Utf8View(.exact).init(truncated);
        try testing.expectError(error.InvalidUtf8, iter.nextCodepoint());
    }
}

test "Wtf8View iterator exact nextCodepoint matches decodeCursor" {
    try testWtf8ViewNextCp(ascii);
    try testWtf8ViewNextCp(greek);
    try testWtf8ViewNextCp(maths);
    try testWtf8ViewNextCp(emotes);
}

test "Wtf8View iterator exact nextCodepointSlice matches input slices" {
    try testWtf8ViewNextCpSlice(ascii);
    try testWtf8ViewNextCpSlice(greek);
    try testWtf8ViewNextCpSlice(maths);
    try testWtf8ViewNextCpSlice(emotes);
}

test "Wtf8View iterator exact reports malformed input as InvalidWtf8" {
    const invalid = "\xf0\x28\x8c\xbc";

    {
        var iter = wtf8.Wtf8View(.exact).init(invalid);
        try testing.expectError(error.InvalidWtf8, iter.nextCodepoint());
    }
    {
        var iter = wtf8.Wtf8View(.exact).init(invalid);
        try testing.expectError(error.InvalidWtf8, iter.nextCodepointSlice());
    }
    {
        var iter = wtf8.Wtf8View(.exact).init(invalid);
        try testing.expectError(error.InvalidWtf8, iter.peek(1));
        try testing.expectEqual(@as(usize, 0), iter.i);
    }
}

test "utf8.lossy decode preserves valid input" {
    try testing.expectEqual(@as(u21, 'a'), utf8.lossy.decode("abc"));
    try testing.expectEqual(@as(u21, 0x03B1), utf8.lossy.decode("α"));
    try testing.expectEqual(@as(u21, 0x1F913), utf8.lossy.decode("🤓"));
}

test "utf8.lossy overlongs use replacement characters" {
    try expectUtf8LossyDecode("\xc0\xaf", &.{ 0xfffd, 0xfffd }, &.{ 1, 1 });
    try expectUtf8LossyDecode("\xe0\x80\xaf", &.{ 0xfffd, 0xfffd, 0xfffd }, &.{ 1, 1, 1 });
    try expectUtf8LossyDecode("\xf0\x80\x80\xaf", &.{ 0xfffd, 0xfffd, 0xfffd, 0xfffd }, &.{ 1, 1, 1, 1 });
}

test "utf8.lossy surrogate-form sequences use replacement characters" {
    try expectUtf8LossyDecode("\xed\xad\xbf", &.{ 0xfffd, 0xfffd, 0xfffd }, &.{ 1, 1, 1 });
}

test "utf8.lossy truncation follows maximal subparts" {
    const bytes = "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41";
    try expectUtf8LossyDecode(bytes, &.{ 0xfffd, 0xfffd, 0xfffd, 0xfffd, 0x41 }, &.{ 2, 1, 3, 2, 1 });
    try expectUtf8LossyDecode("\xe1\x80", &.{0xfffd}, &.{2});
    try expectUtf8LossyDecode("\xf1\x80\x80", &.{0xfffd}, &.{3});
    try expectUtf8LossyDecode("\xe1\x80\xc0", &.{ 0xfffd, 0xfffd }, &.{ 2, 1 });
    try expectUtf8LossyDecode("\xf1\x80\x80\xc0", &.{ 0xfffd, 0xfffd }, &.{ 3, 1 });
}

test "utf8.lossy countCodepoints counts replacements" {
    try testing.expectEqual(@as(usize, 4), utf8.lossy.countCodepoints(mixed));
    try testing.expectEqual(@as(usize, 2), utf8.lossy.countCodepoints("\xc0\xaf"));
    try testing.expectEqual(@as(usize, 5), utf8.lossy.countCodepoints("\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41"));
}

test "utf8.lossy validate matches exact validation" {
    const invalid = "a\xf0\x28\x8c\xbc";

    try testing.expectEqual(utf8.validate(mixed), utf8.lossy.validate(mixed));
    try testing.expectEqual(utf8.validate(invalid), utf8.lossy.validate(invalid));

    var exact_cursor: usize = 0;
    var lossy_cursor: usize = 0;
    try testing.expectEqual(utf8.validateCursor(invalid, &exact_cursor), utf8.lossy.validateCursor(invalid, &lossy_cursor));
    try testing.expectEqual(exact_cursor, lossy_cursor);
}

test "utf8.lossy transcoding emits replacement characters" {
    const bytes = "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41";
    const expected_native = [_]u16{ 0xfffd, 0xfffd, 0xfffd, 0xfffd, 0x41 };
    var out_le: [expected_native.len]u16 = undefined;
    var out_be: [expected_native.len]u16 = undefined;

    try testing.expectEqual(expected_native.len, utf8.lossy.toUtf16Le(&out_le, bytes));
    try testing.expectEqualSlices(u16, &expected_native, &out_le);
    try testing.expectEqual(expected_native.len, utf8.lossy.toUtf16Be(&out_be, bytes));
    try expectBigEndianUtf16(&expected_native, &out_be);

    var i_16: usize = 0;
    var i_8: usize = 0;
    utf8.lossy.toUtf16LeCursor(&out_le, bytes, &i_16, &i_8);
    try testing.expectEqual(expected_native.len, i_16);
    try testing.expectEqual(bytes.len, i_8);
}
const IteratorRegressionError = error{OopsYouBrokeTheIteratorAgain};

test "don't break the iterator" {
    const bytes = "\xff";
    var iter_loss = utf8.lossy.iterator(bytes);
    if (!std.mem.eql(u8, iter_loss.nextCodepointSlice().?, &utf8_uffd)) {
        return error.OopsYouBrokeTheIteratorAgain;
    }
}

test "Utf8View iterator lossy yields replacements and maximal subpart slices" {
    const bytes = "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41";
    var iter = utf8.iterator(bytes, .lossy);

    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0x41), iter.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), iter.nextCodepoint());

    try expectUtf8LossyIteratorSlices(bytes, &.{ &utf8_uffd, &utf8_uffd, &utf8_uffd, &utf8_uffd, "A" });

    iter = utf8.iterator(bytes, .lossy);
    try testing.expectEqualStrings(&utf8_uffd, iter.peek());
    try testing.expectEqual(@as(usize, 0), iter.i);
}

test "utf8.lossy iterator slices for overlongs are replacement bytes" {
    try expectUtf8LossyIteratorSlices("\xc0\xaf", &.{ &utf8_uffd, &utf8_uffd });
    try expectUtf8LossyIteratorSlices("\xe0\x80\xaf", &.{ &utf8_uffd, &utf8_uffd, &utf8_uffd });
    try expectUtf8LossyIteratorSlices("\xf0\x80\x80\xaf", &.{ &utf8_uffd, &utf8_uffd, &utf8_uffd, &utf8_uffd });
}

test "utf8.lossy iterator slices for surrogate-form sequences are replacement bytes" {
    try expectUtf8LossyIteratorSlices("\xed\xad\xbf", &.{ &utf8_uffd, &utf8_uffd, &utf8_uffd });
}

test "utf8.lossy iterator slices for truncation use replacement bytes and valid tails" {
    try expectUtf8LossyIteratorSlices(
        "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41",
        &.{ &utf8_uffd, &utf8_uffd, &utf8_uffd, &utf8_uffd, "A" },
    );
}

test "utf8.lossy iterator convenience function is specialized to lossy" {
    const bytes = "\xc0\xafA";
    var iter = utf8.lossy.iterator(bytes);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 'A'), iter.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), iter.nextCodepoint());
}

test "wtf8.lossy preserves valid input and replaces malformed input" {
    try testing.expectEqual(@as(u21, 0x03B1), wtf8.lossy.decode("α"));
    try expectWtf8LossyDecode("\xc0\xaf", &.{ 0xfffd, 0xfffd }, &.{ 1, 1 });
    try expectWtf8LossyDecode("\xe1\x80", &.{0xfffd}, &.{2});
    try expectWtf8LossyDecode("\xf1\x80\x80", &.{0xfffd}, &.{3});
    try expectWtf8LossyDecode("\xe1\x80\xc0", &.{ 0xfffd, 0xfffd }, &.{ 2, 1 });
    try expectWtf8LossyDecode("\xf1\x80\x80\xc0", &.{ 0xfffd, 0xfffd }, &.{ 3, 1 });
}

test "wtf8.lossy countCodepoints and transcode replace malformed input" {
    const bytes = "\xc0\xaf";
    const expected_native = [_]u16{ 0xfffd, 0xfffd };
    var out_le: [expected_native.len]u16 = undefined;
    var out_be: [expected_native.len]u16 = undefined;

    try testing.expectEqual(@as(usize, 2), wtf8.lossy.countCodepoints(bytes));
    try testing.expectEqual(expected_native.len, wtf8.lossy.toWtf16Le(&out_le, bytes));
    try testing.expectEqualSlices(u16, &expected_native, &out_le);
    try testing.expectEqual(expected_native.len, wtf8.lossy.toWtf16Be(&out_be, bytes));
    try expectBigEndianUtf16(&expected_native, &out_be);

    var i_16: usize = 0;
    var i_8: usize = 0;
    wtf8.lossy.toWtf16LeCursor(&out_le, bytes, &i_16, &i_8);
    try testing.expectEqual(expected_native.len, i_16);
    try testing.expectEqual(bytes.len, i_8);
}

test "wtf8.lossy validate matches exact validation" {
    const invalid = "\xf0\x28\x8c\xbc";

    try testing.expectEqual(wtf8.validate(greek), wtf8.lossy.validate(greek));
    try testing.expectEqual(wtf8.validate(invalid), wtf8.lossy.validate(invalid));

    var exact_cursor: usize = 0;
    var lossy_cursor: usize = 0;
    try testing.expectEqual(wtf8.validateCursor(invalid, &exact_cursor), wtf8.lossy.validateCursor(invalid, &lossy_cursor));
    try testing.expectEqual(exact_cursor, lossy_cursor);
}

test "utf8.assume_valid validate matches exact validation" {
    const invalid = "a\xf0\x28\x8c\xbc";

    try testing.expectEqual(utf8.validate(mixed), utf8.valid.validate(mixed));
    try testing.expectEqual(utf8.validate(invalid), utf8.valid.validate(invalid));

    var exact_cursor: usize = 0;
    var assume_cursor: usize = 0;
    try testing.expectEqual(utf8.validateCursor(invalid, &exact_cursor), utf8.valid.validateCursor(invalid, &assume_cursor));
    try testing.expectEqual(exact_cursor, assume_cursor);
}

test "wtf8.assume_valid validate matches exact validation" {
    const invalid = "\xf0\x28\x8c\xbc";

    try testing.expectEqual(wtf8.validate(greek), wtf8.valid.validate(greek));
    try testing.expectEqual(wtf8.validate(invalid), wtf8.valid.validate(invalid));

    var exact_cursor: usize = 0;
    var assume_cursor: usize = 0;
    try testing.expectEqual(wtf8.validateCursor(invalid, &exact_cursor), wtf8.valid.validateCursor(invalid, &assume_cursor));
    try testing.expectEqual(exact_cursor, assume_cursor);
}

test "Wtf8View iterator lossy yields replacements without errors" {
    const bytes = "\xc0\xaf";
    var iter = wtf8.iterator(bytes, .lossy);

    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), iter.nextCodepoint());

    try expectWtf8LossyIteratorSlices(bytes, &.{ &utf8_uffd, &utf8_uffd });

    iter = wtf8.iterator(bytes, .lossy);
    try testing.expectEqualStrings(&utf8_uffd, iter.peek());
    try testing.expectEqual(@as(usize, 0), iter.i);
}

test "lossy iterator returns replacement bytes on malformed input or error.OopsYouBrokeTheIteratorAgain" {
    const bytes = "\xc0\xaf";

    {
        var iter = utf8.iterator(bytes, .lossy);
        const slice = iter.nextCodepointSlice() orelse return IteratorRegressionError.OopsYouBrokeTheIteratorAgain;
        if (!std.mem.eql(u8, &utf8_uffd, slice)) return IteratorRegressionError.OopsYouBrokeTheIteratorAgain;
    }
    {
        var iter = wtf8.iterator(bytes, .lossy);
        const slice = iter.nextCodepointSlice() orelse return IteratorRegressionError.OopsYouBrokeTheIteratorAgain;
        if (!std.mem.eql(u8, &utf8_uffd, slice)) return IteratorRegressionError.OopsYouBrokeTheIteratorAgain;
    }
}

test "lossy iterator peek returns replacement bytes on malformed input or error.OopsYouBrokeTheIteratorAgain" {
    const bytes = "\xc0\xaf";

    {
        var iter = utf8.iterator(bytes, .lossy);
        if (!std.mem.eql(u8, &utf8_uffd, iter.peek())) return IteratorRegressionError.OopsYouBrokeTheIteratorAgain;
        try testing.expectEqual(@as(usize, 0), iter.i);
    }
    {
        var iter = wtf8.iterator(bytes, .lossy);
        if (!std.mem.eql(u8, &utf8_uffd, iter.peek())) return IteratorRegressionError.OopsYouBrokeTheIteratorAgain;
        try testing.expectEqual(@as(usize, 0), iter.i);
    }
}

test "wtf8.lossy iterator convenience function is specialized to lossy" {
    const bytes = "\xc0\xafA";
    var iter = wtf8.lossy.iterator(bytes);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 0xfffd), iter.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 'A'), iter.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), iter.nextCodepoint());
}

test "Utf8View iterator assume_valid matches exact on valid input" {
    var iter = utf8.iterator(emotes, .assume_valid);
    var cursor: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        const expected = try utf8.decodeCursor(emotes, &cursor);
        try testing.expectEqual(expected, cp);
    }
    try testing.expectEqual(emotes.len, cursor);

    iter = utf8.iterator(emotes, .assume_valid);
    try testing.expectEqualStrings(try prefixAfterNCps(emotes, 3), iter.peek(3));
    try testing.expectEqual(@as(usize, 0), iter.i);
}

test "utf8.valid iterator convenience function is specialized to assume_valid" {
    var iter = utf8.valid.iterator(emotes);
    var cursor: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        try testing.expectEqual(try utf8.decodeCursor(emotes, &cursor), cp);
    }
    try testing.expectEqual(emotes.len, cursor);
}

test "Utf8View iterator assume_valid nextCodepointSlice matches input slices" {
    var iter = utf8.Utf8View(.assume_valid).init(emotes);
    var cursor: usize = 0;
    while (iter.nextCodepointSlice()) |cp_slice| {
        const start = cursor;
        _ = utf8.valid.decodeCursor(emotes, &cursor);
        try testing.expectEqualStrings(emotes[start..cursor], cp_slice);
    }
    try testing.expectEqual(emotes.len, cursor);
}

test "Wtf8View iterator assume_valid matches exact on valid input" {
    var iter = wtf8.iterator(emotes, .assume_valid);
    var cursor: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        const expected = try wtf8.decodeCursor(emotes, &cursor);
        try testing.expectEqual(expected, cp);
    }
    try testing.expectEqual(emotes.len, cursor);

    iter = wtf8.iterator(emotes, .assume_valid);
    try testing.expectEqualStrings(try prefixAfterNCps(emotes, 3), iter.peek(3));
    try testing.expectEqual(@as(usize, 0), iter.i);
}

test "wtf8.valid iterator convenience function is specialized to assume_valid" {
    var iter = wtf8.valid.iterator(emotes);
    var cursor: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        try testing.expectEqual(try wtf8.decodeCursor(emotes, &cursor), cp);
    }
    try testing.expectEqual(emotes.len, cursor);
}

test "Wtf8View iterator assume_valid nextCodepointSlice matches input slices" {
    var iter = wtf8.Wtf8View(.assume_valid).init(emotes);
    var cursor: usize = 0;
    while (iter.nextCodepointSlice()) |cp_slice| {
        const start = cursor;
        _ = wtf8.valid.decodeCursor(emotes, &cursor);
        try testing.expectEqualStrings(emotes[start..cursor], cp_slice);
    }
    try testing.expectEqual(emotes.len, cursor);
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");
const is_debug = builtin.mode == .Debug;
const dfa = @import("dfa.zig");
