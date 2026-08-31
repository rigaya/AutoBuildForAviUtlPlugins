#!/bin/bash
# pacman -S mingw-w64-clang-x86_64-toolchain clang64/mingw-w64-clang-x86_64-cmake
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR=`pwd`/build_svtav1
BUILD_CCFLAGS=${BUILD_CCFLAGS:-"-Ofast -ffast-math -fomit-frame-pointer -flto"}
BUILD_LDFLAGS=${BUILD_LDFLAGS:-"-static -static-libgcc -flto -Wl,--gc-sections -Wl,--strip-all"}

SVTAV1_REV=${SVTAV1_REV:-}
SVTAV1_BRANCH=${SVTAV1_BRANCH:-"master"}

echo BUILD_CCFLAGS=${BUILD_CCFLAGS}

PKGCONFIG=pkg-config
CMAKE_TARGET="MSYS Makefiles"

if [ -n "$MSYSTEM" ]; then
    MAKE_PROCESS=$NUMBER_OF_PROCESSORS
else
    MAKE_PROCESS=$(nproc)
fi

#download
mkdir -p $BUILD_DIR/src
cd $BUILD_DIR/src
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.autocrlf
export GIT_CONFIG_VALUE_0=false

ENABLE_AVX512=${ENABLE_AVX512:-"ON"}
TARGET_ARCH="x64"
FFMPEG_ARCH="x86_64"
SVTAV1APPEXE="SvtAv1EncApp.exe"
if [ -n "$MSYSTEM" ]; then
  if [ $MSYSTEM != "MINGW64" ] && [ $MSYSTEM != "CLANG64" ]; then
      echo "This script is for mingw64/clang64 only!"
      exit 1
  fi
  if [ $MSYSTEM == "CLANG64" ]; then
      export CC=${CC:-clang}
      export CXX=${CXX:-clang++}
  else
      export CC=${CC:-gcc}
      export CXX=${CXX:-g++}
  fi
  # Keep distributed binaries CPU-neutral.  Architecture-specific tuning can
  # still be tested explicitly through SVTAV1_CPU_FLAGS.
  BUILD_CCFLAGS="${BUILD_CCFLAGS} ${SVTAV1_CPU_FLAGS:-}"
  ENABLE_AVX512=${ENABLE_AVX512_WINDOWS:-"ON"}
else
  export CC=${CC:-clang}
  export CXX=${CXX:-clang++}
  AVX512_COUNT=$(cat /proc/cpuinfo | grep flags | grep avx512 | wc -l)
  if [ $AVX512_COUNT -eq 0 ]; then
    ENABLE_AVX512="OFF"
  fi
  CMAKE_TARGET="Unix Makefiles"
  SVTAV1APPEXE="SvtAv1EncApp"
fi

if [ -z "${PGO_TRAIN_AVX512+x}" ]; then
  PGO_TRAIN_AVX512="OFF"
  if [ "${ENABLE_AVX512}" = "ON" ] && [ -r /proc/cpuinfo ] &&
     awk 'BEGIN { IGNORECASE=1 } /^(flags|features)[[:space:]]*:.*avx512f/ { found=1; exit } END { exit !found }' /proc/cpuinfo; then
    PGO_TRAIN_AVX512="ON"
  fi
fi
echo PGO_TRAIN_AVX512=${PGO_TRAIN_AVX512}

ENABLE_PGO=ON
IS_CLANG=OFF
CXX_VERSION=$("$CXX" --version 2>/dev/null)
if [[ "$CXX_VERSION" == *clang* ]]; then
  IS_CLANG=ON
fi
if [ $IS_CLANG == "ON" ]; then
  ENABLE_PGO=ON
  if [ -z "${LLVM_PROFDATA:-}" ]; then
    CLANG_VERSION=$($CC -dumpversion | cut -d. -f1)
    LLVM_PROFDATA=$(command -v llvm-profdata || command -v llvm-profdata-${CLANG_VERSION})
  fi
  if [ -z "${LLVM_PROFDATA}" ]; then
    echo "clang ${CLANG_VERSION} に対応する llvm-profdata が見つかりません。"
    exit 1
  fi
  echo LLVM_PROFDATA=${LLVM_PROFDATA}
  # extend stack to 32MB to avoid stack overflow (MinGW/Windows only)
  if [ -n "$MSYSTEM" ]; then
    BUILD_LDFLAGS="${BUILD_LDFLAGS} -Wl,--icf=all -Wl,--stack,33554432"
  fi
fi

if [ $ENABLE_PGO == "ON" ]; then
  export PROFILE_GEN_CC="-fprofile-generate"
  export PROFILE_GEN_LD="-fprofile-generate"
  export PROFILE_USE_CC="-fprofile-use"
  export PROFILE_USE_LD="-fprofile-use"
  if [ $IS_CLANG == "ON" ]; then
    export PROFILE_GEN_CC="-fprofile-generate -gline-tables-only"
    export PROFILE_GEN_LD="-fprofile-generate -gline-tables-only"
  else
    export PROFILE_USE_CC="-fprofile-use -fprofile-correction -fprofile-partial-training"
    export PROFILE_USE_LD="-fprofile-use -fprofile-correction -fprofile-partial-training"
  fi
fi

if [ ! -n "$INSTALL_DIR" ]; then
  INSTALL_DIR=$BUILD_DIR/$TARGET_ARCH/build
fi

if [ -d "SVT-AV1" ]; then
    cd SVT-AV1
    git reset --hard HEAD
    git pull
    cd ..
else
    git clone https://gitlab.com/AOMediaCodec/SVT-AV1.git
fi

cd SVT-AV1
if [ "${SVTAV1_REV}" != "" ]; then
    git checkout --force ${SVTAV1_REV}
else
    git checkout --force ${SVTAV1_BRANCH}
    git reset --hard origin/${SVTAV1_BRANCH}
fi
cd ..

mkdir -p $BUILD_DIR/$TARGET_ARCH
cd $BUILD_DIR/$TARGET_ARCH
if [ -d "SVT-AV1" ]; then
    rm -rf SVT-AV1
fi
cp -r ../src/SVT-AV1 SVT-AV1

cd $BUILD_DIR/$TARGET_ARCH/SVT-AV1
mkdir -p build/msys2
cd build/msys2

if [ $ENABLE_PGO == "ON" ]; then

  cmake -G "${CMAKE_TARGET}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DNATIVE=OFF \
    -DSVT_AV1_LTO=ON \
    -DENABLE_NASM=ON \
    -DENABLE_AVX512=${ENABLE_AVX512} \
    $SVTAV1_CMAKE_OPT \
    -DCMAKE_ASM_NASM_COMPILER=nasm \
    -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
    -DCMAKE_C_FLAGS="${BUILD_CCFLAGS} ${PROFILE_GEN_CC}" \
    -DCMAKE_CXX_FLAGS="${BUILD_CCFLAGS} ${PROFILE_GEN_CC}" \
    -DCMAKE_EXE_LINKER_FLAGS="${BUILD_LDFLAGS} ${PROFILE_GEN_LD}" \
    ../..

  make SvtAv1EncApp -j${MAKE_PROCESS}

  prof_files=()
  prof_weights=()
  prof_idx=0
  # 先頭14本は通常の8/10bit CRF経路。特殊オプションで分岐確率を薄めないよう重くする。
  PGO_STANDARD_PROFILE_COUNT=14
  PGO_STANDARD_WEIGHT=${PGO_STANDARD_WEIGHT:-3}

  # 1080pのCI素材は30フレーム。連結して長いGOPと時間方向の処理を学習する。
  PGO_MAIN_WIDTH=1920
  PGO_MAIN_HEIGHT=1080
  PGO_YUV_REPEAT=${PGO_YUV_REPEAT:-20}
  PGO_YUV_PATH=${YUV_PATH}
  PGO_YUV_PATH_10=${YUV_PATH_10}
  PGO_720_PATH=${YUV_PATH_720:-}
  PGO_720_PATH_10=${YUV_PATH_720_10:-}
  PGO_YUV_GENERATED=OFF
  function cleanup_pgo_yuv() {
    if [ "${PGO_YUV_GENERATED}" = "ON" ]; then
      rm -f "${PGO_YUV_PATH}" "${PGO_YUV_PATH_10}"
    fi
  }
  trap cleanup_pgo_yuv EXIT
  if [ ! -r "${PGO_YUV_PATH}" ] || [ ! -r "${PGO_YUV_PATH_10}" ]; then
    echo "PGO用1080p素材を読み込めません。YUV_PATHとYUV_PATH_10を確認してください。"
    exit 1
  fi
  if { [ -n "${PGO_720_PATH}" ] && [ ! -r "${PGO_720_PATH}" ]; } ||
     { [ -n "${PGO_720_PATH_10}" ] && [ ! -r "${PGO_720_PATH_10}" ]; }; then
    echo "PGO用720p素材を読み込めません。YUV_PATH_720とYUV_PATH_720_10を確認してください。"
    exit 1
  fi
  if [ ${PGO_YUV_REPEAT} -gt 1 ]; then
    PGO_YUV_PATH=`pwd`/pgo_test_8.yuv
    PGO_YUV_PATH_10=`pwd`/pgo_test_10.yuv
    PGO_YUV_GENERATED=ON
    : > "${PGO_YUV_PATH}"
    : > "${PGO_YUV_PATH_10}"
    for ((repeat_idx = 0; repeat_idx < PGO_YUV_REPEAT; repeat_idx++)); do
      cat "${YUV_PATH}" >> "${PGO_YUV_PATH}"
      cat "${YUV_PATH_10}" >> "${PGO_YUV_PATH_10}"
    done
  fi

  function run_prof() {
    local prof_weight=$1
    shift
    ../../Bin/Release/${SVTAV1APPEXE} "$@"
    prof_idx=$((prof_idx + 1))
    
    if [ $IS_CLANG == "ON" ]; then
      for file in default_*_0.profraw; do
        new_file="${file%.profraw}_${prof_idx}.${file##*.}"
        mv "$file" "$new_file"
        echo ${new_file}
        prof_files+=( "${new_file}" )
        prof_weights+=( "${prof_weight}" )
      done
    fi
  }

  # Cover slow through fast presets and both bit depths.  The additional
  # preset-3 and tiled film-grain runs improve common workloads without
  # allowing one command line to dominate the distribution build profile.
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  2 -n 30 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  3 -n 300 --asm avx2 \
    --enable-variance-boost 1 --qp-scale-compress-strength 2 --enable-tf 2 --ac-bias 1.0 --luminance-qp-bias 10
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  4 -n 300 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  5 -n 300 --asm avx2 \
    --film-grain 10 --film-grain-denoise 1 --enable-overlays 1 --tile-rows 1 --tile-columns 1
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  6 -n 300 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  8 -n 600 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset 10 -n 600 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  2 -n 30 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  3 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  4 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  5 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  6 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  8 -n 600 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 10 -n 600 --input-depth 10 --asm avx2

  # preset 0/1固有のOBMC・inter-intra探索を短尺で学習する。preset 1はpreset 0で通らないOBMC制御も補う。
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset 0 -n 30 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset 1 -n 30 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 0 -n 30 --input-depth 10 --asm avx2

  # 720pは解像度クラス固有の分岐を残すため、8/10bitの低速・高速presetを短く実行する。
  if [ -n "${PGO_720_PATH}" ] && [ -n "${PGO_720_PATH_10}" ]; then
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 -b /dev/null -i "${PGO_720_PATH}"    --preset 4 -n 30 --asm avx2
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 -b /dev/null -i "${PGO_720_PATH}"    --preset 8 -n 60 --asm avx2
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 -b /dev/null -i "${PGO_720_PATH_10}" --preset 4 -n 30 --input-depth 10 --asm avx2
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 -b /dev/null -i "${PGO_720_PATH_10}" --preset 8 -n 60 --input-depth 10 --asm avx2
  fi

  # CRF以外の主要な制御経路は短い実行で学習し、通常経路のカウンタを過度に薄めない。
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --rc 1 --tbr 2500 --keyint 120 --pred-struct 2 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 8 -n 120 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --rc 2 --tbr 2500 --keyint 120 --rtc 1 --pred-struct 1 --hierarchical-levels 2 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 8 -n 120 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --rc 2 --tbr 2500 --keyint 120 --rtc 0 --pred-struct 1 --recode-loop 3 --undershoot-pct 5 --overshoot-pct 5 --buf-sz 1000 --buf-initial-sz 600 --buf-optimal-sz 600 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 8 -n 120 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --pred-struct 0 --keyint 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --tune 5 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --tune 2 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --superres-mode 1 --superres-denom 12 --superres-kf-denom 12 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --superres-mode 3 --superres-qthres 0 --superres-kf-qthres 0 --scm 0 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --rc 0 --qp 30 --aq-mode 1 --enable-qm 1 --qm-min 4 --qm-max 12 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --rc 0 --qp 30 --aq-mode 1 --enable-qm 1 --qm-min 4 --qm-max 12 --chroma-qm-min 4 --chroma-qm-max 12 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 6 -n 60 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --resize-mode 1 --resize-denom 12 --resize-kf-denom 12 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --resize-mode 1 --resize-denom 16 --resize-kf-denom 16 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --superres-mode 1 --superres-denom 12 --superres-kf-denom 12 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 6 -n 60 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --resize-mode 1 --resize-denom 16 --resize-kf-denom 16 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 6 -n 60 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --resize-mode 1 --resize-denom 12 --resize-kf-denom 12 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 6 -n 60 --input-depth 10 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --film-grain 10 --film-grain-denoise 1 --adaptive-film-grain 0 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 5 -n 120 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --pred-struct 0 --keyint 1 --scm 1 --enable-intrabc 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --fast-decode 2 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 8 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --tune 0 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 6 -n 60 --asm avx2
  run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --passes 2 --rc 1 --tbr 2500 --keyint 120 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 8 -n 60 --asm avx2
  if [ "${ENABLE_AVX512}" = "ON" ] && [ "${PGO_TRAIN_AVX512}" = "ON" ]; then
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  2 -n 30 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  3 -n 300 --asm avx512 \
      --enable-variance-boost 1 --qp-scale-compress-strength 2 --enable-tf 2 --ac-bias 1.0 --luminance-qp-bias 10
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  4 -n 300 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  5 -n 300 --asm avx512 \
      --film-grain 10 --enable-overlays 1
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  6 -n 300 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  8 -n 600 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}"    --preset 10 -n 600 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  2 -n 30 --input-depth 10 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  3 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  4 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  5 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  6 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  8 -n 600 --input-depth 10 --asm avx512
    run_prof 1 -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" --crf 30 --scd 1 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 10 -n 600 --input-depth 10 --asm avx512
  fi

  if [ $IS_CLANG == "ON" ]; then
    echo ${prof_files[@]}
    prof_merge_args=()
    for idx in "${!prof_files[@]}"; do
      prof_weight=${prof_weights[$idx]}
      if [ ${idx} -lt ${PGO_STANDARD_PROFILE_COUNT} ]; then
        prof_weight=$((prof_weight * PGO_STANDARD_WEIGHT))
      fi
      prof_merge_args+=( "-weighted-input=${prof_weight},${prof_files[$idx]}" )
    done
    "${LLVM_PROFDATA}" merge --sparse -output=default.profdata "${prof_merge_args[@]}"
    "${LLVM_PROFDATA}" merge -output=default.full.profdata "${prof_merge_args[@]}"
    "${LLVM_PROFDATA}" show --all-functions --counts default.profdata
    bash "${SCRIPT_DIR}/analyze_svtav1_profdata.sh" default.full.profdata

    PROFILE_USE_CC=${PROFILE_USE_CC}=`pwd`/default.profdata
    PROFILE_USE_LD=${PROFILE_USE_LD}=`pwd`/default.profdata
  fi

  cleanup_pgo_yuv
  trap - EXIT
fi

cmake -G "${CMAKE_TARGET}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DNATIVE=OFF \
  -DENABLE_NASM=ON \
  -DENABLE_AVX512=${ENABLE_AVX512} \
  $SVTAV1_CMAKE_OPT \
  -DCMAKE_ASM_NASM_COMPILER=nasm \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
  -DCMAKE_C_FLAGS="${BUILD_CCFLAGS} ${PROFILE_USE_CC}" \
  -DCMAKE_CXX_FLAGS="${BUILD_CCFLAGS} ${PROFILE_USE_CC}" \
  -DCMAKE_EXE_LINKER_FLAGS="${BUILD_LDFLAGS} ${PROFILE_USE_LD}" \
  ../..

make SvtAv1EncApp -j${MAKE_PROCESS}
make SvtAv1EncApp install
