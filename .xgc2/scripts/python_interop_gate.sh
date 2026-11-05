#!/usr/bin/env bash
# Exercise real Python and C++ peers through the installed UDP Zenoh router.
# PYO3_PYTHON may select an existing private interpreter instead of python3.
# usage: python_interop_gate.sh --prefix PREFIX [--python X]
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix=""; py=""
while (( $# )); do case "$1" in --prefix) prefix="$2"; shift 2;; --python) py="$2"; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
[[ -n "${prefix}" ]] || { echo 'usage: python_interop_gate.sh --prefix PREFIX [--python X]' >&2; exit 2; }
prefix="$(cd "${prefix}" && pwd -P)"
python_bin="$(command -v "${PYO3_PYTHON:-python3}")"
if [[ -n "${py}" ]]; then
  runtime="$("${python_bin}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  [[ "${runtime}" == "${py}" ]] || { echo "interop needs python${py}, found ${runtime}" >&2; exit 1; }
fi
[[ -x "${prefix}/bin/zenohd" && -f "${prefix}/lib/libzenohc.so" ]] || {
  echo "missing installed zenohd or C SDK under ${prefix}" >&2; exit 1; }

work="$(mktemp -d)"; router_pid=""
cleanup() {
  if [[ -n "${router_pid}" ]]; then kill -TERM "${router_pid}" 2>/dev/null || true; wait "${router_pid}" 2>/dev/null || true; fi
  rm -rf -- "${work}"
}
trap cleanup EXIT

port="$("${python_bin}" -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
endpoint="udp/127.0.0.1:${port}?rel=1;mixed_rel=1;multistream=1"
key="xgc2/zenoh/python-interop/ci-$(date +%s%N)-$$"
"${python_bin}" - "${endpoint}" > "${work}/router.json" <<'PY'
import json, sys
json.dump({"mode": "router", "listen": {"endpoints": [sys.argv[1]], "exit_on_failure": True},
           "connect": {"endpoints": []},
           "scouting": {"multicast": {"enabled": False}, "gossip": {"enabled": False}}}, sys.stdout)
PY
c++ -std=c++17 -O2 -DZENOHCXX_ZENOHC -I"${prefix}/include" "${script_dir}/python_interop_peer.cpp" \
  -L"${prefix}/lib" -lzenohc -Wl,-rpath,"${prefix}/lib" -o "${work}/cpp-peer"
NO_COLOR=1 RUST_LOG='zenoh_transport::unicast::universal=trace,quinn_proto::connection=trace' \
  "${prefix}/bin/zenohd" -c "${work}/router.json" >"${work}/router.log" 2>&1 &
router_pid=$!

# Wait only for this router's local UDP listener; actual connectivity and
# declaration readiness are exercised by the two SDK clients below.
"${python_bin}" - "${port}" "${router_pid}" <<'PY'
import os, sys, time
port, pid = int(sys.argv[1]), int(sys.argv[2])
end = time.monotonic() + 5
while time.monotonic() < end:
    os.kill(pid, 0)
    with open('/proc/net/udp') as f:
        if any(line.split()[1] == '0100007F:{:04X}'.format(port) for line in list(f)[1:]):
            break
    time.sleep(0.01)
else:
    raise SystemExit('isolated zenohd UDP listener did not start')
PY

set +e
NO_COLOR=1 RUST_LOG='zenoh_transport::unicast::universal=trace,quinn_proto::connection=trace' \
  timeout 40 "${python_bin}" "${script_dir}/python_interop_peer.py" "${work}/cpp-peer" "${endpoint}" "${key}" >"${work}/peers.log" 2>&1
status=$?
set -e
if [[ ${status} != 0 ]]; then
  cat "${work}/peers.log" "${work}/router.log" >&2
  echo "Python/C++ interop failed (exit ${status})" >&2
  exit "${status}"
fi

# Link presence alone is not proof of the selected wire semantics. Show actual
# stream declaration and DATAGRAM traces alongside the payload assertions.
for pattern in 'DeclareSubscriber' 'STREAM id=client bidirectional' 'DATAGRAM len=' 'got datagram frame'; do
  if ! grep -Fq "${pattern}" "${work}/peers.log"; then
    cat "${work}/peers.log" >&2
    echo "missing mixed-reliability trace: ${pattern}" >&2
    exit 1
  fi
done
grep -E '^(python:|cpp:)' "${work}/peers.log"
for pattern in 'DeclareSubscriber' 'STREAM id=client bidirectional' 'DATAGRAM len=' 'got datagram frame'; do
  grep -Fm 1 "${pattern}" "${work}/peers.log"
done
echo 'Python <-> C++ UDP mixed interop OK'
