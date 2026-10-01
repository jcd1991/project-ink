// SPDX-License-Identifier: MPL-2.0
import Flutter
import UIKit

/// Observes Pencil contacts while leaving ordinary touch gestures to Flutter.
final class InkFlutterViewController: FlutterViewController, UIPencilInteractionDelegate {
    private let pointerAdapter = InkPointerAdapter()
    private var pencilInteraction: UIPencilInteraction?
    private var pencilInputRecognizer: InkPencilGestureRecognizer?

    override func viewDidLoad() {
        super.viewDidLoad()
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
        pencilInteraction = interaction

        let pencilRecognizer = InkPencilGestureRecognizer()
        pencilRecognizer.delegate = self
        pencilRecognizer.onSamples = { [weak self] touches, event, phase in
            guard let self else { return }
            _ = self.publishStylus(touches, event: event, phase: phase)
        }
        view.addGestureRecognizer(pencilRecognizer)
        pencilInputRecognizer = pencilRecognizer
    }

    override func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === pencilInputRecognizer ||
            otherGestureRecognizer === pencilInputRecognizer {
            return true
        }
        return super.gestureRecognizer(
            gestureRecognizer,
            shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
        )
    }

    private func publishStylus(_ touches: Set<UITouch>, event: UIEvent?, phase: UInt8) -> Bool {
        let stylusTouches = touches.filter(pointerAdapter.isStylus)
        guard !stylusTouches.isEmpty else { return false }
        if phase == 0 {
            let maximumForce = stylusTouches.map { max($0.maximumPossibleForce, 1) }.max() ?? 1
            let force = stylusTouches.map(\.force).max() ?? 0
            _ = InkCanvasDiagnosticEventStream.shared.publish([
                "kind": "hardware.pencil_contact_began",
                "device": "apple_pencil",
                "touchCount": stylusTouches.count,
                "forceNormalized": force / maximumForce,
                "maximumPossibleForce": maximumForce,
                "timestampSeconds": stylusTouches.map(\.timestamp).max() ?? ProcessInfo.processInfo.systemUptime,
            ])
        }
        guard let packets = pointerAdapter.packet(
            from: Array(stylusTouches),
            event: event,
            in: view,
            phase: phase
        ) else {
            _ = InkCanvasDiagnosticEventStream.shared.publish([
                "kind": "hardware.pointer_packet_rejected",
                "device": "apple_pencil",
                "phase": phase,
                "touchCount": stylusTouches.count,
                "reason": "packet_encode_failed",
            ])
            return false
        }
        var publishedAll = true
        for packet in packets {
            let published = InkPointerEventStream.shared.publish(packet)
            publishedAll = publishedAll && published
            if !published {
                _ = InkCanvasDiagnosticEventStream.shared.publish([
                    "kind": "hardware.pointer_packet_dropped",
                    "device": "apple_pencil",
                    "phase": phase,
                    "touchCount": stylusTouches.count,
                    "byteLength": packet.count,
                    "reason": "pointer_event_channel_has_no_listener",
                ])
            }
        }
        if !publishedAll {
            _ = InkCanvasDiagnosticEventStream.shared.publish([
                "kind": "hardware.pointer_batch_incomplete",
                "device": "apple_pencil",
                "phase": phase,
                "touchCount": stylusTouches.count,
                "packetCount": packets.count,
            ])
        }
        return publishedAll
    }

    private func publishPencilAction() {
        let preferredAction = UIPencilInteraction.preferredTapAction
        switch preferredAction {
        case .ignore:
            return
        case .showContextualPalette, .showColorPalette, .showInkAttributes, .runSystemShortcut:
            _ = InkPencilCommandEventStream.shared.publish("quickMenu")
        default:
            _ = InkPencilCommandEventStream.shared.publish("toggleEraser")
        }
    }

    @available(iOS, deprecated: 17.5)
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        publishPencilAction()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        publishPencilAction()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        guard UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        _ = InkPencilCommandEventStream.shared.publish("quickMenu")
    }
}
