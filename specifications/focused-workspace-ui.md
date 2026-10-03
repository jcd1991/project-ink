# Focused workspace UI: Simple and Studio

Status: refined implementation plan, 2026-10-01. Requirements below are proposed;
code inspection establishes the current behavior, not physical-device acceptance.

## Design basis

Keep Simple for drawing essentials and Studio for advanced editing. Canvas Focus
is a temporary presentation state available in either workspace.

The reference provides several concrete interaction patterns:

| Documentation detail | Project Ink requirement |
| --- | --- |
| Tools expose additional settings; both modes offer size/opacity and a mode switch. | Keep essentials directly reachable and give the selected tool an explicit settings entry. |
| Simple mode has separate main, sub, and transparent color roles. | Show each role and retain the chosen brush when painting transparently. |
| Procreate keeps Paint, Smudge, and Erase as visible modes; Clip Studio exposes an Eraser tool and a temporary shortcut. | Keep the selected foreground color shared across brushes, and expose a direct, selected-state Eraser toggle in Studio. Preset color remains the brush's base/dynamic input. |
| Small Tool Slider palettes replace full sliders with pop-ups. | Adapt quick controls to available height and text size. |
| Palette docks support collapse, icon views, resizing, and rearrangement. | Define tablet palette states and restoration explicitly. |
| Saved workspaces can be reloaded or reset. | Separate session restoration, saved layout, and reset behavior. |
| Some advanced layers cannot be edited in Simple mode. | Declare Simple capabilities and provide an explicit route to Studio for other operations. |

Sources: [Tablet interface](https://help.clip-studio.com/en-us/manual_en/090_tablet/Tablet_interface.htm),
[Using Simple Mode](https://help.clip-studio.com/en-us/manual_en/090_tablet/Using_Simple_Mode.htm),
[Tool Sliders](https://help.clip-studio.com/en-us/manual_en/240_brushes/Tool_Sliders_palette.htm),
[Palettes](https://help.clip-studio.com/en-us/manual_en/690_interface/Palettes.htm),
and [Workspaces](https://help.clip-studio.com/en-us/manual_en/690_interface/Register_and_manage_your_workspace.htm).
For shared brush-mode patterns, see Procreate's [Paint, Smudge, and Erase](https://help.procreate.com/procreate/handbook/brushes/paint-smudge-erase)
and Clip Studio's [Tool Shortcuts](https://help.clip-studio.com/en-us/manual_en/780_shortcuts/Tool_Shortcuts.htm).

Focus is a Project Ink design proposal. The linked tablet overview establishes
Simple/Studio behavior; it does not specify this proposed Focus interaction.

## Verified starting point and gaps

Inspection of `app/lib/canvas/canvas_screen.dart`, `app/lib/app/editor_action.dart`,
`app/lib/app/workspace_preferences.dart`, and `app/lib/canvas/gesture_defaults.dart`
shows:

| Existing behavior | Gap to rectify |
| --- | --- |
| Simple/Studio preference, left-handed preference, and themes already exist. | Retain these and define restoration independently for each mode. |
| Simple toolbar is a horizontally scrolling row containing file, selection, transform, brush, layer, color, comic, and workspace controls. | Bound the persistent essentials; place secondary actions in labeled overflow. |
| Simple edge controls already contain undo/redo, size, opacity, and eyedropper. | Avoid duplicate undo/redo surfaces; provide compact slider behavior and bounded height. |
| `_toggleTabletWorkspaceMode` opens Layers when entering Studio and clears other palette flags. | Open Layers on first use only; subsequently restore each mode's prior palette state. |
| `toggleInterface` and four-finger tap already hide/show chrome. | Reuse this action for Focus, add a visible exit and consistent restoration. |
| Touch tools, brushes, layers, and comics overlays are built outside the `_interfaceHidden` checks. | Include all workspace overlays in Focus suppression; existing hide flags do not suppress all panels. |
| Escape calls `_closeTransientPanels`, which does not restore a hidden interface. | Define Escape/Back precedence and an explicit Focus exit. |
| Transparent color callbacks currently route through `toggleEraser`. | Keep transparent drawing independent; the Studio command bar also offers a direct eraser toggle that preserves the selected brush and its settings. |
| Studio has a 48-point rail and command bar; touch palettes use positioned fixed-width panels. | Specify adaptive tablet docking and verify complete palette access through visible controls. |
| Desktop supports richer layout/customization structures. | Prove tablet access and persistence before treating desktop support as tablet parity. |

## Simple mode specification

Default to Simple on a fresh tablet setup. Keep the mode switch labeled and visible;
also provide it in the workspace menu. Shared theme and handedness apply immediately
in both modes. Use 48 logical-pixel minimum touch targets.

Top bar: document title/status with bounded width, Save, Undo, Redo, Focus,
Simple/Studio switch, and More. On narrow layouts shorten the title and move
secondary commands into More; essentials must not require horizontal scrolling.
Remove duplicate undo/redo buttons from the edge strip once they are in the top bar.

Drawing rail: Brush, Eraser, Selection, Fill, Color roles, and Layers. Include only
implemented commands supported by the active layer. Put Comics, materials,
transform, document setup, gesture preferences, accessibility, and export in More.
Tapping an inactive tool selects it. Tapping the selected Brush/Eraser opens its
presets; double-tap or an explicit Settings control opens its properties. Gesture
shortcuts always have an accessible button/menu equivalent. Show the actual active
tool rather than the current hard-coded document-title suffix `Pen`.

Brush size/opacity remain reachable beside the drawing rail. Show units and values,
and preview changes while dragging through the existing brush-update path. When
height is constrained, replace long sliders with labeled value buttons that open
one slider pop-up. Retain the existing size-persistence behavior and explicitly
verify opacity retention on brush changes and app restart. Do not save on every
pointer movement. Mirror rail placement for left-handed use.

Color control: primary, secondary, and transparency, with distinct selection
markers. Tapping a swatch selects its role; tapping the selected swatch opens the
picker. Offer Swap and Reset explicitly. Transparency uses the selected brush's
shape and settings; switching to the Eraser tool remains a separate operation.
Long-press sampling uses the existing gesture binding and shows old/new color
feedback. Disabled sampling/painting must explain the relevant layer limitation.

Simple Layers: thumbnail, name, visibility, selected state, and Add are immediately
visible. Layer options provide opacity, blend, rename, lock, alpha lock, clipping,
duplicate, and delete when supported. Drag uses a deliberate handle or long press;
ordinary scroll must not reorder. Swipe/double-tap can open options, with an explicit
Options button as the accessible equivalent. Advanced creation and properties route
to Studio. [Layer palette reference](https://help.clip-studio.com/en-us/manual_en/180_layers/Using_layers.htm)

Simple may select and render all supported Project Ink layer types. Raster painting
and compatible operations remain available. Advanced vector, mask, comic, tone, and
text operations require a capability decision per operation, rather than blanket
disabling an entire document. Explain the limitation inline and offer Switch to
Studio, retaining selected page/layer/tool and artwork. Never flatten or convert
content during a mode switch.

## Studio mode specification

Use a compact command bar, tool rail, quick size/opacity controls, and an edge
palette switcher. Provide visible routes to Tools, Brushes, Tool properties,
Color, Layers, Materials, Comics, History, and Quick Access. Check capability
availability before exposing each entry. A tool's properties and a layer's
properties must remain distinct. Group related tools and expose the selected
group's choices. [Tool grouping reference](https://help.clip-studio.com/en-us/manual_en/150_tools/The_Tool_palette.htm)

Define three palette presentation states: pinned, collapsed to icons, and temporary
pop-up. Start with one active pinned palette on a tablet; Layers is the first-use
default. Palette headers provide name, options, collapse/pin, and close. Closing a
palette must leave a visible way to reopen it. A temporary palette dismisses on
outside touch; a pinned palette stays open. Width is bounded by available canvas
space and text scale. In portrait or split view, use a sheet/pop-up when pinning
would leave less than a proposed 360 logical-pixel canvas width; confirm this
threshold during device review.

A user-requested pin/collapse may resize the viewport. Preserve document scale,
rotation, and the document point at the viewport center; do not automatically Fit.
Pop-ups overlay the viewport without moving the artwork. Rearrangement is deliberate
through an Arrange palettes control with drag handles/drop indicators and a menu
alternative. Adapt desktop preferences to tablet layouts with bounded fallback;
do not overwrite the saved arrangement simply because the window became smaller.

Preserve existing Illustration/Comic/custom workspace controls. Name their scope:
workspace preset, Simple/Studio mode, and Focus are separate controls. Reset layout
acts on the chosen mode/preset, lists what it will reset, and leaves document state
and shared theme/gesture preferences intact.

## Focus and interaction contract

Reuse `EditorActionId.toggleInterface`; expose the user-facing label Canvas Focus.
All buttons, command search, and the existing four-finger binding dispatch the same
action. Keep gesture remapping intact. Existing two-finger undo, three-finger redo,
and two-finger navigation stay available. [Touch gesture reference](https://help.clip-studio.com/en-us/manual_en/750_gestures/Basic_touch_gestures.htm)

Entering Focus hides bars, rails, palettes, palette tabs, quick menus, and selection
launchers. Artwork, selection boundaries, rulers, and drawing guides remain visible.
The viewport keeps the same dimensions/origin by default, so entering Focus does
not shift artwork or the stylus location. Expansion to previously docked space is
deferred until an explicit anchor-preserving transition is designed.

Retain a quiet, always reachable 48-point Exit Focus button inside safe-area bounds.
Do not hide the sole exit on a timer. It must have a screen-reader label and accept
touch without drawing beneath it. A second Quick controls button opens a temporary
overlay for Undo/Redo, brush size, opacity, and color; closing it returns to Focus.
Its interaction area blocks canvas input. Drawing elsewhere must not exit Focus.

Escape/Android Back first cancels or dismisses the top transient UI, then exits
Focus, then follows normal editor navigation. Active transforms, text entry,
material previews, and dialogs retain their own Commit/Cancel controls; Focus entry
is unavailable until those transactions are resolved. If a stroke is active, defer
the transition until pointer-up/cancel. No layout change may interrupt a stroke.

Restore the prior palette presentation and open palette on exit. Keep the current
viewport if the artist navigated while focused. Focus stays session-only; a cold
launch opens the remembered Simple/Studio mode with visible controls. If a save
fails while focused, show an actionable failure indicator and allow retry.

## Temporary panels, files, and materials

Only one temporary workspace panel is active at a time. For outside dismissal,
consume the dismissing pointer sequence so it cannot leave a mark. The next stylus
contact draws normally. Preserve independent scrolling and panel-local draft state.

Save creates/updates the editable `.inkproj`; export creates a shareable output.
Show Saving, Saved, and Save failed distinctly. Local checkpoint success and file
provider write-back success must follow the existing document-picker contract.
Before New/Open or leaving the editor, finish the active stroke and handle dirty
state with save/discard/cancel where required. Provider cancellation leaves the
current document active. Do not label Open project as a Gallery until an actual
gallery exists. Show only export formats supported by the selected adapter and
declare flattened output where relevant.

Materials must identify whether an item is a brush, project metadata, or an
insertable canvas asset. Canvas insertion needs a bounded placement preview with
explicit Apply/Cancel; cancel leaves artwork/history unchanged and apply is undoable.
Do not promise this flow for metadata-only materials. Keep any missing insertion
backend as a separate dependency rather than a decorative enabled button. Include
a short local control guide in Help; a full tutorial system can follow later.

## Delivery and acceptance

This is a focused increment of the existing professional UI work, not a restart
of the application's numbered roadmap.

1. State and safety: centralize transitions, capability gates, per-mode restoration,
   Focus overlay suppression, and pointer/transaction arbitration.
2. Simple refinement: bounded essential bar, selected-tool interactions, adaptable
   sliders, color roles, compact Layers, and truthful file/material labels.
3. Studio refinement: complete palette access, pin/collapse/pop-up behavior,
   orientation fallback, handedness, and scoped saved-layout/reset controls.
4. Acceptance: verify the following behavior and inspect rendered tablet layouts.
   Leave deferred enhancements in the project's existing Phase 5 queue.

Required checks:

- Mode round trip restores each mode's palette state; artwork/page/layer/tool,
  engine history, and pending brush draft remain intact.
- Focus suppresses every workspace overlay; Exit, Quick controls, Escape/Back,
  and four-finger toggling work without hidden touch traps or stray paint marks.
- Stylus-down transitions wait for stroke completion; selection/transform/dialog
  transactions resolve explicitly. Navigation during Focus survives exit.
- Transparency retains brush identity and settings; color swaps and picker
  dismissal preserve the selected role. Verify actual Rust output.
- Sliders remain usable with 150%/200% text. Presets and opacity survive the
  applicable persistence boundary without excessive saves.
- Layer limitations offer a working Studio route without changing content.
- File/provider cancellation, failed save, export, and material Apply/Cancel
  behave correctly through visible controls.
- Review iPad portrait/landscape, Android tablet, split view, and phone fallback
  with light/dark/high-contrast themes and both handedness settings. Verify safe
  areas, keyboard appearance, and 48-point targets. Preserve the remembered Studio
  preference when a narrow window temporarily uses the compact Simple shell.
- Use focused widget/state checks for restoration and input blocking, visual
  inspection for layout, and physical stylus checks for transitions. Screenshots
  alone do not establish stroke latency or absence of brief rendering flashes.

Phase 5 follow-ups: additional floating palette arrangements, personalized Focus
layouts, a full local tutorial system, and backend-dependent material insertion.
Device acceptance above remains part of this increment before declaring it complete.
