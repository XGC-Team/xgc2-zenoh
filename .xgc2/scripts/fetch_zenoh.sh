#!/usr/bin/env bash
# Materialize the three official source archives selected by zenoh.lock.
# No branch resolution, dependency rewrite or toolchain installation occurs here.
# usage: fetch_zenoh.sh OUTPUT_DIR
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
lock="${repo_root}/zenoh.lock"
out="${1:?usage: fetch_zenoh.sh OUTPUT_DIR}"
get() { sed -n "s/^$1=//p" "${lock}" | head -n 1; }
mkdir -p "${out}"
fetch_source() {
  local component="$1" name="$2" repository commit digest archive
  repository="$(get "${component}_REPOSITORY")"
  commit="$(get "${component}_SHA")"
  digest="$(get "${component}_ARCHIVE_SHA256")"
  [[ -n "${repository}" && "${commit}" =~ ^[0-9a-f]{40}$ && "${digest}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "missing source identity for ${component}" >&2; exit 1; }
  repository="${repository#https://github.com/}"
  repository="${repository%.git}"
  archive="${out}/${name}.tar.gz"
  curl --fail --location --retry 6 --retry-delay 3 --retry-connrefused --max-time 300 \
    "https://codeload.github.com/${repository}/tar.gz/${commit}" -o "${archive}"
  printf '%s  %s\n' "${digest}" "${archive}" | sha256sum --check --quiet
  mkdir -p "${out}/${name}"
  tar -xzf "${archive}" -C "${out}/${name}" --strip-components=1
}
fetch_source ZENOH_C zenoh-c
fetch_source ZENOH_RUST zenoh
fetch_source ZENOH_CPP zenoh-cpp
printf '%s  %s\n' \
  "$(get CARGO_LOCK_SHA256)" "${out}/zenoh-c/Cargo.lock" \
  "$(get OPAQUE_UPSTREAM_CARGO_LOCK_SHA256)" "${out}/zenoh-c/build-resources/opaque-types/Cargo.lock" \
  "$(get ZENOH_RUST_CARGO_LOCK_SHA256)" "${out}/zenoh/Cargo.lock" | sha256sum --check --quiet
echo "official Zenoh sources: ${out}"
