#!/bin/bash
# pacman -S mingw-w64-clang-x86_64-toolchain
BUILD_DIR=`pwd`/build_svtav1
BUILD_CCFLAGS="-Ofast -ffast-math -fomit-frame-pointer -flto"
BUILD_LDFLAGS="-static -static-libgcc -flto -Wl,--gc-sections -Wl,--strip-all"

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
git config --global core.autocrlf false

ENABLE_AVX512="ON"
TARGET_ARCH="x64"
FFMPEG_ARCH="x86_64"
SVTAV1APPEXE="SvtAv1EncApp.exe"
if [ -n "$MSYSTEM" ]; then
  if [ $MSYSTEM != "MINGW64" ] && [ $MSYSTEM != "CLANG64" ]; then
      echo "This script is for mingw64/clang64 only!"
      exit 1
  fi
  export CC=${CC:-gcc}
  export CXX=${CXX:-g++}
  if [ $MSYSTEM == "CLANG64" ]; then
      export CC=clang
      export CXX=clang++
  fi
else
  AVX512_COUNT=$(cat /proc/cpuinfo | grep flags | grep avx512 | wc -l)
  if [ $AVX512_COUNT -eq 0 ]; then
    ENABLE_AVX512="OFF"
  fi
  CMAKE_TARGET="Unix Makefiles"
  SVTAV1APPEXE="SvtAv1EncApp"
fi

ENABLE_PGO=ON
if [ $CXX == "clang++" ]; then
  ENABLE_PGO=ON
fi

if [ $ENABLE_PGO == "ON" ]; then
  export PROFILE_GEN_CC="-fprofile-generate"
  export PROFILE_GEN_LD="-fprofile-generate"
  export PROFILE_USE_CC="-fprofile-use"
  export PROFILE_USE_LD="-fprofile-use"
  if [ $CXX == "clang++" ]; then
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
  prof_idx=0

  function run_prof() {
    ../../Bin/Release/${SVTAV1APPEXE} $@
    prof_idx=$((prof_idx + 1))
    
    if [ $CXX == "clang++" ]; then
      for file in default_*_0.profraw; do
        new_file="${file%.profraw}_${prof_idx}.${file##*.}"
        mv "$file" "$new_file"
        echo ${new_file}
        prof_files+=( ${new_file} )
      done
    fi
  }

  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  2 -n 30 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  4 -n 30 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  6 -n 30 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  8 -n 60 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset 12 -n 60 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  2 -n 30 --input-depth 10 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  4 -n 30 --input-depth 10 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  6 -n 30 --input-depth 10 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  8 -n 60 --input-depth 10 --asm avx2
  run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset 12 -n 60 --input-depth 10 --asm avx2
  if [ ${ENABLE_AVX512} = "ON" ]; then
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  2 -n 30 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  4 -n 30 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  6 -n 30 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset  8 -n 60 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH}    --preset 12 -n 60 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  2 -n 30 --input-depth 10 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  4 -n 30 --input-depth 10 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  6 -n 30 --input-depth 10 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset  8 -n 60 --input-depth 10 --asm avx512
    run_prof -w 1280 -h 720 --crf 30 --scd 1 --fps-num 30 --fps-denom 1 -b /dev/null -i ${YUV_PATH_10} --preset 12 -n 60 --input-depth 10 --asm avx512
  fi

  if [ $CXX == "clang++" ]; then
    echo ${prof_files[@]}
    llvm-profdata merge -output=default.profdata "${prof_files[@]}"

    PROFILE_USE_CC=${PROFILE_USE_CC}=`pwd`/default.profdata
    PROFILE_USE_LD=${PROFILE_USE_LD}=`pwd`/default.profdata
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