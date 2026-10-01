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
