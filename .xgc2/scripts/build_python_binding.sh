#!/usr/bin/env bash
# Build the matching zenoh-python 1.8.0 binding for the requested runtime/arch.
# Only runtimes listed as supported in .xgc2/product.yml python_bindings may build;
# anything else exits non-zero so CI reports it as unsupported instead of passing.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "${script_dir}/../.." && pwd)"
py=""; arch=""; out=""
while (( $# )); do case "$1" in --python) py="$2"; shift 2;; --arch) arch="$2"; shift 2;; --out) out="$2"; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
[[ -n "${py}" && -n "${arch}" && -n "${out}" ]] || { echo 'usage: build_python_binding.sh --python X --arch arm64|amd64 --out DIR' >&2; exit 2; }
version="$(sed -n "s/^ZENOH_PYTHON_VERSION=//p" "${repo_root}/zenoh.lock" | head -n1)"
version="${version:-1.8.0}"
supported="$(sed -n "s/^python_bindings=//p" "${repo_root}/.xgc2/product.yml" | head -n1)"
case ",${supported}," in
  *",${py}/${arch},"*) ;;
  *) echo "Python ${py} / ${arch} is not a supported binding in this product (supported: ${supported})" >&2; exit 1 ;;
esac
mkdir -p "${out}"
python3 -m pip download --no-deps --only-binary :all: "eclipse-zenoh==${version}" -d "${out}" 2>&1 | tail -2 || {
  # No compatible wheel published for this runtime: build from the pinned source.
  pip_src="$(mktemp -d)"; trap 'rm -rf "${pip_src}"' EXIT
  curl -fsSL "https://github.com/eclipse-zenoh/zenoh-python/archive/refs/tags/${version}.tar.gz" -o "${pip_src}/src.tgz"
  tar -C "${pip_src}" -xzf "${pip_src}/src.tgz" --strip-components=1
  ( cd "${pip_src}" && pip wheel . --no-deps -w "${out}" )
}
ls -l "${out}"
