# Unicoder: Un-standard Unicode Library

Think of `unicoder` as a reimagining of Zig's `std.unicode`.  The
standard library has a well-defined purview, concerning itself with
validation, transcoding, iteration, and similar basic encoding-level
operations.

Unicoder covers the same ground, while being more efficient, better
organized, and encouraging patterns of use not available through
`std.unicode`.

## Guide

The library namespace is organized into sections, based on what the
functions and types in that section operate on:

- `codepoint` for `u21`s
- `utf8` and `wtf8` for byte-oriented encodings
- `utf16` and `wtf16` for wide encodings.

The encoding libraries (not you, `codepoint`) have 'exact' semantics:
like the standard library, they validate as they go, and throw an error
if they encounter any sequence which is ill-formed according to the
specification.  Unlike stdlib, there is only one error.  The `8` series
have a function `diagnoseError` which leverages stdlib to tell you
exactly what's wrong, if you care.

```zig
const cp1 = try std.unicode.utf8CountCodepoints(str);
const cp2 = try unicoder.utf8.countCodepoints(str);
assert(cp1 == cp2);
```

As a drop-in replacement for `std.unicode` in existing code, this
pattern will get you pretty far.

### Cursors

Functions which work across a slice, which is most of them, come in
'cursor' variants.  A cursor is a `*usize`, which the function will
update for you as it does its business.  This is almost always what you
want.

### Lossy and Valid

The exact semantics are closest to stdlib, offering the easiest
upgrade pathway for existing code, and do make the most sense for some
applications.

However, variants are provided: for example, `utf8.lossy` and
`utf8.valid`.  The 'lossy' variation replaces ill-formed sequences with
the Unicode Replacement Character, `U+FFFD`, using the Substitution of
Maximal Subparts algorithm.  This is the recommended approach to ill-
formed sequences in the Unicode standard, and with good reason.  As
guidance, lossy should be seriously considered any time the result of
operations will not be saved to disk or sent over the network, and is
even appropriate if it will be, in some cases.

The valid libraries are for when you know that slices contain
validly-encoded whatever-it-is.  They discount the possibility that
this isn't the case completely, and if that's wrong, the behavior
is unspecified, and the consequences may include memory hazards and
security vulnerabilities.  These expose the functions `validate` and
`validateCursor`, which do not make such assumptions (obviously) in
answering the question to which they are put.

It is strenuously recommended that users of `valid` libs create a
custom `struct` type to represent known-good sequences, as a way of
tracking provenance of already-validated slices.  Users are also advised
that it is rare that validity is a hard prerequisite of operating on
probably-Unicode.

Some routines in `valid` will assert validity before operations
commence, in debug modes only.  Which of these do so is undocumented,
and subject to change.

## Endianness

This library is deliberately biased toward little-endian 16 bit
encodings.  Broadly, we consider the presence of big-endian 16 bit
Unicode to represent a problem to be solved as early as possible.

The `(u|w)tf16` libraries have a function to normalize a buffer of
`u16`s into LE form, if they're in BE form.  Since it is impossible to
non-heuristically check which is which, this will do the opposite if
the opposite is, in fact, the case.

Please understand that endianness in encoding contexts refers to
"network order", and no accommodation to native endianness is made in
terms of the `unicoder` interface.

## Performance

This library is based on [runerip][rrip], which contains benchmarks
against stdlib, demonstrating significant performance improvements.
These have not been ported to `unicoder`, and probably will not be,
because the algorithms are identical, simply more complete and better
organized.

One caveat: some routines in `std.unicode` try to consume an ASCII-only
prefix before switching to the full-unicode path, using SIMD on systems
which support it: most of them, these days.  It's safe to conjecture
that those will be faster in the event that such an ASCII prefix exists.

It is contemplated that future editions of this library will have
"expect ASCII" variations, which improve on this trick by attempting to
return to the fast path after the slow path sees appropriate amounts
of pure-ASCII text.  We do not expect such a refinement to be an
optimization in the general case, however, so it will not be baked into
the baseline routines.

## Fancy Stuff

This library covers only the most basic aspects of Unicode.  For fuller
support, there are a couple good options.  Disclosure: I maintain `zg`.

I recommend [zg][zg] for most cases, as it's the most feature-complete,
at least at the time of writing.  However, [uucode][uucd] has a unique
and very clever approach to building the tries which both libraries
use, which is amenable to tailoring, something `zg` does not provide
at all.  So if you need to customize behavior, `uucode` is the way to
go.

As of `zg`'s latest release, there is little to no difference in how
each library does the things which both libraries do.

In any case, `unicoder` is more narrowly scoped, and will remain so.
All three libraries use the [Höhrmann Algorithm][utfdfa], first ported
to Zig for use in `runerip`.

[rrip]: https://github.com/mnemnion/runerip/
[zg]: https://codeberg.org/atman/zg
[uucd]: https://github.com/jacobsandlund/uucode
[utfdfa]: https://bjoern.hoehrmann.de/utf-8/decoder/dfa/
