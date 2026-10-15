# Native pointer transport v1

The iOS/iPadOS and macOS adapters publish the existing pointer packet v1
through the Flutter event channel:

`org.projectink.studio/pointer_packets_v1`

The native side also exposes `org.projectink.studio/pointer_status_v1`. It
emits `ready` only after the packet EventChannel has a live Flutter listener.
The canvas keeps generic stylus handling enabled until that signal arrives, so
the first contact cannot be swallowed during engine/channel startup. A status
stream error leaves generic handling enabled.

Events are binary `Uint8List` values. Dart owns the viewport matrix and rewrites
the packet's screen coordinates into canvas coordinates before calling the
shared `EngineApi` Rust adapter. No platform-specific input values enter the
brush engine. Native encoders reject non-finite axes and coordinates outside
the packet safety range (±65,536 px); rejected events remain available to the
generic Flutter pointer path.

Discrete Apple Pencil actions use a separate string EventChannel:

`org.projectink.studio/pencil_commands_v1`

The stable v1 command values are `toggleEraser` and `quickMenu`. They never
share the sample stream, so a Pencil double-tap or squeeze cannot accidentally
begin or end a stroke. The Dart canvas applies `toggleEraser` to subsequent
packets and presents the local quick menu for `quickMenu`.

## iOS/iPadOS

`InkFlutterViewController` intercepts Pencil contacts only; ordinary finger
touches continue through Flutter's gesture arena. Move packets contain actual,
coalesced, and predicted samples from UIKit. Pencil pressure, tilt components,
azimuth, and (when available) Apple Pencil Pro barrel-roll angle are normalized
to the packet v1 fields. The legacy Apple Pencil
double-tap callback and the iOS 17.5+ `UIPencilInteraction` tap/squeeze
callbacks publish the discrete command channel. The EventChannels are
registered from the implicit engine delegate.

`UIHoverGestureRecognizer` publishes Pencil hover positions on the same packet
channel with the `hover` flag. Hover samples update only the transient canvas
crosshair; they are filtered before stroke queueing and never reach Rust as
drawing input. Hover end/cancel clears the crosshair.

## Android

Canvas S Pen input uses Flutter's hit-tested pointer path. `MainActivity` must
always pass the original `MotionEvent` to `FlutterActivity`; activity-level
dispatch cannot distinguish the drawing surface from toolbar, dialog, and
layer controls, so consuming the event prevents those controls from receiving
stylus taps. Android does not subscribe to the native packet/readiness channels
for canvas drawing. The generic Flutter path remains the sole Android stroke
source and routes only contacts hit-tested by the canvas surface.

`MainActivity` still watches for the rising edge of the S Pen primary-button
state and publishes `toggleEraser` on the discrete command channel; holding the
button does not repeat the command. Do not re-enable native Android canvas
packets without a canvas-capture contract that excludes editor controls and
preserves single-source stroke delivery.

## macOS

`InkPointerMonitor` consumes AppKit tablet-point events for stylus and eraser
devices only. It converts coordinates into the Flutter view, preserves pressure,
tilt, rotation, and device identity, and publishes the same packet v1 channel.
The lower- or upper-side pen button publishes one `toggleEraser` command on its
rising edge; holding the button does not repeat the command. Ordinary mouse and
trackpad events remain on Flutter's generic path.

If the Dart stream reports a transport error, the canvas disables the native
stylus path and returns to generic Flutter pointer handling. Native adapters
also leave the original event untouched when no EventChannel listener is
connected, so startup races do not swallow input. A packet sample carrying the
`ERASER` flag clears alpha in the Rust tile engine; it remains undoable like an
ordinary stroke. Physical Pencil and S Pen validation is still required before
claiming latency acceptance.

## Windows

The Windows runner prefers `WM_POINTER` / Windows Ink pen packets. If the
runner cannot obtain a Windows Ink pen packet, it may load the optional WinTab
driver at runtime and listen for `WT_PACKET`. The fallback requests only
bounded position, button, status, timestamp, pressure, and orientation fields,
normalizes them into packet v1, and closes its WinTab context as soon as a
Windows Ink packet is observed so one physical stroke cannot be delivered
twice. The DLL is resolved from the Windows system directory only; no vendor
SDK or link-time import is required. If neither path is available, Flutter's
generic pointer handling remains active.

## Linux

The GTK runner normalizes Wayland/X11 tablet events when a pen device exposes
pressure and tilt axes. `GDK_SOURCE_ERASER` is accepted alongside
`GDK_SOURCE_PEN` and sets the v1 `ERASER` flag; mouse, touch, and cursor devices
remain on the generic Flutter path. When no tablet protocol is available, the
adapter leaves the generic Flutter pointer path active and reports the explicit
fallback rather than fabricating stylus pressure.
