# Project Ink 0.1.0 — experimental alpha

Local draft for a GitHub prerelease. No release has been published and no
download has been cleared for distribution yet. Rebuilt packages include the
layer layout, nested-save guard and provider destination lifecycle fixes. See the
[candidate evidence](alpha-candidate-verification.md) before attaching binaries.

Project Ink is a local-first illustration app: create a canvas, draw with
built-in brushes, edit layers, undo/redo, save a named `.inkproj` project, reopen
it and export PNG. No account or network service is required for drawing.
Comic pages, panels and linked dialogue are experimental; SVG is the complete
comic export. Batch comic PNG currently includes artwork only.

## Candidate platforms

| Candidate | Build/signing | Current acceptance |
|---|---|---|
| macOS universal ZIP (arm64 + x86_64) | Ad hoc signature; not Developer ID signed or notarized | Apple silicon/macOS 27: draw → save → quit → reopen → export passed; PNG matches saved pixels exactly. Gatekeeper assessment rejects the ad hoc build; exception workflow and Intel interaction remain unverified. |
| Android arm64 APK | Dedicated alpha certificate; signature and alignment verified | Installed on S23 Ultra/Android 16; real long strokes and force-stop recovery observed, named reopen confirmed by user, new-drawing PNG decoded at 2048×2048 with transparency. Latest fixes rebuilt and installed as a data-preserving update; pressure/workspace/final provider matrix and historical loss explanation remain open. Do not attach this APK yet. |
| iOS/iPadOS | No candidate included | Debug/no-codesign compilation passed; physical acceptance and distribution provisioning pending. |

## Install and verify

Download `SHA256SUMS`, `BUILD-INFO.txt`, the desired artifact and, for Android,
`ANDROID-SIGNING.txt` into one directory. On macOS, run:

```sh
shasum -a 256 -c SHA256SUMS
```

On Linux use `sha256sum -c SHA256SUMS`. Every listed file must be present and
report OK. Checksums detect changed downloads; trust the release source too.

macOS: extract the ZIP and open `project_ink.app`. This candidate is not
notarized; downloaded installation can be blocked by Gatekeeper. A normal
user-approved installation procedure still needs verification before offering
the ZIP. Do not disable Gatekeeper system-wide. Local extraction/launch does
not establish downloaded installation acceptance.

Android: once cleared, install the APK using the device's package installer or
`adb install -r project-ink-0.1.0-android-arm64.apk`. The alpha key differs from
earlier debug builds, so those installs cannot be updated in place. Export or
back up their artwork before removing them; uninstalling clears app-local
recovery. Retain the alpha signing key for future compatible updates.

## First artist check

1. Make a disposable canvas. Paint on the layer labeled **Active** with two
   brush families, different colors and sizes, then erase, pan and zoom.
2. Add/select a layer, draw, hide/show it, and undo/redo.
3. Save a named project into a folder you can find. Quit, relaunch and explicitly
   reopen that project. Confirm the layer contents and export a PNG.
4. Check image dimensions and transparent/opaque background against the canvas.
   For comics, create a page, panel and dialogue and inspect the SVG export.

Keep copies of valuable artwork during alpha testing. Named projects use the
folder selected through the native picker; preserve the complete `.inkproj`
package/directory, not just its manifest. App-local recovery is a separate
last-session checkpoint and is not a substitute for named saves. On macOS,
opening can request the containing folder to permit safe sibling writes.

## Known limitations

- A blank startup canvas may show an unsaved-change prompt during Open.
- Advanced layer/mask/clipping combinations have engine regression coverage;
  combined physical acceptance is incomplete.
- Android's earlier missing sketch/empty History cause remains unproven.
  Later long-stroke recovery and named reopen succeeded; the changed marks in
  the export were an intentional new drawing. Light/firm S Pen pressure and
  the combined workspace/History path need final-candidate confirmation.
- Comic typography, flattened lettered PNG/PDF and print production are limited.
- Brush interchange, file-provider behavior, maximum document sizes and device
  performance are not comprehensively certified.
- Pencil, Intel Mac and additional Android hardware are unverified for these
  candidates. Broad Clip Studio/Procreate/ibisPaint parity is outside this alpha.

## Feedback

When a repository is configured, use its Issues tab and the prepared bug or
artist-workflow templates. Include version/artifact name, OS/device/input,
steps, Active layer, expected/actual results and whether a named save or recovery
was involved. Private artwork and raw diagnostic traces are not required.
Security reports need a verified private route; see [SECURITY.md](../SECURITY.md).
Issue and private security URLs must be filled and verified before publication.
