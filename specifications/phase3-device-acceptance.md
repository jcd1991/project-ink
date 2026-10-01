# Phase 5 external device-transfer acceptance for Phase 3

This runbook verifies the deferred physical Phase 3 gate during Phase 5
without making a server, account, or cloud service part of the product. Local
Rust/Flutter fixtures and portable fingerprints are development evidence only;
they do not replace these final external runs.

## Prepare one source project

1. On the M1/M4 iPad, create or open the eight-page stick-figure project.
2. Exercise the selected-page preview, edit one dialogue balloon and its tail
   style, change one gutter, make one panel polygonal, and run print preview.
3. Use **Transfer check** and record the 64-character fingerprint. This
   fingerprint covers the canonical structure plus SVG and bounded raster
   projections.
4. Save the `.inkproj` through Files. Keep the original file unchanged.

## Verify each destination

Repeat on the Galaxy S23 Ultra/S Pen, Samsung tablet, M1 Mac, Windows, and
Linux desktop when available:

1. Open a local copy of the same `.inkproj` using the platform picker.
2. Confirm eight pages, page numbers, panel/balloon counts, dialogue text,
   polygon geometry, gutter value, tone/effect counts, and print guides.
3. Run **Transfer check**. The fingerprint must match the source exactly.
4. Export all pages to a new local directory. Compare the page SVG SHA-256
   hashes with the source export; differing hashes are a release blocker.
5. Edit a second dialogue line and save a new copy. Reopen it on the source
   device and confirm the new fingerprint differs while the untouched page
   content remains identical.

## Evidence and limitations

- Record device model, OS version, app build/engine revision, fingerprint,
  export hashes, and a screenshot of the selected-page preview showing the
  stick-figure artwork and edited comic objects.
- Run with networking disabled; no account or telemetry is required.
- macOS Sidecar is useful for a quick pointer-path smoke test, but it does not
  replace direct iPad Apple Pencil acceptance because hover, pressure, tilt,
  and Pencil-specific controls are delivered by the iPad-native adapter.
