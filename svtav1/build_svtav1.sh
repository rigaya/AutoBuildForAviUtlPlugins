#!/bin/bash
# pacman -S mingw-w64-clang-x86_64-toolchain clang64/mingw-w64-clang-x86_64-cmake
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR=`pwd`/build_svtav1
BUILD_CCFLAGS=${BUILD_CCFLAGS:-"-Ofast -ffast-math -fomit-frame-pointer -flto=full -fno-exceptions -fno-rtti -falign-functions=32 -falign-loops=32 -ffunction-sections -fdata-sections"}
BUILD_LDFLAGS=${BUILD_LDFLAGS:-"-static -static-libgcc -flto=full -Wl,--gc-sections -Wl,--strip-all -Wl,-O2"}

SVTAV1_REV=${SVTAV1_REV:-}
SVTAV1_BRANCH=${SVTAV1_BRANCH:-"master"}

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
  # unwind 表を削ってコード密度を上げる。例外は使わない。
  BUILD_CCFLAGS="${BUILD_CCFLAGS} -fno-asynchronous-unwind-tables"
  # extend stack to 32MB to avoid stack overflow (MinGW/Windows only)
  if [ -n "$MSYSTEM" ]; then
    BUILD_LDFLAGS="${BUILD_LDFLAGS} -Wl,--icf=all -Wl,--lto-O3 -Wl,--stack,33554432"
  else
    BUILD_LDFLAGS="${BUILD_LDFLAGS} -Wl,--lto-O3"
  fi
  if [ "${SVTAV1_KEEP_CMOV:-ON}" = "ON" ]; then
    BUILD_LDFLAGS="${BUILD_LDFLAGS} -Wl,-mllvm,-x86-cmov-converter=false"
    echo "SVTAV1_KEEP_CMOV=ON (-Wl,-mllvm,-x86-cmov-converter=false)"
  fi
else
  BUILD_CCFLAGS="${BUILD_CCFLAGS} --param=l1-cache-size=32 --param=l1-cache-line-size=64 --param=l2-cache-size=512"
fi

PGO_USE_EXTRA_CC=""
PGO_USE_EXTRA_LD=""
if [ $ENABLE_PGO == "ON" ]; then
  export PROFILE_GEN_CC="-fprofile-generate"
  export PROFILE_GEN_LD="-fprofile-generate"
  export PROFILE_USE_CC="-fprofile-use"
  export PROFILE_USE_LD="-fprofile-use"
  if [ $IS_CLANG == "ON" ]; then
    export PROFILE_GEN_CC="-fprofile-generate -fprofile-update=atomic -gline-tables-only -funique-internal-linkage-names"
    export PROFILE_GEN_LD="-fprofile-generate -fprofile-update=atomic -gline-tables-only -funique-internal-linkage-names"
    PGO_USE_EXTRA_CC="-funique-internal-linkage-names"
    PGO_USE_EXTRA_LD="-funique-internal-linkage-names -Wl,-mllvm,-enable-ext-tsp-block-placement"
    export PROFILE_USE_CC="-fprofile-use ${PGO_USE_EXTRA_CC}"
    export PROFILE_USE_LD="-fprofile-use ${PGO_USE_EXTRA_LD}"
  else
    export PROFILE_GEN_CC="-fprofile-generate -fprofile-update=atomic"
    export PROFILE_GEN_LD="-fprofile-generate -fprofile-update=atomic"
    export PROFILE_USE_CC="-fprofile-use -fprofile-correction -fprofile-partial-training"
    export PROFILE_USE_LD="-fprofile-use -fprofile-correction -fprofile-partial-training"
  fi
fi
echo BUILD_CCFLAGS=${BUILD_CCFLAGS}
echo BUILD_LDFLAGS=${BUILD_LDFLAGS}

if [ ! -n "$INSTALL_DIR" ]; then
  INSTALL_DIR=$BUILD_DIR/$TARGET_ARCH/build
fi

if [ -d "SVT-AV1" ]; then
    cd SVT-AV1
    git fetch origin
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

  # 1080pのCI素材は約30フレーム。エンコーダは -n が入力より多いと先頭へループするので、
  # 巨大な連結YUVは作らず、短いクリップをメモリに載せてGOP長だけ回す。
  PGO_MAIN_WIDTH=1920
  PGO_MAIN_HEIGHT=1080
  PGO_YUV_PATH=${YUV_PATH}
  PGO_YUV_PATH_10=${YUV_PATH_10}
  PGO_720_PATH=${YUV_PATH_720:-}
  PGO_720_PATH_10=${YUV_PATH_720_10:-}
  PGO_CLIP_FRAMES=${PGO_CLIP_FRAMES:-30}
  PGO_PROF_DIR=`pwd`/pgo_raw
  rm -rf "${PGO_PROF_DIR}"
  mkdir -p "${PGO_PROF_DIR}"
  if [ ! -r "${PGO_YUV_PATH}" ] || [ ! -r "${PGO_YUV_PATH_10}" ]; then
    echo "PGO用1080p素材を読み込めません。YUV_PATHとYUV_PATH_10を確認してください。"
    exit 1
  fi
  if { [ -n "${PGO_720_PATH}" ] && [ ! -r "${PGO_720_PATH}" ]; } ||
     { [ -n "${PGO_720_PATH_10}" ] && [ ! -r "${PGO_720_PATH_10}" ]; }; then
    echo "PGO用720p素材を読み込めません。YUV_PATH_720とYUV_PATH_720_10を確認してください。"
    exit 1
  fi

  function run_prof() {
    local prof_weight=$1
    shift
    prof_idx=$((prof_idx + 1))
    echo "PGO[${prof_idx}] asm=${PGO_ASM:-?} weight=${prof_weight} $*"
    # 相対パスにする。Windows 版 llvm-profdata は /c/... を開けない。
    local prof_file="pgo_raw/run_${prof_idx}.profraw"
    LLVM_PROFILE_FILE="${prof_file}" \
      ../../Bin/Release/${SVTAV1APPEXE} --progress 0 "$@"
    if [ $IS_CLANG == "ON" ]; then
      if [ -e "${prof_file}" ]; then
        echo "${prof_file}"
        prof_files+=( "${prof_file}" )
        prof_weights+=( "${prof_weight}" )
      else
        echo "warning: profraw がありません (run ${prof_idx})" >&2
      fi
    fi
  }

  # --nb は -n 以下。クリップより長い -n はエンコーダ側でループする。
  function pgo_nb_for() {
    local n=$1
    local cap=${2:-${PGO_CLIP_FRAMES}}
    if [ "${n}" -gt "${cap}" ]; then
      echo "${cap}"
    else
      echo "${n}"
    fi
  }

  function pgo_1080() {
    local weight=$1 frames=$2
    shift 2
    local nb
    nb=$(pgo_nb_for "${frames}")
    run_prof "${weight}" -w "${PGO_MAIN_WIDTH}" -h "${PGO_MAIN_HEIGHT}" \
      --fps-num 30000 --fps-denom 1001 -b /dev/null \
      --nb "${nb}" -n "${frames}" --asm "${PGO_ASM}" \
      -i "${PGO_INPUT}" "${PGO_DEPTH_OPT[@]}" "$@"
  }

  function pgo_crf() {
    local weight=$1 frames=$2 preset=$3
    shift 3
    pgo_1080 "${weight}" "${frames}" --crf 30 --scd 1 --preset "${preset}" "$@"
  }

  # 8bit / 10bit で同一設定。入力と --input-depth だけ変える。
  function pgo_depth() {
    PGO_INPUT=$1
    PGO_720_INPUT=$2
    PGO_DEPTH_OPT=()
    if [ "${3}" = "10" ]; then
      PGO_DEPTH_OPT=(--input-depth 10)
    fi
    echo "=== PGO suite --asm ${PGO_ASM} depth=${3} ==="

    pgo_crf 10 90 3
    pgo_crf 10 90 5
    pgo_crf  2 30 8
    pgo_crf  1 30 0
    pgo_crf  1 15 1
    pgo_crf  1 15 4

    pgo_crf 4 30 3 --enable-variance-boost 1 --qp-scale-compress-strength 2 --enable-tf 2 --ac-bias 1.0 --luminance-qp-bias 10
    pgo_crf 4 30 5 --film-grain 10 --film-grain-denoise 1 --enable-overlays 1 --tile-rows 1 --tile-columns 1
    pgo_crf 2 30 3 --tune 0
    pgo_crf 2 30 5 --fast-decode 2

    if [ -n "${PGO_720_INPUT}" ]; then
      local nb720
      nb720=$(pgo_nb_for 30 60)
      run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 -b /dev/null -i "${PGO_720_INPUT}" --preset 4 -n 30 --nb "${nb720}" --asm "${PGO_ASM}" "${PGO_DEPTH_OPT[@]}"
    fi

    pgo_1080 1 15 --crf 18 --scd 1 --preset 5
    pgo_1080 1 15 --crf 50 --scd 1 --preset 5
    pgo_crf 1 15 5 --max-tx-size 32
    pgo_crf 1 15 5 --enable-dlf 2 --enable-mfmv 1
    pgo_crf 1 15 3 --scm 3
    pgo_1080 1 30 --rc 1 --tbr 2500 --keyint 120 --pred-struct 2 --preset 8
    pgo_1080 1 30 --rc 2 --tbr 2500 --keyint 120 --rtc 1 --pred-struct 1 --hierarchical-levels 2 --preset 8
    pgo_1080 1 15 --rc 2 --tbr 2500 --keyint 120 --rtc 0 --pred-struct 1 --recode-loop 3 --undershoot-pct 5 --overshoot-pct 5 --buf-sz 1000 --buf-initial-sz 600 --buf-optimal-sz 600 --preset 8
    pgo_1080 1 15 --crf 30 --pred-struct 0 --keyint 1 --preset 5
    pgo_1080 1 15 --crf 30 --pred-struct 0 --keyint 1 --scm 1 --enable-intrabc 1 --preset 5
    pgo_1080 1 15 --crf 30 --tune 5 --preset 5
    pgo_1080 1 15 --crf 30 --superres-mode 1 --superres-denom 12 --superres-kf-denom 12 --preset 5
    pgo_1080 1 15 --crf 30 --superres-mode 3 --superres-qthres 0 --superres-kf-qthres 0 --scm 0 --preset 5
    pgo_1080 1 15 --rc 0 --qp 30 --aq-mode 1 --enable-qm 1 --qm-min 4 --qm-max 12 --chroma-qm-min 4 --chroma-qm-max 12 --preset 5
    pgo_1080 1 15 --crf 30 --resize-mode 1 --resize-denom 16 --resize-kf-denom 16 --preset 5
    pgo_1080 1 15 --passes 2 --rc 1 --tbr 2500 --keyint 120 --preset 8
  }

  # 同一集団を avx2 / avx512 × 8bit / 10bit で回す。
  function pgo_suite() {
    PGO_ASM=$1
    pgo_depth "${PGO_YUV_PATH}" "${PGO_720_PATH}" 8
    pgo_depth "${PGO_YUV_PATH_10}" "${PGO_720_PATH_10}" 10
  }

  pgo_suite avx2
  if [ "${ENABLE_AVX512}" = "ON" ] && [ "${PGO_TRAIN_AVX512}" = "ON" ]; then
    pgo_suite avx512
  fi

  if [ $IS_CLANG == "ON" ]; then
    echo ${prof_files[@]}
    prof_merge_args=()
    for idx in "${!prof_files[@]}"; do
      prof_merge_args+=( "-weighted-input=${prof_weights[$idx]},${prof_files[$idx]}" )
    done
    "${LLVM_PROFDATA}" merge --sparse -output=default.profdata "${prof_merge_args[@]}"
    "${LLVM_PROFDATA}" merge -output=default.full.profdata "${prof_merge_args[@]}"
    bash "${SCRIPT_DIR}/analyze_svtav1_profdata.sh" default.full.profdata |
      tee "${BUILD_DIR}/${TARGET_ARCH}/pgo_coverage.txt"
    cp -f default.profdata "${BUILD_DIR}/${TARGET_ARCH}/svtav1.profdata"
    cp -f default.full.profdata "${BUILD_DIR}/${TARGET_ARCH}/svtav1.full.profdata"

    PGO_PROFDATA=`pwd`/default.profdata
    if command -v cygpath >/dev/null 2>&1; then
      PGO_PROFDATA=$(cygpath -m "${PGO_PROFDATA}")
    fi
    PROFILE_USE_CC="-fprofile-use=${PGO_PROFDATA} ${PGO_USE_EXTRA_CC}"
    PROFILE_USE_LD="-fprofile-use=${PGO_PROFDATA} ${PGO_USE_EXTRA_LD}"
  fi
  if [ "${PGO_COVERAGE_ONLY:-}" = "1" ]; then
    echo "PGO_COVERAGE_ONLY=1, skip profile-use rebuild"
    exit 0
  fi
fi

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
  -DCMAKE_C_FLAGS="${BUILD_CCFLAGS} ${PROFILE_USE_CC}" \
  -DCMAKE_CXX_FLAGS="${BUILD_CCFLAGS} ${PROFILE_USE_CC}" \
  -DCMAKE_EXE_LINKER_FLAGS="${BUILD_LDFLAGS} ${PROFILE_USE_LD}" \
  ../..

make SvtAv1EncApp -j${MAKE_PROCESS}
make SvtAv1EncApp install
