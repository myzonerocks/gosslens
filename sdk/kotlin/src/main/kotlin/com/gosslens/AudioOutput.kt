package com.gosslens

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Routes the lens mixer to the device speaker. The pull is graph-thread
 * only, so [pump] runs in the frame loop and fills a ring a writer
 * thread drains into a streaming [AudioTrack]; underrun plays silence.
 */
class GossAudioOutput(private val session: GossSession) {
    private val ring = ShortArray(RING_FRAMES)
    private var readIndex = 0
    private var writeIndex = 0
    private val lock = Object()
    private val pullBuffer: ByteBuffer =
        ByteBuffer.allocateDirect(PULL_FRAMES * 2).order(ByteOrder.nativeOrder())
    private val chunk = ShortArray(CHUNK_FRAMES)
    private var track: AudioTrack? = null
    private var writer: Thread? = null
    @Volatile private var running = false

    /** Starts the platform track and its writer thread. */
    fun start() {
        if (track != null) return
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
        track = t
        running = true
        writer = Thread {
            while (running) {
                var filled = 0
                synchronized(lock) {
                    while (filled < chunk.size && readIndex != writeIndex) {
                        chunk[filled] = ring[readIndex]
                        readIndex = (readIndex + 1) % RING_FRAMES
                        filled += 1
                    }
                }
                while (filled < chunk.size) {
                    chunk[filled] = 0
                    filled += 1
                }
                t.write(chunk, 0, chunk.size)
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
        val shorts = pullBuffer.asShortBuffer()
        synchronized(lock) {
            for (i in 0 until count) {
                val next = (writeIndex + 1) % RING_FRAMES
                if (next == readIndex) break
                ring[writeIndex] = shorts.get(i)
                writeIndex = next
            }
        }
    }

    /** Stops the writer thread and releases the platform track. */
    fun stop() {
        running = false
        writer?.join(500)
        writer = null
        track?.stop()
        track?.release()
        track = null
    }

    companion object {
        /** The lens mixer's fixed output format. */
        const val SAMPLE_RATE = 48_000
        private const val RING_FRAMES = 16_384
        private const val PULL_FRAMES = 4_096
        private const val CHUNK_FRAMES = 960
    }
}
