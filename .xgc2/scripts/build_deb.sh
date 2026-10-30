#!/usr/bin/env bash
# Package a prepared zenoh prefix as the xgc2-zenoh Debian package.
#
# Mirrors devops/products/common/acados/.xgc2/scripts/build_deb.sh: the prefix is
# staged under the package ownership paths, a minimal control file is generated
# from .xgc2/product.yml, and the deb plus SHA256SUMS land in the output dir.
#
# usage: build_deb.sh --prefix DIR [--arch amd64|arm64] [--output DIR]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

package_name="xgc2-zenoh"
product_version() { sed -n 's/^version:[[:space:]]*//p' "${repo_root}/.xgc2/product.yml" | head -n 1; }

prefix=""
arch=""
output_dir="${ZENOH_DEB_OUTPUT_DIR:-${repo_root}/debs}"
base_version="${PACKAGE_BASE_VERSION:-$(product_version)}"
distribution="${PACKAGE_DISTRIBUTION:-focal}"
install_prefix="${ZENOH_INSTALL_PREFIX:-/opt/xgc2/zenoh}"

while (( $# )); do
  case "$1" in
    --prefix) prefix="${2:?}"; shift 2 ;;
    --arch) arch="${2:?}"; shift 2 ;;
    --output) output_dir="${2:?}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${prefix}" ]] || { echo 'usage: build_deb.sh --prefix DIR [--arch amd64|arm64] [--output DIR]' >&2; exit 2; }
prefix="$(cd "${prefix}" && pwd -P)"
if [[ -z "${arch}" ]]; then
  case "$(readelf -h "${prefix}/lib/libzenohc.so" | sed -n 's/.*Machine:[[:space:]]*//p')" in
    AArch64*) arch=arm64 ;;
    *X86-64*) arch=amd64 ;;
    *) echo 'cannot determine prefix architecture' >&2; exit 1 ;;
  esac
fi

"${script_dir}/check_prefix.sh" "${prefix}" --arch "${arch}"

version="${base_version}~${distribution}"
work="$(mktemp -d "${TMPDIR:-/tmp}/xgc2-zenoh-deb.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT
pkg_root="${work}/${package_name}"
mkdir -p "${pkg_root}/DEBIAN" "${pkg_root}${install_prefix}" "${pkg_root}/usr/lib/cmake/${package_name}"
cp -a "${prefix}/." "${pkg_root}${install_prefix}/"
rm -f "${pkg_root}${install_prefix}/SHA256SUMS"
# CMake packages are exposed at the product ownership paths too, so consumers can
# find_package(zenohc) without knowing the TRO prefix layout.
mkdir -p "${pkg_root}/usr/lib/cmake"
for pkg in zenohc zenohcxx; do
  if [[ -d "${prefix}/lib/cmake/${pkg}" ]]; then
    cp -a "${prefix}/lib/cmake/${pkg}" "${pkg_root}/usr/lib/cmake/${pkg}"
  fi
done
mkdir -p "${pkg_root}/etc/ld.so.conf.d"
printf '%s\n' "${install_prefix}/lib" > "${pkg_root}/etc/ld.so.conf.d/xgc2-zenoh.conf"
cat > "${pkg_root}/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
ldconfig 2>/dev/null || true
exit 0
POST
cat > "${pkg_root}/DEBIAN/postrm" <<'POST'
#!/bin/sh
set -e
ldconfig 2>/dev/null || true
exit 0
POST
chmod 0755 "${pkg_root}/DEBIAN/postinst" "${pkg_root}/DEBIAN/postrm"

cat > "${pkg_root}/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${version}
Architecture: ${arch}
Maintainer: XGC Team <dev@xgc.team>
Section: libs
Priority: optional
Depends: libc6, libgcc-s1, libstdc++6
Description: XGC2 zenoh SDK (pinned zenoh-c 1.8.0 C SDK with zenoh-cpp 1.8.0 headers)
 Frozen upstream pins: zenoh-c $(sed -n 's/^ZENOH_C_SHA=//p' "${repo_root}/zenoh.lock") ,
 zenoh $(sed -n 's/^ZENOH_RUST_SHA=//p' "${repo_root}/zenoh.lock") , Rust
 $(sed -n 's/^RUST_TOOLCHAIN=//p' "${repo_root}/zenoh.lock") , built against focal
 glibc 2.31. Provides the single TRO_ZENOH_PREFIX consumed by -DTRO_WITH_ZENOH=ON.
EOF

mkdir -p "${output_dir}"
deb="${output_dir}/${package_name}_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "${pkg_root}" "${deb}" >/dev/null
( cd "${output_dir}" && sha256sum "$(basename "${deb}")" > "$(basename "${deb}").sha256" )
echo "${deb}"
cat "${deb}.sha256"
