#!/bin/sh
set -eu
vendor_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive="$vendor_dir/llama-b11960-xcframework.zip"
expected='feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759'
local_archive=false
case "${1:-}" in
    '') ;;
    --archive)
        [ "$#" -eq 2 ] || { printf '%s\n' 'Usage: fetch-llama.sh [--archive PATH]' >&2; exit 2; }
        archive=$2
        local_archive=true
        [ -f "$archive" ] || { printf '%s\n' 'Local llama.cpp archive does not exist.' >&2; exit 2; }
        ;;
    --help) printf '%s\n' 'Usage: fetch-llama.sh [--archive PATH]'; exit 0 ;;
    *) printf '%s\n' 'Usage: fetch-llama.sh [--archive PATH]' >&2; exit 2 ;;
esac

stage=$(mktemp -d "$vendor_dir/.llama.XXXXXX")
target="$vendor_dir/build-apple/llama.xcframework"
old="$stage/previous.xcframework"
cleanup() {
    if [ -d "$old" ] && [ ! -e "$target" ]; then mv "$old" "$target"; fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 --output "$stage/archive.zip" \
        'https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip'
    archive="$stage/archive.zip"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != "$expected" ]; then
    printf '%s\n' 'llama.cpp checksum mismatch. The archive was not extracted.' >&2
    exit 1
fi
unzip -q "$archive" -d "$stage"
for slice in ios-arm64 macos-arm64_x86_64; do
    [ -f "$stage/build-apple/llama.xcframework/$slice/llama.framework/llama" ] || {
        printf '%s\n' "Missing llama.cpp slice: $slice" >&2; exit 1;
    }
done
parent="$vendor_dir/build-apple"
if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] && [ ! -L "$parent" ] || { printf '%s\n' 'Refusing an unsafe build-apple directory.' >&2; exit 1; }
else
    mkdir "$parent"
fi
if [ -e "$target" ] || [ -L "$target" ]; then
    [ -d "$target" ] && [ ! -L "$target" ] || { printf '%s\n' 'Refusing to replace an unsafe llama.cpp destination.' >&2; exit 1; }
    mv "$target" "$old"
fi
mv "$stage/build-apple/llama.xcframework" "$target"
if [ "$local_archive" = false ] && [ "$archive" = "$stage/archive.zip" ]; then
    mv "$archive" "$vendor_dir/llama-b11960-xcframework.zip"
fi
printf '%s\n' 'Verified llama.cpp b11960 is ready in apple/Vendor/build-apple/llama.xcframework.'
printf '%s\n' 'Available: iOS device and native macOS. No iOS simulator or visionOS slice.'
