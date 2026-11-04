#!/bin/bash
#
# build-ffmpeg-ios.sh —— 为 iOS 交叉编译 FFmpeg（全组件 + arm64/arm64e 双架构）
#
# 产物：vendor/ffmpeg-ios/{include,lib}
#       lib/*.a 为 lipo 后的 fat 静态库（含 arm64 + arm64e）
#
set -euo pipefail

FFMPEG_VER="${FFMPEG_VER:-7.1}"
ARCHS_LIST="${ARCHS_LIST:-arm64 arm64e}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/vendor"
PREFIX="$ROOT/ffmpeg-ios"
SRC="$ROOT/ffmpeg-$FFMPEG_VER"

mkdir -p "$ROOT"

# ── 缓存命中就直接退出（并校验双架构切片）──
# 只看文件在不在不够：中途超时/中断会留下只有 arm64 的库，
# 命中缓存后跳过编译 → lipo 报 same architecture，或产出缺 arm64e 的 dylib
# （A12 以上机型注入直接闪退）。这里逐库逐架构校验。
if [ "${FFMPEG_FORCE_REBUILD:-0}" != "1" ] && [ -d "$PREFIX/include" ] && [ -d "$PREFIX/lib" ]; then
  _missing=0
  for _lib in libavformat.a libavcodec.a libavutil.a libswscale.a libswresample.a; do
    [ -f "$PREFIX/lib/$_lib" ] || _missing=1
    _archs="$(lipo -archs "$PREFIX/lib/$_lib" 2>/dev/null || echo unknown)"
    for _arch in $ARCHS_LIST; do
      case " $_archs " in
        *" $_arch "*) ;;
        *) echo "==> $_lib 缺 $_arch 切片（实际：$_archs）"; _missing=1 ;;
      esac
    done
  done
  if [ "$_missing" = "0" ]; then
    echo "==> 已有 FFmpeg 产物（$(lipo -archs "$PREFIX/lib/libavformat.a")），跳过编译"
    echo "    强制重建：FFMPEG_FORCE_REBUILD=1 ./scripts/build-ffmpeg-ios.sh"
    exit 0
  fi
  echo "==> 产物不完整，重新编译"
fi

if [ ! -d "$SRC" ]; then
  echo "==> 下载 ffmpeg $FFMPEG_VER"
  curl -fL --retry 5 --retry-delay 5 -o "$ROOT/ffmpeg.tar.xz" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
  tar xf "$ROOT/ffmpeg.tar.xz" -C "$ROOT"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun -f clang)"

BUILT_ARCHS=""
for ARCH in $ARCHS_LIST; do
  BDIR="$ROOT/build-$ARCH"
  echo ""
  echo "==================== 编译 $ARCH ===================="
  rm -rf "$BDIR"
  mkdir -p "$BDIR"
  cd "$BDIR"

  # ── 最小化开关（默认关）───────────────────────────────
  #   FFMPEG_MINIMAL=1 只编需要的组件，体积可降到约 1/3
  #   风险：漏掉某个组件会拉流失败/解码失败，改完必须逐项验证
  #     · 拉流（rtsp://）
  #     · 软解（H.264 / HEVC）
  #     · AAC 音频
  #     · rtmp:// （如果你也用）
  #   回退：不设该变量重新编即可（脚本会重建）
  if [ "${FFMPEG_MINIMAL:-0}" = "1" ]; then
    MIN_FLAGS="--disable-everything \
      --enable-avformat --enable-avcodec --enable-swscale --enable-swresample \
      --enable-network \
      --enable-protocol=file,rtsp,rtp,tcp,udp,rtmp,http,https \
      --enable-demuxer=rtsp,flv,mov,mpegts,h264,aac \
      --enable-decoder=h264,hevc,aac,mp3 \
      --enable-parser=h264,hevc,aac"
    echo "==> FFMPEG_MINIMAL=1：仅编译最小组件集"
  else
    MIN_FLAGS=""
  fi

  # 全组件：不再 --disable-everything，只关掉 CLI/文档/外部依赖
  "$SRC/configure" \
    --prefix="$BDIR/out" \
    --arch=arm64 \
    --target-os=darwin \
    --cc="$CC" \
    --sysroot="$SDK" \
    --enable-cross-compile \
    --disable-programs \
    --disable-avdevice \
    --disable-avfilter \
    --disable-postproc \
    --disable-doc \
    --disable-debug \
      --disable-autodetect \
    --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
    --enable-network \
    --enable-pic \
    --extra-cflags="-arch $ARCH -mios-version-min=14.0 -O2" \
    --extra-ldflags="-arch $ARCH -mios-version-min=14.0" \
    $MIN_FLAGS

  make -j"$(sysctl -n hw.ncpu)"
  make install

  BUILT_ARCHS="$BUILT_ARCHS $ARCH"
  echo "==== $ARCH 完成 ===="
done

echo ""
echo "==================== 合并架构 (lipo) ===================="
mkdir -p "$PREFIX/lib" "$PREFIX/include"

FIRST_ARCH="$(echo $BUILT_ARCHS | awk '{print $1}')"
cp -R "$ROOT/build-$FIRST_ARCH/out/include/." "$PREFIX/include/"

for LIB in "$ROOT"/build-"$FIRST_ARCH"/out/lib/*.a; do
  BASE="$(basename "$LIB")"
  INPUTS=""
  for ARCH in $BUILT_ARCHS; do
    INPUTS="$INPUTS $ROOT/build-$ARCH/out/lib/$BASE"
  done
  if [ "$(echo $BUILT_ARCHS | wc -w)" -gt 1 ]; then
    lipo -create $INPUTS -output "$PREFIX/lib/$BASE"
  else
    cp "$LIB" "$PREFIX/lib/$BASE"
  fi
  echo "  $BASE -> $(lipo -archs "$PREFIX/lib/$BASE")"
done

echo ""
echo "==> 产物："
ls -lh "$PREFIX/lib" | sed -n '1,20p'
