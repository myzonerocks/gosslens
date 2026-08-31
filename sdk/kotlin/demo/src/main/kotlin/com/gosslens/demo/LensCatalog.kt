package com.gosslens.demo

import com.gosslens.Gosslens

// The asset-free post lenses the filter picker swaps between, and the
// virtual-background composite, each an inline manifest activated straight
// from these bytes. The picker order matches filterNames below; None
// carries no manifest and deactivates the post lens entirely.
object LensCatalog {
    val filterNames = listOf("None", "Blur", "Grade", "Bloom")

    private val blur =
        """{"glf":"1.0","id":"com.gosslens.demo.blur","version":"1.0.0","display_name":"Blur","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"blur","type":"blur.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[]}"""

    private val grade =
        """{"glf":"1.0","id":"com.gosslens.demo.grade","version":"1.0.0","display_name":"Grade","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"grade","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"invert":1.0}}],"triggers":[]}"""

    private val bloom =
        """{"glf":"1.0","id":"com.gosslens.demo.bloom","version":"1.0.0","display_name":"Bloom","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"bloom","type":"bloom.pass","inputs":{"frame":"camera"},"params":{},"bloom":{"threshold":0.6,"intensity":0.8}}],"triggers":[]}"""

    // Composites the background against the in-engine person mask, so the
    // segmenter's subject stays sharp while the background is replaced.
    private val virtualBackground =
        """{"glf":"1.0","id":"com.gosslens.demo.virtual-background","version":"1.0.0","display_name":"Virtual Background","engine_compat":">=0.5","capabilities":["segmentation"],"parameters":[],"nodes":[{"id":"background","type":"blend.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[]}"""

    /** The manifest for a filter index, or null for None (no post lens). */
    fun filterManifest(index: Int): ByteArray? = when (index) {
        1 -> blur
        2 -> grade
        3 -> bloom
        else -> null
    }?.toByteArray(Charsets.UTF_8)

    fun virtualBackgroundManifest(): ByteArray = virtualBackground.toByteArray(Charsets.UTF_8)

    // The in-engine selfie segmenter model, shipped as an app asset. When it
    // is absent at runtime the virtual-background toggle degrades rather than
    // crashing.
    const val SEGMENTER_ASSET = "selfie_segmenter.tflite"

    /** The canned gesture class the hand result carries, as a short label. */
    fun gestureName(gesture: Int): String = when (gesture) {
        Gosslens.GESTURE_CLOSED_FIST -> "fist"
        Gosslens.GESTURE_OPEN_PALM -> "open palm"
        Gosslens.GESTURE_POINTING_UP -> "point up"
        Gosslens.GESTURE_THUMB_DOWN -> "thumb down"
        Gosslens.GESTURE_THUMB_UP -> "thumb up"
        Gosslens.GESTURE_VICTORY -> "victory"
        Gosslens.GESTURE_ILOVEYOU -> "love"
        else -> "none"
    }
}
