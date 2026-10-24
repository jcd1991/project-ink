#!/usr/bin/env python3
"""Validate Ink's crate ownership boundaries using Cargo metadata (stdlib only)."""
import json
import subprocess
import sys

# Explicit edges preserve the owning module boundaries; new crates fail closed.
ALLOWED = {
    "ink-model": set(),
    "ink-command": {"ink-model"},
    "ink-input": {"ink-model"},
    "ink-raster": {"ink-model"},
    "ink-tools": {"ink-model"},
    "ink-vector": {"ink-model"},
    "ink-text": set(),
    "ink-comic": {"ink-text"},
    "ink-brush": {"ink-model", "ink-input", "photocraft-psd"},
    "ink-compositor": {"ink-raster"},
    "ink-export": {"photocraft-psd"},
    "ink-storage": {"ink-comic", "ink-command", "ink-model", "ink-raster"},
    "ink-live-render": set(),
    "photocraft-psd": set(),
    "ink-test-support": {"ink-input"},
    "ink-engine": {
        "ink-comic", "ink-brush", "ink-command", "ink-input", "ink-live-render",
        "ink-model", "ink-raster", "ink-storage", "ink-export", "ink-compositor",
        "ink-tools", "ink-vector",
    },
    "ink_bridge": {
        "ink-command", "ink-comic", "ink-brush", "ink-engine", "ink-export",
        "ink-tools", "ink-model", "ink-raster", "ink-storage", "ink-live-render",
        "ink-vector",
    },
}
UI = {"flutter_rust_bridge", "egui", "eframe", "winit", "rfd"}
GRAPHICS = {"wgpu", "wgpu-hal", "metal", "objc", "objc2"}


def violations(metadata):
    """Return actionable errors, including target-specific and renamed edges."""
    members = set(metadata["workspace_members"])
    packages = [p for p in metadata["packages"] if p["id"] in members]
    names = {p["name"] for p in packages}
    errors = []
    for package in packages:
        name = package["name"]
        if name not in ALLOWED:
            errors.append(f"{name}: unregistered workspace crate")
            continue
        for dep in package["dependencies"]:
            target = dep["name"]  # Cargo's actual package name, not its alias.
            kind = dep.get("kind") or "normal"
            edge = f"{name} -> {target} ({kind}, target={dep.get('target') or 'all'})"
            if target in UI and name != "ink_bridge":
                errors.append(f"{edge}: UI/FRB belongs at the bridge boundary")
            if target in GRAPHICS and name != "ink-live-render":
                errors.append(f"{edge}: graphics handles belong in ink-live-render")
            if target == "ink-test-support" and kind != "dev":
                errors.append(f"{edge}: test support must be a dev-dependency")
            if target in names and kind != "dev" and target not in ALLOWED[name]:
                errors.append(f"{edge}: forbidden ownership dependency")
            if name == "photocraft-psd" and target in names:
                errors.append(f"{edge}: vendored parser must remain standalone")
    return errors


def main():
    result = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--no-deps", "--locked"],
        check=True, capture_output=True, text=True,
    )
    errors = violations(json.loads(result.stdout))
    if errors:
        print("Architecture violations:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print("Architecture boundaries passed (all workspace crates and target edges).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
