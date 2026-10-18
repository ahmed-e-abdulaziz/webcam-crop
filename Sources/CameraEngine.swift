// Capture -> crop/scale on the GPU (VideoToolbox) -> OBS Virtual Camera + in-app preview.
import AVFoundation
import AppKit
import Combine
import CoreMedia
import ServiceManagement
import VideoToolbox

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraEngine()

    // MARK: settings (persisted)
    @Published var zoom = 2.0 { didSet { paramsChanged() } }
    @Published var centerX = 0.5 { didSet { paramsChanged() } }
    @Published var centerY = 0.5 { didSet { paramsChanged() } }
    @Published var outputHeight = 720 { didSet { paramsChanged() } }
    @Published var cameraID = "" { didSet { if cameraID != oldValue { save(); restartCapture() } } }
    @Published var sendOnLaunch = false { didSet { save() } }

    // MARK: state
    @Published private(set) var sending = false
    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var activeCameraName = ""
    @Published private(set) var fps = 0
    @Published private(set) var captureSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var problem: String?
    @Published private(set) var obsAppRunning = false
    /// macOS Video Effects (Control Center) currently applied to our capture, e.g. ["Studio Light"]
    @Published private(set) var activeEffects: [String] = []
    private weak var activeDevice: AVCaptureDevice?
    @Published var previewVisible = false { didSet { if previewVisible != oldValue { updateCapture() } } }

    let firstLaunch: Bool
    let session = AVCaptureSession()

    private let defaults = UserDefaults.standard
    private var loading = true
    private var clamping = false
    private let sessionQueue = DispatchQueue(label: "webcamcrop.session")
    private let videoQueue = DispatchQueue(label: "webcamcrop.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?  // sessionQueue
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    // shared with the video thread (guarded by lock)
    private let lock = NSLock()
    private var _params = CropParams()
    private var _sink: OBSVirtualCamera?
    private var _previewRenderer: AVSampleBufferVideoRenderer?
    private var _frames = 0
    private var _lastFrame = Date.distantPast

    // video thread only
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var formatDesc: CMVideoFormatDescription?

    private override init() {
        firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        super.init()
        let d = defaults
        if d.object(forKey: "zoom") != nil { zoom = d.double(forKey: "zoom") }
        if d.object(forKey: "centerX") != nil { centerX = d.double(forKey: "centerX") }
        if d.object(forKey: "centerY") != nil { centerY = d.double(forKey: "centerY") }
        if d.object(forKey: "outputHeight") != nil { outputHeight = d.integer(forKey: "outputHeight") }
        cameraID = d.string(forKey: "cameraID") ?? ""
        sendOnLaunch = d.bool(forKey: "sendOnLaunch")
        d.set(true, forKey: "hasLaunched")
        loading = false
        pushParams()

        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        if let t = transfer {
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_CropSourceToCleanAperture)
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        sessionQueue.async { [self] in
            session.beginConfiguration()
            output.alwaysDiscardsLateVideoFrames = true
            // 420v straight from the camera decoder; VideoToolbox converts to UYVY while it crops
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        refreshCameras()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshCameras()
                self?.restartCapture()
            })
        }
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                        queue: .main) { [weak self] _ in self?.restartCapture() })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: public API

    func appLaunched() {
        if sendOnLaunch { setSending(true) }
    }

    func setSending(_ on: Bool) {
        if on == sending { return }
        if on {
            withCameraPermission { [self] granted in
                guard granted else {
                    problem = "Camera access is off. Allow Webcam Crop in System Settings › Privacy & Security › Camera."
                    return
                }
                do {
                    let sink = try OBSVirtualCamera()
                    lock.lock(); _sink = sink; lock.unlock()
                    sending = true
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                }
                updateCapture()
            }
        } else {
            lock.lock(); let sink = _sink; _sink = nil; lock.unlock()
            sink?.stop()
            sending = false
            fps = 0
            updateCapture()
        }
    }

    func setZoom(_ z: Double) { zoom = min(max(z, Crop.minZoom), Crop.maxZoom) }

    func setCenter(x: Double, y: Double) {
        clamping = true
        centerX = x
        clamping = false
        centerY = y
    }

    func recenter() { setCenter(x: 0.5, y: 0.5) }

    func showVideoEffects() { AVCaptureDevice.showSystemUserInterface(.videoEffects) }

    func setPreviewRenderer(_ r: AVSampleBufferVideoRenderer?) {
        lock.lock(); _previewRenderer = r; lock.unlock()
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                problem = "Open at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    var statusText: String {
        if let problem { return problem }
        if sending {
            if fps > 0 { return "Sending \(outputHeight * 16 / 9)×\(outputHeight) · \(fps) fps" }
            return activeCameraName.isEmpty ? "Waiting for camera…" : "Starting…"
        }
        return "Off — your call app shows the OBS placeholder"
    }

    func shutdown() {
        lock.lock(); let sink = _sink; _sink = nil; lock.unlock()
        sink?.stop()
        sessionQueue.sync { if session.isRunning { session.stopRunning() } }
    }

    // MARK: settings plumbing

    private func paramsChanged() {
        if loading { return }
        if !clamping {
            clamping = true
            let z = min(max(zoom, Crop.minZoom), Crop.maxZoom)
            if z != zoom { zoom = z }
            // keep the centre where the box can actually reach
            var p = currentParams()
            let (cw, ch) = Crop.size(width: captureSize.width, height: captureSize.height, p)
            let hx = cw / 2 / captureSize.width, hy = ch / 2 / captureSize.height
            p.centerX = min(max(centerX, hx), 1 - hx)
            p.centerY = min(max(centerY, hy), 1 - hy)
            if p.centerX != centerX { centerX = p.centerX }
            if p.centerY != centerY { centerY = p.centerY }
            clamping = false
        }
        pushParams()
        save()
    }

    private func currentParams() -> CropParams {
        let h = outputHeight == 1080 ? 1080 : 720
        return CropParams(zoom: zoom, centerX: centerX, centerY: centerY, outputWidth: h * 16 / 9, outputHeight: h)
    }

    private func pushParams() {
        let p = currentParams()
        lock.lock(); _params = p; lock.unlock()
    }

    private func save() {
        if loading { return }
        let d = defaults
        d.set(zoom, forKey: "zoom")
        d.set(centerX, forKey: "centerX")
        d.set(centerY, forKey: "centerY")
        d.set(outputHeight, forKey: "outputHeight")
        d.set(cameraID, forKey: "cameraID")
        d.set(sendOnLaunch, forKey: "sendOnLaunch")
    }

    // MARK: cameras

    private static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.filter { $0.uniqueID != obsDeviceUID }
    }

    private func refreshCameras() {
        cameras = Self.discover().map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen camera, or the first external one when none is chosen / it's unplugged.
    private static func resolve(_ id: String) -> AVCaptureDevice? {
        let all = discover()
        if !id.isEmpty { return all.first { $0.uniqueID == id } }
        return all.first { $0.deviceType == .external } ?? all.first
    }

    private static func bestFormat(_ device: AVCaptureDevice) -> (AVCaptureDevice.Format, CMTime)? {
        let target = 30.0
        var best: (AVCaptureDevice.Format, CMTime, Int)?
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width <= 3840 else { continue }
            guard let r = f.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= target - 0.5 }) else { continue }
            // cameras report e.g. 30.00003 fps; an out-of-range duration throws an uncatchable exception
            let dur = (r.maxFrameRate > target + 0.5 && r.minFrameRate <= target)
                ? CMTime(value: 1, timescale: CMTimeScale(target)) : r.minFrameDuration
            let area = Int(d.width) * Int(d.height)
            if best == nil || area > best!.2 { best = (f, dur, area) }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: capture lifecycle

    private func updateCapture() {
        let want = sending || previewVisible
        let id = cameraID
        if want {
            withCameraPermission { [self] granted in
                guard granted else { return }
                sessionQueue.async { [self] in
                    if !session.isRunning || currentInput == nil { startCaptureOnQueue(id) }
                }
            }
        } else {
            sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } }
        }
    }

    private func restartCapture() {
        let want = sending || previewVisible
        let id = cameraID
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            if want { startCaptureOnQueue(id) }
        }
    }

    private func startCaptureOnQueue(_ id: String) {
        guard let device = Self.resolve(id) else {
            if let input = currentInput { session.removeInput(input); currentInput = nil }
            DispatchQueue.main.async { self.activeCameraName = "" }
            return
        }
        if currentInput?.device.uniqueID != device.uniqueID {
            session.beginConfiguration()
            if let input = currentInput { session.removeInput(input); currentInput = nil }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
            session.commitConfiguration()
        }
        guard currentInput != nil else { return }
        let fmt = Self.bestFormat(device)
        do {
            try device.lockForConfiguration()
            if let fmt {
                device.activeFormat = fmt.0
                device.activeVideoMinFrameDuration = fmt.1
                device.activeVideoMaxFrameDuration = fmt.1
            }
            if !session.isRunning { session.startRunning() }  // start while locked so our format sticks
            device.unlockForConfiguration()
        } catch {
            if !session.isRunning { session.startRunning() }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let name = device.localizedName
        lock.lock(); _lastFrame = Date(); lock.unlock()
        DispatchQueue.main.async {
            self.activeDevice = device
            self.activeCameraName = name
            self.captureSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            self.paramsChanged()
        }
    }

    /// Every second on main: fps, watchdog, OBS check.
    private func tick() {
        lock.lock(); let n = _frames; _frames = 0; let last = _lastFrame; lock.unlock()
        if fps != n { fps = n }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: obsBundleID).isEmpty == false
        if running != obsAppRunning { obsAppRunning = running }
        var fx: [String] = []
        if let d = activeDevice, sending || previewVisible {
            if d.isStudioLightActive { fx.append("Studio Light") }
            if d.isPortraitEffectActive { fx.append("Portrait") }
            if d.isBackgroundReplacementActive { fx.append("Background") }
            if d.isCenterStageActive { fx.append("Center Stage") }
        }
        if fx != activeEffects { activeEffects = fx }
        if (sending || previewVisible) && Date().timeIntervalSince(last) > 4 {
            lock.lock(); _lastFrame = Date(); lock.unlock()  // retry every 4 s, not every tick
            refreshCameras()
            restartCapture()
        }
    }

    private func withCameraPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// VideoToolbox copies the camera's attachments onto the output. In a GUI app those include
    /// macOS video-effects metadata that the OBS extension can't deserialize (every frame is then
    /// dropped with FigSampleBufferSerialization err -19646), so keep only the colour tags.
    private var loggedAttachments = false
    private var loggedSource = false
    private func sanitizeAttachments(_ buf: CVPixelBuffer) {
        let keep: [CFString] = [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey,
                                kCVImageBufferTransferFunctionKey]
        if !loggedAttachments {
            loggedAttachments = true
            let all = (CVBufferCopyAttachments(buf, .shouldPropagate) as? [String: Any]) ?? [:]
            debugLog("output attachments before cleanup: \(all.keys.sorted())")
            for k in keep { debugLog("  \(k) = \(String(describing: CVBufferCopyAttachment(buf, k, nil)))") }
        }
        let saved = keep.compactMap { k in CVBufferCopyAttachment(buf, k, nil).map { (k, $0) } }
        CVBufferRemoveAllAttachments(buf)
        for (k, v) in saved { CVBufferSetAttachment(buf, k, v, .shouldPropagate) }
    }

    // MARK: per frame (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        let p = _params, sink = _sink, renderer = _previewRenderer
        _frames += 1
        _lastFrame = Date()
        lock.unlock()
        guard sink != nil || renderer != nil,
              let src = CMSampleBufferGetImageBuffer(sampleBuffer), let transfer else { return }
        if !loggedSource {
            loggedSource = true
            let all = (CVBufferCopyAttachments(src, .shouldPropagate) as? [String: Any]) ?? [:]
            let fmt = CVPixelBufferGetPixelFormatType(src)
            if let d = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device {
                debugLog("device effects active: studioLight=\(d.isStudioLightActive) portrait=\(d.isPortraitEffectActive) background=\(d.isBackgroundReplacementActive) centerStage=\(d.isCenterStageActive) canReact=\(d.canPerformReactionEffects) gestures=\(AVCaptureDevice.reactionEffectGesturesEnabled)")
            }
            debugLog("effects: studioLight=\(AVCaptureDevice.isStudioLightEnabled) portrait=\(AVCaptureDevice.isPortraitEffectEnabled) centerStage=\(AVCaptureDevice.isCenterStageEnabled) reactions=\(AVCaptureDevice.reactionEffectsEnabled) background=\(AVCaptureDevice.isBackgroundReplacementEnabled)")
            debugLog("source \(CVPixelBufferGetWidth(src))x\(CVPixelBufferGetHeight(src)) fmt=\(String(format: "%08x", fmt)) attachments: \(all)")
        }

        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let r = Crop.rect(width: w, height: h, p)
        // the crop is the clean aperture of the source; offsets are measured from the image centre
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: r.width,
            kCVImageBufferCleanApertureHeightKey: r.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: r.midX - Double(w) / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: r.midY - Double(h) / 2,
        ]
        CVBufferSetAttachment(src, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)

        if pool == nil || poolSize != (p.outputWidth, p.outputHeight) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8,  // UYVY, what OBS expects
                kCVPixelBufferWidthKey: p.outputWidth,
                kCVPixelBufferHeightKey: p.outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = (p.outputWidth, p.outputHeight)
            formatDesc = nil
        }
        guard let pool else { return }
        var dstOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOut) == kCVReturnSuccess, let dst = dstOut,
              VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return }
        sanitizeAttachments(dst)

        if formatDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDesc!, imageBuffer: dst) {
            formatDesc = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: dst, formatDescriptionOut: &formatDesc)
        }
        guard let formatDesc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var outBuf: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: dst, formatDescription: formatDesc,
                                                       sampleTiming: &timing, sampleBufferOut: &outBuf) == noErr,
              let out = outBuf else { return }

        sink?.send(out)
        // The preview gets its own sample buffer: the DisplayImmediately attachment it needs makes
        // the OBS extension reject the frame (FigSampleBufferSerialization err -19646).
        if let renderer {
            var pvBuf: CMSampleBuffer?
            if CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: dst, formatDescription: formatDesc,
                                                        sampleTiming: &timing, sampleBufferOut: &pvBuf) == noErr,
               let pv = pvBuf {
                if let atts = CMSampleBufferGetSampleAttachmentsArray(pv, createIfNecessary: true),
                   CFArrayGetCount(atts) > 0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                if renderer.requiresFlushToResumeDecoding { renderer.flush() }
                if renderer.isReadyForMoreMediaData { renderer.enqueue(pv) }
            }
        }
    }
}

/// Appends a line to ~/Library/Logs/WebcamCrop.log (diagnostics; NSLog output is redacted).
func debugLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WebcamCrop.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
