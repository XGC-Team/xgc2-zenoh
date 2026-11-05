#!/usr/bin/env bash
# Stage the existing uv-managed CPython for inclusion in the Bionic deb.
# The caller provides an empty staging directory; this script never downloads.
# usage: bionic-runtime-stage.sh EMPTY_DIRECTORY
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This is an in-repository source lock, not user-supplied shell code.
source "${script_dir}/bionic-runtime.lock"
output="${1:?usage: bionic-runtime-stage.sh EMPTY_DIRECTORY}"
[[ -d "${output}" && -z "$(ls -A "${output}")" ]] || {
  echo "runtime staging directory must exist and be empty: ${output}" >&2; exit 1; }

case "$(dpkg --print-architecture)" in
  amd64)
    machine=x86_64
    exe_sha="${XGC2_ZENOH_BIONIC_PYTHON_AMD64_EXEC_SHA256}"
    lib_sha="${XGC2_ZENOH_BIONIC_PYTHON_AMD64_LIB_SHA256}"
    metadata="${script_dir}/bionic-runtime-metadata-amd64.json"
    ;;
  arm64)
    machine=aarch64
    exe_sha="${XGC2_ZENOH_BIONIC_PYTHON_ARM64_EXEC_SHA256}"
    lib_sha="${XGC2_ZENOH_BIONIC_PYTHON_ARM64_LIB_SHA256}"
    metadata="${script_dir}/bionic-runtime-metadata-arm64.json"
    ;;
  *) echo 'Bionic Python runtime supports amd64 and arm64' >&2; exit 1 ;;
esac

source_dir="${UV_PYTHON_INSTALL_DIR:?UV_PYTHON_INSTALL_DIR must select the existing image runtime}/cpython-${XGC2_ZENOH_BIONIC_PYTHON_VERSION}-linux-${machine}-gnu"
printf '%s  %s\n' "${exe_sha}" "${source_dir}/bin/python3.12" | sha256sum --check --quiet
printf '%s  %s\n' "${lib_sha}" "${source_dir}/lib/libpython3.12.so.1.0" | sha256sum --check --quiet
cp -a "${source_dir}/." "${output}/"

# uv adjusts sysconfig to its installation path. Preserve the same runtime but
# point this copied prefix at the package's final path, not at the build image.
"${source_dir}/bin/python3.12" -I - "${output}" "${machine}" "${XGC2_ZENOH_BIONIC_PYTHON_PREFIX}" <<'PY'
import pathlib, sys, sysconfig
root, machine, target = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
name = "_sysconfigdata__linux_{}-linux-gnu".format(machine)
path = root / "lib/python3.12" / (name + ".py")
original = path.read_text()
source_prefix = sysconfig.get_config_var("prefix")
if source_prefix not in original:
    raise SystemExit("uv sysconfig does not contain its installation prefix")
path.write_text(original.replace(source_prefix, target))
for cached in (path.parent / "__pycache__").glob(name + ".*.pyc"):
    cached.unlink()
PY

licenses="${output}/share/licenses/python-build-standalone"
mkdir -p "${licenses}/licenses"
cp -a "${script_dir}/bionic-runtime-licenses/." "${licenses}/licenses/"
cp "${metadata}" "${licenses}/PYTHON.json"
cp "${script_dir}/bionic-runtime.lock" "${licenses}/bionic-runtime.lock"
echo "staged CPython ${XGC2_ZENOH_BIONIC_PYTHON_VERSION} for ${machine} in ${output}"
