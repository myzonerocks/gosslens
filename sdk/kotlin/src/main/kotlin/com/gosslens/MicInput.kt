package com.gosslens

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Feeds the device microphone into the session: the web SDK's GossMicInput, brought here so
 * practice, live and capture do not each write their own float conversion. The engine resamples
 * whatever rate the device grants, so this submits the granted rate rather than the requested one.
 */
class GossMicInput(
    private val engine: GossEngine,
    private val session: GossSession,
    private val sampleRate: Int = 48_000,
) {
    private var record: AudioRecord? = null
    private var reader: Thread? = null
    @Volatile private var running = false

    /**
     * Starts the capture thread. The caller must already hold RECORD_AUDIO; this deliberately does
     * not request it, because the app owns that policy and a call may already hold the microphone.
     * Returns false when the platform refuses to open a recorder.
     */
    fun start(): Boolean {
        if (running) return true
        val minBytes = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
        )
        if (minBytes <= 0) return false
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_FLOAT,
                minBytes * 2,
            )
        } catch (_: SecurityException) {
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return false
        }
        // The rate the platform granted, which is not always the one asked for.
        val granted = rec.sampleRate
        val frames = FRAMES_PER_READ
        // One direct buffer for the life of the capture, so a read every few milliseconds
        // allocates nothing.
        val buffer = ByteBuffer.allocateDirect(frames * 4).order(ByteOrder.nativeOrder())
        val floats = FloatArray(frames)
        rec.startRecording()
        record = rec
        running = true
        reader = Thread {
            var at = 0L
            while (running) {
                val read = rec.read(floats, 0, frames, AudioRecord.READ_BLOCKING)
                if (read <= 0) continue
                buffer.clear()
                buffer.asFloatBuffer().put(floats, 0, read)
                val stamp = at * 1_000_000L / granted
                engine.submitAudio(session, buffer, read, granted, 1, stamp)
                at += read
            }
        }.also { it.isDaemon = true; it.start() }
        return true
    }

    fun stop() {
        if (!running) return
        running = false
        reader?.join(500)
        reader = null
        record?.let {
            it.stop()
            it.release()
        }
        record = null
    }

    private companion object {
        const val FRAMES_PER_READ = 1024
    }
}
