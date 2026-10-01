// SPDX-License-Identifier: MPL-2.0
package org.projectink.studio

import android.view.MotionEvent
import kotlin.math.abs

internal object InkPointerSampleValidation {
    const val MAX_COORDINATE_ABS = 65_536f

    fun valid(
        x: Float,
        y: Float,
        pressure: Float,
        tilt: Float,
        orientation: Float,
    ): Boolean = x.isFinite() && y.isFinite() &&
        abs(x) <= MAX_COORDINATE_ABS && abs(y) <= MAX_COORDINATE_ABS &&
        pressure.isFinite() && tilt.isFinite() && orientation.isFinite()
}

/** Converts S Pen MotionEvent history to pointer packet v1. */
class InkPointerAdapter {
    private var sequence = 0

    fun isPrimaryButtonPressed(event: MotionEvent): Boolean =
        containsStylus(event) &&
            (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0

    fun packet(event: MotionEvent): ByteArray? {
        if (!containsStylus(event)) return null
        val samples = mutableListOf<InkPointerSampleV1>()
        val phase = phase(event.actionMasked)
        if (phase == null) return null

        if (phase == 1.toByte()) {
            for (history in 0 until event.historySize) {
                for (index in 0 until event.pointerCount) {
                    if (!isStylus(event.getToolType(index))) continue
                    samples += sample(event, index, phase, 1 shl 1, history) ?: return null
                }
            }
        }
        for (index in 0 until event.pointerCount) {
            if (!isStylus(event.getToolType(index))) continue
            samples += sample(event, index, phase, 1, null) ?: return null
        }
        return InkPointerPacketV1.encode(samples)
    }

    private fun containsStylus(event: MotionEvent): Boolean =
        (0 until event.pointerCount).any { isStylus(event.getToolType(it)) }

    private fun isStylus(toolType: Int): Boolean =
        toolType == MotionEvent.TOOL_TYPE_STYLUS ||
            toolType == MotionEvent.TOOL_TYPE_ERASER

    private fun phase(action: Int): Byte? = when (action) {
        MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> 0.toByte()
        MotionEvent.ACTION_MOVE, MotionEvent.ACTION_HOVER_MOVE -> 1.toByte()
        MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> 2.toByte()
        MotionEvent.ACTION_CANCEL -> 3.toByte()
        else -> null
    }

    private fun sample(
        event: MotionEvent,
        index: Int,
        phase: Byte,
        historyFlag: Int,
        history: Int?,
    ): InkPointerSampleV1? {
        val historicalIndex = history
        val historical = historicalIndex != null
        val historyValue = historicalIndex ?: -1
        val x = if (historical) event.getHistoricalX(index, historyValue) else event.getX(index)
        val y = if (historical) event.getHistoricalY(index, historyValue) else event.getY(index)
        val pressure = if (historical) event.getHistoricalPressure(index, historyValue) else event.getPressure(index)
        val tilt = if (historical) {
            event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, index, historyValue)
        } else {
            event.getAxisValue(MotionEvent.AXIS_TILT, index)
        }
        val orientation = if (historical) {
            event.getHistoricalOrientation(index, historyValue)
        } else {
            event.getOrientation(index)
        }
        val timestamp = if (historical) event.getHistoricalEventTime(historyValue) else event.eventTime
        if (!InkPointerSampleValidation.valid(x, y, pressure, tilt, orientation)) {
            return null
        }
        var flags = historyFlag
        if (event.getToolType(index) == MotionEvent.TOOL_TYPE_ERASER) flags = flags or (1 shl 3)
        if (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) flags = flags or (1 shl 4)
        return InkPointerSampleV1(
            pointerId = event.getPointerId(index),
            flags = flags.toShort(),
            deviceKind = 1,
            phase = phase,
            canvasX = x,
            canvasY = y,
            pressure = pressure.coerceIn(0f, 1f),
            tiltX = tilt,
            tiltY = 0f,
            azimuth = orientation,
            twist = 0f,
            timestampNs = timestamp * 1_000_000L,
            sequence = sequence++,
        )
    }
}
