<p align="center">
  <img src="assets/branding/project-ink-logo.png" alt="Project Ink inkwell mark" width="176">
</p>

<h1 align="center">Project Ink</h1>

<p align="center">
  <strong>An opinionated, easy-to-use, mobile-friendly illustration app.</strong><br>
  Built on Rust. Open source. Made for drawing wherever you are.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MPL-2.0 license" src="https://img.shields.io/badge/license-MPL--2.0-2a7f62?style=flat-square"></a>
  <img alt="Experimental" src="https://img.shields.io/badge/status-experimental-c88624?style=flat-square">
  <img alt="Rust core" src="https://img.shields.io/badge/core-Rust-b7410e?style=flat-square&logo=rust&logoColor=white">
  <img alt="Flutter app" src="https://img.shields.io/badge/app-Flutter-168de2?style=flat-square&logo=flutter&logoColor=white">
</p>

<p align="center">
  <a href="#what-makes-project-ink-different">Why Ink</a> ·
  <a href="#where-the-project-is">Project status</a> ·
  <a href="#run-it-locally">Build</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

Project Ink is a local-first illustration and comic studio for touchscreens,
pen displays, and desktop. Flutter shapes the workspace; a Rust engine owns
the artwork and project data. The goal is a capable drawing app that feels
approachable on mobile and stays under the artist’s control.

## What makes Project Ink different

- **Mobile-friendly by design.** The interface adapts across phones, tablets,
  and desktop, with touch, stylus, and keyboard workflows.
- **Rust at the center.** Documents, pixels, layers, history, persistence, and
  export have one authoritative Rust owner.
- **Local first.** Work offline without an account, ads, or a required cloud
  service. Native `.inkproj` files keep projects portable, with local recovery
  support.
- **One creative workspace.** Illustration tools and comic-oriented page and
  panel workflows live in the same app.

## Where the project is

Project Ink is experimental and changing quickly. iOS/iPadOS, Android, macOS,
Windows, and Linux are development targets; that list is not a claim of stable
or release-supported builds. Platform downloads and support claims depend on
separate install, input, file, recovery, and export acceptance.

For the current candidate and release gates, see the
[alpha checklist](specifications/alpha-release-checklist.md),
[candidate verification notes](specifications/alpha-candidate-verification.md),
and [release readiness](specifications/release-readiness.md).
The [first-release scope](specifications/first-release-scope.md) describes the
intended artist workflows and current non-goals.

## Run it locally

Use the pinned Flutter 3.47.5 toolchain and a Rust toolchain:

```sh
cd app
flutter pub get
flutter run -d macos
```

For other targets, platform setup, Rust bridge details, and validation
commands, start with the [app development guide](app/README.md). The project
keeps its public formats and platform workflows documented under
[`specifications/`](specifications/).

## Open source

Project Ink is licensed under the [Mozilla Public License 2.0](LICENSE).
Contributions are welcome; please read [CONTRIBUTING.md](CONTRIBUTING.md).
Report security issues using [SECURITY.md](SECURITY.md). Some bundled assets may
have separate terms, so check their accompanying notices before reusing them.
