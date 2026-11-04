#!/bin/sh
set -eu

vendor_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive="$vendor_dir/CoreKiwix-14.2.1-2.tar.gz"
expected="14820648788dddc3df8a89ff0820af60d7efc1cfda6c83602989455263ee1561"

if [ ! -f "$archive" ]; then
    if ! curl --fail --location --retry 2 --speed-time 30 --speed-limit 100000 --output "$archive.part" \
        'https://download.kiwix.org/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz'; then
        curl --fail --location --retry 2 --output "$archive.part" \
            'https://mirrors.dotsrc.org/kiwix/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz'
    fi
    mv "$archive.part" "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != "$expected" ]; then
    printf '%s\n' 'CoreKiwix checksum mismatch. The archive was not extracted.' >&2
    exit 1
fi
tar -xzf "$archive" -C "$vendor_dir" --strip-components 2
printf '%s\n' 'Verified CoreKiwix 14.2.1-2 is ready in ipad/Vendor/CoreKiwix.xcframework.'
