#!/usr/bin/env bash
# Native pub/sub round trip against an INSTALLED zenoh prefix (same architecture).
# Fails if the library does not load, does not link, or the payload round trip is lost.
# The C below follows the zenoh-c 1.8 API: the subscriber callback is
# (z_loaned_sample_t *, void *) and every owned value is moved with z_move().
set -euo pipefail
prefix="${1:?usage: smoke_pubsub.sh PREFIX}"
prefix="$(cd "${prefix}" && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/zenoh-smoke.XXXXXX")"; trap 'rm -rf -- "${work}"' EXIT
cat > "${work}/smoke.c" <<'C'
#include <zenoh.h>
#include <stdio.h>
#include <string.h>

static volatile int got = 0;
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
    got = 1;
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

    for (int i = 0; i < 100 && !got; i++) { z_sleep_ms(50); }
    z_drop(z_move(sub));
    z_close(z_loan_mut(session), NULL);
    if (!got) { fprintf(stderr, "pub/sub round trip lost\n"); return 7; }
    if (strcmp(received, "probe") != 0) { fprintf(stderr, "payload mismatch: '%s'\n", received); return 8; }
    puts("zenoh native pub/sub OK (payload verified)");
    return 0;
}
C
cc -O2 -I"${prefix}/include" "${work}/smoke.c" -o "${work}/smoke" -L"${prefix}/lib" -lzenohc -Wl,-rpath,"${prefix}/lib"
"${work}/smoke"
