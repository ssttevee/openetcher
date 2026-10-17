#!/usr/bin/env bash
#
# Runs `zig build test` once per target, each as its own command.
#
# Zig only analyzes code it reaches, so a plain `zig build test` on one host
# never compiles the other platforms' backends or the big-endian decoding
# paths. Running the suite per target keeps them honest; s390x is the
# big-endian target.
#
# usage: scripts/test-targets.sh [target...]
#
# Targets are `native` or Zig target triples. With no arguments the default
# list runs. Set ZIG to choose the host compiler.
#
# macOS targets run on the host (x86_64 through Rosetta on Apple silicon).
# Linux and Windows targets need Zig's qemu and Wine integration, which only
# works on a Linux host, so on macOS they run inside a container built from
# linux-test.Dockerfile. Wine runs Windows binaries of the host's own
# architecture only, hence aarch64-windows on Apple silicon.

set -euo pipefail

default_targets=(native x86_64-macos x86_64-linux-musl aarch64-linux-musl s390x-linux-musl aarch64-windows)

zig=${ZIG:-zig}
repo=$(cd "$(dirname "$0")/.." && pwd)
image=openetcher-linux-test

usage() {
    echo "usage: $0 [target...]" >&2
    echo "default targets: ${default_targets[*]}" >&2
    exit 2
}

# Prints and runs one command.
run() {
    echo "+ $*" >&2
    "$@"
}

host_test() {
    (cd "$repo" && run "$zig" build test "$@")
}

# Runs `zig build test <args>` on a Linux host, in a container when needed.
linux_test() {
    if [[ $(uname -s) == Linux ]]; then
        host_test "$@"
        return
    fi
    run docker build --quiet -t "$image" -f "$repo/scripts/linux-test.Dockerfile" "$repo/scripts" >/dev/null
    # Build outputs live in a volume so the host and container caches never
    # mix; tests still create their temporary directories under the repo.
    run docker run --rm \
        -v "$repo:/src" -w /src \
        -v openetcher-zig-cache:/cache \
        -e ZIG_GLOBAL_CACHE_DIR=/cache/global \
        -e ZIG_LOCAL_CACHE_DIR=/cache/local \
        "$image" zig build test "$@"
}

test_target() {
    local target=$1
    case $target in
        native) host_test ;;
        x86_64-macos*) host_test -Dtarget="$target" -frosetta ;;
        *-macos*) host_test -Dtarget="$target" ;;
        # Both flags are ignored when the target runs natively.
        *-linux*) linux_test -Dtarget="$target" -fqemu ;;
        *-windows*) linux_test -Dtarget="$target" -fwine ;;
        *) echo "no way to run tests for target: $target" >&2; return 1 ;;
    esac
}

[[ ${1:-} == -h || ${1:-} == --help ]] && usage
targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=("${default_targets[@]}")

failed=()
for target in "${targets[@]}"; do
    echo "== $target" >&2
    test_target "$target" || failed+=("$target")
done

if [[ ${#failed[@]} -ne 0 ]]; then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
echo "all targets passed: ${targets[*]}" >&2
