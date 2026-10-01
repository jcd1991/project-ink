// SPDX-License-Identifier: MPL-2.0
import UIKit

/// Observes Apple Pencil contacts on Flutter's view without cancelling the
/// touch sequence delivered to Flutter. UIViewController touch overrides are
/// not a reliable interception point because FlutterView handles the touches
/// before they reach its view controller.
final class InkPencilGestureRecognizer: UIGestureRecognizer {
    var onSamples: ((Set<UITouch>, UIEvent?, UInt8) -> Void)?
    private var activePencilTouches = Set<ObjectIdentifier>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activePencilTouches.formUnion(touches.map(ObjectIdentifier.init))
        onSamples?(touches, event, 0)
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        onSamples?(touches, event, 1)
        state = .changed
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        let activeTouches = Set(
            touches.filter { activePencilTouches.contains(ObjectIdentifier($0)) }
        )
        let ignoredCount = touches.count - activeTouches.count
        guard !activeTouches.isEmpty else {
            if ignoredCount > 0 {
                _ = InkCanvasDiagnosticEventStream.shared.publish([
                    "kind": "hardware.pencil_estimated_properties_ignored",
                    "reason": "contact_already_ended",
                    "touchCount": ignoredCount,
                ])
            }
            return
        }
        // UIKit may revise Pencil force after the initial estimated contact.
        // Record updates for diagnostics, but do not treat them as new path
        // samples because their coordinates belong to an earlier timestamp.
        for touch in activeTouches {
            let maximumForce = max(touch.maximumPossibleForce, 1)
            let location = touch.preciseLocation(in: touch.view)
            _ = InkCanvasDiagnosticEventStream.shared.publish([
                "kind": "hardware.pencil_estimated_properties_updated",
                "device": "apple_pencil",
                "forceNormalized": touch.force / maximumForce,
                "maximumPossibleForce": maximumForce,
                "timestampSeconds": touch.timestamp,
                "estimationUpdateIndex": touch.estimationUpdateIndex?.intValue as Any? ?? NSNull(),
                "estimatedProperties": touch.estimatedProperties.rawValue,
                "expectedProperties": touch.estimatedPropertiesExpectingUpdates.rawValue,
                "x": location.x,
                "y": location.y,
            ])
        }
        // An estimated-property callback refers to an earlier touch sample.
        // Appending it as a fresh move can take the input path backwards when
        // its position arrives after newer coalesced samples. UIKit provides
        // estimationUpdateIndex so drawing apps can revise that original
        // sample in place; our v1 packet stream has no correction opcode yet,
        // so keep the callback diagnostic-only instead of corrupting geometry.
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onSamples?(touches, event, 2)
        activePencilTouches.subtract(touches.map(ObjectIdentifier.init))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        _ = InkCanvasDiagnosticEventStream.shared.publish([
            "kind": "hardware.touch_cancelled",
            "device": "apple_pencil",
            "touchCount": touches.count,
            "timestampSeconds": event?.timestamp ?? ProcessInfo.processInfo.systemUptime,
        ])
        onSamples?(touches, event, 3)
        activePencilTouches.subtract(touches.map(ObjectIdentifier.init))
        state = .cancelled
    }

    override func reset() {
        super.reset()
        activePencilTouches.removeAll(keepingCapacity: true)
    }
}
