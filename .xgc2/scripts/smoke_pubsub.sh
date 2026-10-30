#!/usr/bin/env bash
# Native pub/sub round trip against an INSTALLED zenoh prefix (same architecture).
# Fails if the library does not load, does not link, or the round trip is lost.
set -euo pipefail
prefix="${1:?usage: smoke_pubsub.sh PREFIX}"
prefix="$(cd "${prefix}" && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/zenoh-smoke.XXXXXX")"; trap 'rm -rf -- "${work}"' EXIT
cat > "${work}/smoke.c" <<'C'
#include <zenoh.h>
#include <stdio.h>
#include <string.h>
static volatile int got = 0;
static void on_sample(z_owned_sample_t *s) { (void)s; got = 1; }
int main(void) {
    z_owned_config_t cfg; z_config_default(&cfg);
    z_owned_session_t s; if (z_open(&s, z_move(cfg), NULL) < 0) { fprintf(stderr, "open failed\n"); return 2; }
    z_view_keyexpr_t ke; if (z_view_keyexpr_from_str(&ke, "xgc2/zenoh/ci") < 0) return 3;
    z_owned_closure_sample_t cb; z_closure(&cb, on_sample, NULL, NULL);
    z_owned_subscriber_t sub;
    if (z_declare_subscriber(z_loan(s), &sub, z_loan(ke), z_move(cb), NULL) < 0) { fprintf(stderr, "declare failed\n"); return 4; }
    if (z_put(z_loan(s), z_loan(ke), z_owned_bytes_t(), NULL) < 0) { /* put below uses bytes api */ }
    z_owned_bytes_t payload; z_bytes_from_static_str(&payload, "probe");
    if (z_put(z_loan(s), z_loan(ke), z_move(payload), NULL) < 0) { fprintf(stderr, "put failed\n"); return 5; }
    for (int i = 0; i < 100 && !got; i++) z_sleep_ms(50);
    z_drop(z_move(sub)); z_close(z_move(s));
    if (!got) { fprintf(stderr, "pub/sub round trip lost\n"); return 6; }
    puts("zenoh native pub/sub OK"); return 0;
}
C
cc -O2 -I"${prefix}/include" "${work}/smoke.c" -o "${work}/smoke" -L"${prefix}/lib" -lzenohc -Wl,-rpath,"${prefix}/lib"
"${work}/smoke"
