#!/usr/bin/env bash
# Verification gates for a prepared zenoh prefix (see col/agy-zenoh-arm-supply-route.md §4).
# usage: check_prefix.sh PREFIX [--arch amd64|arm64]
set -euo pipefail

prefix="${1:?usage: check_prefix.sh PREFIX [--arch amd64|arm64]}"
arch="${2:+${2#--arch}}"
arch="${arch:-arm64}"
prefix="$(cd "${prefix}" && pwd -P)"

fail() { echo "zenoh prefix check FAILED: $*" >&2; exit 1; }

[[ -f "${prefix}/include/zenoh.h" ]] || fail "missing include/zenoh.h"
[[ -f "${prefix}/include/zenoh.hxx" ]] || fail "missing include/zenoh.hxx (zenoh-cpp 1.8.0 headers are required: composite compiles ZENOHCXX_ZENOHC)"
[[ -f "${prefix}/lib/libzenohc.so" ]] || fail "missing lib/libzenohc.so"

elf="$(readelf -h "${prefix}/lib/libzenohc.so")"
grep -q 'Class:.*ELF64' <<<"${elf}" || fail "libzenohc.so is not ELF64"
case "${arch}" in
  arm64) grep -q 'Machine:.*AArch64' <<<"${elf}" || fail "libzenohc.so is not AArch64" ;;
  amd64) grep -q 'Machine:.*X86-64' <<<"${elf}" || fail "libzenohc.so is not X86-64" ;;
  *) fail "unsupported arch ${arch}" ;;
esac

highest="$(objdump -T "${prefix}/lib/libzenohc.so" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n1)"
[[ -n "${highest}" ]] || fail "no GLIBC version symbols found"
python3 - "${highest#GLIBC_}" 2.31 <<'PY' || fail "required ${highest} exceeds the focal baseline GLIBC_2.31"
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
