import AVFoundation
import AppKit
import SwiftUI

// MARK: - Menu bar panel

struct MenuPanel: View {
    @EnvironmentObject var engine: CameraEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { engine.sending }, set: { engine.setSending($0) })) {
                Text("Send cropped camera").font(.headline)
            }
            .toggleStyle(.switch)
            StatusLine()
            ZoomControl()
            Divider()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Adjust framing…", systemImage: "crop")
            }
            .buttonStyle(.borderless)
            Button {
                engine.shutdown()
                NSApp.terminate(nil)
            } label: {
                Label("Quit Webcam Crop", systemImage: "power")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
    }
}

struct StatusLine: View {
    @EnvironmentObject var engine: CameraEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.problem != nil ? Color.orange : (engine.sending && engine.fps > 0 ? Color.green : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(engine.statusText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !engine.activeEffects.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("macOS \(engine.activeEffects.joined(separator: ", ")) is on for this app. It shows in your call and costs a lot of CPU.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Video Effects…") { engine.showVideoEffects() }
                        .controlSize(.small)
                }
            }
            if engine.obsAppRunning {
                Text("OBS is open — quit it, or its own virtual camera will fight with this one.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Logarithmic zoom slider (1×–8×) so low zoom levels get as much travel as high ones.
struct ZoomControl: View {
    @EnvironmentObject var engine: CameraEngine

    var body: some View {
        let logMax = log(Crop.maxZoom)
        HStack(spacing: 8) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(engine.zoom) / logMax },
                                  set: { engine.setZoom(exp($0 * logMax)) }),
                   in: 0...1)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Text(String(format: "%.1f×", engine.zoom))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var engine: CameraEngine
    private let previewSize = CGSize(width: 448, height: 252)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Picker("Camera", selection: $engine.cameraID) {
                    Text("Automatic").tag("")
                    ForEach(engine.cameras) { Text($0.name).tag($0.id) }
                }
                .frame(width: 300)
                Spacer()
                Toggle(isOn: Binding(get: { engine.sending }, set: { engine.setSending($0) })) {
                    Text("Send to virtual camera")
                }
                .toggleStyle(.switch)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera").font(.headline)
                    CropEditor()
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Drag to move the frame · scroll or pinch to zoom")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("What others see").font(.headline)
                    OutputPreview()
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(engine.zoom > 4 ? "Above 4× the picture gets noticeably soft." : " ")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ZoomControl()

            HStack(spacing: 16) {
                Button("Center") { engine.recenter() }
                Button("Reset zoom") { engine.setZoom(1) }
                Picker("Output", selection: $engine.outputHeight) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
            }

            StatusLine()

            Divider()

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Start sending when the app opens", isOn: $engine.sendOnLaunch)
                    Toggle("Open at login", isOn: Binding(get: { engine.openAtLogin },
                                                          set: { engine.openAtLogin = $0 }))
                }
                Spacer()
                Text("In your call app pick **OBS Virtual Camera**.\nKeep the OBS app itself closed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(20)
        .fixedSize()
        .onAppear {
            engine.previewVisible = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            engine.previewVisible = false
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Crop editor (live camera + draggable crop box)

struct CropEditor: View {
    @EnvironmentObject var engine: CameraEngine
    @State private var dragStart: CGPoint?
    @State private var zoomStart: Double?
    @State private var hovering = false
    @State private var scrollMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let video = videoRect(in: geo.size)
            let crop = cropRect(in: video)
            ZStack {
                CameraPreview(session: engine.session)
                Path { p in
                    p.addRect(video)
                    p.addRect(crop)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in p.addRect(crop) }
                    .stroke(Color.yellow, lineWidth: 2)
                if engine.activeCameraName.isEmpty {
                    Text("No camera").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragStart == nil {
                            if crop.contains(v.startLocation) {
                                dragStart = CGPoint(x: engine.centerX, y: engine.centerY)
                            } else {  // clicked outside the box: jump there
                                dragStart = CGPoint(x: (v.startLocation.x - video.minX) / video.width,
                                                    y: (v.startLocation.y - video.minY) / video.height)
                            }
                        }
                        engine.setCenter(x: dragStart!.x + v.translation.width / video.width,
                                         y: dragStart!.y + v.translation.height / video.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if zoomStart == nil { zoomStart = engine.zoom }
                        engine.setZoom(zoomStart! * v.magnification)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            .onHover { hovering = $0 }
        }
        .background(Color.black)
        .onAppear {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard hovering else { return event }
                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
                engine.setZoom(engine.zoom * exp(dy))
                return nil
            }
        }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m) }
            scrollMonitor = nil
        }
    }

    /// Where the aspect-fit camera image sits inside the view.
    private func videoRect(in size: CGSize) -> CGRect {
        let cs = engine.captureSize
        guard cs.width > 0, cs.height > 0 else { return CGRect(origin: .zero, size: size) }
        let s = min(size.width / cs.width, size.height / cs.height)
        let w = cs.width * s, h = cs.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func cropRect(in video: CGRect) -> CGRect {
        let cs = engine.captureSize
        let p = CropParams(zoom: engine.zoom, centerX: engine.centerX, centerY: engine.centerY,
                           outputWidth: engine.outputHeight * 16 / 9, outputHeight: engine.outputHeight)
        let r = Crop.rect(width: Int(cs.width), height: Int(cs.height), p)
        let s = video.width / cs.width
        return CGRect(x: video.minX + r.minX * s, y: video.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }
}

// MARK: - AppKit-backed video views

final class CapturePreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        // show the camera un-mirrored, exactly as the crop box maps it
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CapturePreviewView { CapturePreviewView(session: session) }
    func updateNSView(_ nsView: CapturePreviewView, context: Context) { nsView.needsLayout = true }
}

final class DisplayLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

struct OutputPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> DisplayLayerView {
        let v = DisplayLayerView()
        CameraEngine.shared.setPreviewRenderer(v.displayLayer.sampleBufferRenderer)
        return v
    }

    func updateNSView(_ nsView: DisplayLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: DisplayLayerView, coordinator: ()) {
        CameraEngine.shared.setPreviewRenderer(nil)
    }
}
