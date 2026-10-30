#!/usr/bin/env python3
"""Create and verify XGC2 trusted build artifact manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


BUILD_SCHEMA = "xgc2.build-artifact.v1"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def deb_metadata(path: Path) -> dict[str, Any]:
    output = [
        subprocess.check_output(["dpkg-deb", "-f", str(path), field], text=True).strip()
        for field in ("Package", "Version", "Architecture")
    ]
    if len(output) != 3 or not all(output):
        raise ValueError(f"cannot read package metadata from {path}")
    return {
        "package": output[0],
        "version": output[1],
        "architecture": output[2],
        "filename": path.name,
        "sha256": sha256(path),
        "size_bytes": path.stat().st_size,
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_deb(path: Path, declared: dict[str, Any]) -> None:
    actual = deb_metadata(path)
    key_map = {"file": "filename", "size": "size_bytes"}
    for key in ("file", "package", "version", "architecture", "sha256", "size"):
        actual_key = key_map.get(key, key)
        if declared.get(key) != actual[actual_key]:
            raise ValueError(f"{path}: debs[].{key} mismatch")


def find_deb(root: Path, filename: str, *, near: Path | None = None) -> Path:
    if not filename or Path(filename).name != filename:
        raise ValueError(f"unsafe deb filename: {filename!r}")
    root = root.resolve()
    if near is not None:
        scope = near.resolve().parent
        while scope == root or root in scope.parents:
            matches = sorted(path for path in scope.rglob(filename) if path.is_file())
            if len(matches) == 1:
                return matches[0]
            if len(matches) > 1:
                raise ValueError(f"expected one {filename} below {scope}, found {len(matches)}")
            if scope == root:
                break
            scope = scope.parent
    matches = sorted(path for path in root.rglob(filename) if path.is_file())
    if len(matches) != 1:
        raise ValueError(f"expected one {filename} below {root}, found {len(matches)}")
    return matches[0]


def local_product_version() -> str:
    text = Path(".xgc2/product.yml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s#]+)", text, re.MULTILINE)
    if not match:
        raise ValueError("cannot read version from .xgc2/product.yml")
    return match.group(1)


def create_build(args: argparse.Namespace) -> None:
    debs = sorted(Path(args.deb_dir).rglob("*.deb"))
    if not debs:
        raise ValueError(f"no debs found below {args.deb_dir}")
    output = Path(args.output_dir)
    entries = []
    for deb in debs:
        meta = deb_metadata(deb)
        if meta["architecture"] not in (args.architecture, "all"):
            raise ValueError(f"{deb}: architecture is not compatible with {args.architecture}")
        entries.append(
            {
                "file": meta["filename"],
                "package": meta["package"],
                "version": meta["version"],
                "architecture": meta["architecture"],
                "sha256": meta["sha256"],
                "size": meta["size_bytes"],
            }
        )
    payload = {
        "schema": BUILD_SCHEMA,
        "product": args.product,
        "source_sha": args.source_sha,
        "version": args.product_version,
        "distribution": args.distribution,
        "architecture": args.architecture,
        "ci": {
            "run_id": str(args.ci_run_id),
            "workflow": args.ci_workflow,
            "workflow_ref": args.ci_workflow_ref,
        },
        "created_at": utc_now(),
        "debs": entries,
    }
    name = f"{args.product}_{args.distribution}_{args.architecture}.build.json"
    write_json(output / name, payload)


def verify_build(args: argparse.Namespace) -> None:
    root = Path(args.artifact_dir)
    expected_version = args.product_version or local_product_version()
    candidates: list[tuple[Path, dict[str, Any], Path]] = []
    for manifest_path in sorted(root.rglob("*.json")):
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if manifest.get("schema") != BUILD_SCHEMA:
            continue
        if manifest.get("product") != args.product:
            continue
        if manifest.get("version") != expected_version:
            continue
        if manifest.get("distribution") != args.distribution:
            continue
        if manifest.get("source_sha") != args.source_sha:
            continue
        ci = manifest.get("ci")
        if not isinstance(ci, dict) or not all(ci.get(key) for key in ("run_id", "workflow", "workflow_ref")):
            continue
        if args.ci_run_id and str(ci.get("run_id")) != str(args.ci_run_id):
            continue
        if args.architecture and manifest.get("architecture") != args.architecture:
            continue
        deb_entries = manifest.get("debs")
        if not isinstance(deb_entries, list) or not deb_entries:
            raise ValueError(f"{manifest_path}: debs must be a non-empty list")
        for declared in deb_entries:
            deb = find_deb(root, str(declared.get("file", "")), near=manifest_path)
            validate_deb(deb, declared)
            candidates.append((manifest_path, manifest, deb))
    if not candidates:
        raise ValueError("trusted run has no matching, valid build manifest")

    deb_output = Path(args.deb_output_dir)
    manifest_output = Path(args.manifest_output_dir)
    deb_output.mkdir(parents=True, exist_ok=True)
    manifest_output.mkdir(parents=True, exist_ok=True)
    copied_manifests: set[Path] = set()
    for manifest_path, _manifest, deb in candidates:
        shutil.copy2(deb, deb_output / deb.name)
        if manifest_path not in copied_manifests:
            shutil.copy2(manifest_path, manifest_output / manifest_path.name)
            copied_manifests.add(manifest_path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--deb-dir", required=True)
    build.add_argument("--output-dir", required=True)
    build.add_argument("--product", required=True)
    build.add_argument("--product-version", required=True)
    build.add_argument("--distribution", required=True)
    build.add_argument("--architecture", required=True)
    build.add_argument("--source-sha", required=True)
    build.add_argument("--ci-run-id", required=True)
    build.add_argument("--ci-workflow", required=True)
    build.add_argument("--ci-workflow-ref", required=True)
    build.set_defaults(func=create_build)

    verify = sub.add_parser("verify-build")
    verify.add_argument("--artifact-dir", required=True)
    verify.add_argument("--deb-output-dir", required=True)
    verify.add_argument("--manifest-output-dir", required=True)
    verify.add_argument("--product", required=True)
    verify.add_argument("--product-version")
    verify.add_argument("--distribution", required=True)
    verify.add_argument("--architecture")
    verify.add_argument("--source-sha", required=True)
    verify.add_argument("--ci-run-id")
    verify.set_defaults(func=verify_build)

    return result


def main() -> int:
    args = parser().parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
