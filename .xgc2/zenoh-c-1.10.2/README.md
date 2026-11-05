# Zenoh C 1.10.2 opaque helper lock

This is the dependency projection produced from the official main Cargo.lock by
Zenoh C commit 363554eef1a52b1c59a37fc2c8aa87ec1aa8e52e's build chain.
`build.rs::sync_opaque_types_lockfile` copies the main lock into the helper;
`buildrs/opaque_types_generator.rs` then invokes Cargo offline for that helper.
The archive's helper lock therefore is not the post-build lock.

Generated with the existing image's Rust/Cargo 1.93.0, the default C SDK features
plus `shared-memory` and `unstable` (and the helper's `panic` feature). All 452
common package versions, sources (URL encoding normalized) and registry checksums
match the upstream main lock. The projected graph drops main-build-only packages
and adds the local `opaque-types` package. No Zenoh implementation source is changed.

`OPAQUE_UPSTREAM_CARGO_LOCK_SHA256` verifies the original source archive input.
`OPAQUE_CARGO_LOCK_SHA256` verifies this reviewed helper projection before fetch
and the actual helper lock produced by the official build. Main C and daemon
builds retain `--locked --offline`; upstream's nested helper still performs its
own offline projection, and its exact output is checked and retained under the
build output's `build-locks/<architecture>` before any hash failure can clean up.
