#!/usr/bin/env bash
# Native C SDK, C++ headers and official zenohd from the locked upstream sources.
# The target distro image supplies all tools; this script never installs them.
# usage: build_zenoh.sh --out DIR [--jobs N]
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
lock="${repo_root}/zenoh.lock"
get() { sed -n "s/^$1=//p" "${lock}" | head -n 1; }
out=""; jobs="${ZENOH_BUILD_JOBS:-1}"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    --jobs) jobs="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${out}" && "${out}" == /* ]] || { echo '--out must be an absolute path' >&2; exit 2; }
[[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be a positive integer' >&2; exit 2; }
architecture="$(dpkg --print-architecture)"
case "${architecture}" in amd64|arm64) ;; *) echo "unsupported architecture ${architecture}" >&2; exit 2 ;; esac
version="$(get ZENOH_C_VERSION)"
rust_toolchain="$(get RUST_TOOLCHAIN)"
# Select the image's installed compiler instead of letting an upstream
# rust-toolchain.toml download the maintainer's preferred development toolchain.
export RUSTUP_TOOLCHAIN="${rust_toolchain}"
[[ "$(rustc --version)" == "rustc ${rust_toolchain} "* ]] || {
  echo "the builder image must carry Rust ${rust_toolchain}" >&2; exit 1; }
cmake_version="$(cmake --version | awk 'NR==1 { print $3 }')"
dpkg --compare-versions "${cmake_version}" ge 3.16 || {
  echo "zenoh-c ${version} requires CMake >= 3.16 in the builder image (found ${cmake_version})" >&2; exit 1; }
build_glibc="$(ldd --version | awk 'NR==1 { print $NF }')"
prefix="${out}/zenoh-${architecture}"
mkdir -p "${out}"
rm -rf "${prefix}"
mkdir -p "${prefix}"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
"${script_dir}/fetch_zenoh.sh" "${scratch}/sources"
source_c="${scratch}/sources/zenoh-c"
source_rust="${scratch}/sources/zenoh"
source_cpp="${scratch}/sources/zenoh-cpp"

# Main sources and lock remain upstream bytes. The official build.rs copies
# the main lock into the opaque helper and Cargo projects its dependency graph.
# Prefetch that reviewed projection under --locked, then verify the actual
# upstream-generated result after the build instead of expecting the archive
# helper lock to survive that documented generation step.
opaque_lock="${repo_root}/.xgc2/zenoh-c-${version}/opaque-Cargo.lock"
printf '%s  %s\n' "$(get OPAQUE_CARGO_LOCK_SHA256)" "${opaque_lock}" | sha256sum --check --quiet
cp "${opaque_lock}" "${source_c}/build-resources/opaque-types/Cargo.lock"
export CARGO_NET_GIT_FETCH_WITH_CLI=true CARGO_BUILD_JOBS="${jobs}"
cargo fetch --locked --manifest-path "${source_c}/Cargo.toml"
cargo fetch --locked --manifest-path "${source_c}/build-resources/opaque-types/Cargo.toml"
cargo fetch --locked --manifest-path "${source_rust}/Cargo.toml"
export CARGO_NET_OFFLINE=true
cmake -S "${source_c}" -B "${scratch}/c-build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${prefix}" -DZENOHC_BUILD_WITH_SHARED_MEMORY=TRUE \
  -DZENOHC_BUILD_WITH_UNSTABLE_API=TRUE '-DZENOHC_CARGO_FLAGS=--locked;--offline'
cmake --build "${scratch}/c-build" --parallel "${jobs}"
cmake --install "${scratch}/c-build"
# Retain the actual generated locks even when the post-build hash gate fails.
evidence="${out}/build-locks/${architecture}"
mkdir -p "${evidence}"
cp "${source_c}/build-resources/opaque-types/Cargo.lock" "${evidence}/opaque-Cargo.lock"
cp "${scratch}/c-build/release/Cargo.lock" "${evidence}/Cargo.lock"
printf '%s  %s\n' \
  "$(get CARGO_LOCK_SHA256)" "${evidence}/Cargo.lock" \
  "$(get OPAQUE_CARGO_LOCK_SHA256)" "${evidence}/opaque-Cargo.lock" | sha256sum --check --quiet

cmake -S "${source_cpp}" -B "${scratch}/cpp-build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${prefix}" -DCMAKE_INSTALL_PREFIX="${prefix}" \
  -DZENOHCXX_ENABLE_TESTS=OFF -DZENOHCXX_ENABLE_EXAMPLES=OFF
cmake --install "${scratch}/cpp-build"
# The 1.10.2 installed C++ config aliases non-GLOBAL imported backends.
# CMake 3.16 requires those imports to be GLOBAL; only the package export is
# adjusted. Upstream headers and all C/Rust implementation bytes stay intact.
zenohcxx_config="${prefix}/lib/cmake/zenohcxx/zenohcxxConfig.cmake"
sed -i \
  -e 's/add_library(zenohcxx_zenohc INTERFACE IMPORTED)/add_library(zenohcxx_zenohc INTERFACE IMPORTED GLOBAL)/' \
  -e 's/add_library(zenohcxx_zenohpico INTERFACE IMPORTED)/add_library(zenohcxx_zenohpico INTERFACE IMPORTED GLOBAL)/' \
  "${zenohcxx_config}"

cargo build --release --locked --offline --manifest-path "${source_rust}/Cargo.toml" --package zenohd
install -Dm0755 "${source_rust}/target/release/zenohd" "${prefix}/bin/zenohd"
for name in zenoh-c zenoh zenoh-cpp; do
  for file in "${scratch}/sources/${name}"/LICENSE* "${scratch}/sources/${name}"/NOTICE*; do
    if [[ -f "${file}" ]]; then
      install -Dm0644 "${file}" "${prefix}/share/licenses/${name}/$(basename "${file}")"
    fi
  done
done
install -Dm0644 "${lock}" "${prefix}/share/xgc2/zenoh.lock"
printf '%s  %s\n' \
  "$(get CARGO_LOCK_SHA256)" "${source_c}/Cargo.lock" \
  "$(get OPAQUE_CARGO_LOCK_SHA256)" "${source_c}/build-resources/opaque-types/Cargo.lock" \
  "$(get ZENOH_RUST_CARGO_LOCK_SHA256)" "${source_rust}/Cargo.lock" | sha256sum --check --quiet
printf 'zenoh-c=%s source=%s zenoh=%s rust=%s arch=%s glibc<=%s\n' \
  "${version}" "$(get ZENOH_C_SHA)" "$(get ZENOH_RUST_SHA)" "${rust_toolchain}" \
  "${architecture}" "${build_glibc}" > "${prefix}/.xgc2-zenoh-sdk"
"${script_dir}/check_prefix.sh" "${prefix}" --arch "${architecture}" --baseline "${build_glibc}"
echo "prefix: ${prefix}"
