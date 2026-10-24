<p align="center">
  <img src="assets/branding/project-ink-logo.png" alt="Project Ink inkwell mark" width="160">
</p>

<h1 align="center">Project Ink</h1>

<p align="center">
  <strong>Make art. Keep it yours.</strong><br>
  An open-source, mobile-friendly illustration and comic studio for touch,<br>
  stylus, and desktop.<br>
  Built with Rust. Shaped with Flutter. Local-first by design.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MPL-2.0 license" src="https://img.shields.io/badge/license-MPL--2.0-2a7f62?style=flat-square"></a>
  <img alt="Experimental" src="https://img.shields.io/badge/status-experimental-c88624?style=flat-square">
  <img alt="Rust core" src="https://img.shields.io/badge/core-Rust-b7410e?style=flat-square&logo=rust&logoColor=white">
  <img alt="Flutter app" src="https://img.shields.io/badge/app-Flutter-168de2?style=flat-square&logo=flutter&logoColor=white">
</p>

<p align="center">
  <a href="#try-it">Build from source</a> ·
  <a href="#where-ink-is-now">Alpha status</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

Project Ink is a local-first drawing studio for people who want a real canvas
on the device in their hand—and room to grow into a bigger workspace. Sketch,
paint, work in layers, build comic pages, and save portable projects without
needing an account or a cloud connection.

## From first stroke to finished page

- **Draw your way.** Work with pressure-aware brushes, smoothing, stabilization,
  touch, stylus, and keyboard workflows.
- **Build with layers.** Organize artwork with layers, groups, masks, selection,
  transform, fill, and vector tools.
- **Make comics, too.** Create multi-page projects with panels and lettering in
  the same workspace.
- **Keep control of your work.** Projects use the native `.inkproj` format, with
  local recovery support and no required account, ads, or online service.

Rust owns document state, pixels, layers, history, persistence, and export.
Flutter shapes the responsive interface and handles presentation and input.

## Where Ink is now

Project Ink is **experimental** and changing quickly. iOS/iPadOS, Android,
macOS, Windows, and Linux are development targets—not promises of stable,
release-supported downloads. Platform support is earned separately through
install, input, file, recovery, and export checks.

For current candidates and release gates, see the
[alpha checklist](specifications/alpha-release-checklist.md),
[candidate verification notes](specifications/alpha-candidate-verification.md),
and [release readiness](specifications/release-readiness.md). The
[first-release scope](specifications/first-release-scope.md) describes the
intended workflows and non-goals.

## Try it

You’ll need the pinned Flutter 3.47.5 toolchain and a Rust toolchain. To run the
macOS app locally:

```sh
cd app
flutter pub get
flutter run -d macos
```

For platform setup, Rust bridge details, and validation commands, start with
the [app development guide](app/README.md). More architecture and file-format
notes live in [`specifications/`](specifications/).

## Open source, open canvas

Project Ink is licensed under the [Mozilla Public License 2.0](LICENSE).
Contributions are welcome—start with [CONTRIBUTING.md](CONTRIBUTING.md). Found
a security issue? Follow [SECURITY.md](SECURITY.md). Some bundled assets have
separate terms; check their accompanying notices before reuse.

<p align="center"><em>Your next sketch could help shape what comes next.</em></p>
