#!/usr/bin/env bash
# Verification gates for a prepared zenoh prefix (see col/agy-zenoh-arm-supply-route.md §4).
# The glibc ceiling defaults to THIS container's own libc: the build runs inside the
# target distro image, so an artifact may never require a newer glibc than the
# distro ships. Pass --baseline (or ZENOH_GLIBC_BASELINE) to pin a stricter floor.
# usage: check_prefix.sh PREFIX --arch amd64|arm64 [--baseline X.Y]
set -euo pipefail

prefix=""; arch=""; baseline="${ZENOH_GLIBC_BASELINE:-}"
while (( $# )); do
  case "$1" in
    --arch) arch="${2:?}"; shift 2 ;;
    --baseline) baseline="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) if [[ -z "${prefix}" && "$1" != -* ]]; then prefix="$1"; shift; else echo "unknown option: $1" >&2; exit 2; fi ;;
  esac
done
[[ -n "${prefix}" && -n "${arch}" ]] || { echo 'usage: check_prefix.sh PREFIX --arch amd64|arm64 [--baseline X.Y]' >&2; exit 2; }
prefix="$(cd "${prefix}" && pwd -P)"
if [[ -z "${baseline}" ]]; then
  baseline="$(ldd --version 2>/dev/null | awk 'NR==1 { print $NF }')"
fi
[[ "${baseline}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "cannot determine the glibc baseline (ldd gave '${baseline}')" >&2; exit 1; }

fail() { echo "zenoh prefix check FAILED: $*" >&2; exit 1; }

[[ -f "${prefix}/include/zenoh.h" ]] || fail "missing include/zenoh.h"
[[ -f "${prefix}/include/zenoh.hxx" ]] || fail "missing include/zenoh.hxx (zenoh-cpp 1.8.0 headers are required: composite compiles ZENOHCXX_ZENOHC)"
[[ -f "${prefix}/lib/libzenohc.so" ]] || fail "missing lib/libzenohc.so"
[[ -f "${prefix}/lib/libzenohc.a" ]] || fail "missing lib/libzenohc.a"
[[ -f "${prefix}/lib/cmake/zenohc/zenohcConfig.cmake" ]] || fail "missing lib/cmake/zenohc/zenohcConfig.cmake"
[[ -f "${prefix}/lib/cmake/zenohcxx/zenohcxxConfig.cmake" ]] || fail "missing lib/cmake/zenohcxx/zenohcxxConfig.cmake (zenoh-cpp 1.8.0 headers/CMake package required by ZENOHCXX_ZENOHC)"

elf="$(readelf -h "${prefix}/lib/libzenohc.so")"
grep -q 'Class:.*ELF64' <<<"${elf}" || fail "libzenohc.so is not ELF64"
case "${arch}" in
  arm64) grep -q 'Machine:.*AArch64' <<<"${elf}" || fail "libzenohc.so is not AArch64" ;;
  amd64) grep -q 'Machine:.*X86-64' <<<"${elf}" || fail "libzenohc.so is not X86-64" ;;
  *) fail "unsupported arch ${arch}" ;;
esac

highest="$(objdump -T "${prefix}/lib/libzenohc.so" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n1)"
[[ -n "${highest}" ]] || fail "no GLIBC version symbols found"
python3 - "${highest#GLIBC_}" "${baseline}" <<'PY' || fail "required ${highest} exceeds this distro's baseline GLIBC_${baseline}"
import sys
need = tuple(int(x) for x in sys.argv[1].split('.'))
base = tuple(int(x) for x in sys.argv[2].split('.'))
sys.exit(0 if need <= base else 1)
PY
echo "glibc highest required: ${highest} (baseline <= GLIBC_2.31)"

if [[ -f "${prefix}/SHA256SUMS" ]]; then
  ( cd "${prefix}" && sha256sum --quiet -c SHA256SUMS ) || fail "SHA256SUMS mismatch"
else
  ( cd "${prefix}" && find include lib -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
  echo "wrote SHA256SUMS"
fi
echo "zenoh prefix OK: ${prefix} (${arch})"
