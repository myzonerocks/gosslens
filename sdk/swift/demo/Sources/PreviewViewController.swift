import AVFoundation
import Gosslens
import QuartzCore
import UIKit
import os

// A UIView whose backing layer is the CAMetalLayer the engine renders into.
final class MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class PreviewViewController: UIViewController {
    private let log = Logger(subsystem: "com.gosslens.demo", category: "preview")
    private let camera = CameraController()
    private let statusLabel = UILabel()
    private let trackingLabel = UILabel()
    private let switchCameraButton = UIButton(type: .system)
    private let beautyStack = UIStackView()
    private let controlsStack = UIStackView()
    private let lensPicker = UISegmentedControl(items: PostFilter.allCases.map { $0.title })
    private let overlaysSwitch = UISwitch()
    private let backgroundSwitch = UISwitch()
    private let captureButton = UIButton(type: .system)
    private let noteLabel = UILabel()
    private let captureThumbnail = UIImageView()
    private let faceLayer = CAShapeLayer()
    private let faceRegionLayer = CAShapeLayer()
    private let handLayer = CAShapeLayer()
    private let trackedFace = GossFaceResult()
    private let trackedHands = GossHandResult()
    private let trackedPose = GossPoseResult()
    private let poseLayer = CAShapeLayer()
    private var lastPoseSerial: UInt64 = 0
    private var lastFaceSerial: UInt64 = 0
    private var lastHandSerial: UInt64 = 0

    private var engine: GossEngine?
    private var session: GossSession?
    private var audioOutput: GossAudioOutput?
    private var displayLink: CADisplayLink?

    private var renderedFrames = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private var fpsWindowFrames = 0
    private var lastFrameStart = CFAbsoluteTimeGetCurrent()
    private var lastFps: Double = 0
    private var lastDegrade: GossDegradeLevel = .full

    // The showcase state the picker and the background toggle both drive:
    // one active lens at a time, with the segmenter overlaying it when on.
    private var overlaysVisible = true
    private var currentFilter: PostFilter = .none
    private var segmentationOn = false
    private var beautyAmounts = [Float](repeating: 0, count: 6)
    private var baselineManifest: Data?
    private var thumbnailHideItem: DispatchWorkItem?

    override func loadView() {
        view = MetalView()
        view.backgroundColor = .black
    }

    private var metalView: MetalView { view as! MetalView }

    override func viewDidLoad() {
        super.viewDidLoad()

        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail

        trackingLabel.textColor = .white
        trackingLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        trackingLabel.numberOfLines = 1
        trackingLabel.lineBreakMode = .byTruncatingTail

        let statusStack = UIStackView(arrangedSubviews: [statusLabel, trackingLabel])
        statusStack.axis = .vertical
        statusStack.spacing = 2
        statusStack.alignment = .leading
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusStack)

        switchCameraButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        switchCameraButton.tintColor = .white
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)
        switchCameraButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchCameraButton)

        captureThumbnail.contentMode = .scaleAspectFill
        captureThumbnail.clipsToBounds = true
        captureThumbnail.layer.cornerRadius = 6
        captureThumbnail.layer.borderWidth = 1
        captureThumbnail.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        captureThumbnail.isHidden = true
        captureThumbnail.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureThumbnail)

        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: switchCameraButton.leadingAnchor, constant: -8),

            switchCameraButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            switchCameraButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            switchCameraButton.widthAnchor.constraint(equalToConstant: 44),
            switchCameraButton.heightAnchor.constraint(equalToConstant: 44),

            captureThumbnail.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            captureThumbnail.topAnchor.constraint(equalTo: switchCameraButton.bottomAnchor, constant: 12),
            captureThumbnail.widthAnchor.constraint(equalToConstant: 72),
            captureThumbnail.heightAnchor.constraint(equalToConstant: 96),
        ])

        let version = Gosslens.abiVersion()
        log.info("goss abi \(version >> 16).\(version & 0xffff)")
        guard version >> 16 == 0 else {
            statusLabel.text = "abi major mismatch"
            return
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        camera.onStateChange = { [weak self] state in
            self?.statusLabel.text = "capture \(state.rawValue)"
        }

        faceLayer.fillColor = UIColor.white.cgColor
        faceLayer.strokeColor = nil
        view.layer.addSublayer(faceLayer)

        // A named attach point (the nose tip) drawn distinct from the raw
        // landmarks, so the demo exercises the face-region readout.
        faceRegionLayer.fillColor = UIColor.systemTeal.cgColor
        faceRegionLayer.strokeColor = nil
        view.layer.addSublayer(faceRegionLayer)

        handLayer.fillColor = UIColor.white.withAlphaComponent(0.8).cgColor
        handLayer.strokeColor = nil
        view.layer.addSublayer(handLayer)

        poseLayer.fillColor = UIColor.white.withAlphaComponent(0.6).cgColor
        poseLayer.strokeColor = nil
        view.layer.addSublayer(poseLayer)

        setupBeautyControls()
        setupShowcaseControls()
    }

    // Each slider reaches setBeauty directly; the effect shows up in the
    // live preview itself, composited on the render thread through the
    // GPU bridge (Metal write, gpupixel GL read, back out through
    // Metal) - no CPU round trip through beautifyFrame involved.
    private func setupBeautyControls() {
        beautyStack.axis = .vertical
        beautyStack.spacing = 8
        beautyStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(beautyStack)
        NSLayoutConstraint.activate([
            beautyStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            beautyStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            beautyStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        for (index, name) in ["smooth", "whiten", "thin face", "big eye", "lipstick", "blush"].enumerated() {
            let label = UILabel()
            label.text = name
            label.textColor = .white
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true

            let slider = UISlider()
            slider.minimumValue = 0
            slider.maximumValue = 1
            slider.tag = index
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
            slider.thumbTintColor = .white
            slider.addTarget(self, action: #selector(beautySliderChanged(_:)), for: .valueChanged)

            let row = UIStackView(arrangedSubviews: [label, slider])
            row.axis = .horizontal
            row.spacing = 8
            beautyStack.addArrangedSubview(row)
        }
    }

    // The lens filter picker, the overlay and virtual-background toggles, and
    // the capture button, stacked just above the beauty sliders. The
    // background toggle starts disabled with a note when the selfie model is
    // not bundled, so the segmentation showcase degrades instead of crashing.
    private func setupShowcaseControls() {
        lensPicker.selectedSegmentIndex = currentFilter.rawValue
        lensPicker.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.25)
        lensPicker.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        lensPicker.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        lensPicker.addTarget(self, action: #selector(lensFilterChanged), for: .valueChanged)

        overlaysSwitch.isOn = overlaysVisible
        overlaysSwitch.onTintColor = .systemTeal
        overlaysSwitch.addTarget(self, action: #selector(overlaysToggled), for: .valueChanged)
        let overlaysRow = labeledSwitchRow(title: "overlays", control: overlaysSwitch)

        backgroundSwitch.isOn = false
        backgroundSwitch.onTintColor = .systemTeal
        backgroundSwitch.addTarget(self, action: #selector(virtualBackgroundToggled), for: .valueChanged)
        let backgroundRow = labeledSwitchRow(title: "background", control: backgroundSwitch)

        let toggleRow = UIStackView(arrangedSubviews: [overlaysRow, backgroundRow])
        toggleRow.axis = .horizontal
        toggleRow.distribution = .fillEqually
        toggleRow.spacing = 12

        captureButton.setTitle("Capture", for: .normal)
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        captureButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        captureButton.layer.cornerRadius = 8
        captureButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)

        noteLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.numberOfLines = 1
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true

        controlsStack.axis = .vertical
        controlsStack.spacing = 10
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.addArrangedSubview(lensPicker)
        controlsStack.addArrangedSubview(toggleRow)
        controlsStack.addArrangedSubview(captureButton)
        controlsStack.addArrangedSubview(noteLabel)
        view.addSubview(controlsStack)
        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controlsStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controlsStack.bottomAnchor.constraint(equalTo: beautyStack.topAnchor, constant: -12),
        ])

        if !virtualBackgroundAvailable {
            backgroundSwitch.isEnabled = false
            showNote("background needs the selfie model")
        }
    }

    private func labeledSwitchRow(title: String, control: UISwitch) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    // The in-engine selfie segmenter is a raw .tflite the app bundles itself,
    // not part of the engine archive; without it the virtual background stays
    // off and the toggle disables rather than failing at runtime.
    private var virtualBackgroundAvailable: Bool {
        Bundle.main.url(forResource: "selfie_segmenter", withExtension: "tflite") != nil
    }

    @objc private func beautySliderChanged(_ slider: UISlider) {
        beautyAmounts[slider.tag] = slider.value
        try? session?.setBeauty(effect: Int32(slider.tag), amount: slider.value)
    }

    @objc private func switchCameraTapped() {
        camera.switchCamera()
    }

    @objc private func overlaysToggled() {
        overlaysVisible = overlaysSwitch.isOn
        faceLayer.isHidden = !overlaysVisible
        faceRegionLayer.isHidden = !overlaysVisible
        handLayer.isHidden = !overlaysVisible
        poseLayer.isHidden = !overlaysVisible
    }

    @objc private func lensFilterChanged() {
        currentFilter = PostFilter(rawValue: lensPicker.selectedSegmentIndex) ?? .none
        applyActiveLens()
    }

    // Stands the selfie segmenter up on the camera and lets the
    // background-swap lens key the person over a replaced background.
    // A segmenter that reports unsupported at runtime turns the toggle
    // back off and disables it, so the toggle never leaves a half state.
    @objc private func virtualBackgroundToggled() {
        guard let session else { return }
        if backgroundSwitch.isOn {
            guard let url = Bundle.main.url(forResource: "selfie_segmenter", withExtension: "tflite"),
                  let model = try? Data(contentsOf: url)
            else {
                backgroundSwitch.isOn = false
                backgroundSwitch.isEnabled = false
                showNote("background needs the selfie model")
                return
            }
            do {
                try session.enableSegmentation(model: model, threads: 0)
                segmentationOn = true
                showNote(nil)
            } catch {
                backgroundSwitch.isOn = false
                backgroundSwitch.isEnabled = false
                segmentationOn = false
                showNote("segmenter unavailable here")
                log.info("segmentation enable failed: \(String(describing: error))")
            }
        } else {
            session.disableSegmentation()
            segmentationOn = false
        }
        applyActiveLens()
    }

    // Captures the composited frame the renderer just presented as a PNG,
    // writes it into the app documents directory, and shows a thumbnail. The
    // bytes are deterministic, so the same composite gives the same file.
    @objc private func captureTapped() {
        guard let engine, let session else { return }
        do {
            let (png, width, height) = try engine.capturePhoto(session: session)
            guard !png.isEmpty else {
                showNote("nothing to capture yet")
                return
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = documents.appendingPathComponent("gosslens-\(Int(Date().timeIntervalSince1970)).png")
            try Data(png).write(to: url)
            log.info("captured \(width)x\(height) png at \(url.path, privacy: .public)")
            showNote("saved to documents")
            if let image = UIImage(data: Data(png)) {
                showCaptureThumbnail(image)
            }
        } catch {
            showNote("capture failed")
            log.info("capture failed: \(String(describing: error))")
        }
    }

    private func showCaptureThumbnail(_ image: UIImage) {
        thumbnailHideItem?.cancel()
        captureThumbnail.image = image
        captureThumbnail.isHidden = false
        captureThumbnail.alpha = 1
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.captureThumbnail.alpha = 0 } completion: { _ in
                self?.captureThumbnail.isHidden = true
            }
        }
        thumbnailHideItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: hide)
    }

    private func showNote(_ text: String?) {
        noteLabel.text = text
        noteLabel.isHidden = (text == nil)
    }

    // Resolves the one active lens from the current showcase state: the
    // segmentation background wins while it is on, otherwise the picked
    // post lens rides. Beauty is re-applied after every swap, since a fresh
    // lens can reset the beauty chain to its own defaults.
    private func applyActiveLens() {
        guard let session else { return }
        if segmentationOn, virtualBackgroundAvailable,
           let manifestURL = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "background-swap") {
            do {
                try session.activateLensFromDirectory(bundlePath: manifestURL.deletingLastPathComponent().path)
            } catch {
                log.info("background lens activate failed: \(String(describing: error))")
            }
        } else if let manifest = currentFilter.manifestData {
            do {
                try session.activateLens(manifestJson: manifest)
            } catch {
                log.info("filter lens activate failed: \(String(describing: error))")
            }
        } else if let baseline = baselineManifestData() {
            try? session.activateLens(manifestJson: baseline)
        }
        reapplyBeauty()
    }

    private func baselineManifestData() -> Data? {
        if let cached = baselineManifest { return cached }
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "beauty-baseline"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        baselineManifest = data
        return data
    }

    private func reapplyBeauty() {
        guard let session else { return }
        for effect in 0 ..< beautyAmounts.count {
            try? session.setBeauty(effect: Int32(effect), amount: beautyAmounts[effect])
        }
    }

    private var conformanceStarted = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = view.window?.screen.scale ?? 3.0
        let pixelWidth = UInt32(view.bounds.width * scale)
        let pixelHeight = UInt32(view.bounds.height * scale)
        metalView.metalLayer.contentsScale = scale
        metalView.metalLayer.drawableSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))

        // The conformance run reuses this same real window/renderer
        // setup, just feeding a fixed corpus frame instead of live
        // camera - see ConformanceRunner. Own engine/session instances,
        // so the normal live-preview path below never starts.
        if CommandLine.arguments.contains("-GossConformance") {
            if !conformanceStarted, pixelWidth > 0 {
                conformanceStarted = true
                ConformanceRunner.run(metalLayer: metalView.metalLayer, width: pixelWidth, height: pixelHeight)
            }
            return
        }

        if engine == nil, pixelWidth > 0 {
            startEngine(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        } else if let engine {
            engine.resize(width: pixelWidth, height: pixelHeight)
        }
    }

    private func startEngine(pixelWidth: UInt32, pixelHeight: UInt32) {
        guard let newEngine = try? GossEngine.create() else {
            statusLabel.text = "engine create failed"
            return
        }
        engine = newEngine

        do {
            try newEngine.initRenderer(surface: Unmanaged.passUnretained(metalView.metalLayer).toOpaque(), width: pixelWidth, height: pixelHeight)
        } catch {
            statusLabel.text = "renderer init failed"
            log.error("renderer init failed")
            return
        }

        guard let newSession = try? GossSession.create(engine: newEngine) else {
            statusLabel.text = "session create failed"
            return
        }
        session = newSession

        // Lens sounds reach the speaker through the platform engine; the
        // render tick pumps the mixer on the same thread that ticks the lens.
        let output = GossAudioOutput(session: newSession)
        try? output.start()
        audioOutput = output

        camera.start(session: newSession)

        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func renderTick() {
        guard let engine, let session else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let frameTimeUs = UInt32(max(0, (start - lastFrameStart) * 1_000_000))
        lastFrameStart = start

        lastDegrade = session.reportFrame(frameTimeUs: frameTimeUs, thermal: ProcessInfo.processInfo.thermalState.gossThermal)
        drawFaceOverlay()
        drawHandOverlay()
        drawPoseOverlay()
        tickLens(dtUs: frameTimeUs)
        updateTrackingReadout()
        guard (try? engine.renderFrame(session: session)) != nil else { return }
        renderedFrames += 1
        fpsWindowFrames += 1

        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsWindowStart >= 2.0 {
            lastFps = Double(fpsWindowFrames) / (now - fpsWindowStart)
            log.info("fps \(String(format: "%.1f", self.lastFps)) rendered \(self.renderedFrames) submitted \(self.camera.submittedFrames) state \(self.camera.state.rawValue)")
            statusLabel.text = String(format: "capture %@  %.1f fps  degrade:%@", camera.state.rawValue, lastFps, lastDegrade.shortLabel)
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
    }

    // The one-line tracking readout: whether a face is present, its stable
    // track id, the canned gesture the first hand shows, and the frame rate.
    private func updateTrackingReadout() {
        let hasFace = trackedFace.presence >= 0.5 && trackedFace.landmarkCount > 0
        let id = session?.faceTrackId(index: 0).map { String($0) } ?? "-"
        let gesture = trackedHands.handCount > 0 ? trackedHands.gestures[0].shortLabel : "none"
        trackingLabel.text = String(format: "face %@  id:%@  gesture:%@  %.0f fps", hasFace ? "yes" : "no", id, gesture, lastFps)
    }

    /// Landmarks arrive in sensor pixels; the sensor sits one quarter turn
    /// from portrait, the same turn the preview applies.
    private func drawFaceOverlay() {
        guard overlaysVisible, let session, (try? session.faceResult(trackedFace)) != nil else { return }
        guard trackedFace.frameSerial != lastFaceSerial else { return }
        lastFaceSerial = trackedFace.frameSerial
        guard trackedFace.landmarkCount > 0, trackedFace.presence >= 0.5 else {
            faceLayer.path = nil
            faceRegionLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for index in 0 ..< trackedFace.landmarkCount {
            let x = CGFloat(trackedFace.landmarks[index * 3])
            let y = CGFloat(trackedFace.landmarks[index * 3 + 1])
            // Quarter turn: sensor x runs down the portrait screen. The
            // front camera's preview is mirrored for a selfie view, so
            // the overlay's horizontal axis mirrors along with it.
            var viewX = (sensorHeight - y) * scaleX
            if camera.mirrored {
                viewX = bounds.width - viewX
            }
            let viewY = x * scaleY
            path.addEllipse(in: CGRect(x: viewX - 1.5, y: viewY - 1.5, width: 3, height: 3))
        }
        // The nose-tip attach point, mapped through the same sensor-to-screen
        // transform the landmarks use above.
        if let nose = try? session.faceRegion(.noseTip) {
            var regionX = (sensorHeight - CGFloat(nose.y)) * scaleX
            if camera.mirrored { regionX = bounds.width - regionX }
            let regionY = CGFloat(nose.x) * scaleY
            let regionPath = CGMutablePath()
            regionPath.addEllipse(in: CGRect(x: regionX - 4, y: regionY - 4, width: 8, height: 8))
            faceRegionLayer.path = regionPath
        } else {
            faceRegionLayer.path = nil
        }
        faceLayer.path = path
    }

    /// The same sensor-to-screen mapping the face overlay uses; hands
    /// ride the same camera pose.
    private func drawHandOverlay() {
        guard overlaysVisible, let session, (try? session.handResult(trackedHands)) != nil else { return }
        guard trackedHands.frameSerial != lastHandSerial else { return }
        lastHandSerial = trackedHands.frameSerial
        guard trackedHands.handCount > 0 else {
            handLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for handAt in 0 ..< trackedHands.handCount {
            let base = handAt * GossHandResult.landmarkCount * 3
            for point in 0 ..< GossHandResult.landmarkCount {
                let x = CGFloat(trackedHands.landmarks[base + point * 3])
                let y = CGFloat(trackedHands.landmarks[base + point * 3 + 1])
                var viewX = (sensorHeight - y) * scaleX
                if camera.mirrored {
                    viewX = bounds.width - viewX
                }
                let viewY = x * scaleY
                path.addEllipse(in: CGRect(x: viewX - 2, y: viewY - 2, width: 4, height: 4))
            }
        }
        handLayer.path = path
    }

    /// The same sensor-to-screen mapping as the other overlays; only
    /// confidently visible joints draw.
    private func drawPoseOverlay() {
        guard overlaysVisible, let session, (try? session.poseResult(trackedPose)) != nil else { return }
        guard trackedPose.frameSerial != lastPoseSerial else { return }
        lastPoseSerial = trackedPose.frameSerial
        guard trackedPose.landmarkCount > 0, trackedPose.presence >= 0.5 else {
            poseLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for point in 0 ..< trackedPose.landmarkCount {
            guard trackedPose.visibilities[point] >= 0.5 else { continue }
            let x = CGFloat(trackedPose.landmarks[point * 3])
            let y = CGFloat(trackedPose.landmarks[point * 3 + 1])
            var viewX = (sensorHeight - y) * scaleX
            if camera.mirrored {
                viewX = bounds.width - viewX
            }
            let viewY = x * scaleY
            path.addEllipse(in: CGRect(x: viewX - 3, y: viewY - 3, width: 6, height: 6))
        }
        poseLayer.path = path
    }

    /// Rides the same result drawFaceOverlay just refreshed - ticking
    /// every render frame regardless of whether that particular result
    /// was new keeps the lens's own animation ramps advancing smoothly
    /// at display refresh rate rather than at tracking cadence.
    private func tickLens(dtUs: UInt32) {
        guard let session else { return }
        let signals = GossLensSignals(
            hasFace: trackedFace.presence >= 0.5 && trackedFace.landmarkCount > 0,
            handsPresent: trackedHands.handCount > 0,
            blendshapes: trackedFace.blendshapes
        )
        try? session.tickLens(dtUs: dtUs, signals: signals)
        try? audioOutput?.pump()
    }

    @objc private func appDidEnterBackground() {
        displayLink?.isPaused = true
        camera.stop()
    }

    @objc private func appWillEnterForeground() {
        displayLink?.isPaused = false
        camera.start(session: session)
    }
}

private extension ProcessInfo.ThermalState {
    var gossThermal: GossThermal {
        switch self {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}

private extension GossDegradeLevel {
    var shortLabel: String {
        switch self {
        case .full: return "full"
        case .reducedMlCadence: return "ml-cadence"
        case .segmentationOff: return "seg-off"
        case .beautySimplified: return "beauty-lite"
        case .passthrough: return "passthrough"
        }
    }
}

private extension GossGesture {
    var shortLabel: String {
        switch self {
        case .none: return "none"
        case .closedFist: return "fist"
        case .openPalm: return "palm"
        case .pointingUp: return "point"
        case .thumbDown: return "thumb-down"
        case .thumbUp: return "thumb-up"
        case .victory: return "victory"
        case .iLoveYou: return "iloveyou"
        }
    }
}
