#!/bin/bash

set -e -o pipefail

ARM_TOOLCHAIN_VERSION=10.3-2021.07
ARM_TOOLCHAIN_FILENAME=gcc-arm-${ARM_TOOLCHAIN_VERSION}-x86_64-arm-none-eabi.tar.xz
ARM_TOOLCHAIN_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/${ARM_TOOLCHAIN_VERSION}/binrel/${ARM_TOOLCHAIN_FILENAME}
ARM_TOOLCHAIN_SHA256SUM=45225813f74e0c3f76af2715d30d1fbebb873c1abe7098f9c694e5567cc2279c

AARCH64_TOOLCHAIN_VERSION=10.3-2021.07
AARCH64_TOOLCHAIN_FILENAME=gcc-arm-${AARCH64_TOOLCHAIN_VERSION}-x86_64-aarch64-none-elf.tar.xz
AARCH64_TOOLCHAIN_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/${AARCH64_TOOLCHAIN_VERSION}/binrel/${AARCH64_TOOLCHAIN_FILENAME}
AARCH64_TOOLCHAIN_SHA256SUM=6f74b1ee370caeb716688d2e467e5b44727fdc0ed56023fe5c72c0620019ecef

ATF_SOURCE_VERSION=2.10.1
ATF_SOURCE_FILENAME=arm-trusted-firmware-2.10.1.tar.gz
ATF_SOURCE_URL=https://github.com/mj22226/arm-trusted-firmware//archive/refs/tags/v2.10.1/arm-trusted-firmware-2.10.1.tar.gz
ATF_SOURCE_SHA256SUM=de8490452e337d8d182baeaf87ad961948a43e27af9878f40c26ba5b22e58516
# Set fixed build timestamp for reproducible builds
ATF_BUILD_EPOCH=$(date +%s)

die() {
  echo "$@" 1>&2
  exit 1
}

download_and_check() {
  local URL="$1"
  local FILENAME="download_dir/$2"
  local SHA256SUM="$3"

  mkdir -p "download_dir"

  [ -e "$FILENAME" ] || wget --retry-connrefused --waitretry=1 --read-timeout=20 \
    --timeout=15 -t 5 --quiet -O "$FILENAME" "$URL"

  shasum="$(sha256sum "$FILENAME" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')"
  if [[ "$shasum" == "$SHA256SUM"  ]]; then
    echo "$FILENAME"
    return 0
  fi
  rm -f "$FILENAME"
  die "Checksum missmatch on $FILENAME, $shasum != $SHA256SUM"
}

extract() {
  ARCHIVE="$1"

  rm -rf "${ARCHIVE}_extracted"
  mkdir -p "${ARCHIVE}_extracted"
  tar -C "${ARCHIVE}_extracted" -xaf "$ARCHIVE"
  realpath "${ARCHIVE}_extracted"/*
}

extract_toolchain() {
  ARCHIVE="$1"

  if [ -d "${ARCHIVE}_extracted" ]; then
    realpath "${ARCHIVE}_extracted"/*
  else
    extract "$ARCHIVE"
  fi
}

echo "Downloading ARM toolchain ..."
ARM_TOOLCHAIN_FILENAME="$(download_and_check "$ARM_TOOLCHAIN_URL" "$ARM_TOOLCHAIN_FILENAME" "$ARM_TOOLCHAIN_SHA256SUM")"
echo "Downloading AARCH64 toolchain ..."
AARCH64_TOOLCHAIN_FILENAME="$(download_and_check "$AARCH64_TOOLCHAIN_URL" "$AARCH64_TOOLCHAIN_FILENAME" "$AARCH64_TOOLCHAIN_SHA256SUM")"
echo "Downloading ATF source ..."
ATF_SOURCE_FILENAME="$(download_and_check "$ATF_SOURCE_URL" "$ATF_SOURCE_FILENAME" "$ATF_SOURCE_SHA256SUM")"

echo "Extracting ARM toolchain ..."
CROSS_COMPILE_ARM="$(extract_toolchain "$ARM_TOOLCHAIN_FILENAME")"/bin/arm-none-eabi-
echo "Extracting AARCH64 toolchain ..."
CROSS_COMPILE_AARCH64="$(extract_toolchain "$AARCH64_TOOLCHAIN_FILENAME")"/bin/aarch64-none-elf-

rm -rf output_dir
mkdir output_dir

for target in targets/*.sh; do
  # Unpack clean tree
  ATF_DIR="$(extract "$ATF_SOURCE_FILENAME")"

  unset PLAT TARGET BINARY_PATH ARCH MAKE_FLAGS
  . "$target"

  BINARY_FORMAT="${BINARY_PATH#*.}"

  case "$ARCH" in
    aarch64) CROSS_COMPILE="$CROSS_COMPILE_AARCH64";;
    arm) CROSS_COMPILE="$CROSS_COMPILE_ARM";;
    *) die Invalid arch "$ARCH";;
  esac

  make -C "$ATF_DIR" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    M0_CROSS_COMPILE="$CROSS_COMPILE_ARM" \
    CROSS_CM3="$CROSS_COMPILE_ARM" \
    PLAT="$PLAT" \
    SOURCE_DATE_EPOCH="$ATF_BUILD_EPOCH" \
    BUILD_STRING="v$ATF_SOURCE_VERSION" \
    LC_ALL=C \
    $MAKE_FLAGS \
    "$TARGET"

  cp ${ATF_DIR}/build/${PLAT}/release/${BINARY_PATH} output_dir/${PLAT}_${TARGET}.${BINARY_FORMAT}
  rm -rf ${ATF_DIR}
done

# download ddr.bin,rk3568/88_bl31.elf from https://github.com/rkbin/
# rk356x

wget https://github.com/rockchip-linux/rkbin/raw/master/bin/rk35/rk3568_ddr_1560MHz_v1.18.bin -O output_dir/rk3568_ddr.bin
sha256sum -c <<<"9e6200ca13f846379bae703b036d42e280888ab3a8143999380bdc9898d04322 output_dir/rk3568_ddr.bin"

# rk3588

wget https://github.com/rockchip-linux/rkbin/raw/master/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.12.bin -O output_dir/rk3588_ddr.bin
sha256sum -c <<<"ab20fa76d5535bb95c427b117b242510316b8c27889639dd0c4c2a44832cfb2f  output_dir/rk3588_ddr.bin"

cat << EOF > build_info.txt
build epoch: $ATF_BUILD_EPOCH

EOF
sha256sum download_dir/* 2> /dev/null >> build_info.txt || true
echo >> build_info.txt
GZIP='-n -6' tar -C output_dir/ --mtime "@${ATF_BUILD_EPOCH}" \
  --owner=0 --group=0 --numeric-owner --sort=name \
  -czf atf-v${ATF_SOURCE_VERSION}.tar.gz .
mv atf-v${ATF_SOURCE_VERSION}.tar.gz output_dir
sha256sum output_dir/* >> build_info.txt
sha256sum output_dir/* > output_dir/SHA256SUMS

cat build_info.txt
