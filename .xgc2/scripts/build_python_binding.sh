#!/usr/bin/env bash
# Build the zenoh-python 1.8.0 binding for the requested runtime/arch FROM THE
# PINNED SOURCE ONLY. Upstream's published cp38 wheel is a mislabeled artifact:
# its .so references PyCMethod_New (CPython >= 3.9 limited API) while claiming
# cp38, so NO published binary can satisfy a real py3.8 runtime. We apply the
# reviewed .xgc2 patch (abi3-py39 -> abi3-py38, moving release branch -> frozen
# rev pins, maturin>1 -> maturin==1.12.6 build pin) and produce the honest
# wheel ourselves, then gate it with a real import on THIS interpreter.
# usage: build_python_binding.sh --python X --arch arm64|amd64 --out DIR
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "${script_dir}/../.." && pwd)"
lock="${repo_root}/zenoh.lock"
py=""; arch=""; out=""
while (( $# )); do case "$1" in --python) py="$2"; shift 2;; --arch) arch="$2"; shift 2;; --out) out="$2"; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
[[ -n "${py}" && -n "${arch}" && -n "${out}" ]] || { echo 'usage: build_python_binding.sh --python X --arch arm64|amd64 --out DIR' >&2; exit 2; }
supported="$(sed -n 's/^ZENOH_PYTHON_BINDINGS=//p' "${lock}" | head -n1)"
case ",${supported}," in
  *",${py}/${arch},"*) ;;
  *) echo "Python ${py} / ${arch} is not a supported binding in this product (supported: ${supported})" >&2; exit 1 ;;
esac
runtime="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
[[ "${runtime}" == "${py}" ]] || {
  echo "the binding must be built under the target interpreter python${py} (found ${runtime});" >&2
  echo "run this inside the matching distro container" >&2; exit 1; }
[[ "$(dpkg --print-architecture)" == "${arch}" ]] || {
  echo "--arch ${arch} does not match this container's dpkg architecture $(dpkg --print-architecture)" >&2; exit 1; }
expected_machine="$(case "${arch}" in amd64) echo x86_64;; arm64) echo aarch64;; *) echo unknown;; esac)"
python_machine="$(python3 -c 'import platform; print(platform.machine())')"
[[ "${python_machine}" == "${expected_machine}" ]] || {
  echo "python platform ${python_machine} does not match --arch ${arch} (${expected_machine})" >&2; exit 1; }

get() { sed -n "s/^$1=//p" "${lock}" | head -n 1; }
zp_sha="$(get ZENOH_PYTHON_SHA)"; zp_archive_sha="$(get ZENOH_PYTHON_ARCHIVE_SHA256)"
zp_lock_sha="$(get ZENOH_PYTHON_CARGO_LOCK_SHA256)"; rust_sha="$(get ZENOH_RUST_SHA)"
zp_patch_sha="$(get ZENOH_PYTHON_PATCH_SHA256)"; zp_upstream_lock_sha="$(get ZENOH_PYTHON_UPSTREAM_CARGO_LOCK_SHA256)"
for value in "${zp_sha}" "${zp_archive_sha}" "${zp_lock_sha}" "${rust_sha}" "${zp_patch_sha}" "${zp_upstream_lock_sha}"; do
  [[ -n "${value}" ]] || { echo 'zenoh.lock is incomplete' >&2; exit 1; }
done
adapted="${repo_root}/.xgc2/zenoh-python-1.8.0"
patch_file="${adapted}/py38-abi3-and-pins.patch"
[[ -f "${patch_file}" && -f "${adapted}/Cargo.lock" ]] || {
  echo "missing reviewed patch/lock in ${adapted}" >&2; exit 1; }
# The patch must carry exactly the frozen zenoh rev, not a drifted pin.
grep -q "rev = \"${rust_sha}\"" "${patch_file}" || {
  echo "patch does not pin zenoh at the frozen ZENOH_RUST_SHA ${rust_sha}" >&2; exit 1; }
printf '%s  %s\n' "${zp_patch_sha}" "${patch_file}" | sha256sum --check --quiet
printf '%s  %s\n' "${zp_lock_sha}" "${adapted}/Cargo.lock" | sha256sum --check --quiet
mkdir -p "${out}"
if compgen -G "${out}/*.whl" >/dev/null; then
  echo "output directory ${out} already contains a wheel; use a fresh staging directory" >&2; exit 1
fi
scratch="$(mktemp -d)"; trap 'rm -rf "${scratch}"' EXIT
curl --fail --location --retry 4 --retry-delay 2 --max-time 300 \
  "https://github.com/eclipse-zenoh/zenoh-python/archive/${zp_sha}.tar.gz" -o "${scratch}/src.tgz"
printf '%s  %s\n' "${zp_archive_sha}" "${scratch}/src.tgz" | sha256sum --check --quiet
mkdir "${scratch}/source"
tar -xzf "${scratch}/src.tgz" -C "${scratch}/source" --strip-components=1

# Preconditions: the frozen upstream source must contain exactly the lines the
# reviewed patch rewrites; drift fails explicitly instead of producing a hybrid.
src="${scratch}/source"
printf '%s  %s\n' "${zp_upstream_lock_sha}" "${src}/Cargo.lock" | sha256sum --check --quiet
python3 - "${src}" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
cargo = (root / "Cargo.toml").read_text()
proj = (root / "pyproject.toml").read_text()
assert cargo.count('"abi3-py39"') == 1, "unexpected pyo3 abi3 feature declarations"
assert cargo.count('branch = "release/1.8.0"') == 2, "unexpected zenoh branch-pin declarations"
assert proj.count('requires = ["maturin>1"]') == 1, "unexpected maturin build requirement"
assert (root / "Cargo.lock").is_file(), "upstream Cargo.lock missing"
PY
patch --batch -s -p1 -d "${src}" < "${patch_file}"

# The reviewed adapted lock is authoritative: it keeps every crates.io pin from
# the shipped lock and rewrites only the two zenoh git deps to the frozen rev.
cp "${adapted}/Cargo.lock" "${src}/Cargo.lock"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo fetch --locked --manifest-path "${src}/Cargo.toml"
export CARGO_NET_OFFLINE=true
# PEP 517: pip's isolated build env installs the pinned maturin==1.12.6 and runs
# cargo --release under CARGO_NET_OFFLINE against the reviewed lock. PYO3_PYTHON
# pins the interpreter pyo3 probes (never a newer one on PATH); the maturin
# --locked flag makes the build itself refuse any lock drift.
export PYO3_PYTHON="$(command -v python3)"
export MATURIN_PEP517_ARGS="--locked"
python3 -m pip wheel "${src}" --no-deps -w "${out}"
printf '%s  %s\n' "${zp_lock_sha}" "${src}/Cargo.lock" | sha256sum --check --quiet

shopt -s nullglob
wheels=("${out}"/*.whl)
(( ${#wheels[@]} == 1 )) || { echo "expected exactly one wheel in ${out}, got ${#wheels[@]}" >&2; exit 1; }
# ELF ABI gate (AGY review): never trust wheel tags — every undefined Py*/_Py*
# symbol of the built extension must resolve in THIS runtime's libpython. This
# catches exactly the upstream defect (PyCMethod_New/PyInterpreterState_Get
# leaking from a 3.9 limited-API compile into a cp38-tagged artifact).
import_dir="$(mktemp -d)"; trap 'rm -rf "${scratch}" "${import_dir}"' EXIT
( cd "${import_dir}" && unzip -q "${wheels[0]}" )
[[ -d "${import_dir}/zenoh" ]] || { echo "wheel has no zenoh package" >&2; exit 1; }
shopt -s nullglob
sos=("${import_dir}/zenoh/"*.so)
(( ${#sos[@]} == 1 )) || { echo "expected exactly one zenoh extension module, got ${#sos[@]}" >&2; exit 1; }
so="${sos[0]}"
python3 - "${wheels[0]}" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    wheel_meta = [name for name in archive.namelist() if name.endswith(".dist-info/WHEEL")]
    if len(wheel_meta) != 1:
        raise SystemExit(f"expected one WHEEL metadata file, got {wheel_meta}")
    metadata = archive.read(wheel_meta[0]).decode()
if "Generator: maturin (1.12.6)" not in metadata:
    raise SystemExit("WHEEL does not record the pinned maturin 1.12.6 generator")
if "Tag: cp38-abi3-linux_" not in metadata:
    raise SystemExit("WHEEL tag is not cp38-abi3-linux_*")
print("WHEEL metadata OK: maturin 1.12.6, cp38-abi3-linux_*")
PY
command -v objdump >/dev/null || { echo "objdump is required for the glibc gate" >&2; exit 1; }
max_glibc="$(objdump -T "${so}" | grep -o 'GLIBC_[0-9.]*' | sed 's/^GLIBC_//' | sort -V | tail -1)"
[[ -n "${max_glibc}" ]] || { echo "cannot determine the extension's glibc ceiling" >&2; exit 1; }
build_glibc="$(ldd --version | awk 'NR==1 { print $NF }')"
python3 - "${max_glibc}" "${build_glibc}" <<'PY'
import sys
def version(text): return tuple(int(part) for part in text.split("."))
if version(sys.argv[1]) > version(sys.argv[2]):
    raise SystemExit(f"glibc gate FAILED: extension needs {sys.argv[1]} > container {sys.argv[2]}")
print(f"glibc gate OK: extension <= GLIBC_{sys.argv[1]} (container {sys.argv[2]})")
PY
libpython="$(python3 - <<'PY'
import os, sysconfig
libdir = sysconfig.get_config_var("LIBDIR")
ldlib = sysconfig.get_config_var("LDLIBRARY")
multiarch = sysconfig.get_config_var("MULTIARCH")
candidates = [os.path.join(libdir, ldlib)]
if multiarch:
    candidates.append(os.path.join(libdir, multiarch, ldlib))
for candidate in candidates:
    if os.path.isfile(candidate):
        print(os.path.realpath(candidate))
        break
else:
    raise SystemExit("cannot find libpython")
PY
)"
[[ -f "${libpython}" ]] || { echo "cannot find libpython" >&2; exit 1; }
missing="$(comm -23 <(nm -D --undefined-only "${so}" | awk '$NF ~ /^_?Py/ {print $NF}' | sort -u) \
                     <(nm -D --defined-only "${libpython}" | awk '{print $NF}' | sort -u))"
[[ -z "${missing}" ]] || {
  echo "ABI gate FAILED: ${so##*/} references symbols missing from ${libpython}:" >&2
  echo "${missing}" >&2; exit 1; }
echo "ELF ABI gate OK: all Py* symbols resolve in ${libpython}"
# Real-runtime gate: import the freshly built binding on THIS interpreter.
PYTHONPATH="${import_dir}" python3 -c \
  'import importlib.metadata, sys, zenoh; v = importlib.metadata.version("eclipse-zenoh"); assert v == "1.8.0", v; print("zenoh python binding", v, "on", sys.version.split()[0])'
echo "wheel: ${wheels[0]}"
