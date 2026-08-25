#!/bin/bash
# pacman -S mingw-w64-clang-x86_64-toolchain clang64/mingw-w64-clang-x86_64-cmake
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

  make SvtAv1EncApp -j${NUMBER_OF_PROCESSORS}

  prof_files=()
  prof_weights=()
  prof_idx=0

  # The CI samples contain 60 frames. Concatenate them logically so PGO sees
  # longer runs without requiring a content-specific input file.
  PGO_YUV_REPEAT=${PGO_YUV_REPEAT:-10}
  PGO_YUV_PATH=${YUV_PATH}
  PGO_YUV_PATH_10=${YUV_PATH_10}
  if [ ${PGO_YUV_REPEAT} -gt 1 ]; then
    PGO_YUV_PATH=`pwd`/pgo_test_8.yuv
    PGO_YUV_PATH_10=`pwd`/pgo_test_10.yuv
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
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  2 -n 30 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  3 -n 300 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  4 -n 300 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  6 -n 300 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  8 -n 600 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset 10 -n 600 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 32 --enable-mfmv 1 --film-grain 10 --scd 1 --tile-rows 2 --tile-columns 2 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 4 -n 180 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  2 -n 30 --input-depth 10 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  3 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  4 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  6 -n 300 --input-depth 10 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  8 -n 600 --input-depth 10 --asm avx2
  run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 10 -n 600 --input-depth 10 --asm avx2
  if [ "${ENABLE_AVX512}" = "ON" ] && [ "${PGO_TRAIN_AVX512}" = "ON" ]; then
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  2 -n 30 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  3 -n 300 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  4 -n 300 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  6 -n 300 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset  8 -n 600 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH}"    --preset 10 -n 600 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 32 --enable-mfmv 1 --film-grain 10 --scd 1 --tile-rows 2 --tile-columns 2 --fps-num 30000 --fps-denom 1001 -b /dev/null -i "${PGO_YUV_PATH}" --preset 4 -n 180 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  2 -n 30 --input-depth 10 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  3 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  4 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  6 -n 300 --input-depth 10 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset  8 -n 600 --input-depth 10 --asm avx512
    run_prof 1 -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i "${PGO_YUV_PATH_10}" --preset 10 -n 600 --input-depth 10 --asm avx512
  fi

  if [ $IS_CLANG == "ON" ]; then
    echo ${prof_files[@]}
    prof_merge_args=()
    for idx in "${!prof_files[@]}"; do
      prof_merge_args+=( "-weighted-input=${prof_weights[$idx]},${prof_files[$idx]}" )
    done
    llvm-profdata merge -output=default.profdata "${prof_merge_args[@]}"

    PROFILE_USE_CC=${PROFILE_USE_CC}=`pwd`/default.profdata
    PROFILE_USE_LD=${PROFILE_USE_LD}=`pwd`/default.profdata
  fi

  if [ ${PGO_YUV_REPEAT} -gt 1 ]; then
    rm -f "${PGO_YUV_PATH}" "${PGO_YUV_PATH_10}"
  fi

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

make SvtAv1EncApp -j${NUMBER_OF_PROCESSORS}
make SvtAv1EncApp install