#!/bin/sh
set -eu
vendor_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive="$vendor_dir/llama-b11960-xcframework.zip"
expected='feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759'
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 --output "$archive.part" \
        'https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip'
    mv "$archive.part" "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != "$expected" ]; then
    printf '%s\n' 'llama.cpp checksum mismatch. The archive was not extracted.' >&2
    exit 1
fi
unzip -q -o "$archive" -d "$vendor_dir"
printf '%s\n' 'Verified llama.cpp b11960 is ready in ipad/Vendor/build-apple/llama.xcframework.'
