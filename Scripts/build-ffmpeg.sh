#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
SDK="${SDK:-$THEOS/sdks/iPhoneOS16.5.sdk}"
if [[ ! -d "$SDK" ]]; then
    SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
fi
TOOLCHAIN="$THEOS/toolchain/linux/iphone/bin"
if [[ ! -x "$TOOLCHAIN/clang" ]] || ! "$TOOLCHAIN/clang" --version >/dev/null 2>&1; then
    TOOLCHAIN="$(dirname "$(xcrun -sdk iphoneos -f clang)")"
fi
DEFAULT_VERSION="8.1.2"
# SHA-256 of ffmpeg-8.1.2.tar.xz. ffmpeg.org only publishes GPG signatures, so
# this value was cross-checked against two independent package managers that
# verify the upstream tarball: Homebrew (ffmpeg@8 formula) and MacPorts
# (ffmpeg8 Portfile, size 11710924 bytes).
DEFAULT_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
VERSION="${FFMPEG_VERSION:-$DEFAULT_VERSION}"
if [[ -z "${FFMPEG_SHA256:-}" && "$VERSION" == "$DEFAULT_VERSION" ]]; then
    FFMPEG_SHA256="$DEFAULT_SHA256"
fi
MINOS="${FFMPEG_MIN_IOS:-15.0}"
BUILD="$ROOT/.build/ffmpeg"
SOURCE="$BUILD/ffmpeg-$VERSION"
OUTPUT="$ROOT/Vendor/FFmpeg"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

verify_tarball() {
    local file="$1"
    if [[ -z "${FFMPEG_SHA256:-}" ]]; then
        echo "WARNING: ************************************************************" >&2
        echo "WARNING: No FFMPEG_SHA256 set for FFmpeg $VERSION." >&2
        echo "WARNING: $file is NOT integrity-checked." >&2
        echo "WARNING: Set FFMPEG_SHA256=<sha256 of ffmpeg-$VERSION.tar.xz> to verify it." >&2
        echo "WARNING: ************************************************************" >&2
        return 0
    fi
    local actual
    actual="$(sha256_of "$file")"
    if [[ "$actual" != "$(printf '%s' "$FFMPEG_SHA256" | tr 'A-F' 'a-f')" ]]; then
        echo "error: SHA-256 mismatch for $file" >&2
        echo "  expected: $FFMPEG_SHA256" >&2
        echo "  actual:   $actual" >&2
        rm -f "$file"
        exit 1
    fi
    echo "Verified $file (sha256 $actual)"
}

mkdir -p "$BUILD" "$OUTPUT/lib"
TARBALL="$BUILD/ffmpeg-$VERSION.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
    curl -L --fail "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" \
        -o "$TARBALL.part"
    mv "$TARBALL.part" "$TARBALL"
fi
verify_tarball "$TARBALL"
if [[ ! -d "$SOURCE" ]]; then
    tar -xf "$TARBALL" -C "$BUILD"
fi

build_arch() {
    local arch="$1"
    local target="$2"
    local directory="$BUILD/build-$arch"
    local prefix="$BUILD/install-$arch"
    rm -rf "$directory" "$prefix"
    mkdir -p "$directory" "$prefix"
    cd "$directory"
    "$SOURCE/configure" \
        --prefix="$prefix" \
        --target-os=darwin \
        --arch=aarch64 \
        --enable-cross-compile \
        --sysroot="$SDK" \
        --cc="$TOOLCHAIN/clang" \
        --cxx="$TOOLCHAIN/clang++" \
        --ar="$TOOLCHAIN/ar" \
        --ranlib="$TOOLCHAIN/ranlib" \
        --nm="$TOOLCHAIN/nm" \
        --strip="$TOOLCHAIN/strip" \
        --extra-cflags="-target $target -miphoneos-version-min=$MINOS -fPIC -fvisibility=hidden" \
        --extra-cxxflags="-target $target -miphoneos-version-min=$MINOS -fPIC -fvisibility=hidden" \
        --extra-ldflags="-target $target -miphoneos-version-min=$MINOS" \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --enable-small \
        --disable-asm \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-autodetect \
        --disable-network \
        --disable-everything \
        --enable-avutil \
        --enable-avcodec \
        --enable-avformat \
        --disable-avdevice \
        --disable-avfilter \
        --enable-swscale \
        --disable-swresample \
        --enable-protocol=file \
        --enable-demuxer=mov,matroska,image2 \
        --enable-muxer=mp4 \
        --enable-bsf=aac_adtstoasc \
        --enable-parser=h264,hevc,vp9,av1,aac,mjpeg,png \
        --enable-decoder=h264,hevc,vp9,av1,aac,mjpeg,png \
        --enable-encoder=h264_videotoolbox,hevc_videotoolbox \
        --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox \
        --disable-iconv \
        --disable-zlib \
        --disable-bzlib \
        --disable-lzma \
        --disable-securetransport \
        --enable-videotoolbox \
        --disable-audiotoolbox \
        --disable-avfoundation
    make -j"$JOBS"
    make install
}

build_arch arm64 "arm64-apple-ios$MINOS"

rm -rf "$OUTPUT/include"
cp -R "$BUILD/install-arm64/include" "$OUTPUT/include"
for library in avformat avcodec avutil swscale; do
    cp "$BUILD/install-arm64/lib/lib$library.a" "$OUTPUT/lib/lib$library.a"
done
cp "$SOURCE/COPYING.LGPLv2.1" "$OUTPUT/COPYING.LGPLv2.1"
cp "$SOURCE/COPYING.LGPLv3" "$OUTPUT/COPYING.LGPLv3"
