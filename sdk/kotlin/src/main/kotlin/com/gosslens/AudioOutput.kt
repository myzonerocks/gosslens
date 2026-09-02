package com.gosslens

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Routes the lens mixer to the device speaker. The pull is graph-thread
 * only, so [pump] runs in the frame loop and fills a ring a writer
 * thread drains into a streaming [AudioTrack]; underrun plays silence.
 */
class GossAudioOutput(private val session: GossSession) {
    /** The state the writer thread and the drop safety net share. It holds
     * no reference to the wrapper: a running thread is a GC root, so a
     * thread capturing the wrapper would pin it (and its session) forever
     * and the platform track could never be reclaimed. */
    private class Playback {
        val ring = ShortArray(RING_FRAMES)
        var readIndex = 0
        var writeIndex = 0
        val lock = Object()
        val chunk = ShortArray(CHUNK_FRAMES)
        var track: AudioTrack? = null
        var writer: Thread? = null
        @Volatile var running = false

        fun stop() {
            running = false
            writer?.join(500)
            writer = null
            track?.stop()
            track?.release()
            track = null
        }
    }

    private val playback = Playback()
    private val pullBuffer: ByteBuffer =
        ByteBuffer.allocateDirect(PULL_FRAMES * 2).order(ByteOrder.nativeOrder())
    // One view over the pull buffer, created once so pump() allocates
    // nothing per frame.
    private val pullShorts = pullBuffer.asShortBuffer()

    /** Releases the track and thread if the wrapper is dropped without
     * stop(); the action holds only the playback state, never the wrapper. */
    private val cleanable: Any? =
        if (Build.VERSION.SDK_INT >= 33) NativeCleaner.register(this, PlaybackStopper(playback)) else null

    private class PlaybackStopper(private val playback: Playback) : Runnable {
        override fun run() = playback.stop()
    }

    /** Starts the platform track and its writer thread. */
    fun start() {
        if (playback.track != null) return
        val minBytes = AudioTrack.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBytes, CHUNK_FRAMES * 4))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        t.play()
        val p = playback
        p.track = t
        p.running = true
        p.writer = Thread {
            while (p.running) {
                var filled = 0
                synchronized(p.lock) {
                    while (filled < p.chunk.size && p.readIndex != p.writeIndex) {
                        p.chunk[filled] = p.ring[p.readIndex]
                        p.readIndex = (p.readIndex + 1) % RING_FRAMES
                        filled += 1
                    }
                }
                while (filled < p.chunk.size) {
                    p.chunk[filled] = 0
                    filled += 1
                }
                t.write(p.chunk, 0, p.chunk.size)
            }
        }.also { it.name = "goss-audio-out"; it.start() }
    }

    /**
     * Pulls the next mixer block into the ring. Call once per frame
     * from the same thread that ticks the lens.
     */
    fun pump(frames: Int = 800) {
        val count = minOf(frames, PULL_FRAMES)
        pullBuffer.clear()
        if (!session.pullAudio(pullBuffer, count)) return
        val p = playback
        synchronized(p.lock) {
            for (i in 0 until count) {
                val next = (p.writeIndex + 1) % RING_FRAMES
                if (next == p.readIndex) break
                p.ring[p.writeIndex] = pullShorts.get(i)
                p.writeIndex = next
            }
        }
    }

    /** Stops the writer thread and releases the platform track. Safe to
     * call more than once; the drop safety net runs the same stop. */
    fun stop() = playback.stop()

    companion object {
        /** The lens mixer's fixed output format. */
        const val SAMPLE_RATE = 48_000
        private const val RING_FRAMES = 16_384
        private const val PULL_FRAMES = 4_096
        private const val CHUNK_FRAMES = 960
    }
}
