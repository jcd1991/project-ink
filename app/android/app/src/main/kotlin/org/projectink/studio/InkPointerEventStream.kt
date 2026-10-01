// SPDX-License-Identifier: MPL-2.0
package org.projectink.studio

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Binary packet stream consumed by the Dart canvas input router. */
object InkPointerEventStream : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun publish(packet: ByteArray): Boolean {
        if (packet.isEmpty() || sink == null) return false
        mainHandler.post { sink?.success(packet) }
        return true
    }
}

/** Readiness signal used to arbitrate generic stylus fallback during startup. */
object InkPointerStatusEventStream : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        mainHandler.post { sink?.success("ready") }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}

/** Discrete S Pen actions kept separate from the high-frequency sample stream. */
object InkPencilCommandEventStream : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun publish(command: String): Boolean {
        if (sink == null) return false
        mainHandler.post { sink?.success(command) }
        return true
    }
}
