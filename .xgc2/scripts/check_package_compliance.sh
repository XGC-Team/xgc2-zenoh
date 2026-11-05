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
  suite="${version##*~}"
  [[ "${suite}" == "bionic" || "${suite}" == "focal" || "${suite}" == "jammy" || "${suite}" == "noble" ]] || {
    echo "unexpected suite suffix in ${version}" >&2; exit 1; }
  listing="$(dpkg-deb -c "${deb}")"
  depends="$(dpkg-deb -f "${deb}" Depends)"
  grep -q './opt/xgc2/zenoh/include/zenoh.h$' <<<"${listing}" || { echo "missing zenoh.h in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/include/zenoh.hxx$' <<<"${listing}" || { echo "missing zenoh.hxx in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/libzenohc.so$' <<<"${listing}" || { echo "missing libzenohc.so in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/libzenohc.a$' <<<"${listing}" || { echo "missing libzenohc.a in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/bin/zenohd$' <<<"${listing}" || { echo "missing bin/zenohd in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/cmake/zenohc/zenohcConfig.cmake$' <<<"${listing}" || { echo "missing zenohcConfig.cmake in ${deb}" >&2; exit 1; }
  grep -q './opt/xgc2/zenoh/lib/cmake/zenohcxx/zenohcxxConfig.cmake$' <<<"${listing}" || { echo "missing zenohcxxConfig.cmake in ${deb}" >&2; exit 1; }
  grep -q './usr/lib/cmake/zenohc/zenohcConfig.cmake$' <<<"${listing}" || { echo "missing zenohc forwarding stub in ${deb}" >&2; exit 1; }
  grep -q './usr/lib/cmake/zenohcxx/zenohcxxConfig.cmake$' <<<"${listing}" || { echo "missing zenohcxx forwarding stub in ${deb}" >&2; exit 1; }
  grep -q './etc/ld.so.conf.d/xgc2-zenoh.conf$' <<<"${listing}" || { echo "missing ld.so.conf entry in ${deb}" >&2; exit 1; }
  if [[ "${suite}" == "bionic" ]]; then
    grep -qE '(^|, )libgcc1(,|$)' <<<"${depends}" || { echo "bionic package must depend on libgcc1" >&2; exit 1; }
  else
    grep -qE '(^|, )libgcc-s1(,|$)' <<<"${depends}" || { echo "${suite} package must depend on libgcc-s1" >&2; exit 1; }
  fi
  case "${suite}" in
    focal|noble)
      grep -qE '(^|, )python3(,|$)' <<<"${depends}" || { echo "${suite} package must depend on python3" >&2; exit 1; }
      grep -q './usr/lib/python3/dist-packages/zenoh/' <<<"${listing}" || { echo "${suite} package lacks its system Python binding" >&2; exit 1; }
      ;;
    bionic)
      for dependency in libtcl8.6 libtk8.6; do
        grep -qE "(^|, )${dependency}(,|$)" <<<"${depends}" || { echo "Bionic runtime lacks ${dependency} Depends" >&2; exit 1; }
      done
      if grep -qE '(^|, )python3(,|$)' <<<"${depends}"; then echo 'Bionic must not claim the system Python 3.6 binding' >&2; exit 1; fi
      grep -q './opt/xgc2/zenoh/bin/python -> ../python/bin/python3$' <<<"${listing}" || { echo 'Bionic lacks its explicit private Python entry' >&2; exit 1; }
      grep -q './opt/xgc2/zenoh/python/lib/python3.12/site-packages/zenoh/' <<<"${listing}" || { echo 'Bionic lacks its private Python binding' >&2; exit 1; }
      if grep -q './usr/lib/python3/dist-packages/zenoh/' <<<"${listing}"; then echo 'Bionic overwrites system Python with Zenoh' >&2; exit 1; fi
      ;;
    jammy)
      if grep -qE '(^|, )python3(,|$)' <<<"${depends}"; then echo 'Jammy C SDK package must not depend on python3' >&2; exit 1; fi
      if grep -q './usr/lib/python3/dist-packages/zenoh/' <<<"${listing}"; then echo 'Jammy carries undeclared Python payload' >&2; exit 1; fi
      ;;
  esac
  if grep -qE '\.(rs|toml)$' <<<"${listing}"; then echo "rust sources leaked into ${deb}" >&2; exit 1; fi
  echo "compliance OK: ${name} ${version} ${arch} (${suite}, python=$(if [[ "${suite}" != "jammy" ]]; then echo yes; else echo no; fi))"
done
