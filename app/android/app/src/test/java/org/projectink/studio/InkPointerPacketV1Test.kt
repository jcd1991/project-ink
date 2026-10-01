// SPDX-License-Identifier: MPL-2.0
package org.projectink.studio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class InkPointerPacketV1Test {
    @Test
    fun rejectsNonFiniteAndOutOfRangeAxesBeforeEncoding() {
        assertTrue(InkPointerSampleValidation.valid(1f, -2f, 0.5f, 0f, 0f))
        assertFalse(InkPointerSampleValidation.valid(Float.NaN, 0f, 0.5f, 0f, 0f))
        assertFalse(InkPointerSampleValidation.valid(65_536.1f, 0f, 0.5f, 0f, 0f))
        assertFalse(InkPointerSampleValidation.valid(0f, 0f, Float.POSITIVE_INFINITY, 0f, 0f))
        assertFalse(InkPointerSampleValidation.valid(0f, 0f, 0.5f, Float.NaN, 0f))
    }

    @Test
    fun boundsSamplesAndRetainsConfirmedSamplesFirst() {
        val samples = (0 until 300).map { index ->
            val flags = when {
                index < 100 -> 1
                index < 200 -> 1 shl 1
                else -> 1 shl 2
            }
            InkPointerSampleV1(
                pointerId = index,
                flags = flags.toShort(),
                deviceKind = 1,
                phase = 1,
                canvasX = 0f,
                canvasY = 0f,
                pressure = 1f,
                tiltX = 0f,
                tiltY = 0f,
                azimuth = 0f,
                twist = 0f,
                timestampNs = index.toLong(),
                sequence = index,
            )
        }

        val packet = InkPointerPacketV1.encode(samples)
        val header = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(1.toShort(), header.short)
        assertEquals(InkPointerPacketV1.maxSamples.toShort(), header.short)
        assertEquals(0, header.int)
    }
}
