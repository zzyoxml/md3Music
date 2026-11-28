#!/usr/bin/env bash
#
# 一键交叉编译 libkugou_server.so（4 个 Android ABI）并覆盖 jniLibs
#
# 前置要求：
#   1. rustup 已安装 android target（未装时本脚本会自动安装）：
#        rustup target add aarch64-linux-android armv7-linux-androideabi \
#                         i686-linux-android x86_64-linux-android
#   2. Android NDK（ndkVersion 见 android/app/build.gradle.kts，本项目为 28.2.13676358）
#
# NDK 查找顺序：
#   $ANDROID_NDK_HOME
#   $ANDROID_NDK
#   ~/Android/Sdk/ndk/<version>（取存在的最高版本）
#
# 产物复制目标（默认，可用 --out 覆盖）：
#   <repo>/android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/libkugou_server.so
#
# 用法：
#   ./build_android.sh              # 编译 4 ABI 并覆盖 jniLibs
#   ./build_android.sh --no-copy    # 只编译不复制
#   ./build_android.sh --out /path/to/jniLibs
#   ./build_android.sh --host       # 额外编译主机 release（验证编译/测试用）
#
set -euo pipefail

cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
DEFAULT_JNI="$REPO_ROOT/android/app/src/main/jniLibs"
OUT_DIR="$DEFAULT_JNI"
DO_COPY=1
DO_HOST=0
BUILD_TYPE="release"

for arg in "$@"; do
  case "$arg" in
    --no-copy) DO_COPY=0 ;;
    --host)    DO_HOST=1 ;;
    --out)     echo "错误：--out 需要跟一个路径参数（如 --out /path/to/jniLibs）" >&2; exit 1 ;;
    --out=*)   OUT_DIR="${arg#--out=}" ;;
    --debug)   BUILD_TYPE="debug" ;;
    -h|--help)
      echo "用法：./build_android.sh [--no-copy] [--host] [--debug] [--out=<jniLibs目录>]"
      exit 0 ;;
    *)
      echo "未知参数：$arg" >&2
      echo "用法：./build_android.sh [--no-copy] [--host] [--debug] [--out=<jniLibs目录>]" >&2
      exit 1 ;;
  esac
done

# ---------- 1. 定位 NDK ----------
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  NDK="$ANDROID_NDK_HOME"
elif [ -n "${ANDROID_NDK:-}" ] && [ -d "$ANDROID_NDK" ]; then
  NDK="$ANDROID_NDK"
elif [ -d "$HOME/Android/Sdk/ndk" ]; then
  NDK="$(ls -1d "$HOME/Android/Sdk/ndk"/* 2>/dev/null | sort -V | tail -1)"
else
  echo "错误：找不到 Android NDK。请设置 ANDROID_NDK_HOME，或安装 NDK 到 ~/Android/Sdk/ndk/" >&2
  exit 1
fi
BIN="$NDK/toolchains/llvm/prebuilt"
if [ -d "$BIN/linux-x86_64" ]; then
  BIN="$BIN/linux-x86_64/bin"
elif [ -d "$BIN/darwin-x86_64" ]; then
  BIN="$BIN/darwin-x86_64/bin"
else
  echo "错误：NDK 缺少 LLVM 预编译工具链：$NDK" >&2
  exit 1
fi

echo "使用 NDK：$NDK"

# ---------- 2. 确认 rustup / android target ----------
if command -v rustup >/dev/null 2>&1; then
  for t in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
    if ! rustup target list --installed | grep -qx "$t"; then
      echo "安装 rustup target：$t"
      rustup target add "$t"
    fi
  done
else
  echo "提示：未检测到 rustup，跳过 target 自动安装（请自行确认 4 个 android target 已安装）"
fi

# ---------- 3. 构建 ----------
# 各 target 对应的 clang 包装脚本（NDK 只提供带 API 级别的名字）
# CC/AR 用 <target 全小写>（cc-rs 读取 CC_<target>，target 里 - 转 _）
# cargo 的 linker 变量必须全大写，否则会被静默忽略
build() {
  local target="$1"
  local clang="$2"
  # aarch64-linux-android -> CC_aarch64_linux_android / CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
  local ccvar="CC_${target//-/_}"
  local arvar="AR_${target//-/_}"
  local lc="${target//-/_}"          # 小写形式 aarch64_linux_android
  local linker="CARGO_TARGET_${lc^^}_LINKER"   # ^^ 转大写
  local release_flag=""
  [ "$BUILD_TYPE" = "release" ] && release_flag="--release"
  echo "==> 构建 $target ($BUILD_TYPE)"
  env "$ccvar"="$BIN/$clang" \
      "$arvar"="$BIN/llvm-ar" \
      "$linker"="$BIN/$clang" \
      cargo build --target "$target" $release_flag
}

build aarch64-linux-android    aarch64-linux-android21-clang
build armv7-linux-androideabi  armv7a-linux-androideabi21-clang
build i686-linux-android       i686-linux-android21-clang
build x86_64-linux-android     x86_64-linux-android21-clang

if [ "$DO_HOST" = "1" ]; then
  echo "==> 构建主机 release（编译/测试验证）"
  cargo build --release
fi

# ---------- 4. 复制到 jniLibs ----------
if [ "$DO_COPY" = "1" ]; then
  declare -A TARGET_TO_ABI=(
    [aarch64-linux-android]=arm64-v8a
    [armv7-linux-androideabi]=armeabi-v7a
    [i686-linux-android]=x86
    [x86_64-linux-android]=x86_64
  )
  echo "==> 复制到 $OUT_DIR"
  for t in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
    abi="${TARGET_TO_ABI[$t]}"
    src="target/$t/$BUILD_TYPE/libkugou_server.so"
    mkdir -p "$OUT_DIR/$abi"
    cp "$src" "$OUT_DIR/$abi/libkugou_server.so"
    echo "    $abi: $(stat -c%s "$src") bytes"
  done
  echo
  echo "完成。jniLibs 已更新，可直接 flutter build apk --release --split-per-abi"
else
  echo
  echo "完成（--no-copy）。产物位于 target/<target>/$BUILD_TYPE/libkugou_server.so"
fi
