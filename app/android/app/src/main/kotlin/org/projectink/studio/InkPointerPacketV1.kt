// SPDX-License-Identifier: MPL-2.0
package org.projectink.studio

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class InkPointerSampleV1(
    val pointerId: Int,
    val flags: Short,
    val deviceKind: Byte,
    val phase: Byte,
    val canvasX: Float,
    val canvasY: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
    val azimuth: Float,
    val twist: Float,
    val timestampNs: Long,
    val sequence: Int,
)

object InkPointerPacketV1 {
    const val maxSamples = 256
    private const val coalescedFlag = 1 shl 1
    private const val predictedFlag = 1 shl 2

    fun encode(samples: List<InkPointerSampleV1>): ByteArray {
        val boundedSamples = bound(samples)
        val buffer = ByteBuffer.allocate(4 + boundedSamples.size * 48).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putShort(1)
        buffer.putShort(boundedSamples.size.toShort())
        boundedSamples.forEach { sample ->
            buffer.putInt(sample.pointerId)
            buffer.putShort(sample.flags)
            buffer.put(sample.deviceKind)
            buffer.put(sample.phase)
            buffer.putFloat(sample.canvasX)
            buffer.putFloat(sample.canvasY)
            buffer.putFloat(sample.pressure)
            buffer.putFloat(sample.tiltX)
            buffer.putFloat(sample.tiltY)
            buffer.putFloat(sample.azimuth)
            buffer.putFloat(sample.twist)
            buffer.putLong(sample.timestampNs)
            buffer.putInt(sample.sequence)
        }
        return buffer.array()
    }

    private fun bound(samples: List<InkPointerSampleV1>): List<InkPointerSampleV1> {
        if (samples.size <= maxSamples) return samples
        val selected = samples.withIndex()
            .sortedWith(compareBy({ priority(it.value.flags) }, { it.index }))
            .take(maxSamples)
            .map { it.index }
            .toSet()
        return samples.withIndex()
            .filter { it.index in selected }
            .map { it.value }
    }

    private fun priority(flags: Short): Int {
        val value = flags.toInt()
        if (value and predictedFlag != 0) return 2
        if (value and coalescedFlag != 0) return 1
        return 0
    }
}
