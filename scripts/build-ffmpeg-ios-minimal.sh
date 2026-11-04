#!/usr/bin/env bash
#
# 精简版 FFmpeg 构建（备用，不自动生效）
# ---------------------------------------------------------------
# 与 scripts/build-ffmpeg-ios.sh 的唯一区别：只编进我们真正用到的组件，
# 目标是把 __text 从 ~12MB 降到 ~3MB，dylib 从 35MB 降到 8~10MB（与原版同量级）。
#
# 用法（等音视频稳定后再切）：
#   git mv scripts/build-ffmpeg-ios.sh scripts/build-ffmpeg-ios-full.sh
#   git mv scripts/build-ffmpeg-ios-minimal.sh scripts/build-ffmpeg-ios.sh
# 然后跑一次 CI —— 会触发一次冷编译（40~70 分钟），之后恢复缓存。
#
# 切换前请确认以下功能都还要用：
#   - RTSP 拉流（rtsp/rtp）
#   - RTMP 推拉（rtmp/rtmps）
#   - 本地视频文件（mov/mp4/m4v + h264/hevc + aac/mp3/wav）
#   - 音频重采样（swresample）
#   - 视频缩放转格式（swscale）
#
set -euo pipefail

SRC="${1:-vendor/ffmpeg}"
OUT="${2:-vendor/ffmpeg-ios}"
ARCHS="${ARCHS:-arm64 arm64e}"
MIN_IOS="${MIN_IOS:-13.0}"

mkdir -p "$OUT"

for ARCH in $ARCHS; do
    echo "==> building ffmpeg for $ARCH"

    BUILD="build-$ARCH"
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
    cd "$BUILD"

    if [ "$ARCH" = "arm64" ]; then
        HOST="aarch64-apple-darwin"
        EXTRA=""
    else
        HOST="arm64e-apple-darwin"
        EXTRA="--extra-cflags=-arch\ arm64e --extra-ldflags=-arch\ arm64e"
    fi

    # 关键：--disable-everything 之后按需打开
    eval "$SRC/configure" \
        --prefix="$PWD/install" \
        --target-os=darwin \
        --arch=aarch64 \
        --cpu=arm64 \
        --cc="xcrun --sdk iphoneos clang -arch $ARCH" \
        --cxx="xcrun --sdk iphoneos clang++ -arch $ARCH" \
        --as="xcrun --sdk iphoneos clang -arch $ARCH" \
        --ar="xcrun --sdk iphoneos ar" \
        --ranlib="xcrun --sdk iphoneos ranlib" \
        --strip="xcrun --sdk iphoneos strip" \
        --enable-cross-compile \
        --sysroot="$(xcrun --sdk iphoneos --show-sdk-path)" \
        --enable-pic \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-stripping \
        --disable-shared \
        --enable-static \
        --disable-autodetect \
        --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
        --disable-avdevice --disable-avfilter --disable-postproc \
        --disable-encoders --disable-muxers --disable-filters \
        --disable-everything \
        --enable-network \
        --enable-protocol=file,tcp,udp,http,https,rtmp,rtmps \
        --enable-demuxer=rtsp,rtp,h264,hevc,aac,mov,mp4,m4v,mp3,wav,flv \
        --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_f32le,pcm_s16be,pcm_f32be \
        --enable-parser=h264,hevc,aac,mpegaudio \
        --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
        --enable-swscale --enable-swresample \
        --disable-programs \
        $EXTRA

    make -j"$(sysctl -n hw.ncpu)"
    make install
    cd ..
done

echo "==> 合并双架构静态库到 $OUT"
mkdir -p "$OUT/lib" "$OUT/include"
# 结构需与 build-ffmpeg-ios.sh 产物一致：$OUT/lib/libav*.a（FAT）
for LIB in avcodec avformat avutil swscale swresample; do
    xcrun lipo -create \
        "build-arm64/install/lib/lib$LIB.a" \
        "build-arm64e/install/lib/lib$LIB.a" \
        -output "$OUT/lib/lib$LIB.a"
done
cp -R "build-arm64/install/include/"* "$OUT/include/"

echo "==> 验证"
for LIB in avcodec avformat avutil swscale swresample; do
    echo -n "lib$LIB.a archs: "
    xcrun lipo -archs "$OUT/lib/lib$LIB.a"
done
