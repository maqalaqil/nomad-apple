#!/bin/sh
set -eu

vendor_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive="$vendor_dir/CoreKiwix-14.2.1-2.tar.gz"
expected="14820648788dddc3df8a89ff0820af60d7efc1cfda6c83602989455263ee1561"
local_archive=false
case "${1:-}" in
    '') ;;
    --archive)
        [ "$#" -eq 2 ] || { printf '%s\n' 'Usage: fetch-corekiwix.sh [--archive PATH]' >&2; exit 2; }
        archive=$2
        local_archive=true
        [ -f "$archive" ] || { printf '%s\n' 'Local CoreKiwix archive does not exist.' >&2; exit 2; }
        ;;
    --help) printf '%s\n' 'Usage: fetch-corekiwix.sh [--archive PATH]'; exit 0 ;;
    *) printf '%s\n' 'Usage: fetch-corekiwix.sh [--archive PATH]' >&2; exit 2 ;;
esac

# Keep the previous working framework until the verified replacement is ready.
stage=$(mktemp -d "$vendor_dir/.corekiwix.XXXXXX")
target="$vendor_dir/CoreKiwix.xcframework"
old="$stage/previous.xcframework"
cleanup() {
    if [ -d "$old" ] && [ ! -e "$target" ]; then mv "$old" "$target"; fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$archive" ]; then
    if ! curl --fail --location --retry 2 --speed-time 30 --speed-limit 100000 --output "$stage/archive.tar.gz" \
        'https://download.kiwix.org/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz'; then
        curl --fail --location --retry 2 --output "$stage/archive.tar.gz" \
            'https://mirrors.dotsrc.org/kiwix/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz'
    fi
    archive="$stage/archive.tar.gz"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != "$expected" ]; then
    printf '%s\n' 'CoreKiwix checksum mismatch. The archive was not extracted.' >&2
    exit 1
fi
tar -xzf "$archive" -C "$stage" --strip-components 2
for slice in ios-arm64 ios-arm64_x86_64-simulator macos-arm64_x86_64; do
    [ -f "$stage/CoreKiwix.xcframework/$slice/merged.a" ] && [ -d "$stage/CoreKiwix.xcframework/$slice/Headers" ] || {
        printf '%s\n' "Missing CoreKiwix slice: $slice" >&2; exit 1;
    }
done
if [ -e "$target" ] || [ -L "$target" ]; then
    [ -d "$target" ] && [ ! -L "$target" ] || { printf '%s\n' 'Refusing to replace an unsafe CoreKiwix destination.' >&2; exit 1; }
    mv "$target" "$old"
fi
mv "$stage/CoreKiwix.xcframework" "$target"
if [ "$local_archive" = false ] && [ "$archive" = "$stage/archive.tar.gz" ]; then
    mv "$archive" "$vendor_dir/CoreKiwix-14.2.1-2.tar.gz"
fi
printf '%s\n' 'Verified CoreKiwix 14.2.1-2 is ready in apple/Vendor/CoreKiwix.xcframework.'
printf '%s\n' 'Available: iOS device, iOS simulator, native macOS. No visionOS slice.'
