#!/bin/bash
# msys2 / Linux 共用 x262 ビルドスクリプト
#pacman -S base-devel mingw-w64-i686-toolchain mingw-w64-x86_64-toolchain
#pacman -S p7zip git nasm
set -e
SCRIPT_DIR=`pwd`
BUILD_DIR=${SCRIPT_DIR}/build_x262
LSMASH_CONFIGURE_PATCH="${SCRIPT_DIR}/patch/lsmash_configure.diff"
X262_REV=${X262_REV:-}
X262_BRANCH=${X262_BRANCH:-"master"}
if [ -n "$MSYSTEM" ]; then
    MAKE_PROCESS=${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 4)}
else
    MAKE_PROCESS=$(nproc)
fi

# gcc が書き込み不能な TEMP (例: C:\WINDOWS) を参照しないようにする
mkdir -p "$BUILD_DIR/tmp"
export TMPDIR="$BUILD_DIR/tmp"
if command -v cygpath >/dev/null 2>&1; then
    # MinGW gcc は Windows の TMP/TEMP を見る。混在パス (C:/...) にする
    WIN_TMP=`cygpath -m "$TMPDIR"`
    export TMP="$WIN_TMP"
    export TEMP="$WIN_TMP"
    export TMPDIR="$WIN_TMP"
else
    export TMP="$TMPDIR"
    export TEMP="$TMPDIR"
fi

mkdir -p $BUILD_DIR/src
cd $BUILD_DIR/src
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.autocrlf
export GIT_CONFIG_VALUE_0=false

TARGET_ARCH="x64"
export CC=${CC:-gcc}
export CXX=${CXX:-g++}
if [ -n "$MSYSTEM" ]; then
    if [ $MSYSTEM = "MINGW32" ]; then
        TARGET_ARCH="x86"
    else
        TARGET_ARCH="x64"
    fi
    if [ $MSYSTEM = "CLANG64" ]; then
        export CC=clang
        export CXX=clang++
    fi
fi

if [ ! -n "$INSTALL_DIR" ]; then
  INSTALL_DIR=$BUILD_DIR/$TARGET_ARCH/build
fi

BUILD_CCFLAGS="-flto -msse2 -fexcess-precision=fast -mfpmath=sse -ffast-math -fomit-frame-pointer -fno-ident -I${INSTALL_DIR}/include"
BUILD_LDFLAGS="-flto -static -static-libgcc -static-libstdc++ -Wl,--gc-sections -Wl,--strip-all -L${INSTALL_DIR}/lib"
if [ -n "$MSYSTEM" ] && [ "$MSYSTEM" = "MINGW32" ]; then
    BUILD_CCFLAGS="-m32 ${BUILD_CCFLAGS}"
fi

if [ -d "x262" ]; then
    cd x262
    git pull
    cd ..
else
    git clone https://github.com/kierank/x262.git
fi

cd x262
if [ "${X262_REV}" != "" ]; then
    git checkout --force ${X262_REV}
else
    git checkout --force ${X262_BRANCH}
    git reset --hard origin/${X262_BRANCH}
fi
cd ..

if [ -d "l-smash" ]; then
    cd l-smash
    git pull
    cd ..
else
    git clone https://github.com/l-smash/l-smash.git l-smash
fi

mkdir -p $BUILD_DIR/$TARGET_ARCH
cd $BUILD_DIR/$TARGET_ARCH
if [ -d "x262" ]; then
    rm -rf x262
fi
cp -r ../src/x262 x262

if [ -d "l-smash" ]; then
    rm -rf l-smash
fi
cp -r ../src/l-smash l-smash

#build L-SMASH
cd $BUILD_DIR/$TARGET_ARCH/l-smash
patch -p0 < "$LSMASH_CONFIGURE_PATCH"
./configure \
--prefix=$INSTALL_DIR \
--cc=${CC} \
--extra-cflags="${BUILD_CCFLAGS}" \
--extra-ldflags="${BUILD_LDFLAGS}"
make clean
make TMP="$TMP" TEMP="$TEMP" TMPDIR="$TMPDIR" -j$MAKE_PROCESS lib
make TMP="$TMP" TEMP="$TEMP" TMPDIR="$TMPDIR" install-lib

#build x262
echo "Start build x262(${TARGET_ARCH})"
cd $BUILD_DIR/$TARGET_ARCH/x262
X262_REV=`git rev-list HEAD | wc -l`
export X262_REV=$X262_REV

PKG_CONFIG_PATH=${INSTALL_DIR}/lib/pkgconfig \
./configure \
 --prefix=$INSTALL_DIR \
 --enable-static \
 --enable-mpeg2 \
 --disable-ffms \
 --disable-gpac \
 --disable-lavf \
 --bit-depth=all \
 --extra-cflags="-O3 ${BUILD_CCFLAGS}" \
 --extra-ldflags="${BUILD_LDFLAGS}"

make TMP="$TMP" TEMP="$TEMP" TMPDIR="$TMPDIR" -j$MAKE_PROCESS
make TMP="$TMP" TEMP="$TEMP" TMPDIR="$TMPDIR" install

if [ -n "$MSYSTEM" ]; then
    EXE_SUFFIX=".exe"
else
    EXE_SUFFIX=""
fi
if [ -f "x264${EXE_SUFFIX}" ] && [ ! -f "x262${EXE_SUFFIX}" ]; then
    cp -f "x264${EXE_SUFFIX}" "x262${EXE_SUFFIX}"
fi
if [ -f "${INSTALL_DIR}/bin/x264${EXE_SUFFIX}" ] && [ ! -f "${INSTALL_DIR}/bin/x262${EXE_SUFFIX}" ]; then
    cp -f "${INSTALL_DIR}/bin/x264${EXE_SUFFIX}" "${INSTALL_DIR}/bin/x262${EXE_SUFFIX}"
fi
