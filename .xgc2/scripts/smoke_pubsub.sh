#!/usr/bin/env bash
# Installed-artifact smoke: exercise the REAL consumer path — find_package(zenohc)
# and find_package(zenohcxx) resolved through the deb's /usr/lib/cmake exposure,
# link against the imported targets (no -I/-L bypass), then run a pub/sub round
# trip and a zenoh.hxx session open. usage: smoke_pubsub.sh PREFIX
set -euo pipefail
prefix="${1:?usage: smoke_pubsub.sh PREFIX}"
prefix="$(cd "${prefix}" && pwd -P)"
[[ -f "${prefix}/lib/libzenohc.so" ]] || { echo "no installed libzenohc.so under ${prefix}" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/zenoh-smoke.XXXXXX")"; trap 'rm -rf -- "${work}"' EXIT

cat > "${work}/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(zenoh_installed_smoke C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Resolved only through the deb's /usr/lib/cmake forwarding stubs: this is the
# consumer contract, so the gate must prove configure + link, not raw -I/-L.
find_package(zenohc 1.8.0 EXACT CONFIG REQUIRED)
find_package(zenohcxx 1.8.0 EXACT CONFIG REQUIRED)
add_executable(zenoh_smoke smoke.c)
target_link_libraries(zenoh_smoke PRIVATE zenohc::lib)
add_executable(zenoh_static_smoke smoke.c)
target_link_libraries(zenoh_static_smoke PRIVATE zenohc::static)
add_executable(zenohcxx_smoke smoke.cxx)
target_link_libraries(zenohcxx_smoke PRIVATE zenohcxx::zenohc)
CMAKE

cat > "${work}/smoke.c" <<'C'
#include <zenoh.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static atomic_int got = 0;
static char received[64];

static void on_sample(z_loaned_sample_t *sample, void *context) {
    (void)context;
    z_owned_string_t text;
    if (z_bytes_to_string(z_sample_payload(sample), &text) != Z_OK) { return; }
    size_t len = z_string_len(z_loan(text));
    if (len < sizeof received) {
        memcpy(received, z_string_data(z_loan(text)), len);
        received[len] = '\0';
    }
    z_drop(z_move(text));
    atomic_store_explicit(&got, 1, memory_order_release);
}

int main(void) {
    z_owned_config_t config;
    z_config_default(&config);
    z_owned_session_t session;
    if (z_open(&session, z_move(config), NULL) < 0) { fprintf(stderr, "z_open failed\n"); return 2; }

    z_view_keyexpr_t key;
    if (z_view_keyexpr_from_str(&key, "xgc2/zenoh/ci") < 0) { return 3; }

    z_owned_closure_sample_t callback;
    z_closure(&callback, on_sample, NULL, NULL);
    z_owned_subscriber_t sub;
    if (z_declare_subscriber(z_loan(session), &sub, z_loan(key), z_move(callback), NULL) < 0) {
        fprintf(stderr, "z_declare_subscriber failed\n"); return 4;
    }

    z_owned_bytes_t payload;
    if (z_bytes_from_static_str(&payload, "probe") < 0) { return 5; }
    if (z_put(z_loan(session), z_loan(key), z_move(payload), NULL) < 0) {
        fprintf(stderr, "z_put failed\n"); return 6;
    }

    for (int i = 0; i < 100 && !atomic_load_explicit(&got, memory_order_acquire); i++) { z_sleep_ms(50); }
    z_drop(z_move(sub));
    z_close(z_loan_mut(session), NULL);
    if (!got) { fprintf(stderr, "pub/sub round trip lost\n"); return 7; }
    if (strcmp(received, "probe") != 0) { fprintf(stderr, "payload mismatch: '%s'\n", received); return 8; }
    puts("zenoh native pub/sub OK (payload verified)");
    return 0;
}
C

cat > "${work}/smoke.cxx" <<'CXX'
// zenoh.hxx consumer check: the zenohcxx::zenohc target must supply include
// dirs, the ZENOHCXX_ZENOHC define, and the zenohc::lib link transitively.
#include <zenoh.hxx>
int main(void) {
    zenoh::ZResult err = -1;
    zenoh::Config config = zenoh::Config::create_default();
    zenoh::Session session = zenoh::Session::open(std::move(config),
                                                  zenoh::Session::SessionOptions::create_default(), &err);
    if (err != Z_OK) { return 1; }
    return 0;
}
CXX

cmake -S "${work}" -B "${work}/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "${work}/build" --parallel
"${work}/build/zenoh_smoke"
"${work}/build/zenoh_static_smoke"
"${work}/build/zenohcxx_smoke" || { echo "zenohcxx session open failed" >&2; exit 1; }
echo "zenoh cxx include/link/session OK"
