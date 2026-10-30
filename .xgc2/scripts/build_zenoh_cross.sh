#!/usr/bin/env bash
# Build the pinned zenoh-c 1.8.0 SDK prefix inside a DISPOSABLE container.
#
# The host (workstation or FS150-03) is never mutated: the cross toolchain, the Rust
# toolchain and any source materialization all happen inside the throw-away
# container. When a prepared pinned tree is available it is mounted read-only; when
# it is not, the container materializes it from the frozen SHAs in zenoh.lock
# (network is used only inside that container) and then builds strictly offline from
# the vendored crates. Both lock files are sha256-verified before the build is
# accepted.
#
# usage: build_zenoh_cross.sh --out DIR [--arch arm64|amd64] [--image IMAGE] [--jobs N]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
lock="${repo_root}/zenoh.lock"

image_default='ghcr.io/xgc-team/xgc2-images/xgc2-build-focal-full-noetic:1.0.8@sha256:fce2d76fddf4f6439bf0a188249b731650febdc163befc360bed186b269d252a'
out=""; image="${image_default}"; jobs="${ZENOH_BUILD_JOBS:-8}"; arch="arm64"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    --arch) arch="${2:?}"; shift 2 ;;
    --image) image="${2:?}"; shift 2 ;;
    --jobs) jobs="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${out}" && "${out}" == /* ]] || { echo '--out must be an absolute path' >&2; exit 2; }
case "${arch}" in arm64) rust_target=aarch64-unknown-linux-gnu; cross_cc=aarch64-linux-gnu-gcc; cross_cxx=aarch64-linux-gnu-g++ ;;
               amd64) rust_target=x86_64-unknown-linux-gnu; cross_cc=gcc; cross_cxx=g++ ;;
               *) echo 'unsupported arch' >&2; exit 2 ;; esac
# Native runners build natively; only a foreign target needs the cross toolchain.
host_arch="$(uname -m)"; [[ "${host_arch}" == "aarch64" ]] && host_arch=arm64
[[ "${host_arch}" == "x86_64" ]] && host_arch=amd64
if [[ "${host_arch}" == "${arch}" ]]; then native=1; cc=gcc; cxx=g++; cross_pkgs=""; else native=0; cc="${cross_cc}"; cxx="${cross_cxx}"; cross_pkgs="gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross"; fi

get() { sed -n "s/^$1=//p" "${lock}" | head -n 1; }
zenoh_c_sha="$(get ZENOH_C_SHA)"; zenoh_rust_sha="$(get ZENOH_RUST_SHA)"
cargo_lock_sha="$(get CARGO_LOCK_SHA256)"; opaque_lock_sha="$(get OPAQUE_CARGO_LOCK_SHA256)"
rust_toolchain="$(get RUST_TOOLCHAIN)"; glibc_baseline="$(get GLIBC_BASELINE)"
cpp_sha="$(get ZENOH_CPP_ARCHIVE_SHA256)"; cpp_version="$(get ZENOH_CPP_VERSION)"
for v in "${zenoh_c_sha}" "${zenoh_rust_sha}" "${cargo_lock_sha}" "${opaque_lock_sha}" "${rust_toolchain}" "${cpp_sha}"; do
  [[ -n "${v}" ]] || { echo 'zenoh.lock is incomplete' >&2; exit 1; }
done

mkdir -p "${out}"
image_id="$(docker image inspect --format '{{.Id}}' "${image}")"
[[ -n "${image_id}" ]] || { echo "builder image unavailable: ${image}" >&2; exit 1; }

# Optional prepared tree (offline reuse): repo copy, then any caller-provided dir.
pinned="${ZENOH_PINNED_SOURCE:-${repo_root}/../../ros1/visualization/ros-visualizer/.xgc2/zenoh-c-1.8.0}"
mount_args=(); fetch=1
if [[ -d "${pinned}/src/zenoh-c-pinned" && -d "${pinned}/src/vendor" ]]; then
  mount_args=(--mount "type=bind,src=${pinned},dst=/in,readonly"); fetch=0
fi
# The re-resolved pinned locks live in this repo; the upstream tag lock pins zenoh
# 1.7.2 and would fail --locked, so these are authoritative.
pinned_locks="${repo_root}/.xgc2/zenoh-c-1.8.0"
[[ -f "${pinned_locks}/Cargo.lock" && -f "${pinned_locks}/opaque-Cargo.lock" ]] || {
  echo "missing pinned locks in ${pinned_locks}" >&2; exit 1; }
mount_args+=(--mount "type=bind,src=${pinned_locks},dst=/locks,readonly")

docker run --rm \
  "${mount_args[@]}" \
  --mount "type=bind,src=${out},dst=/out" \
  -e ZENOH_FETCH="${fetch}" -e ZENOH_C_SHA="${zenoh_c_sha}" -e ZENOH_RUST_SHA="${zenoh_rust_sha}" \
  -e CARGO_LOCK_SHA="${cargo_lock_sha}" -e OPAQUE_LOCK_SHA="${opaque_lock_sha}" \
  -e RUST_TOOLCHAIN="${rust_toolchain}" -e GLIBC_BASELINE="${glibc_baseline}" \
  -e ZENOH_CPP_VERSION="${cpp_version}" -e ZENOH_CPP_SHA="${cpp_sha}" \
  -e RUST_TARGET="${rust_target}" -e CC_TARGET="${cc}" -e CXX_TARGET="${cxx}" \
  -e CROSS_PKGS="${cross_pkgs}" -e PREFIX_NAME="zenoh-${arch}" -e CARGO_BUILD_JOBS="${jobs}" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  --entrypoint bash "${image_id}" -euo pipefail -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      build-essential cmake ninja-build curl unzip xz-utils ca-certificates git \
      ${CROSS_PKGS}

    # The image ships a rustup toolchain whose sysroot has no cross target std, so
    # the pinned standalone toolchain is installed unconditionally into /opt/rust
    # and every later rustc call resolves to it.
    curl -fsSL "https://static.rust-lang.org/dist/rust-${RUST_TOOLCHAIN}-x86_64-unknown-linux-gnu.tar.xz" -o /tmp/rust.tar.xz
    tar -C /tmp -xf /tmp/rust.tar.xz
    "/tmp/rust-${RUST_TOOLCHAIN}-x86_64-unknown-linux-gnu/install.sh" --prefix=/opt/rust --disable-ldconfig --without=rust-docs >/dev/null
    curl -fsSL "https://static.rust-lang.org/dist/rust-std-${RUST_TOOLCHAIN}-${RUST_TARGET}.tar.xz" -o /tmp/rust-std.tar.xz
    tar -C /tmp -xf /tmp/rust-std.tar.xz
    "/tmp/rust-std-${RUST_TOOLCHAIN}-${RUST_TARGET}/install.sh" --prefix=/opt/rust --disable-ldconfig >/dev/null
    export PATH="/opt/rust/bin:${PATH}"
    test -x /opt/rust/bin/rustc
    test -d "/opt/rust/lib/rustlib/${RUST_TARGET}"
    export PATH="/opt/rust/bin:${PATH}"

    if [[ "${ZENOH_FETCH}" == "1" ]]; then
      mkdir -p /in/src
      # Tarball API instead of git/gnutls: the container reaches GitHub over HTTPS
      # but the git gnutls handshake is unreliable here.
      curl -fsSL -o /tmp/zenoh-c-src.tar.gz "https://codeload.github.com/eclipse-zenoh/zenoh-c/tar.gz/${ZENOH_C_SHA}"
      mkdir -p /in/src/zenoh-c-pinned
      tar -C /in/src/zenoh-c-pinned --strip-components=1 -xzf /tmp/zenoh-c-src.tar.gz
      python3 - "${ZENOH_RUST_SHA}" <<PY
import pathlib, sys
sha, root = sys.argv[1], pathlib.Path("/in/src/zenoh-c-pinned")
for name in ("Cargo.toml", "Cargo.toml.in", "build-resources/opaque-types/Cargo.toml"):
    p = root / name
    if p.is_file():
        p.write_text(p.read_text().replace("branch = \"release/1.8.0\"", f"rev = \"{sha}\""))
PY
      printf "%s  %s\n" "${CARGO_LOCK_SHA}" /locks/Cargo.lock | sha256sum --check --quiet
      printf "%s  %s\n" "${OPAQUE_LOCK_SHA}" /locks/opaque-Cargo.lock | sha256sum --check --quiet
      install -m 0644 /locks/Cargo.lock /in/src/zenoh-c-pinned/Cargo.lock
      install -m 0644 /locks/opaque-Cargo.lock /in/src/zenoh-c-pinned/build-resources/opaque-types/Cargo.lock
      ( cd /in/src/zenoh-c-pinned && cargo vendor --locked --versioned-dirs /in/src/vendor >/dev/null )
      curl -fsSL -o /tmp/zenoh-cpp.zip "https://github.com/eclipse-zenoh/zenoh-cpp/releases/download/${ZENOH_CPP_VERSION}/zenohcpp-${ZENOH_CPP_VERSION}-standalone.zip"
      printf "%s  %s\n" "${ZENOH_CPP_SHA}" /tmp/zenoh-cpp.zip | sha256sum --check --quiet
      mkdir -p /in/unpacked/zenoh-cpp && unzip -q /tmp/zenoh-cpp.zip -d /in/unpacked/zenoh-cpp
    fi

    cp -a /in/src/zenoh-c-pinned /work-zenoh-c
    mkdir -p /work-cargo-home
    cat > /work-cargo-home/config.toml <<EOF
[source.crates-io]
replace-with = "vendored-sources"
[source."git+https://github.com/eclipse-zenoh/zenoh.git?rev=${ZENOH_RUST_SHA}"]
git = "https://github.com/eclipse-zenoh/zenoh.git"
rev = "${ZENOH_RUST_SHA}"
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "/in/src/vendor"
[target.${RUST_TARGET}]
linker = "${CC_TARGET}"
EOF
    export CARGO_HOME=/work-cargo-home CARGO_NET_OFFLINE=true RUSTC_LINKER="${CC_TARGET}"
    cmake -S /work-zenoh-c -B /work-build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="${RUST_TARGET%%-*}" \
      -DCMAKE_C_COMPILER="${CC_TARGET}" -DCMAKE_CXX_COMPILER="${CXX_TARGET}" \
      -DCMAKE_INSTALL_PREFIX="/out/${PREFIX_NAME}" \
      -DZENOHC_CUSTOM_TARGET="${RUST_TARGET}" \
      -DZENOHC_BUILD_WITH_SHARED_MEMORY=TRUE \
      -DZENOHC_BUILD_WITH_UNSTABLE_API=TRUE \
      "-DZENOHC_CARGO_FLAGS=--locked;--offline"
    cmake --build /work-build --target cargo --parallel "${CARGO_BUILD_JOBS}"
    printf "%s  %s\n" "${CARGO_LOCK_SHA}" /work-zenoh-c/Cargo.lock | sha256sum --check --quiet
    printf "%s  %s\n" "${OPAQUE_LOCK_SHA}" /work-zenoh-c/build-resources/opaque-types/Cargo.lock | sha256sum --check --quiet
    cmake --install /work-build
    cp -a /in/unpacked/zenoh-cpp/include/. "/out/${PREFIX_NAME}/include/"
    mkdir -p "/out/${PREFIX_NAME}/lib/cmake"
    [[ -d /in/unpacked/zenoh-cpp/lib/cmake/zenohcxx ]] || { echo "zenoh-cpp cmake package missing from the pinned archive" >&2; exit 1; }
    cp -a /in/unpacked/zenoh-cpp/lib/cmake/zenohcxx "/out/${PREFIX_NAME}/lib/cmake/"
    printf "zenoh-c source=%s zenoh=%s rust=%s arch=%s lock=%s opaque=%s glibc<=%s\n" \
      "${ZENOH_C_SHA}" "${ZENOH_RUST_SHA}" "${RUST_TOOLCHAIN}" "${RUST_TARGET}" \
      "${CARGO_LOCK_SHA}" "${OPAQUE_LOCK_SHA}" "${GLIBC_BASELINE}" > "/out/${PREFIX_NAME}/.xgc2-zenoh-sdk"
    chown -R "${HOST_UID}:${HOST_GID}" "/out/${PREFIX_NAME}"
  '

echo "prefix: ${out}/zenoh-${arch}"
"${script_dir}/check_prefix.sh" "${out}/zenoh-${arch}" --arch "${arch}"
