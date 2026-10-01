# Flutter shell

The shell is intentionally thin: it owns responsive controls, viewport
transforms, gesture arbitration, accessibility, and visible tile composition.
The generated `flutter_rust_bridge` v2 bindings and Cargokit plugin provide the
production Rust adapter in `lib/bridge/engine_api.dart`; the in-memory adapter
is retained for isolated widget tests and shell seams. The production
`ProjectInkApp` never substitutes it: a Rust startup failure is shown to the
user instead of silently changing document authority.
Dirty tiles arrive through a fixed-width binary FRB packet, are decoded off the
paint path, and are composed into the transformed document canvas with
revision-aware caching.
On iOS/iPadOS, Android, and macOS, stylus-only native adapters publish packet v1
over `org.projectink.studio/pointer_packets_v1`; Dart transforms those
coordinates and routes them through the same Rust engine API.
The iOS, macOS, and Android adapter seams encode pointer packet v1 in
little-endian binary form. Keep the Rust engine as the only document/pixel
authority.

The Dart engine contract exposes native `.inkproj` open through
`FrbEngineApi.open(path)`, atomic save-as through `saveAs(path)`, and PNG
export through `exportPng(path)`. File-picker UI is intentionally kept outside
the engine adapter so each platform can select a directory-backed project
without duplicating document state.

`AutosaveCoordinator` is the local checkpoint seam for an open path. It
coalesces pointer/command mutations and defers checkpoints while a continuous
edit such as a stroke is active, avoiding a Rust bridge save during incoming
pointer packets. It resumes checkpoint scheduling when the last edit ends;
an explicit flush waits for active edits and never overlaps Rust saves. A save
error keeps the revision dirty so a later explicit flush can retry. The
production entry point always provides an app-owned recovery path under
`Project Ink/Recovery/` and reopens
that checkpoint on the next launch; an explicit Save still writes the named
portable project selected by the user. Embedders can pass a different
`autosavePath` to `ProjectInkApp` when they own the document session.

`DocumentPicker` is the platform seam for directory-backed project selection.
When supplied to `ProjectInkApp`, it enables Open, Save, and Export PNG toolbar
actions; the picker implementation owns platform storage and dialog behavior.
`PlatformDocumentPicker` is native-first: desktop uses native directory/save
dialogs, Android uses the native directory provider when it can return a local
path, and Android SAF/iOS Files project-open selections are staged into
app-owned storage before Rust opens them. Project saves use a transactional
provider replacement when a writable parent was granted, and completed PNG
exports use a bounded, collision-safe provider promotion under the same
capability. Changing picker UI will not change the Rust path contract.
On Android and iOS, new saves ask for a project name before the
directory-backed path is created; imported provider projects bypass that
prompt and retain their source name.

For local physical-device acceptance runs, pass a callback to
`ProjectInkApp.onPerformanceSnapshot`. It receives a bounded p95 trace from
normalized packet receipt to the post-frame callback, along with dirty-tile and
tile-update timings. To persist those snapshots for later review, also pass a
local `ProjectInkApp.performanceTracePath`; the app writes newline-delimited
JSON asynchronously and performs no network reporting.

The production entry point has an opt-in convenience path for device runs:
`flutter run -d DEVICE_ID --dart-define=PROJECT_INK_TRACE=true`. It stores a
timestamped JSONL file under the app Documents `phase1-traces/` directory.
Normal builds keep this disabled and do not create trace files.

Run from this directory:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```
