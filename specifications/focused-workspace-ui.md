# Focused workspace UI: Simple and Studio

Status: The cross-platform mode and responsive-layout standardization was
implemented on 2026-10-07. Current worktree verification passes `flutter
analyze`, all 659 Flutter tests, the Rust workspace tests, and workspace
Clippy. The current Android arm64 profile build also passes and produces
`app/build/app/outputs/flutter-apk/app-profile.apk` (68.4 MB); Gradle warns that
the app selects NDK 27.1 while several plugins request NDK 28.2. An earlier
macOS debug build passed on 2026-10-07, but the current worktree was not rebuilt
for macOS or iOS: only 1.7 GiB was free, below the macOS runner's 6 GiB build
preflight. The APK was installed and touch-checked on a Samsung phone for mode
switching, Color/Layers access, and the Studio Tool Properties and Materials
sheets. During that device session, the previously visible sketch was no
longer shown; the active History sheet reported “No edits yet,” and an app
restart did not restore the sketch. No save was issued, so the device document
state remains unresolved. This does not record macOS interactive or
stylus-performance acceptance.

## Goal and design decisions

Keep Simple focused on drawing essentials and Studio focused on advanced
editing on every platform. Simple/Studio is an editor preference, not a device
class. Preserve the location and meaning of the drawing controls while changing
modes: active color, brush size, brush opacity, undo, redo, and brush selection.
Studio may add palettes and workspace controls, but switching modes must not
hide the active color or basic brush adjustments.

Keep three choices separate: editor mode (Simple/Studio), responsive canvas
layout (phone, touch workspace, or desktop), and workspace layout preset
(Illustration, Comic, Minimal, or custom). Canvas Focus remains a temporary
presentation state. A narrow viewport changes control placement; it does not
silently change the selected editor mode or workspace preset. Simple/Studio
controls phone, tablet, and narrow-web touch layouts. Wide desktop keeps its
professional shell and docks independently of the touch editor preference.

At phone widths, both modes use the same compact bottom drawing controls and
top-bar mode selector. Studio exposes its additional destinations through the
More menu and phone sheets; it does not place tablet rails over the drawing
area. At tablet and narrow-web widths, the shared drawing controls stay on the
same handedness-aware edge in both modes, with Studio palette navigation on
the opposite edge. Wide desktop keeps the established desktop docks and
command bar regardless of the saved touch editor preference.

Use one visible Color entry point on tablet. It displays the active main color
and opens one color surface containing main color, sub color, transparent
drawing, Swap, and Reset. Main and sub colors remain distinct roles. The
transparent role keeps the current brush and its settings; the Eraser tool stays
a separate tool choice. Do not render more than one persistent Color button for
the same action in a mode, even when that action is present in a customizable
command bar.

The selected foreground color is shared across brushes. Color controls update
that shared color without overwriting a brush preset's base color or dynamic
color settings.

Keep brush size and opacity available beside the drawing controls in both
modes. Show the selected value and units. Use direct sliders when there is
room; when height or text scaling makes them cramped, use labeled value buttons
that open one precise slider. Keep brush presets and advanced brush editing in
the Brush Library.

Use the same mode and workspace concepts on phone, tablet, and narrow web
layouts. Keep the selected workspace layout inside a labeled Workspace layout
section in More, separate from the Simple/Studio editor-mode selector:

```text
Simple top bar: [Document/status] [Save] [Undo] [Redo] [Focus] [Simple | Studio] [More]
Studio top bar: [Document/status] [Save] [Undo] [Redo] [Focus] [Simple | Studio] [More]
Drawing controls: [Tool] [Brush] [Eraser] [Color chip] [Size] [Opacity]
Studio palettes: [Tools] [Brushes] [Properties] [Color] [Layers] [Materials]
                [Comics] [History] [Quick Access]
Wide desktop: [Document/status] [Workspace layout] [Menus/commands] [Docks]
```

The drawing controls may adapt from a vertical edge rail to a compact bottom
strip or sheet when the viewport is narrow. Preserve the left/right handedness
setting where controls are on an edge. The top bar must keep essential actions
visible without horizontal scrolling on phone and tablet widths. Labels,
selected state, and accessible names must agree.

Canvas Focus is a temporary presentation state in either mode. It preserves
the viewport and document state, hides editor chrome, and provides visible Exit
Focus and Quick controls actions.

The screen and existing action services remain state owners. New reusable
control and palette widgets receive immutable snapshots and explicit callbacks.
Rust remains authoritative for brush, color, document, history, and pixels.

## Reference patterns

| Reference | Pattern applied here |
| --- | --- |
| Clip Studio Paint's [Simple and Studio modes](https://help.clip-studio.com/en-us/manual_en/090_tablet/Simple_Mode_and_Studio_Mode.htm) and [Simple Mode controls](https://help.clip-studio.com/en-us/manual_en/090_tablet/Using_Simple_Mode.htm) | Keep Simple focused on core drawing; preserve the active brush, color roles, size, and opacity when artists move to Studio. |
| Clip Studio Paint's [palettes](https://help.clip-studio.com/en-us/manual_en/690_interface/Palettes.htm) and [tool palette](https://help.clip-studio.com/en-us/manual_en/150_tools/The_Tool_palette.htm) | Make palette destinations recognizable, role-based, and reachable through a stable switcher. |
| Procreate's [interface](https://help.procreate.com/procreate/handbook/interface-gestures/interface), [color controls](https://help.procreate.com/procreate/handbook/colors/colors-interface), and [Paint, Smudge, Erase tools](https://help.procreate.com/procreate/handbook/brushes/paint-smudge-erase) | Keep size and opacity near the drawing hand, show the current color directly, and group related drawing modes. |

These are interaction references adapted to Project Ink's existing Rust-owned
document and brush behavior.

## Usability comparison after implementation

This comparison uses the competitors' published control flows as references; it
is a design review, not a timed user study.

| Product | Published interaction | Project Ink implementation | Usability trade-off |
| --- | --- | --- | --- |
| Procreate | Keeps the active color visible, opens its color panel from that swatch, and places direct Size/Opacity sliders by the canvas with handedness options. | Both modes keep one active-color chip and nearby Size/Opacity controls. Studio keeps direct sliders when space allows and uses labeled slider sheets for compact or enlarged-text layouts; the controls mirror for handedness. | The drawing path is comparable and adapts to text scale. Main/Sub color roles are opened from one Color surface, so changing roles takes one extra tap compared with always-visible separate color roles. |
| Clip Studio Paint Simple | Keeps essential drawing controls available, including Main/Sub colors, size/opacity, separate Eraser and transparent drawing, plus a layer panel. | Simple keeps those roles and brush controls available, shows the selected Brush/Eraser state, and routes the selected tool back to the brush library. Main/Sub and transparent drawing are grouped in the shared Color surface. | The focused model stays consistent with Studio and removes duplicate Color buttons. Main/Sub/transparent actions take an extra tap because they are grouped together. |
| Clip Studio Paint Studio | Exposes a broad, rearrangeable palette workspace. | Studio has named, working palette destinations and a dedicated drawing-control edge opposite the tool rail. This increment retains one active floating panel and the Layers first-use default. | Stable routes are easier to discover than the former missing panel paths; Studio is less customizable than Clip Studio Paint until pinned, collapsed, and rearrangeable tablet palettes are implemented. |

Sources: [Procreate interface](https://help.procreate.com/procreate/handbook/interface-gestures/interface), [Procreate color interface](https://help.procreate.com/procreate/handbook/colors/colors-interface), [Clip Studio Paint Simple and Studio modes](https://help.clip-studio.com/en-us/manual_en/090_tablet/Simple_Mode_and_Studio_Mode.htm), and [Clip Studio Paint Simple controls](https://help.clip-studio.com/en-us/manual_en/090_tablet/Using_Simple_Mode.htm).

The primary touch actions use 48 logical-pixel targets and role/value semantics.
That target size is a deliberate mobile-accessibility choice; it is not a
claim of WCAG conformance. Use [WCAG 2.2 Target Size (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html), [Target Size (Enhanced)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html), and Flutter's [Semantics API](https://api.flutter.dev/flutter/widgets/Semantics-class.html) as review references. Native VoiceOver/TalkBack behavior remains a device acceptance item.

## Verified starting point before cross-platform standardization

Inspection of `canvas_screen.dart`, `canvas_top_bar.dart`,
`canvas_compact_controls.dart`, `canvas_editor_auxiliary_overlays.dart`,
`canvas_workspace_panel_selection.dart`, `workspace_preferences.dart`, and
`canvas_workspace_presentation_controller.dart` establishes the current
behavior below.

| Current behavior | Implementation requirement |
| --- | --- |
| Simple's top row has a flexible document title, Open, Save, Undo, Redo, Focus, Color, mode switch, and More. It does not horizontally scroll; the title gives up space as controls accumulate. | Bound the top row to document/status, Save, Undo/Redo, Focus, mode, and More. Move color selection to the shared drawing controls. Keep essential controls visible at minimum supported widths. |
| Simple's edge controls include tool and brush access, Eraser, Layers, main/sub color swatches, transparent paint, size, opacity, and eyedropper. The top row and More menu also expose Color. | Keep one persistent Color entry point and retain direct size/opacity access. Remove redundant top-row and More Color entries. Put secondary commands in labeled More. |
| Tablet Studio's top row starts with document, tool, and brush names, then workspace/menu actions, Focus, mode switch, Color, Eraser, Edit sub color, Transparent paint, command-bar buttons, More commands, and settings. `InkCommandButton` renders icons with tooltip/semantic labels, not visible text. The row scrolls horizontally. | Separate document/workspace actions from drawing controls. Remove duplicate Color, Eraser, and palette actions from the tablet top row. Replace icon-only mode switching with a visible Simple/Studio selector. Do not require horizontal scrolling for essential actions. |
| `showColorPicker` is in `defaultCommandBarItems` and in Studio's compact visible command set. The fixed Color button and command dispatch both open the same main-color dialog; the Menu can expose it again. Edit sub color opens that dialog initialized to the sub color. | Deduplicate visible actions by mode and control location. Main/sub role selection belongs in the shared color surface; keep command search as an alternate route. |
| Tablet Studio's 48-point rail exposes Tools, Brush presets, Eraser, Layers, and Comics. Tablet Studio does not receive `CanvasQuickControls`; those controls are composed for desktop docks. The Brush Library has size and opacity sliders, so the controls remain reachable only while that palette is open. | Add visible size, opacity, and current-color controls to Studio at the same edge of the canvas as Simple's drawing controls. Keep the advanced Brush Library separate. |
| Tablet Studio currently supports floating Tools, Brushes, Layers, and Comics panels. History and Quick Access open sheets. Tablet panel selection has no visible palette destination for Tool properties or Materials; those actions can clear the active floating panel without opening a replacement. Desktop palette routing is richer. | Add an explicit tablet destination or a truthful disabled state for every advertised palette. Verify that Tool properties and Materials open usable content before exposing those commands. |
| Studio opens Layers on the first tablet presentation. Mode switches remember the last open palette per mode while the current editor route remains mounted. Palette memory is not persisted across a cold launch. The selected tablet mode is persisted. | Keep palette memory session-only in this increment: preserve each mode's palette on round trip, and open Layers on a cold Studio launch. Never confuse mode state with workspace preset state. |
| Transparency and Eraser are separate state paths today: transparent drawing toggles its color role; Eraser toggles the active tool state. | Preserve the distinction and make both meanings clear in labels, icons, and selected state. |
| Focus currently suppresses the top bar, tablet rails, Simple edge controls, floating panels, desktop docks, quick menu, and selection launcher. Escape's transient-close handler exits Focus. Focus Quick controls include main color, size, opacity, brush access, Undo, and Redo. | Preserve these working paths. Add regression checks for all overlays and define dismissal order for any transient sheet or dialog opened while focused. |
| `CanvasQuickControls` already presents brush, layer, size, opacity, Eraser, transparency, main/sub color, and swap/reset on desktop. | Reuse its control vocabulary and brush/color action paths for tablet; do not add a second state owner or a separate brush-edit model. |

## Shared tablet drawing controls

Build one tablet drawing-control surface used in Simple and Studio. Keep the
mode-specific tool/palette navigation separate from these high-frequency
controls. The surface receives the active brush, main/sub colors, active tool,
Eraser state, and transparency state as a snapshot. It dispatches changes
through the existing brush and color action owners.

- Show the selected brush name or a Brush button that opens Brush Library.
- Show the current main-color chip as the single persistent Color button. It
  opens one color surface with Main and Sub roles, color picker, recent colors,
  Swap, Reset, and Transparent drawing. The currently active role is explicit.
- Keep the transparent-drawing action visibly distinct from the Eraser tool.
  Its label or supporting text explains that it erases using the active brush.
- Show Size in document pixels and Opacity as a percentage. Preview while
  dragging; persist at the existing change-end boundary, not on every movement.
- Preserve recent-color, color-swap, active-brush, and pending-draft behavior.
  Picker dismissal leaves the selected role and current color unchanged.
- Mirror the control surface for handedness. At constrained heights, replace
  the slider with a value button that opens a labeled, accessible slider.
- In Focus, provide the same basic color, size, and opacity controls through
  the existing Focus Quick controls sheet.

Avoid showing another fixed Color, Edit sub color, or generic color-picker
command alongside the persistent chip. Command search may still find the Color
action. Desktop docks may keep their current layout, but their configurable
command bar must also avoid duplicate visible actions.

## Simple mode

Simple remains the default editor mode on a fresh setup. Keep the mode selector
visible and labeled on phone, tablet, and narrow web layouts. Shared theme and
handedness preferences apply immediately in both modes. Use 48 logical-pixel
minimum touch targets.

Top bar: Document/status, Save, Undo, Redo, Canvas Focus, mode selector, and
More. Bound the title and show save progress/status without shifting the
controls. Put Open/New, export, command search, gesture preferences,
accessibility, workspace preset, and advanced editing routes in labeled More
sections. Do not show Color again in the top bar or More.

Drawing navigation: Brush, Eraser, Selection, Fill, and Layers, plus the shared
Color/size/opacity controls. Expose only implemented operations supported by
the active layer. Tapping an inactive tool selects it. Tapping the selected
Brush or Eraser opens its presets; an explicit Settings action opens properties.
Keep an accessible button/menu equivalent for every gesture shortcut.

Simple may select and render every supported Project Ink layer type. Raster
painting and compatible operations remain available. Gate advanced vector,
mask, comic, tone, and text operations per operation rather than disabling a
whole document. Explain a limitation inline and offer Switch to Studio while
retaining page, layer, tool, brush draft, and artwork. Never flatten or convert
content during a mode switch.

Simple Layers: show thumbnail, name, visibility, selected state, and Add
immediately. Layer options provide opacity, blend, rename, lock, alpha lock,
clipping, duplicate, and delete when supported. Use a deliberate drag handle or
long press for reordering; ordinary scrolling must not reorder. Provide an
accessible Options button for actions also available by swipe or double tap.
Route advanced creation and properties to Studio. See the [layer palette
reference](https://help.clip-studio.com/en-us/manual_en/180_layers/Using_layers.htm).

## Studio mode

Studio provides advanced palettes while preserving the shared drawing
controls. Its top bar contains document/status, Save, Undo/Redo, Canvas Focus,
the labeled mode selector, and More. Put workspace presets in a labeled
Workspace section in More, separate from the mode choice. Keep active tool and
brush visible as compact status. Remove fixed Color,
Edit sub color, Eraser, and Transparent paint buttons from this bar; their
authoritative controls live in the shared drawing surface or Studio rail.

The tool rail selects Tools, Brush Library, Eraser, Layers, and Comics. Palette
navigation provides visible, working routes to Tools, Brushes, Tool properties,
Color, Layers, Materials, Comics, History, and Quick Access. Route History and
Quick Access to their sheets, Color to the shared color surface, and each other
palette to a Studio panel or sheet. If an operation is unsupported in the
current document, show a reason and any supported route instead of silently
closing the current palette.

Keep Tool properties and Layer properties distinct. Group related tools and
show choices for the selected group. Check document/layer capability before
enabling palette actions. Use the [tool grouping
reference](https://help.clip-studio.com/en-us/manual_en/150_tools/The_Tool_palette.htm).

For the first tablet increment, retain the one-active-panel model and current
Layers first-use default. Define and implement pinned, collapsed-to-icons, and
temporary pop-up states as a later palette-layout step. A temporary panel
dismisses on outside touch and consumes that pointer sequence so it cannot
leave a mark. A pinned panel stays open. Closing a panel leaves a visible way
to reopen it.

Bound panel width by available space and text scale. In portrait or split view,
use a sheet/pop-up when pinning would leave less than a proposed 360 logical
pixels of canvas width; confirm that threshold during device review. Preserve
document scale, rotation, and the document point at viewport center when a
user-requested dock resize changes the viewport. Pop-ups overlay without moving
artwork. Do not overwrite saved desktop workspace arrangements when a smaller
window uses a compact fallback.

Keep workspace layout preset, Simple/Studio editor mode, responsive canvas
layout, and Canvas Focus as separate choices. A layout reset names the selected
preset and what it resets. It leaves document state, shared theme, gesture
preferences, editor mode, and the other mode's presentation state intact.

## Canvas Focus and interaction contract

Reuse `EditorActionId.toggleInterface`; label it Canvas Focus. Buttons,
command search, and the existing four-finger binding dispatch the same action.
Keep gesture remapping intact. Preserve two-finger Undo, three-finger Redo, and
two-finger navigation. See the [touch gesture
reference](https://help.clip-studio.com/en-us/manual_en/750_gestures/Basic_touch_gestures.htm).

Entering Focus hides bars, rails, palettes, palette tabs, quick menus, and
selection launchers. Artwork, selection boundaries, rulers, and drawing guides
remain visible. Keep the viewport dimensions and origin stable so entering
Focus does not shift artwork or stylus location. Expanding into dock space is
deferred until an anchor-preserving transition is designed.

Keep a quiet, always-reachable 48-point Exit Focus button inside safe-area
bounds. Give it a screen-reader label and block drawing beneath its hit target.
A second Quick controls button opens a temporary sheet for Undo/Redo, brush
selection, brush size, opacity, and color; closing it returns to Focus. Its
interaction area blocks canvas input. Drawing elsewhere does not exit Focus.

Dismiss the topmost transient sheet/dialog first, then exit Focus on Escape or
Android Back, then continue normal editor navigation. Existing dialogs and
transactions retain their own Commit/Cancel controls. Disable Focus entry while
a transform, text edit, or material preview has an unresolved transaction. If a
stroke is active, defer the transition until pointer-up/cancel. No layout
change may interrupt a stroke.

On Focus exit, restore the prior palette presentation and open palette. Keep
the current viewport if the artist navigated while focused. Focus stays
session-only; a cold launch uses the remembered Simple/Studio mode with visible
controls. If a save fails while focused, show an actionable failure indicator
and allow retry.

## Files and materials

Save creates or updates the editable `.inkproj`; export creates a shareable
output. Show Saving, Saved, and Save failed distinctly. Local checkpoint
success and provider write-back success follow the existing document-picker
contract. Before New/Open or leaving the editor, finish the active stroke and
handle dirty state with Save/Discard/Cancel when required. Provider cancellation
leaves the current document active. Do not label Open project as Gallery until
a gallery exists. Show only export formats supported by the selected adapter
and declare flattened output where relevant.

Label each material as a brush, project metadata, or insertable canvas asset.
Canvas insertion requires a bounded placement preview and explicit Apply/Cancel;
Cancel leaves artwork/history unchanged and Apply is undoable. Do not promise
this flow for metadata-only materials. Keep a missing insertion backend as a
separate dependency rather than showing an enabled decorative button. Include
a short local control guide in Help; a full tutorial system can follow later.

## Implementation status

This is a focused increment of the existing professional UI work, not a restart
of the application's numbered roadmap.

- **Drawing controls and top-bar deduplication are implemented.** Simple and
  Studio share a single visible Color entry point, and both keep Size and
  Opacity available beside the canvas. Both modes use direct sliders when the
  layout permits and labeled value buttons with precise slider sheets in short
  or enlarged-text layouts. The top row keeps Save when available, Undo/Redo, Focus, the
  labeled mode selector, and More visible without horizontal scrolling at the
  tested narrow width. Status and active brush text yield space to controls on
  a narrow phone. The desktop bar also abbreviates to the document name in a
  narrow window and puts secondary commands in More.
- **Studio palette routes are implemented.** Tools, Brushes, Tool properties,
  Color, Layers, Materials, Comics, History, and Quick Access each open a
  working panel or sheet. The first-use Layers panel and one-active-panel
  behavior remain. Handedness changes the rail and drawing-control sides;
  floating palettes avoid the permanent drawing controls.
- **Simple controls are refined.** Brush and Eraser show selected state. An
  inactive tool selects it; activating the selected tool opens the brush
  library. Color roles and transparent drawing stay in the shared color
  surface, separate from the Eraser tool. The More menu groups workspace
  choices separately from the Simple/Studio selector.
- **Accessibility checks are implemented and host-tested.** Main and sub
  colors have role-specific labels and values; sliders announce labels, units,
  and changing values; principal touch controls meet 48 logical pixels; close
  actions are named; and cramped/enlarged-text layouts switch to reachable
  value controls. The full Flutter suite, including rendered-layout checks,
  passes and `flutter analyze` reports no issues. A macOS debug build also
  completes.
- **Device acceptance remains open.** Review iPad portrait/landscape, Android
  tablet, split view, and phone fallback with VoiceOver/TalkBack, both
  handedness settings, high-contrast themes, keyboard appearance, stylus
  strokes, Focus dismissal, and color/eraser pixel behavior. Widget semantics
  do not substitute for those physical checks.

Keep broader palette arrangement work (additional floating layouts,
personalized Focus layouts, full local tutorials, and backend-dependent
material insertion) in the existing Phase 5 queue unless a required palette
cannot be made usable with the current sheet/panel model.

## Acceptance criteria

- Switching Simple → Studio → Simple restores each mode's open palette for the
  current editor session on every platform; page, layer, tool, brush draft,
  artwork, and Rust history remain intact. A cold launch restores the saved
  editor mode and opens visible controls. Palette memory stays session-only;
  Studio opens Layers on a cold touch-workspace launch.
- Exactly one persistent phone/tablet Color entry point is visible per mode. It
  clearly shows the active main color. Main/sub selection, picker dismissal,
  swap/reset, and transparent drawing preserve the selected role and brush.
- Size and opacity are reachable without opening Brush Library in both modes.
  Slider changes preview while dragging and persist at change end. Values,
  units, and selected states remain legible with 150%/200% text scaling.
- The Studio rail and palette switcher expose only working routes. Tool
  properties, Materials, History, and Quick Access open their documented
  surfaces or explain why they are unavailable.
- Eraser tool and transparent drawing remain distinct. Switching between them
  retains brush identity/settings as specified and produces the expected Rust
  pixels; verify with representative strokes.
- Focus suppresses every workspace overlay. Exit, Quick controls, Escape/Back,
  and four-finger toggling work without hidden touch traps or stray paint marks.
  Stylus-down transitions wait for stroke completion, and navigation during
  Focus survives exit.
- Layer limitations offer a working Studio route without changing content.
  File/provider cancellation, failed save, export, and supported material
  Apply/Cancel flows behave through visible controls.
- Review iPad portrait/landscape, Android tablet, split view, and phone fallback
  with light/dark/high-contrast themes and both handedness settings. Verify safe
  areas, keyboard appearance, and 48-point targets. Preserve the remembered
  Studio preference when a narrow window temporarily uses the compact Simple
  shell.
- Run focused widget/state checks for restoration, duplicate-action filtering,
  panel routing, and input blocking; visually inspect rendered layouts; perform
  physical stylus checks for transitions. Screenshots alone do not establish
  stroke latency or absence of brief rendering flashes.
