#!/usr/bin/env bash
# Mirror of the acados package-compliance gate: the produced debs must carry the
# declared package name/version and must not smuggle in the frozen pins' sources.
set -euo pipefail
debs_dir="${1:?usage: check_package_compliance.sh DEBS_DIR}"
shopt -s nullglob
debs=("${debs_dir}"/*.deb)
(( ${#debs[@]} > 0 )) || { echo "no debs in ${debs_dir}" >&2; exit 1; }
for deb in "${debs[@]}"; do
  name="$(dpkg-deb -f "${deb}" Package)"
  version="$(dpkg-deb -f "${deb}" Version)"
  arch="$(dpkg-deb -f "${deb}" Architecture)"
  [[ "${name}" == "xgc2-zenoh" ]] || { echo "unexpected package name ${name}" >&2; exit 1; }
  [[ "${arch}" == "arm64" || "${arch}" == "amd64" ]] || { echo "unexpected arch ${arch}" >&2; exit 1; }
  listing="$(dpkg-deb -c "${deb}")"
  grep -q './opt/xgc2/zenoh/include/zenoh.h$' <<<"${listing}" || { echo "missing zenoh.h in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/include/zenoh.hxx$' <<<"${listing}" || { echo "missing zenoh.hxx in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/libzenohc.so$' <<<"${listing}" || { echo "missing libzenohc.so in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/libzenohc.a$' <<<"${listing}" || { echo "missing libzenohc.a in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/cmake/zenohc/zenohcConfig.cmake$' <<<"${listing}" || { echo "missing zenohcConfig.cmake in ${deb}" >&2; exit 1; }
  grep -q './etc/ld.so.conf.d/xgc2-zenoh.conf$' <<<"${listing}" || { echo "missing ld.so.conf entry in ${deb}" >&2; exit 1; }
  if grep -qE '\.(rs|toml)$' <<<"${listing}"; then echo "rust sources leaked into ${deb}" >&2; exit 1; fi
  echo "compliance OK: ${name} ${version} ${arch}"
done
