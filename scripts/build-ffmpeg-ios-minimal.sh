#!/usr/bin/env bash
#
# 精简版 FFmpeg（iOS 静态库，arm64 + arm64e）
#   用法: ./build-ffmpeg-ios-minimal.sh <源码目录> <输出目录>
#   产物: <输出>/lib/libav*.a (FAT) + <输出>/include
#
# 只编 VCam 用到的组件：rtsp/rtp/rtmp + h264/hevc/aac + swscale/swresample
#
set -euo pipefail

SRC="${1:?需要 ffmpeg 源码目录}"
OUT="${2:?需要输出目录}"
ARCHS="${ARCHS:-arm64 arm64e}"
MIN_IOS="${MIN_IOS:-13.0}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK = $SDK"
mkdir -p "$OUT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "$OUT" && pwd)"

for ARCH in $ARCHS; do
  echo "==> building ffmpeg for $ARCH"
  BUILD="$ROOT/build-$ARCH"
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  cd "$BUILD"

  BASEFLAGS="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS"

  "$SRC/configure" \
    --prefix="$BUILD/install" \
    --target-os=darwin \
    --arch=aarch64 \
    --cpu=arm64 \
    --cc="xcrun --sdk iphoneos clang" \
    --cxx="xcrun --sdk iphoneos clang++" \
    --as="xcrun --sdk iphoneos clang" \
    --ar="xcrun --sdk iphoneos ar" \
    --ranlib="xcrun --sdk iphoneos ranlib" \
    --strip="xcrun --sdk iphoneos strip" \
    --enable-cross-compile \
    --sysroot="$SDK" \
    --extra-cflags="$BASEFLAGS" \
    --extra-cxxflags="$BASEFLAGS" \
    --extra-ldflags="$BASEFLAGS" \
    --enable-pic \
    --disable-programs --disable-doc --disable-debug --disable-stripping \
    --disable-shared --enable-static --disable-autodetect \
    --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
    --disable-avdevice --disable-avfilter --disable-postproc \
    --disable-encoders --disable-muxers --disable-filters --disable-everything \
    --enable-network \
    --enable-protocol=file,tcp,udp,http,https,rtmp,rtmps \
    --enable-demuxer=rtsp,rtp,h264,hevc,aac,mov,mp4,m4v,mp3,wav,flv \
    --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_f32le,pcm_s16be,pcm_f32be \
    --enable-parser=h264,hevc,aac,mpegaudio \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
    --enable-swscale --enable-swresample

  make -j"$(sysctl -n hw.ncpu)"
  make install
  cd "$ROOT"
done

echo "==> 合并双架构静态库到 $OUT"
mkdir -p "$OUT/lib" "$OUT/include"
for LIB in avcodec avformat avutil swscale swresample; do
  xcrun lipo -create \
    "$ROOT/build-arm64/install/lib/lib$LIB.a" \
    "$ROOT/build-arm64e/install/lib/lib$LIB.a" \
    -output "$OUT/lib/lib$LIB.a"
done
cp -R "$ROOT/build-arm64/install/include/"* "$OUT/include/"

echo "==> 验证"
for LIB in avcodec avformat avutil swscale swresample; do
  echo -n "lib$LIB.a archs: "
  xcrun lipo -archs "$OUT/lib/lib$LIB.a"
done
