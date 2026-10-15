# Document picker seam

`DocumentPicker` is a Flutter-side platform adapter. It selects paths; it
does not read, write, cache, or deserialize Project Ink content.

## Contract

- `openProject()` returns an existing `.inkproj` directory path or `null` when
  the user cancels.
- `saveProject(suggestedName)` returns a new `.inkproj` destination path or
  `null` when cancelled. The adapter may ask for a parent directory and append
  the suggested name when the platform cannot create directory packages in a
  save dialog.
- `exportPng(suggestedName)` returns a writable PNG file path or `null` when
  cancelled.
- User cancellation is not an error. Picker or permission failures propagate
  to the document toolbar, which reports them without changing the engine.
- Paths are passed unchanged to Rust after selection. No path is used as an
  object identity, document ID, or serialized layer identifier.

## Mobile provider bridge

The Flutter channel `org.projectink.studio/provider_documents_v1` exposes
`openProject`, `commitProject`, `preparePngExport`, and `commitPng`. Android launches
`ACTION_OPEN_DOCUMENT_TREE`; iOS/iPadOS launches a folder
`UIDocumentPickerViewController`. The native side copies the selected
`.inkproj` directory into app-owned staging storage and returns its absolute
local path plus a write-back capability, or returns `null` for cancellation.
Copy failures are reported as errors and never replace the current document.

When write-back is supported, Rust first publishes the staged local project.
Only then does native code copy it into a provider temporary directory, rename
the original to a backup, promote the temporary directory, and remove the
backup. A failed promotion attempts to restore the original. Root-folder
selections without parent-directory access remain local-only. When a writable
parent is available, `preparePngExport` returns a bounded app-owned local PNG
path and `commitPng` copies the completed file to a collision-safe sibling of
the selected project. The Rust engine never sees a provider URI, and a failed
PNG promotion leaves the staged local file available for retry.

## Platform responsibilities

Native adapters must preserve local access for the duration of the Rust save
or export call. iOS/iPadOS document-provider URLs may require security-scoped
access; Android document-provider selections may require a private local copy
before a Rust filesystem path is returned. Desktop adapters should use native
open/save dialogs and return ordinary absolute filesystem paths. None of these
adapters may require an account, network service, telemetry, or cloud sync.

`PlatformDocumentPicker` currently uses native directory selection on Android
and native directory/save dialogs on Linux, macOS, and Windows. Android SAF and
iOS/iPadOS Files project-open requests are copied into app-owned staging
directories before the path is returned to Dart. Provider imports and
write-backs are bounded to 100,000 entries and 1 GiB of copied bytes, and
partial staging directories are removed on failure. It accepts a selected path
only when it is an ordinary local filesystem path; unsupported provider
volumes and selector failures fall back to the app-owned Documents/Projects
directory. Root-only imports remain at their local staging path when saved or
exported. Provider PNG promotion is bounded to the same 1 GiB file limit as
project staging and is only attempted after a successful local Rust export.

## Document binding and rejected Open

`DocumentPickerSession.bindProject` is optional synchronous Dart bookkeeping.
The application binds a path only after replacement succeeds, binds a newly
saved destination after Save/Save As succeeds, and releases provider selections
with `bindProject(null)` after New canvas succeeds. A pending Open selection
does not replace the current write-back target. `saveProject` always chooses a
new destination; ordinary Save uses the already bound path. New destinations
must be outside every `.inkproj` or `.inkproj.bak` ancestor.

Android and iOS retain imported source metadata keyed by canonical staged path
for the runner session. No security-scoped access is held open between calls.
This allows Save of the current project after another staged candidate fails
Rust validation. Existing copy budgets and transactional promotion apply.

`preparePngExport` now accepts `localProjectPath`, identifying the bound staged
project. A null/unknown path offers no provider export destination. The Dart
adapter skips provider export for a new/local canvas. Bundled native runners and
Dart must be updated together; the channel name and existing method names stay
unchanged. The supplied path never authorizes a new source: it must match an
import recorded by this runner. Physical provider acceptance remains separate
from mocked channel and widget tests.

## Local recent-project index

The app keeps a device-local most-recently-used list of at most 20 absolute
local project-directory paths in shared preferences, with a display name and
last-used timestamp for each entry. It stores filesystem paths only: provider
URIs and paths under the operating-system temporary directory
are rejected, and provider-backed staging paths are not added while the picker
reports an active provider project. A path is added only after a successful
open or save. The index is local navigation state; it does not add project
contents, recovery state, or cloud data to preferences.

Opening a recent entry uses the ordinary document replacement confirmation
and barrier. Availability is checked when the chooser opens. Missing entries
remain visible as unavailable until the user removes them, so a temporarily
disconnected drive can be reconnected without losing the saved shortcut.
