package com.gosslens

import com.google.ar.core.Camera
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Feeds ARCore's world into the session as GossWorldSource does from ARKit: the camera pose and
 * projection, the tracked planes, the anchors and the light, one submit per frame the host hands
 * over. ARCore is compile-only here, so an app that never wears a world lens carries none of it.
 */
class GossARCoreWorldSource(private val session: GossSession) {
    private val stateBuffer = ByteBuffer.allocateDirect(STATE_BYTES).order(ByteOrder.nativeOrder())
    private val lightBuffer = ByteBuffer.allocateDirect(LIGHT_BYTES).order(ByteOrder.nativeOrder())
    private var planesBuffer = ByteBuffer.allocateDirect(PLANE_BYTES * 8).order(ByteOrder.nativeOrder())
    private var anchorsBuffer = ByteBuffer.allocateDirect(ANCHOR_BYTES * 8).order(ByteOrder.nativeOrder())
    private val matrix = FloatArray(16)

    /** Submits one ARCore frame: its pose, projection, planes, anchors and light. */
    fun onFrame(frame: Frame) {
        val camera: Camera = frame.camera
        stateBuffer.clear()
        stateBuffer.putInt(trackingState(camera.trackingState))
        camera.displayOrientedPose.toMatrix(matrix, 0)
        for (value in matrix) stateBuffer.putFloat(value)
        camera.getProjectionMatrix(matrix, 0, NEAR, FAR)
        for (value in matrix) stateBuffer.putFloat(value)
        stateBuffer.putInt(0)
        stateBuffer.putLong(frame.timestamp / 1_000)
        val planes = frame.getUpdatedTrackables(Plane::class.java).filter { it.trackingState == TrackingState.TRACKING }
        if (planesBuffer.capacity() < planes.size * PLANE_BYTES) {
            planesBuffer = ByteBuffer.allocateDirect(planes.size * PLANE_BYTES).order(ByteOrder.nativeOrder())
        }
        planesBuffer.clear()
        for (plane in planes) {
            planesBuffer.putLong(plane.hashCode().toLong())
            plane.centerPose.toMatrix(matrix, 0)
            for (value in matrix) planesBuffer.putFloat(value)
            planesBuffer.putFloat(plane.extentX)
            planesBuffer.putFloat(plane.extentZ)
            planesBuffer.putInt(planeClass(plane.type))
            planesBuffer.putInt(0)
        }
        val anchors = frame.updatedAnchors.filter { it.trackingState == TrackingState.TRACKING }
        if (anchorsBuffer.capacity() < anchors.size * ANCHOR_BYTES) {
            anchorsBuffer = ByteBuffer.allocateDirect(anchors.size * ANCHOR_BYTES).order(ByteOrder.nativeOrder())
        }
        anchorsBuffer.clear()
        for (anchor in anchors) {
            anchorsBuffer.putLong(anchor.hashCode().toLong())
            anchor.pose.toMatrix(matrix, 0)
            for (value in matrix) anchorsBuffer.putFloat(value)
        }
        lightBuffer.clear()
        lightBuffer.putFloat(frame.lightEstimate.pixelIntensity)
        lightBuffer.putFloat(0f)
        session.submitWorld(stateBuffer, planesBuffer, planes.size, anchorsBuffer, anchors.size, lightBuffer)
    }

    /** Tells the session the world is gone, so a world lens falls back to its defined behaviour. */
    fun stop() {
        stateBuffer.clear()
        for (i in 0 until STATE_BYTES) stateBuffer.put(0)
        lightBuffer.clear()
        lightBuffer.putFloat(0f)
        lightBuffer.putFloat(0f)
        session.submitWorld(stateBuffer, planesBuffer, 0, anchorsBuffer, 0, lightBuffer)
    }

    private fun trackingState(state: TrackingState): Int = when (state) {
        TrackingState.TRACKING -> 2
        TrackingState.PAUSED -> 3
        TrackingState.STOPPED -> 0
    }

    private fun planeClass(type: Plane.Type): Int = when (type) {
        Plane.Type.HORIZONTAL_UPWARD_FACING -> 1
        Plane.Type.VERTICAL -> 2
        Plane.Type.HORIZONTAL_DOWNWARD_FACING -> 3
    }

    private companion object {
        /** The ABI's world structs: the state, a plane, an anchor and the light, in bytes. */
        const val STATE_BYTES = 144
        const val PLANE_BYTES = 88
        const val ANCHOR_BYTES = 72
        const val LIGHT_BYTES = 8
        const val NEAR = 0.1f
        const val FAR = 100f
    }
}
