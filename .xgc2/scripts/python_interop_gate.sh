#!/usr/bin/env bash
# Interop gate: the installed Python binding and the installed C SDK exchange a
# VERIFIED payload on a controlled loopback-only session (unique per-run keyexpr,
# multicast scouting disabled on both ends). Proves ABI + wire compatibility —
# a stray message or an empty receive can no longer pass the gate.
# usage: python_interop_gate.sh --prefix PREFIX [--python X]
set -euo pipefail
prefix=""; py=""
while (( $# )); do case "$1" in --prefix) prefix="$2"; shift 2;; --python) py="$2"; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
[[ -n "${prefix}" ]] || { echo 'usage: python_interop_gate.sh --prefix PREFIX [--python X]' >&2; exit 2; }
prefix="$(cd "${prefix}" && pwd -P)"
if [[ -n "${py}" ]]; then
  runtime="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  [[ "${runtime}" == "${py}" ]] || { echo "interop gate must run under python${py} (found ${runtime})" >&2; exit 1; }
fi

work="$(mktemp -d)"; c_pid=""
cleanup() {
  if [[ -n "${c_pid}" ]]; then kill "${c_pid}" 2>/dev/null || true; wait "${c_pid}" 2>/dev/null || true; fi
  rm -rf -- "${work}"
}
trap cleanup EXIT

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
key="xgc2/zenoh/interop/ci-$(date +%s%N)-$$"
payload="interop-probe-$$"

cat > "${work}/c_pub.c" <<'C'
#include <zenoh.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    z_owned_config_t config;
    z_config_default(&config);
    zc_config_insert_json5(z_loan_mut(config), "scouting/multicast/enabled", "false");
    zc_config_insert_json5(z_loan_mut(config), "connect/endpoints", argv[2]);
    z_owned_session_t session;
    if (z_open(&session, z_move(config), NULL) < 0) { fprintf(stderr, "z_open failed\n"); return 3; }
    z_view_keyexpr_t key;
    if (z_view_keyexpr_from_str(&key, argv[1]) < 0) { return 4; }
    for (int i = 0; i < 200; i++) {
        z_owned_bytes_t body;
        if (z_bytes_copy_from_str(&body, argv[3]) < 0) { return 5; }
        if (z_put(z_loan(session), z_loan(key), z_move(body), NULL) < 0) {
            fprintf(stderr, "z_put failed\n"); return 6;
        }
        z_sleep_ms(50);
    }
    z_close(z_loan_mut(session), NULL);
    return 0;
}
C
cc -O2 -I"${prefix}/include" "${work}/c_pub.c" -o "${work}/c_pub" -L"${prefix}/lib" -lzenohc -Wl,-rpath,"${prefix}/lib"
"${work}/c_pub" "${key}" "[\"tcp/127.0.0.1:${port}\"]" "${payload}" & c_pid=$!

set +e
python3 - "${key}" "${port}" "${payload}" <<'PY'
import sys, time
key, port, expected = sys.argv[1], sys.argv[2], sys.argv[3].encode()
import zenoh
cfg = zenoh.Config()
cfg.insert_json5("scouting/multicast/enabled", "false")
cfg.insert_json5("listen/endpoints", f'["tcp/127.0.0.1:{port}"]')
with zenoh.open(cfg) as session:
    got = []
    sub = session.declare_subscriber(key, lambda smp: got.append(smp))
    for _ in range(200):
        if got:
            break
        time.sleep(0.05)
    if not got:
        print("no sample received on the controlled key", file=sys.stderr)
        sys.exit(1)
    payload = got[0].payload.to_bytes()
    if payload != expected:
        print(f"payload mismatch: {payload!r} != {expected!r}", file=sys.stderr)
        sys.exit(2)
print("python side received payload:", payload.decode())
PY
py_rc=$?
wait "${c_pid}"
c_rc=$?
c_pid=""
set -e
[[ ${py_rc} -eq 0 ]] || { echo "python subscriber side failed (rc=${py_rc})" >&2; exit 1; }
[[ ${c_rc} -eq 0 ]] || { echo "C publisher exited ${c_rc}" >&2; exit 1; }
echo 'python<->C interop OK (payload verified on loopback-only session)'
