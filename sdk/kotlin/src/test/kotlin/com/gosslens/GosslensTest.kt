package com.gosslens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The values the C ABI freezes and the pure helpers that pack them, at the
 * TypeScript suite's scope. Nothing here loads the native library, so a wrong
 * constant fails on a laptop rather than on a device.
 */
class GosslensTest {
    @Test
    fun `the landmark count matches the frozen ABI`() {
        assertEquals(478, Gosslens.FACE_LANDMARK_COUNT)
    }

    @Test
    fun `the colour and range constants match the header's numbering`() {
        assertEquals(0, Gosslens.COLOR_BT601)
        assertEquals(1, Gosslens.COLOR_BT709)
        assertEquals(2, Gosslens.COLOR_BT2020)
        assertEquals(0, Gosslens.RANGE_VIDEO)
        assertEquals(1, Gosslens.RANGE_FULL)
    }

    @Test
    fun `an upright unmirrored frame carries no flags`() {
        assertEquals(0, GossFlags.flagsFor(0, false))
    }

    @Test
    fun `a rotation packs as quarter turns above the shift`() {
        assertEquals(1 shl GossFlags.ROTATION_SHIFT, GossFlags.flagsFor(90, false))
        assertEquals(2 shl GossFlags.ROTATION_SHIFT, GossFlags.flagsFor(180, false))
        assertEquals(3 shl GossFlags.ROTATION_SHIFT, GossFlags.flagsFor(270, false))
    }

    @Test
    fun `a full turn is the same as none, and the quarter turns wrap`() {
        assertEquals(GossFlags.flagsFor(0, false), GossFlags.flagsFor(360, false))
        assertEquals(GossFlags.flagsFor(90, false), GossFlags.flagsFor(450, false))
    }

    @Test
    fun `a mirror rides beside the rotation rather than over it`() {
        val mirrored = GossFlags.flagsFor(90, true)
        assertTrue(mirrored and GossFlags.FLAG_MIRROR != 0)
        assertEquals(1 shl GossFlags.ROTATION_SHIFT, mirrored and (0x3 shl GossFlags.ROTATION_SHIFT))
    }

    @Test
    fun `a node state decodes in the order the ABI numbers it`() {
        assertEquals(GossSession.NodeState.READY, GossSession.NodeState.entries[0])
        assertEquals(GossSession.NodeState.DEGRADED, GossSession.NodeState.entries[1])
        assertEquals(GossSession.NodeState.FAILED, GossSession.NodeState.entries[2])
    }

    @Test
    fun `a node reason decodes in the order the ABI numbers it`() {
        val expected = listOf(
            "NONE", "OUT_OF_MEMORY", "ASSET_MISSING", "ASSET_MALFORMED",
            "ASSET_TOO_LARGE", "SHADER_MISSING", "SHADER_LINK_FAILED",
            "MODEL_REJECTED", "MODEL_UNSUPPORTED", "CAPABILITY_UNAVAILABLE",
            "CONSTRAINT_FAILED",
        )
        assertEquals(expected, GossSession.NodeReason.entries.map { it.name })
    }

    @Test
    fun `an unknown degrade rung reads as passthrough, not as full`() {
        assertEquals(DegradeLevel.FULL, DegradeLevel.from(0))
        assertEquals(DegradeLevel.PASSTHROUGH, DegradeLevel.from(4))
        // The conservative assumption: a rung this build does not know is the
        // cheapest one, never the most expensive.
        assertEquals(DegradeLevel.PASSTHROUGH, DegradeLevel.from(99))
    }

    @Test
    fun `thermal states carry the engine's own numbering`() {
        assertEquals(0, Thermal.NOMINAL.raw)
        assertEquals(3, Thermal.CRITICAL.raw)
        assertEquals(Thermal.SERIOUS, Thermal.from(2))
        assertEquals(Thermal.NOMINAL, Thermal.from(42))
    }
}
