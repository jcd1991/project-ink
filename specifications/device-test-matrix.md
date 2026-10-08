# Phase 1 device matrix

| Platform | Reference device | Input path | First acceptance |
| --- | --- | --- | --- |
| iPadOS 17 | iPad Pro M1 11/12.9, Apple Pencil 2 | UIKit coalesced/predicted touches | ≤40 ms p95 visible update |
| iPadOS 17 | iPad Pro M4 13, Apple Pencil Pro | UIKit + hover/squeeze/rotation | ≤25 ms p95 visible update |
| Android API 29+ | Galaxy S23 Ultra, S Pen | MotionEvent history/hover/buttons | ≤40 ms p95 visible update |
| Android API 29+ | Samsung tablet | MotionEvent fallback | no dropped confirmed samples |
| macOS 14+ | Apple Silicon/Intel Mac | NSEvent tablet points | draw/save/reopen |
| Windows 10/11 | Wacom/Huion/XP-Pen | WM_POINTER, runtime WinTab fallback | tablet pressure/eraser; no duplicate strokes |
| Ubuntu 22.04+ | Wayland/X11 tablet | Flutter then libinput/Wayland | pressure or explicit fallback |

The first implementation uses CPU tiles and Flutter compositing. A `wgpu`
external texture is only considered after a profile demonstrates that pooled
dirty-region updates miss the stated latency gates.
> Final hardware and hosted-platform execution of this matrix is a Phase 5
> requirement. Phases 1–4 may validate the adapters with automated tests and
> simulator/emulator startup checks, but must not claim physical latency,
> memory, or tablet acceptance from those checks.

## Shared Illustration Panel tool

The panel workflow is shared by Simple and Studio; there is no platform-only
panel model or separate phone implementation. Include the following in each
platform's UI pass:

| Platform | Input check | Persistence/history check |
| --- | --- | --- |
| iOS/iPadOS | One-finger split and divider drag; confirm Pencil/touch coordinates align | Gutter/border, Undo/Redo, save/reopen with existing pixels intact |
| macOS | Mouse and tablet drag preview/split; divider drag | Same save/reopen and structural Undo/Redo |
| Android | Touch and Galaxy S Pen split/drag; test two-finger Undo and three-finger Redo after a canceled touch start | Save/reopen, confirm the stroke returns, then verify Redo remains available |

Run the interaction in both Simple and Studio. Verify the 2-, 3-, and 4-panel
presets on a blank panel map, then split an existing panel; adjust both gutter
and border; draw over the resulting guides; and ensure the guide remains
visible after switching back to a drawing tool. A host compile or automated
model test is not evidence of device input alignment or installed UI behavior.
