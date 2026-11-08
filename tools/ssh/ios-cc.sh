#!/bin/sh
# clang for arm64 iOS 16 (used as CC by the toybox build)
exec "$(xcrun -sdk iphoneos --find clang)" -arch arm64 -isysroot "$(xcrun -sdk iphoneos --show-sdk-path)" -miphoneos-version-min=16.0 "$@"
