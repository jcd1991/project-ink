// SPDX-License-Identifier: MPL-2.0
package org.projectink.studio

import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RenderNode
import android.view.Choreographer
import android.os.Handler
import android.os.Looper
import android.os.HandlerThread
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/**
 * Bounded hardware-backed Flutter preview textures for the transient Android
 * stroke overlay. Rust remains authoritative for documents, undo, and saved
 * pixels. The channel accepts only bounded metadata and v3 binary dab packets.
 */
internal class InkLiveTextureRegistry(
    private val textures: TextureRegistry,
) : Closeable {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val renderThread = HandlerThread("project-ink-live-texture").apply { start() }
    private val renderHandler = Handler(renderThread.looper)
    private val entries = ConcurrentHashMap<Long, SurfaceEntry>()
    @Volatile
    private var closed = false

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (closed) {
            result.error("registry_closed", "Live texture registry is closed.", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        if (arguments == null) {
            result.error("invalid_arguments", "Expected a map.", null)
            return
        }
        try {
            when (call.method) {
                "create" -> create(arguments, result)
                "setViewport" -> withEntry(arguments, result) { entry ->
                    val matrix = floatMatrix(arguments["matrix"])
                    val generation = boundedLong(arguments["generation"], 0, Long.MAX_VALUE)
                    synchronized(entry.lock) {
                        if (generation < entry.generation) {
                            throw LiveTextureException("stale_generation", "Viewport generation is stale.")
                        }
                        entry.transform.setValues(matrix)
                        entry.generation = generation
                    }
                    rebuildRenderBatches(entry)
                }
                "renderDabs" -> withEntry(arguments, result) { entry ->
                    val packet = arguments["packet"] as? ByteArray
                        ?: throw LiveTextureException("invalid_packet", "Expected a binary dab packet.")
                    applyDabs(entry, decodePacket(packet))
                }
                "renderDabBatches" -> withEntry(arguments, result) { entry ->
                    val packets = arguments["packets"] as? List<*>
                        ?: throw LiveTextureException("invalid_packet", "Expected a list of binary dab packets.")
                    if (packets.isEmpty() || packets.size > MAX_RENDER_PACKETS_PER_BATCH) {
                        throw LiveTextureException("invalid_packet", "Dab packet batch is outside its count limit.")
                    }
                    val decoded = packets.map { value ->
                        val packet = value as? ByteArray
                            ?: throw LiveTextureException("invalid_packet", "Expected each dab packet to be binary.")
                        decodePacket(packet)
                    }
                    applyDabs(entry, decoded.flatten())
                }
                "acknowledge" -> withEntry(arguments, result) { entry ->
                    val stroke = strokeKey(arguments["strokeId"])
                    val sequence = boundedLong(arguments["sequence"], 0, 0xffffffffL)
                    val affectedBatches = LinkedHashSet<RenderBatchKey>()
                    synchronized(entry.lock) {
                        val acknowledgedDabs = entry.dabs.values.filter { dab ->
                            dab.key.high == stroke.first &&
                                dab.key.low == stroke.second &&
                                dab.key.sequence <= sequence
                        }
                        for (dab in acknowledgedDabs) {
                            if (removeDab(entry, dab.key) != null) {
                                affectedBatches += dab.batchKey()
                            }
                        }
                    }
                    rebuildRenderBatches(entry, affectedBatches)
                }
                "cancelAll" -> withEntry(arguments, result) { entry ->
                    synchronized(entry.lock) {
                        entry.dabs.clear()
                        entry.dabsByBatch.clear()
                        entry.renderBatches.clear()
                    }
                }
                "dispose" -> dispose(arguments, result)
                else -> result.notImplemented()
            }
        } catch (error: LiveTextureException) {
            result.error(error.code, error.message, null)
        } catch (error: Exception) {
            result.error("live_texture_failed", error.message ?: "Native preview failed.", null)
        }
    }

    private fun create(arguments: Map<*, *>, result: MethodChannel.Result) {
        if (entries.isNotEmpty()) {
            throw LiveTextureException("surface_busy", "Only one live texture may be active per engine.")
        }
        val width = boundedInt(arguments["width"], 1, MAX_DIMENSION)
        val height = boundedInt(arguments["height"], 1, MAX_DIMENSION)
        val bytes = width.toLong() * height.toLong() * 4L
        if (bytes > MAX_SURFACE_BYTES) {
            throw LiveTextureException("surface_too_large", "Surface exceeds the Android buffer budget.")
        }
        val producer = textures.createSurfaceProducer()
        producer.setSize(width, height)
        val textureId = producer.id()
        val entry = SurfaceEntry(producer, textureId, width, height)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                requestRedraw(entry)
            }

            override fun onSurfaceCreated() {
                requestRedraw(entry)
            }
        })
        entries[textureId] = entry
        result.success(mapOf("textureId" to textureId))
    }

    private fun withEntry(
        arguments: Map<*, *>,
        result: MethodChannel.Result,
        operation: (SurfaceEntry) -> Unit,
    ) {
        val textureId = boundedLong(arguments["textureId"], 0, Long.MAX_VALUE)
        val entry = entries[textureId]
            ?: throw LiveTextureException("unknown_texture", "Texture identifier is stale or unknown.")
        renderHandler.post {
            try {
                operation(entry)
                enqueueRedraw(entry) { error ->
                    mainHandler.post {
                        if (error == null) {
                            result.success(null)
                        } else {
                            result.error(error.code, error.message, null)
                        }
                    }
                }
            } catch (error: LiveTextureException) {
                mainHandler.post { result.error(error.code, error.message, null) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("live_texture_failed", error.message ?: "Native preview failed.", null)
                }
            }
        }
    }

    private fun dispose(arguments: Map<*, *>, result: MethodChannel.Result) {
        val textureId = boundedLong(arguments["textureId"], 0, Long.MAX_VALUE)
        val entry = entries.remove(textureId)
        if (entry == null) {
            result.success(null)
            return
        }
        finishRedraw(entry, LiveTextureException("unknown_texture", "Texture was disposed before redraw."))
        renderHandler.post {
            mainHandler.post {
                try {
                    // Flutter's TextureRegistry must be mutated on the platform
                    // thread, even though queued canvas work is serialized on
                    // the render thread.
                    entry.producer.release()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("live_texture_failed", error.message ?: "Texture release failed.", null)
                }
            }
        }
    }

    private fun requestRedraw(
        entry: SurfaceEntry,
        completion: ((LiveTextureException?) -> Unit)? = null,
    ) {
        renderHandler.post {
            enqueueRedraw(entry, completion)
        }
    }

    /** Coalesce native surface updates to at most one submission per display frame. */
    private fun enqueueRedraw(
        entry: SurfaceEntry,
        completion: ((LiveTextureException?) -> Unit)?,
    ) {
        if (entries[entry.textureId] !== entry) {
            completion?.invoke(LiveTextureException("unknown_texture", "Texture identifier is stale or unknown."))
            return
        }
        val shouldSchedule = synchronized(entry.lock) {
            if (completion != null) entry.pendingRedrawCompletions += completion
            if (entry.redrawScheduled) {
                false
            } else {
                entry.redrawScheduled = true
                true
            }
        }
        if (!shouldSchedule) return

        mainHandler.post {
            if (closed || entries[entry.textureId] !== entry) {
                finishRedraw(entry, LiveTextureException("unknown_texture", "Texture is no longer available."))
                return@post
            }
            Choreographer.getInstance().postFrameCallback {
                renderHandler.post {
                    val completions = synchronized(entry.lock) {
                        entry.redrawScheduled = false
                        entry.pendingRedrawCompletions.toList().also {
                            entry.pendingRedrawCompletions.clear()
                        }
                    }
                    val error = try {
                        if (closed || entries[entry.textureId] !== entry) {
                            throw LiveTextureException("unknown_texture", "Texture is no longer available.")
                        }
                        drawSurface(entry)
                        null
                    } catch (failure: LiveTextureException) {
                        failure
                    } catch (failure: Exception) {
                        LiveTextureException(
                            "live_texture_failed",
                            failure.message ?: "Native preview failed.",
                        )
                    }
                    mainHandler.post {
                        if (error == null && !closed && entries[entry.textureId] === entry) {
                            entry.producer.scheduleFrame()
                        }
                        completions.forEach { it(error) }
                    }
                }
            }
        }
    }

    private fun finishRedraw(entry: SurfaceEntry, error: LiveTextureException) {
        val completions = synchronized(entry.lock) {
            entry.redrawScheduled = false
            entry.pendingRedrawCompletions.toList().also { entry.pendingRedrawCompletions.clear() }
        }
        completions.forEach { it(error) }
    }

    /** Apply a bounded packet group and record each affected node only once. */
    private fun applyDabs(entry: SurfaceEntry, dabs: List<LiveDab>) {
        val affectedBatches = LinkedHashSet<RenderBatchKey>()
        synchronized(entry.lock) {
            for (dab in dabs) {
                val previous = entry.dabs[dab.key]
                if (previous != null) {
                    if (previous != dab) {
                        putDab(entry, dab)
                        affectedBatches += dab.batchKey()
                    }
                } else {
                    if (entry.dabs.size >= MAX_RETAINED_DABS) {
                        val predicted = entry.dabs.entries.firstOrNull { it.value.phase == PHASE_PREDICTED }
                        if (predicted != null) {
                            removeDab(entry, predicted.key)
                            affectedBatches += predicted.value.batchKey()
                        } else if (dab.phase == PHASE_PREDICTED) {
                            continue
                        } else {
                            throw LiveTextureException("queue_full", "Confirmed preview buffer is full.")
                        }
                    }
                    putDab(entry, dab)
                    affectedBatches += dab.batchKey()
                }
            }
        }
        rebuildRenderBatches(entry, affectedBatches)
    }

    /** Draw with Surface.lockHardwareCanvas; no texture pixels cross the channel. */
    private fun drawSurface(entry: SurfaceEntry) {
        val surface = entry.producer.surface
        if (!surface.isValid) {
            throw LiveTextureException("surface_unavailable", "Flutter surface is unavailable.")
        }
        val canvas = try {
            surface.lockHardwareCanvas()
        } catch (error: Exception) {
            throw LiveTextureException("hardware_canvas_unavailable", error.message ?: "Hardware canvas unavailable.")
        }
        try {
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
            synchronized(entry.lock) {
                for (renderBatch in entry.renderBatches.values) {
                    canvas.drawRenderNode(renderBatch)
                }
            }
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        val closingEntries = entries.values.toList()
        entries.clear()
        closingEntries.forEach { entry ->
            finishRedraw(entry, LiveTextureException("registry_closed", "Registry closed before redraw."))
        }
        renderHandler.post {
            mainHandler.post {
                closingEntries.forEach { it.producer.release() }
                renderThread.quitSafely()
            }
        }
    }

    private data class SurfaceEntry(
        val producer: TextureRegistry.SurfaceProducer,
        val textureId: Long,
        val width: Int,
        val height: Int,
        val lock: Any = Any(),
        val transform: Matrix = Matrix(),
        val dabs: LinkedHashMap<DabKey, LiveDab> = LinkedHashMap(),
        val dabsByBatch: LinkedHashMap<RenderBatchKey, LinkedHashMap<DabKey, LiveDab>> = LinkedHashMap(),
        val renderBatches: LinkedHashMap<RenderBatchKey, RenderNode> = LinkedHashMap(),
        val pendingRedrawCompletions: MutableList<(LiveTextureException?) -> Unit> = ArrayList(),
        var redrawScheduled: Boolean = false,
        var generation: Long = 0,
    )

    private data class DabKey(
        val high: Long,
        val low: Long,
        val sequence: Long,
        val dabIndex: Long,
    )

    private data class RenderBatchKey(
        val strokeHigh: Long,
        val strokeLow: Long,
        val sequenceGroup: Long,
        val dabGroup: Long,
    )

    private data class LiveDab(
        val key: DabKey,
        val x: Float,
        val y: Float,
        val radius: Float,
        val opacity: Float,
        val red: Int,
        val green: Int,
        val blue: Int,
        val alpha: Int,
        val phase: Int,
    )

    /** Re-record only bounded sequence groups affected by a packet. */
    private fun rebuildRenderBatches(
        entry: SurfaceEntry,
        affected: Set<RenderBatchKey>? = null,
    ) {
        synchronized(entry.lock) {
            val keys = affected ?: LinkedHashSet<RenderBatchKey>().apply {
                addAll(entry.renderBatches.keys)
                addAll(entry.dabsByBatch.keys)
            }
            for (key in keys) {
                val group = entry.dabsByBatch[key]?.values
                if (group.isNullOrEmpty()) {
                    entry.renderBatches.remove(key)
                    continue
                }
                val renderBatch =
                    entry.renderBatches[key]
                        ?: RenderNode("ink-${key.strokeHigh}-${key.strokeLow}-${key.sequenceGroup}-${key.dabGroup}")
                renderBatch.setPosition(0, 0, entry.width, entry.height)
                val canvas = renderBatch.beginRecording(entry.width, entry.height)
                canvas.concat(entry.transform)
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
                for (dab in group) {
                    paint.color = Color.rgb(dab.red, dab.green, dab.blue)
                    paint.alpha = (dab.alpha * dab.opacity).toInt().coerceIn(0, 255)
                    canvas.drawCircle(dab.x, dab.y, dab.radius, paint)
                }
                renderBatch.endRecording()
                entry.renderBatches[key] = renderBatch
            }
        }
    }

    private fun LiveDab.batchKey(): RenderBatchKey = RenderBatchKey(
        strokeHigh = key.high,
        strokeLow = key.low,
        sequenceGroup = key.sequence / RENDER_BATCH_SEQUENCE_COUNT,
        dabGroup = key.dabIndex / RENDER_BATCH_DAB_COUNT,
    )

    private fun putDab(entry: SurfaceEntry, dab: LiveDab) {
        entry.dabs[dab.key] = dab
        entry.dabsByBatch.getOrPut(dab.batchKey()) { LinkedHashMap() }[dab.key] = dab
    }

    private fun removeDab(entry: SurfaceEntry, key: DabKey): LiveDab? {
        val removed = entry.dabs.remove(key) ?: return null
        val batchKey = removed.batchKey()
        val batch = entry.dabsByBatch[batchKey]
        batch?.remove(key)
        if (batch.isNullOrEmpty()) entry.dabsByBatch.remove(batchKey)
        return removed
    }

    private fun decodePacket(packet: ByteArray): List<LiveDab> {
        if (packet.size < HEADER_BYTES) throw LiveTextureException("invalid_packet", "Dab packet is truncated.")
        val input = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        val version = input.getShort(0).toInt() and 0xffff
        val flags = input.getShort(2).toInt() and 0xffff
        val count = input.getInt(4)
        if (version != PACKET_VERSION || flags != 0 || count < 0 || count > MAX_RECORDS_PER_PACKET ||
            packet.size != HEADER_BYTES + count * RECORD_BYTES
        ) {
            throw LiveTextureException("invalid_packet", "Dab packet header or length is invalid.")
        }
        val records = ArrayList<LiveDab>(count)
        for (index in 0 until count) {
            val offset = HEADER_BYTES + index * RECORD_BYTES
            val x = input.getFloat(offset + 24)
            val y = input.getFloat(offset + 28)
            val radius = input.getFloat(offset + 32)
            val opacity = input.getFloat(offset + 36)
            val rotation = input.getFloat(offset + 40)
            val phase = input.get(offset + 44).toInt() and 0xff
            if (!x.isFinite() || !y.isFinite() || !radius.isFinite() || !opacity.isFinite() || !rotation.isFinite() ||
                radius < 0f || radius > MAX_RADIUS || opacity < 0f || opacity > 1f || phase !in 0..2
            ) {
                throw LiveTextureException("invalid_dab", "Dab contains an invalid value.")
            }
            for (reserved in offset + 49 until offset + RECORD_BYTES) {
                if (input.get(reserved).toInt() != 0) {
                    throw LiveTextureException("invalid_packet", "Reserved dab bytes must be zero.")
                }
            }
            records += LiveDab(
                key = DabKey(
                    high = input.getLong(offset + 8),
                    low = input.getLong(offset),
                    sequence = input.getInt(offset + 16).toLong() and 0xffffffffL,
                    dabIndex = input.getInt(offset + 20).toLong() and 0xffffffffL,
                ),
                x = x,
                y = y,
                radius = radius,
                opacity = opacity,
                red = input.get(offset + 45).toInt() and 0xff,
                green = input.get(offset + 46).toInt() and 0xff,
                blue = input.get(offset + 47).toInt() and 0xff,
                alpha = input.get(offset + 48).toInt() and 0xff,
                phase = phase,
            )
        }
        return records
    }

    private fun strokeKey(value: Any?): Pair<Long, Long> {
        val text = value as? String
            ?: throw LiveTextureException("invalid_argument", "Stroke identifier must be a 32-digit hex string.")
        if (text.length != 32 || text.any { it.digitToIntOrNull(16) == null }) {
            throw LiveTextureException("invalid_argument", "Stroke identifier must be a 32-digit hex string.")
        }
        val high = text.substring(0, 16).toULong(16).toLong()
        val low = text.substring(16, 32).toULong(16).toLong()
        return high to low
    }

    private fun floatMatrix(value: Any?): FloatArray {
        val list = value as? List<*>
            ?: throw LiveTextureException("invalid_argument", "Viewport matrix is missing.")
        if (list.size != 6) throw LiveTextureException("invalid_argument", "Viewport matrix must have six values.")
        val numbers = list.map {
            val number = (it as? Number)?.toDouble()
                ?: throw LiveTextureException("invalid_argument", "Viewport values must be numbers.")
            if (!number.isFinite() || number < -MAX_TRANSFORM || number > MAX_TRANSFORM) {
                throw LiveTextureException("invalid_argument", "Viewport value is outside its bound.")
            }
            number.toFloat()
        }
        return floatArrayOf(numbers[0], numbers[2], numbers[4], numbers[1], numbers[3], numbers[5], 0f, 0f, 1f)
    }

    private fun boundedInt(value: Any?, minimum: Int, maximum: Int): Int {
        val number = value as? Number
            ?: throw LiveTextureException("invalid_argument", "Dimension must be an integer.")
        val longValue = number.toLong()
        if (number.toDouble() != longValue.toDouble() || longValue < minimum || longValue > maximum) {
            throw LiveTextureException("invalid_argument", "Dimension is outside its bound.")
        }
        return longValue.toInt()
    }

    private fun boundedLong(value: Any?, minimum: Long, maximum: Long): Long {
        val number = value as? Number
            ?: throw LiveTextureException("invalid_argument", "Value must be an integer.")
        val result = number.toLong()
        if (number.toDouble() != result.toDouble() || result < minimum || result > maximum) {
            throw LiveTextureException("invalid_argument", "Value is outside its bound.")
        }
        return result
    }

    private class LiveTextureException(val code: String, override val message: String) : Exception(message)

    companion object {
        private const val PACKET_VERSION = 3
        private const val HEADER_BYTES = 8
        private const val RECORD_BYTES = 56
        private const val MAX_RECORDS_PER_PACKET = 2048
        private const val MAX_RENDER_PACKETS_PER_BATCH = 4
        private const val MAX_RETAINED_DABS = 65_536
        private const val MAX_DIMENSION = 8192
        // SurfaceProducer may rotate three GPU buffers. Keep total backing
        // storage under the 256 MiB native preview budget.
        private const val MAX_SURFACE_BYTES = 85_333_333L
        private const val RENDER_BATCH_SEQUENCE_COUNT = 8L
        private const val RENDER_BATCH_DAB_COUNT = 64L
        private const val MAX_RADIUS = 131_072f
        private const val MAX_TRANSFORM = 1_000_000.0
        private const val PHASE_PREDICTED = 0
    }
}
