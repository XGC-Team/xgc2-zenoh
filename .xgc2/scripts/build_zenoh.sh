#!/usr/bin/env bash
# Native zenoh-c 1.8.0 SDK build. Runs INSIDE the target distribution container
# (the CI runner only starts that container). No docker, no apt, no toolchain
# download: the builder image already carries the compiler, cmake and the pinned
# Rust 1.93.0.
#
# The recipe mirrors the validated ros-visualizer native SDK build
# (products/ros1/visualization/ros-visualizer/.xgc2/scripts/build_zenoh_sdk.sh):
# fetch the pinned tarball, pin all three manifests to the 1.8.0 release commit,
# install the reviewed locks, prefetch BOTH manifests (main + opaque-types
# helper), then build offline.
#
# usage: build_zenoh.sh --out DIR [--jobs N]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
lock="${repo_root}/zenoh.lock"

out=""; jobs="${ZENOH_BUILD_JOBS:-1}"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    --jobs) jobs="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${out}" && "${out}" == /* ]] || { echo '--out must be an absolute path' >&2; exit 2; }
[[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be a positive integer' >&2; exit 2; }

architecture="$(dpkg --print-architecture)"
case "${architecture}" in amd64|arm64) ;; *) echo "unsupported architecture ${architecture}" >&2; exit 2 ;; esac

command -v cmake >/dev/null || { echo 'cmake is missing from the builder image' >&2; exit 1; }
command -v cargo >/dev/null || { echo 'cargo is missing from the builder image' >&2; exit 1; }

# Explicit toolchain floor: zenoh-c 1.8.0 declares cmake_minimum_required 3.16.
# Older image cmake (e.g. the bionic dev images' distro 3.10) must fail HERE with
# an attributable message, not mid-configure and never via a product-side
# bootstrap; conforming cmake arrives through the xgc2-images toolchain supply.
cmake_version="$(cmake --version | awk 'NR==1 { print $3 }')"
if ! python3 - "${cmake_version}" 3.16 <<'PY'
import sys
have = tuple(int(x) for x in sys.argv[1].split('.'))
need = tuple(int(x) for x in sys.argv[2].split('.'))
sys.exit(0 if have >= need else 1)
PY
then
  echo "builder image cmake ${cmake_version} is below the zenoh-c 1.8.0 floor (>= 3.16);" >&2
  echo "supply a conforming toolchain in the xgc2-images builder image" >&2
  exit 1
fi

get() { sed -n "s/^$1=//p" "${lock}" | head -n 1; }
zenoh_c_sha="$(get ZENOH_C_SHA)"; zenoh_c_archive_sha="$(get ZENOH_C_ARCHIVE_SHA256)"
zenoh_rust_sha="$(get ZENOH_RUST_SHA)"
cargo_lock_sha="$(get CARGO_LOCK_SHA256)"; opaque_lock_sha="$(get OPAQUE_CARGO_LOCK_SHA256)"
rust_toolchain="$(get RUST_TOOLCHAIN)"
cpp_sha="$(get ZENOH_CPP_ARCHIVE_SHA256)"; cpp_version="$(get ZENOH_CPP_VERSION)"
for value in "${zenoh_c_sha}" "${zenoh_c_archive_sha}" "${zenoh_rust_sha}" "${cargo_lock_sha}" \
  "${opaque_lock_sha}" "${rust_toolchain}" "${cpp_sha}"; do
  [[ -n "${value}" ]] || { echo 'zenoh.lock is incomplete' >&2; exit 1; }
done
pinned_locks="${repo_root}/.xgc2/zenoh-c-1.8.0"
[[ -f "${pinned_locks}/Cargo.lock" && -f "${pinned_locks}/opaque-Cargo.lock" ]] || {
  echo "missing pinned locks in ${pinned_locks}" >&2; exit 1; }
printf '%s  %s\n' "${cargo_lock_sha}" "${pinned_locks}/Cargo.lock" \
  "${opaque_lock_sha}" "${pinned_locks}/opaque-Cargo.lock" | sha256sum --check --quiet

[[ "$(rustc --version)" == "rustc ${rust_toolchain} "* ]] || {
  echo "the builder image must carry Rust ${rust_toolchain} (found: $(rustc --version))" >&2; exit 1; }

# This container's own libc is the artifact's glibc ceiling: a <distro> deb must
# never demand a newer glibc than the distro ships (focal 2.31, jammy 2.35, ...).
build_glibc="$(ldd --version | awk 'NR==1 { print $NF }')"
[[ "${build_glibc}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo 'cannot determine the build glibc' >&2; exit 1; }

prefix="${out}/zenoh-${architecture}"
mkdir -p "${out}"
# A stale prefix would poison the artifact (and its SHA256SUMS gate): rebuild it fresh.
rm -rf "${prefix}"
mkdir -p "${prefix}"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

curl --fail --location --retry 6 --retry-delay 3 --retry-connrefused --max-time 300 \
  "https://codeload.github.com/eclipse-zenoh/zenoh-c/tar.gz/${zenoh_c_sha}" -o "${scratch}/source.tar.gz"
printf '%s  %s\n' "${zenoh_c_archive_sha}" "${scratch}/source.tar.gz" | sha256sum --check --quiet
mkdir "${scratch}/source"
tar -xzf "${scratch}/source.tar.gz" -C "${scratch}/source" --strip-components=1

# The 1.8.0 tag's manifests name the moving release branch while its shipped
# lock names old 1.7.2 main. Pin all three manifests to the 1.8.0 release commit
# and use the reviewed locks.
python3 - "${scratch}/source" "${zenoh_rust_sha}" <<'PY'
import pathlib, sys
root, commit = pathlib.Path(sys.argv[1]), sys.argv[2]
for name, expected in (("Cargo.toml", 5), ("Cargo.toml.in", 5), ("build-resources/opaque-types/Cargo.toml", 3)):
    path = root / name
    data = path.read_text()
    old = 'branch = "release/1.8.0"'
    if data.count(old) != expected:
        raise SystemExit("unexpected upstream Zenoh dependency declarations: " + name)
    path.write_text(data.replace(old, 'rev = "' + commit + '"'))
PY
cp "${pinned_locks}/Cargo.lock" "${scratch}/source/Cargo.lock"
cp "${pinned_locks}/opaque-Cargo.lock" "${scratch}/source/build-resources/opaque-types/Cargo.lock"

export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CARGO_BUILD_JOBS="${jobs}"
cargo fetch --locked --manifest-path "${scratch}/source/Cargo.toml"
cargo fetch --locked --manifest-path "${scratch}/source/build-resources/opaque-types/Cargo.toml"
export CARGO_NET_OFFLINE=true

cmake -S "${scratch}/source" -B "${scratch}/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${prefix}" -DZENOHC_BUILD_WITH_SHARED_MEMORY=TRUE \
  -DZENOHC_BUILD_WITH_UNSTABLE_API=TRUE '-DZENOHC_CARGO_FLAGS=--locked;--offline'
cmake --build "${scratch}/build" --parallel "${jobs}"
printf '%s  %s\n' "${opaque_lock_sha}" "${scratch}/source/build-resources/opaque-types/Cargo.lock" | sha256sum --check --quiet
cmake --install "${scratch}/build"

curl --fail --location --retry 6 --retry-delay 3 --retry-connrefused --max-time 300 \
  "https://github.com/eclipse-zenoh/zenoh-cpp/releases/download/${cpp_version}/zenohcpp-${cpp_version}-standalone.zip" \
  -o "${scratch}/zenoh-cpp.zip"
printf '%s  %s\n' "${cpp_sha}" "${scratch}/zenoh-cpp.zip" | sha256sum --check --quiet
mkdir -p "${scratch}/zenoh-cpp" && unzip -q "${scratch}/zenoh-cpp.zip" -d "${scratch}/zenoh-cpp"
cp -a "${scratch}/zenoh-cpp/include/." "${prefix}/include/"
mkdir -p "${prefix}/lib/cmake"
[[ -d "${scratch}/zenoh-cpp/lib/cmake/zenohcxx" ]] || { echo 'zenoh-cpp cmake package missing from the pinned archive' >&2; exit 1; }
cp -a "${scratch}/zenoh-cpp/lib/cmake/zenohcxx" "${prefix}/lib/cmake/"
# Upstream zenoh-cpp 1.8.0 creates non-GLOBAL imported targets and then aliases
# them; CMake 3.16 (Focal) rejects that. Promote the two backend targets to
# GLOBAL so the real consumer targets (zenohcxx::zenohc / ::zenohpico) resolve.
zenohcxx_config="${prefix}/lib/cmake/zenohcxx/zenohcxxConfig.cmake"
sed -i \
  -e 's/add_library(zenohcxx_zenohc INTERFACE IMPORTED)/add_library(zenohcxx_zenohc INTERFACE IMPORTED GLOBAL)/' \
  -e 's/add_library(zenohcxx_zenohpico INTERFACE IMPORTED)/add_library(zenohcxx_zenohpico INTERFACE IMPORTED GLOBAL)/' \
  "${zenohcxx_config}"
grep -q 'add_library(zenohcxx_zenohc INTERFACE IMPORTED GLOBAL)' "${zenohcxx_config}" || {
  echo 'failed to make the zenohcxx backend imported target GLOBAL' >&2; exit 1; }

printf 'zenoh-c=1.8.0 source=%s zenoh=%s rust=%s arch=%s lock=%s opaque=%s glibc<=%s\n' \
  "${zenoh_c_sha}" "${zenoh_rust_sha}" "${rust_toolchain}" "${architecture}" \
  "${cargo_lock_sha}" "${opaque_lock_sha}" "${build_glibc}" > "${prefix}/.xgc2-zenoh-sdk"

echo "prefix: ${prefix}"
"${script_dir}/check_prefix.sh" "${prefix}" --arch "${architecture}" --baseline "${build_glibc}"
