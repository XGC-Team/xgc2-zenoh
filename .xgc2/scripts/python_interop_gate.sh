#!/usr/bin/env bash
# Interop gate: a Python binding session must exchange a sample with the C SDK
# prefix on the same host (proves ABI + wire compatibility, not just import).
set -euo pipefail
prefix=""; py=""
while (( $# )); do case "$1" in --prefix) prefix="$2"; shift 2;; --python) py="$2"; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
[[ -n "${prefix}" ]] || { echo 'usage: python_interop_gate.sh --prefix PREFIX [--python X]' >&2; exit 2; }
work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
cat > "${work}/c_sub.c" <<'C'
#include <zenoh.h>
#include <stdio.h>
int main(void){ z_owned_config_t c; z_config_default(&c); z_owned_session_t s;
  if (z_open(&s, z_move(c), NULL) < 0) return 2; z_view_keyexpr_t k;
  z_view_keyexpr_from_str(&k, "xgc2/zenoh/interop");
  for (int i=0;i<200;i++){ z_owned_bytes_t b; z_bytes_from_static_str(&b,"interop");
    z_put(z_loan(s), z_loan(k), z_move(b), NULL); z_sleep_ms(50); }
  z_close(z_move(s)); return 0; }
C
cc -O2 -I"${prefix}/include" "${work}/c_sub.c" -o "${work}/c_sub" -L"${prefix}/lib" -lzenohc -Wl,-rpath,"${prefix}/lib"
"${work}/c_sub" & cpid=$!
python3 - <<'PY'
import sys, time
import zenoh
cfg = zenoh.Config()
with zenoh.open(cfg) as s:
    got = []
    sub = s.declare_subscriber("xgc2/zenoh/interop", lambda smp: got.append(smp))
    for _ in range(100):
        if got: break
        time.sleep(0.05)
    sys.exit(0 if got else 1)
PY
rc=$?; wait $cpid || true
[[ ${rc} -eq 0 ]] || { echo 'python<->C interop failed' >&2; exit 1; }
echo 'python<->C interop OK'
