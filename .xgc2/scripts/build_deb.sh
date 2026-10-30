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
case "${distribution}" in
  bionic) libgcc_dep="libgcc1" ;;
  focal|jammy|noble) libgcc_dep="libgcc-s1" ;;
  *) echo "unsupported distribution ${distribution}" >&2; exit 1 ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/xgc2-zenoh-deb.XXXXXX")"
wheel_root=""
cleanup() { rm -rf -- "${work}" ${wheel_root:+"${wheel_root}"}; }
trap cleanup EXIT
pkg_root="${work}/${package_name}"
mkdir -p "${pkg_root}/DEBIAN" "${pkg_root}${install_prefix}" "${pkg_root}/usr/lib/cmake/${package_name}"
cp -a "${prefix}/." "${pkg_root}${install_prefix}/"
rm -f "${pkg_root}${install_prefix}/SHA256SUMS"
# CMake packages are exposed at the product ownership paths too, so consumers
# can find_package(zenohc) without knowing the TRO prefix layout. These are
# FORWARDING stubs, not copies: upstream's configs compute PACKAGE_PREFIX_DIR /
# _IMPORT_PREFIX relative to their own location (../../..), so a copied file
# under /usr/lib/cmake would point imported targets at /usr/lib and /usr/include
# where nothing exists. The stub include()s the real config, which then resolves
# its prefix correctly under ${install_prefix}.
mkdir -p "${pkg_root}/usr/lib/cmake"
for pkg in zenohc zenohcxx; do
  real_dir="${pkg_root}${install_prefix}/lib/cmake/${pkg}"
  if [[ -d "${real_dir}" ]]; then
    stub_dir="${pkg_root}/usr/lib/cmake/${pkg}"
    mkdir -p "${stub_dir}"
    for real in "${real_dir}"/*Config*.cmake; do
      name="$(basename "${real}")"
      printf '# The real %s package lives under the product prefix; include it so\n# its own relative-prefix resolution stays correct.\ninclude("%s/lib/cmake/%s/%s")\n' \
        "${pkg}" "${install_prefix}" "${pkg}" "${name}" > "${stub_dir}/${name}"
    done
  fi
done
if [[ -d "${pkg_root}${install_prefix}/lib/cmake/zenohc" ]]; then
  mkdir -p "${pkg_root}/usr/lib/cmake/xgc2_zenoh"
  printf '# Product-level alias: pulls in the real package configs.\ninclude("%s/lib/cmake/zenohc/zenohcConfig.cmake")\n' \
    "${install_prefix}" > "${pkg_root}/usr/lib/cmake/xgc2_zenoh/xgc2_zenohConfig.cmake"
fi
mkdir -p "${pkg_root}/etc/ld.so.conf.d"
printf '%s\n' "${install_prefix}/lib" > "${pkg_root}/etc/ld.so.conf.d/xgc2-zenoh.conf"
# The matching zenoh-python 1.8.0 binding is Focal-only: non-Focal suites are
# C-SDK-only and must not carry Python payload or a python3 dependency.
python_dep=""
if [[ -n "${ZENOH_PYTHON_WHEEL_DIR:-}" ]]; then
  [[ "${distribution}" == "focal" ]] || {
    echo "python wheel is Focal-only; ${distribution} must be built without ZENOH_PYTHON_WHEEL_DIR" >&2; exit 1; }
  shopt -s nullglob
  wheels=("${ZENOH_PYTHON_WHEEL_DIR}"/*.whl)
  (( ${#wheels[@]} == 1 )) || { echo "expected exactly one python wheel in ${ZENOH_PYTHON_WHEEL_DIR}, got ${#wheels[@]}" >&2; exit 1; }
  case "${arch}" in
    amd64) pyarch=x86_64 ;;
    arm64) pyarch=aarch64 ;;
    *) echo "unsupported python wheel architecture ${arch}" >&2; exit 1 ;;
  esac
  unzip -p "${wheels[0]}" '*.dist-info/WHEEL' | grep -q "Tag: cp38-abi3-linux_${pyarch}" || {
    echo "python wheel is not cp38-abi3-linux_${pyarch}: ${wheels[0]}" >&2; exit 1; }
  # Stage the binding as ordinary dpkg-owned files (acados template shape): no
  # wheel shell left in the payload and no pip run at postinst time.
  site="${pkg_root}/usr/lib/python3/dist-packages"
  mkdir -p "${site}"
  wheel_root="$(mktemp -d)"
  ( cd "${wheel_root}" && unzip -q "${wheels[0]}" ) || { echo "cannot unpack ${wheels[0]}" >&2; exit 1; }
  [[ -d "${wheel_root}/zenoh" ]] || { echo "wheel has no zenoh package" >&2; exit 1; }
  cp -a "${wheel_root}/zenoh" "${site}/"
  for dist in "${wheel_root}"/*.dist-info; do [[ -d "${dist}" ]] && cp -a "${dist}" "${site}/"; done
  python_dep=", python3"
fi
cat > "${pkg_root}/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
ldconfig
exit 0
POST
cat > "${pkg_root}/DEBIAN/postrm" <<'POST'
#!/bin/sh
set -e
ldconfig
exit 0
POST
chmod 0755 "${pkg_root}/DEBIAN/postinst" "${pkg_root}/DEBIAN/postrm"

depends="libc6, ${libgcc_dep}, libstdc++6${python_dep}"
build_glibc="$(ldd --version 2>/dev/null | awk 'NR==1 { print $NF }')"
cat > "${pkg_root}/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${version}
Architecture: ${arch}
Maintainer: XGC Team <dev@xgc.team>
Section: libs
Priority: optional
Depends: ${depends}
Description: XGC2 zenoh SDK (pinned zenoh-c 1.8.0 C SDK with zenoh-cpp 1.8.0 headers)
 Frozen upstream pins: zenoh-c $(sed -n 's/^ZENOH_C_SHA=//p' "${repo_root}/zenoh.lock") ,
 zenoh $(sed -n 's/^ZENOH_RUST_SHA=//p' "${repo_root}/zenoh.lock") , Rust
 $(sed -n 's/^RUST_TOOLCHAIN=//p' "${repo_root}/zenoh.lock") , built natively for
 ${distribution} (glibc ${build_glibc:-unknown}). Provides the single
 TRO_ZENOH_PREFIX consumed by -DTRO_WITH_ZENOH=ON.
EOF

mkdir -p "${output_dir}"
deb="${output_dir}/${package_name}_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "${pkg_root}" "${deb}" >/dev/null
( cd "${output_dir}" && sha256sum "$(basename "${deb}")" > "$(basename "${deb}").sha256" )
echo "${deb}"
cat "${deb}.sha256"
