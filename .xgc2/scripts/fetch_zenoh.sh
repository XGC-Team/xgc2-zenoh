#!/usr/bin/env bash
# Materialize the pinned zenoh-c tree + vendored crates when the in-repo maintained
# copy is absent (CI network path). Mirrors acados/.xgc2/scripts/fetch_acados.sh:
# clone at the frozen SHA only, then vendor exactly the locked crates.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
lock="${repo_root}/zenoh.lock"
out="${1:?usage: fetch_zenoh.sh OUTPUT_DIR}"
get() { sed -n "s/^$1=//p" "${lock}" | head -n 1; }
mkdir -p "${out}/src"
if [[ ! -d "${out}/src/zenoh-c-pinned" ]]; then
  git clone --filter=blob:none https://github.com/eclipse-zenoh/zenoh-c.git "${out}/src/zenoh-c-pinned"
  git -C "${out}/src/zenoh-c-pinned" checkout --detach "$(get ZENOH_C_SHA)"
fi
# The rev-pin replaces the moving release branch, exactly as the frozen provenance does.
python3 - "$(get ZENOH_RUST_SHA)" "${out}/src/zenoh-c-pinned" <<'PY'
import pathlib, sys
sha, root = sys.argv[1], pathlib.Path(sys.argv[2])
for name in ('Cargo.toml', 'Cargo.toml.in', 'build-resources/opaque-types/Cargo.toml'):
    p = root / name
    if p.is_file():
        p.write_text(p.read_text().replace('branch = "release/1.8.0"', f'rev = "{sha}"'))
PY
( cd "${out}/src/zenoh-c-pinned" && CARGO_NET_OFFLINE=false cargo vendor --locked --versioned-dirs "${out}/src/vendor" >/dev/null )
echo "${out}"
