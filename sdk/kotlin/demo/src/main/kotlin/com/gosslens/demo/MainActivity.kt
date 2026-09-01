package com.gosslens.demo

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Choreographer
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView
import android.widget.ToggleButton
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.gosslens.GossAudioOutput
import com.gosslens.GossEngine
import com.gosslens.GossLensSignals
import com.gosslens.GossSession
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

// Live capture through CameraX into the engine, rendered by the core onto
// the SurfaceView, with the shared showcase controls layered over it: beauty
// sliders, tracking overlays, a lens filter picker, a virtual-background
// toggle, capture, and a front/back switch. NV12 planes go through the stated
// CPU copy path until the hardware buffer import lands.
class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private val tag = "GOSSDROID"
    private lateinit var surfaceView: SurfaceView
    private lateinit var overlay: FaceOverlayView
    private var engine: GossEngine? = null
    private var session: GossSession? = null
    private var audioOutput: GossAudioOutput? = null
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val uiExecutor by lazy { ContextCompat.getMainExecutor(this) }

    private var cameraFrames = 0
    private var renderedFrames = 0
    private var fpsWindowStart = 0L
    private var fpsWindowFrames = 0
    private var lastFrameNanos = 0L
    private var lastFps = 0.0
    private var lastReadoutMs = 0L
    private var captureState = "idle"
    private val lensSignals = GossLensSignals()

    // The showcase chrome. Built once for a normal launch; conformance mode
    // leaves them null and only stands the render path up.
    private var statusLine: TextView? = null
    private var trackingLine: TextView? = null
    private var vbToggle: ToggleButton? = null
    private var vbNote: TextView? = null
    private var capturePreview: ImageView? = null
    private var topBar: LinearLayout? = null
    private var bottomBar: LinearLayout? = null

    // The active-lens state the picker and the virtual-background toggle both
    // resolve through applyActiveLens; the toggle takes precedence while on.
    private var selectedFilter = 0
    private var virtualBackgroundOn = false

    // Ring depth 2: submits hop to the main thread (bgfx's contract), so
    // the analyzer refills the next slot while the prior one is in
    // flight. With both slots pending it drops the frame rather than
    // overwrite a buffer a pending submit will still read.
    private val yScratchRing = arrayOfNulls<ByteBuffer>(2)
    private val uvScratchRing = arrayOfNulls<ByteBuffer>(2)
    private var scratchRingIndex = 0
    private val pendingCopySubmits = java.util.concurrent.atomic.AtomicInteger(0)

    // Zero-copy is attempted until the device or stream refuses it once;
    // after that the stream stays on the declared copy path. Written from
    // the main thread (inside the hopped submit below), read from the
    // analyzer thread.
    @Volatile
    private var zeroCopyRefused = false

    // The front camera preview is always mirrored for a selfie view; the back
    // camera never is. Every consumer - both submit paths and the overlay -
    // reads this one decision, updated when the camera switches. Read from the
    // analyzer thread.
    @Volatile
    private var mirrored = true
    private var facingFront = true
    private var cameraProvider: ProcessCameraProvider? = null
    private var imageAnalysis: ImageAnalysis? = null

    // The conformance run reuses this same real window/renderer setup,
    // just feeding a fixed corpus frame instead of live camera - see
    // ConformanceRunner. Set via `am start --ez GossConformance true`, the
    // direct equivalent of the ios SDK's -GossConformance launch argument.
    private var conformanceMode = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        conformanceMode = intent.getBooleanExtra("GossConformance", false)
        val root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        overlay = FaceOverlayView(this)
        root.addView(surfaceView)
        root.addView(overlay)
        if (!conformanceMode) setupControls(root)
        setContentView(root)
        surfaceView.holder.addCallback(this)

        if (!conformanceMode && ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            captureState = "denied"
            Log.i(tag, "capture state denied")
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        val width = surfaceView.width
        val height = surfaceView.height
        if (conformanceMode) {
            ConformanceRunner.run(this, holder.surface, width, height)
            return
        }
        val created = GossEngine.create()
        created.initRenderer(holder.surface, width, height)
        engine = created
        val createdSession = GossSession.create(created)
        session = createdSession

        // Lens sounds reach the speaker through AudioTrack; the render
        // tick pumps the mixer on the same thread that ticks the lens.
        val output = GossAudioOutput(createdSession)
        output.start()
        audioOutput = output
        Log.i(tag, "renderer up ${width}x$height")
        enableTracker(createdSession, "face_landmarker.task", "face") { b -> createdSession.enableFaceTracking(b, 0) }
        enableTracker(createdSession, "gesture_recognizer.task", "hand") { b -> createdSession.enableHandTracking(b, 0) }
        enableTracker(createdSession, "pose_landmarker_full.task", "pose") { b -> createdSession.enablePoseTracking(b, 0) }
        extractBeautyResources()?.let { resourceRoot ->
            if (createdSession.enableBeauty(resourceRoot)) {
                Log.i(tag, "beauty up")
            } else {
                Log.i(tag, "beauty unavailable in this build")
            }
        }
        applyActiveLens()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        }
        Choreographer.getInstance().postFrameCallback(::renderTick)
    }

    // Reads a model bundle asset into a direct buffer and stands its worker up,
    // logging the same plain state whether the bundle is present or not.
    private fun enableTracker(session: GossSession, asset: String, label: String, enable: (ByteBuffer) -> Boolean) {
        try {
            assets.open(asset).use { stream ->
                val bytes = stream.readBytes()
                val bundle = ByteBuffer.allocateDirect(bytes.size)
                bundle.put(bytes)
                bundle.flip()
                if (enable(bundle)) Log.i(tag, "$label tracking up") else Log.i(tag, "$label tracking unavailable in this build")
            }
        } catch (e: java.io.IOException) {
            Log.i(tag, "$label tracking bundle not present")
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        engine?.resize(width, height)
    }

    /** Rides the same result overlay.poll() just refreshed - ticking every
     * render frame regardless of whether that particular result was new
     * keeps the lens's own animation ramps advancing smoothly at display
     * refresh rate rather than at tracking cadence. */
    private fun tickLens(session: GossSession, dtUs: Int) {
        lensSignals.set(overlay.facePresent, overlay.handCount > 0, false, 0.0, 0.0, overlay.latestFaceResult.blendshapes)
        session.tickLens(dtUs, lensSignals)
        audioOutput?.pump()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        session?.close()
        engine?.close()
        audioOutput?.stop()
        audioOutput = null
        session = null
        engine = null
    }

    // Assets ship read-only inside the apk; the effects engine opens its
    // shader and lookup files with plain file i/o, so they need a real
    // path. Copied once per install, reused after.
    private fun extractBeautyResources(): String? {
        val resDir = java.io.File(filesDir, "res")
        if (!resDir.exists()) {
            val names = try { assets.list("res") } catch (e: java.io.IOException) { null }
            if (names.isNullOrEmpty()) return null
            resDir.mkdirs()
            for (name in names) {
                assets.open("res/$name").use { input ->
                    java.io.File(resDir, name).outputStream().use { output -> input.copyTo(output) }
                }
            }
        }
        return filesDir.absolutePath
    }

    // The showcase chrome: status and tracking readouts up top, overlay and
    // flip controls beside them, and the beauty sliders, filter picker,
    // background toggle, and capture button along the bottom. Both bars pad to
    // the system insets so nothing sits under the status or navigation area.
    private fun setupControls(root: FrameLayout) {
        val top = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
        }
        statusLine = readoutLabel().also { top.addView(it) }
        trackingLine = readoutLabel().also { top.addView(it) }
        topBar = top
        root.addView(top, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.TOP })

        val topRight = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(24, 24, 24, 24)
        }
        val overlayButton = ToggleButton(this)
        overlayButton.textOn = "Overlay on"
        overlayButton.textOff = "Overlay off"
        overlayButton.isChecked = true
        overlayButton.setOnCheckedChangeListener { _, checked ->
            overlay.visibility = if (checked) View.VISIBLE else View.GONE
        }
        topRight.addView(overlayButton)
        topRight.addView(Button(this).apply {
            text = "Flip"
            setOnClickListener { switchCamera() }
        })
        root.addView(topRight, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.TOP or Gravity.END })

        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
        }
        setupBeautyControls(bottom)
        bottom.addView(setupLensRow())
        bottomBar = bottom
        root.addView(bottom, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.BOTTOM })

        // A captured photo shows over everything until tapped away.
        val preview = ImageView(this)
        preview.visibility = View.GONE
        preview.setBackgroundColor(Color.BLACK)
        preview.setOnClickListener { preview.visibility = View.GONE }
        capturePreview = preview
        root.addView(preview, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        // Pad both bars clear of the status bar, navigation area, and any
        // display cutout so no control sits under system chrome.
        root.setOnApplyWindowInsetsListener { _, insets ->
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                topBar?.setPadding(24, 24 + bars.top, 24, 24)
                bottomBar?.setPadding(24, 24, 24, 24 + bars.bottom)
            } else {
                @Suppress("DEPRECATION")
                topBar?.setPadding(24, 24 + insets.systemWindowInsetTop, 24, 24)
                @Suppress("DEPRECATION")
                bottomBar?.setPadding(24, 24, 24, 24 + insets.systemWindowInsetBottom)
            }
            insets
        }
    }

    private fun readoutLabel(): TextView = TextView(this).apply {
        setTextColor(Color.WHITE)
        textSize = 12f
        maxLines = 1
        isSingleLine = true
        ellipsize = android.text.TextUtils.TruncateAt.END
    }

    // The filter picker (None/Blur/Grade/Bloom), the virtual-background
    // toggle with its degrade note, and the capture button, on one row.
    private fun setupLensRow(): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val picker = Spinner(this)
        picker.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, LensCatalog.filterNames)
        picker.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                selectedFilter = position
                applyActiveLens()
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        row.addView(picker)
        vbToggle = ToggleButton(this).apply {
            textOn = "Background on"
            textOff = "Background off"
            isChecked = false
            setOnCheckedChangeListener { _, checked -> toggleVirtualBackground(checked) }
        }
        row.addView(vbToggle)
        vbNote = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 11f
            maxLines = 1
            isSingleLine = true
        }
        row.addView(vbNote)
        row.addView(Button(this).apply {
            text = "Capture"
            setOnClickListener { capture() }
        })
        // If the segmenter model never shipped, the background toggle degrades
        // to disabled with a short note instead of failing at tap time.
        if (!assetExists(LensCatalog.SEGMENTER_ASSET)) {
            vbToggle?.isEnabled = false
            vbNote?.text = "no segmenter"
        }
        return row
    }

    private fun assetExists(name: String): Boolean = try {
        assets.open(name).close(); true
    } catch (e: java.io.IOException) { false }

    // Each slider reaches GossSession.setBeauty directly; the effect
    // composites into the live preview through the beauty chain.
    private fun setupBeautyControls(parent: LinearLayout) {
        val names = listOf("smooth", "whiten", "thin face", "big eye", "lipstick", "blush")
        for ((index, name) in names.withIndex()) {
            val rowView = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            rowView.addView(TextView(this).apply {
                text = name
                setTextColor(Color.WHITE)
                maxLines = 1
                isSingleLine = true
                layoutParams = LinearLayout.LayoutParams(160, LinearLayout.LayoutParams.WRAP_CONTENT)
            })
            rowView.addView(SeekBar(this).apply {
                max = 100
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                        session?.setBeauty(index, progress / 100f)
                    }
                    override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                    override fun onStopTrackingTouch(seekBar: SeekBar?) {}
                })
            })
            parent.addView(rowView)
        }
    }

    // Resolves the one active post lens: the virtual background takes
    // precedence while on, otherwise the picked filter, or none.
    private fun applyActiveLens() {
        val session = session ?: return
        if (virtualBackgroundOn) {
            session.activateLens(LensCatalog.virtualBackgroundManifest())
            return
        }
        val manifest = LensCatalog.filterManifest(selectedFilter)
        if (manifest == null) session.deactivateLens() else session.activateLens(manifest)
    }

    // Stands the in-engine segmenter up for the camera and composites a
    // background from the person mask. A missing or refused model degrades the
    // toggle to disabled with a note rather than crashing.
    private fun toggleVirtualBackground(on: Boolean) {
        val session = session ?: return
        if (on) {
            val model = loadSegmenterModel()
            if (model == null || !session.enableSegmentation(model, 2)) {
                Log.i(tag, "segmenter unavailable, virtual background off")
                virtualBackgroundOn = false
                vbToggle?.isChecked = false
                vbToggle?.isEnabled = false
                vbNote?.text = "no segmenter"
                return
            }
            virtualBackgroundOn = true
        } else {
            virtualBackgroundOn = false
            session.disableSegmentation()
        }
        applyActiveLens()
    }

    private fun loadSegmenterModel(): ByteBuffer? = try {
        assets.open(LensCatalog.SEGMENTER_ASSET).use { stream ->
            val bytes = stream.readBytes()
            ByteBuffer.allocateDirect(bytes.size).apply { put(bytes); flip() }
        }
    } catch (e: java.io.IOException) {
        null
    }

    // Renders the composited frame to a PNG, saves it, and shows it over the
    // preview until tapped away.
    private fun capture() {
        val engine = engine ?: return
        val png = engine.capturePhoto(session)
        if (png == null || png.isEmpty()) {
            Log.i(tag, "capture unavailable")
            return
        }
        val dir = getExternalFilesDir(null) ?: filesDir
        val file = File(dir, "capture-${System.currentTimeMillis()}.png")
        file.writeBytes(png)
        Log.i(tag, "capture saved ${file.absolutePath}")
        val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return
        capturePreview?.apply {
            setImageBitmap(bitmap)
            visibility = View.VISIBLE
        }
    }

    private fun switchCamera() {
        facingFront = !facingFront
        mirrored = facingFront
        bindCamera()
    }

    // PowerManager's thermal statuses collapse onto the engine's four
    // levels the same way the ios demo maps ProcessInfo.thermalState.
    private fun thermalLevel(): Int {
        if (android.os.Build.VERSION.SDK_INT < 29) return 0
        val power = getSystemService(android.os.PowerManager::class.java) ?: return 0
        return when (power.currentThermalStatus) {
            android.os.PowerManager.THERMAL_STATUS_NONE -> 0
            android.os.PowerManager.THERMAL_STATUS_LIGHT -> 1
            android.os.PowerManager.THERMAL_STATUS_MODERATE -> 2
            else -> 3
        }
    }

    private fun renderTick(frameTimeNanos: Long) {
        val engine = engine ?: return
        val frameTimeUs = if (lastFrameNanos == 0L) 0 else ((frameTimeNanos - lastFrameNanos) / 1000).toInt()
        lastFrameNanos = frameTimeNanos
        session?.reportFrame(frameTimeUs, thermalLevel())
        session?.let { overlay.poll(it) }
        session?.let { tickLens(it, frameTimeUs) }
        if (engine.renderFrame(session)) {
            renderedFrames += 1
            fpsWindowFrames += 1
        }

        val now = System.nanoTime() / 1_000_000
        if (fpsWindowStart == 0L) fpsWindowStart = now
        if (now - fpsWindowStart >= 2000) {
            lastFps = fpsWindowFrames * 1000.0 / (now - fpsWindowStart)
            Log.i(tag, "fps %.1f rendered %d camera %d".format(lastFps, renderedFrames, cameraFrames))
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
        if (now - lastReadoutMs >= 250) {
            updateReadouts()
            lastReadoutMs = now
        }
        Choreographer.getInstance().postFrameCallback(::renderTick)
    }

    // The two status lines: capture state, fps, and degrade level up top, then
    // the tracking readout (face presence, track id, gesture, fps) below it.
    private fun updateReadouts() {
        val session = session ?: return
        statusLine?.text = "capture %s  %.0f fps  degrade %d".format(captureState, lastFps, session.degradeLevel())
        val id = session.faceTrackId(0)?.toString() ?: "-"
        val gesture = LensCatalog.gestureName(overlay.handGesture)
        val present = if (overlay.facePresent) "yes" else "no"
        trackingLine?.text = "face %s  id:%s  gesture:%s  %.0f fps".format(present, id, gesture, lastFps)
    }

    private fun startCamera() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            cameraProvider = providerFuture.get()
            bindCamera()
        }, uiExecutor)
    }

    private fun bindCamera() {
        val provider = cameraProvider ?: return
        val analysis = imageAnalysis ?: buildAnalysis().also { imageAnalysis = it }
        provider.unbindAll()
        val selector = if (facingFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        provider.bindToLifecycle(this, selector, analysis)
    }

    private fun buildAnalysis(): ImageAnalysis {
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .build()
        analysis.setAnalyzer(analysisExecutor) { image ->
            image.use {
                val session = session ?: return@use

                // bgfx runs on the main thread only; every submit below
                // hops there, keeping its own frame data alive across
                // the hop instead of relying on this analyzer callback's
                // own buffers, which recycle once it returns.
                var zeroCopyAttempted = false
                if (!zeroCopyRefused && android.os.Build.VERSION.SDK_INT >= 28) {
                    val hardwareBuffer = it.image?.hardwareBuffer
                    if (hardwareBuffer != null) {
                        zeroCopyAttempted = true
                        val width = it.width
                        val height = it.height
                        val rotationDegrees = it.imageInfo.rotationDegrees
                        val timestampUs = it.imageInfo.timestamp / 1000
                        val mirror = mirrored
                        uiExecutor.execute {
                            val submitted = session.submitHardwareBuffer(
                                hardwareBuffer,
                                width, height,
                                rotationDegrees, mirror,
                                timestampUs = timestampUs,
                            )
                            hardwareBuffer.close()
                            if (submitted) {
                                cameraFrames += 1
                                if (cameraFrames == 1) {
                                    captureState = "running"
                                    Log.i(tag, "capture state running zero copy")
                                }
                            } else {
                                zeroCopyRefused = true
                                Log.i(tag, "zero copy refused, copy path takes over")
                            }
                        }
                    }
                }

                if (pendingCopySubmits.get() >= yScratchRing.size) return@use

                val y = it.planes[0]
                val u = it.planes[1]
                val v = it.planes[2]

                val slot = scratchRingIndex
                scratchRingIndex = (scratchRingIndex + 1) % yScratchRing.size

                val ySize = y.buffer.remaining()
                var yCopy = yScratchRing[slot]
                if (yCopy == null || yCopy.capacity() < ySize) {
                    yCopy = ByteBuffer.allocateDirect(ySize)
                    yScratchRing[slot] = yCopy
                }
                yCopy.clear()
                yCopy.put(y.buffer)
                yCopy.flip()

                val uvStride: Int
                var uvCopy = uvScratchRing[slot]
                if (u.pixelStride == 2) {
                    // Semi-planar already; the interleaved view starts
                    // at the u plane.
                    val uvSize = u.buffer.remaining()
                    if (uvCopy == null || uvCopy.capacity() < uvSize) {
                        uvCopy = ByteBuffer.allocateDirect(uvSize)
                        uvScratchRing[slot] = uvCopy
                    }
                    uvCopy.clear()
                    uvCopy.put(u.buffer)
                    uvCopy.flip()
                    uvStride = u.rowStride
                } else {
                    // Planar chroma, the emulator's layout: interleave
                    // u and v into one nv12 plane.
                    val chromaWidth = it.width / 2
                    val chromaHeight = it.height / 2
                    val uvSize = chromaWidth * chromaHeight * 2
                    if (uvCopy == null || uvCopy.capacity() < uvSize) {
                        uvCopy = ByteBuffer.allocateDirect(uvSize)
                        uvScratchRing[slot] = uvCopy
                    }
                    uvCopy.clear()
                    val uBuf = u.buffer
                    val vBuf = v.buffer
                    for (row in 0 until chromaHeight) {
                        val uRow = row * u.rowStride
                        val vRow = row * v.rowStride
                        for (col in 0 until chromaWidth) {
                            uvCopy.put(uBuf.get(uRow + col * u.pixelStride))
                            uvCopy.put(vBuf.get(vRow + col * v.pixelStride))
                        }
                    }
                    uvCopy.flip()
                    uvStride = chromaWidth * 2
                }
                if (!zeroCopyAttempted) {
                    val width = it.width
                    val height = it.height
                    val rotationDegrees = it.imageInfo.rotationDegrees
                    val timestampUs = it.imageInfo.timestamp / 1000
                    val yStride = y.rowStride
                    val ySubmit = yCopy
                    val uvSubmit = uvCopy
                    val mirror = mirrored
                    pendingCopySubmits.incrementAndGet()
                    uiExecutor.execute {
                        val submitted = session.submitFrameCopy(
                            ySubmit, yStride, uvSubmit, uvStride,
                            width, height,
                            rotationDegrees, mirrored = mirror,
                            timestampUs = timestampUs,
                        )
                        pendingCopySubmits.decrementAndGet()
                        if (submitted) {
                            cameraFrames += 1
                            if (cameraFrames == 1) {
                                captureState = "running"
                                Log.i(tag, "capture state running")
                            }
                        }
                    }
                }
                overlay.frameGeometry(it.width, it.height, it.imageInfo.rotationDegrees, mirrored)
                session.trackFrame(
                    yCopy, y.rowStride, uvCopy, uvStride,
                    it.width, it.height,
                    timestampUs = it.imageInfo.timestamp / 1000,
                )
            }
        }
        return analysis
    }
}
