#!/usr/bin/env bash
# 精简版 FFmpeg（iOS 静态库，arm64 + arm64e）
# 用法: ./build-ffmpeg-ios-minimal.sh <源码目录> <输出目录>
# 配方照抄 scripts/build-ffmpeg-ios.sh（已知可用），只缩小组件集合
set -euo pipefail

SRC="${1:?need ffmpeg src}"
PREFIX="${2:?need out dir}"
ARCHS="${ARCHS:-arm64 arm64e}"
MIN_IOS="${MIN_IOS:-14.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun -f clang)"
echo "SDK = $SDK"
echo "CC  = $CC"

BUILT=""
for ARCH in $ARCHS; do
  BDIR="$ROOT/build-$ARCH"
  echo ""
  echo "==== build $ARCH ===="
  rm -rf "$BDIR"; mkdir -p "$BDIR"; cd "$BDIR"

  "$SRC/configure" \
    --prefix="$BDIR/out" \
    --arch=arm64 \
    --target-os=darwin \
    --cc="$CC" \
    --sysroot="$SDK" \
    --enable-cross-compile \
    --disable-programs --disable-doc --disable-debug \
    --disable-autodetect \
    --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
    --disable-avdevice --disable-avfilter --disable-postproc \
    --disable-shared --enable-static \
    --enable-network --enable-pic \
    --disable-everything \
    --enable-avformat --enable-avcodec --enable-swscale --enable-swresample \
    --enable-protocol=file,rtsp,rtp,tcp,udp,rtmp,rtmps,http,https \
    --enable-demuxer=rtsp,rtp,flv,mov,mp4,m4v,mpegts,h264,hevc,aac,mp3,wav \
    --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_f32le,pcm_s16be,pcm_f32be \
    --enable-parser=h264,hevc,aac,mpegaudio \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
    --extra-cflags="-arch $ARCH -mios-version-min=$MIN_IOS -O2" \
    --extra-ldflags="-arch $ARCH -mios-version-min=$MIN_IOS"

  make -j"$(sysctl -n hw.ncpu)"
  make install
  BUILT="$BUILT $ARCH"
  echo "==== $ARCH done ===="
done

echo ""
echo "==== lipo ===="
mkdir -p "$PREFIX/lib" "$PREFIX/include"
FIRST="$(echo $BUILT | awk '{print $1}')"
cp -R "$ROOT/build-$FIRST/out/include/." "$PREFIX/include/"

for LIB in "$ROOT/build-$FIRST/out/lib/"*.a; do
  B="$(basename "$LIB")"
  INPUTS=""
  for A in $BUILT; do INPUTS="$INPUTS $ROOT/build-$A/out/lib/$B"; done
  xcrun lipo -create $INPUTS -output "$PREFIX/lib/$B"
  echo -n "  $B : "; xcrun lipo -archs "$PREFIX/lib/$B"
done

echo "==== done ===="
ls -lh "$PREFIX/lib"