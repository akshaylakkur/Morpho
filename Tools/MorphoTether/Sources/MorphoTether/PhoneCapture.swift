//
//  PhoneCapture.swift
//  MorphoTether
//
//  Opens the USB-attached iPhone as a capture device. Two modes:
//    • camera (default): the phone's real camera via Continuity Camera —
//      a clean sensor feed. The phone shows "Connected to Mac" while in use.
//    • screen: the phone's display via the system's iOS screen-capture
//      device (what QuickTime uses) — handy for showing on-phone UI.
//  Either way, everything travels over the cable.
//

import AVFoundation
import CoreMediaIO
import Foundation

enum CaptureMode: String, CaseIterable {
    case camera
    case screen
}

final class PhoneCapture: NSObject {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onDeviceChange: ((AVCaptureDevice?) -> Void)?

    private(set) var device: AVCaptureDevice?
    var deviceName: String? { device?.localizedName }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "morpho.tether.capture", qos: .userInteractive)
    private let mode: CaptureMode
    private let deviceFilter: String?
    private let minimumInterval: CFTimeInterval
    private var lastFrameAt: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    enum CaptureError: Error {
        case cannotAddInput
        case cannotAddOutput
    }

    init(mode: CaptureMode, deviceFilter: String?, fps: Double) {
        self.mode = mode
        self.deviceFilter = deviceFilter
        self.minimumInterval = fps > 0 ? 1 / fps : 0
        super.init()
    }

    // MARK: Discovery

    /// Ask CoreMediaIO to expose tethered iOS devices' displays as capture devices.
    static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
        if status != kCMIOHardwareNoError {
            Log.error("CoreMediaIO refused to expose iOS screen devices (status \(status))")
        }
    }

    /// The iPhones the Mac can open right now in the given mode.
    static func discover(mode: CaptureMode) -> [AVCaptureDevice] {
        switch mode {
        case .camera:
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.continuityCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
            return discovery.devices.filter { $0.isContinuityCamera || $0.modelID.hasPrefix("iPhone") }

        case .screen:
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: nil,
                position: .unspecified
            )
            var seen: Set<String> = []
            var found: [AVCaptureDevice] = []
            for device in discovery.devices + AVCaptureDevice.devices(for: .muxed) {
                let isScreen = device.hasMediaType(.muxed) || device.modelID.localizedCaseInsensitiveContains("iOS")
                guard isScreen, seen.insert(device.uniqueID).inserted else { continue }
                found.append(device)
            }
            return found
        }
    }

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginLocating()
        case .notDetermined:
            Log.info("Requesting camera access — approve the macOS prompt to continue…")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.beginLocating() } else { self.denied() }
                }
            }
        default:
            denied()
        }
    }

    func stop() {
        detach()
    }

    private func denied() -> Never {
        Log.error("Camera access is required to read the iPhone over USB. Allow it under System Settings › Privacy & Security › Camera, then rerun.")
        exit(77)
    }

    private func beginLocating() {
        installObservers()
        switch mode {
        case .camera:
            Log.info("Looking for an iPhone camera on USB (unlock the phone and tap Trust if it asks; Continuity Camera must be on)…")
        case .screen:
            Log.info("Looking for an iPhone display on USB (unlock the phone and tap Trust if it asks)…")
        }
        locate(attempt: 0)
    }

    private func locate(attempt: Int) {
        guard device == nil else { return }
        if let candidate = Self.discover(mode: mode).first(where: matches) {
            attach(candidate)
            return
        }
        if attempt % 10 == 9 {
            Log.info("Still waiting for an iPhone…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.locate(attempt: attempt + 1)
        }
    }

    private func matches(_ candidate: AVCaptureDevice) -> Bool {
        guard let deviceFilter, !deviceFilter.isEmpty else { return true }
        return candidate.localizedName.localizedCaseInsensitiveContains(deviceFilter)
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let gone = note.object as? AVCaptureDevice, gone.uniqueID == self.device?.uniqueID else { return }
            Log.info("\(gone.localizedName) disconnected — waiting for it to come back")
            self.detach()
            self.locate(attempt: 0)
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.error("Capture session error: \(error?.localizedDescription ?? "unknown") — reopening")
            self?.detach()
            self?.locate(attempt: 0)
        })
    }

    private func attach(_ candidate: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        do {
            let input = try AVCaptureDeviceInput(device: candidate)
            guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
            session.addInput(input)

            if mode == .camera {
                // Best quality the phone offers over the cable, in that order.
                for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
                    session.sessionPreset = preset
                    break
                }
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
            session.addOutput(output)
            if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            }
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            Log.error("Could not open \(candidate.localizedName): \(error) — retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.locate(attempt: 0)
            }
            return
        }

        device = candidate
        session.startRunning()
        let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.activeFormat.formatDescription)
        Log.info("Streaming \(candidate.localizedName) · \(mode.rawValue) · \(dimensions.width)×\(dimensions.height)")
        onDeviceChange?(candidate)
    }

    private func detach() {
        if session.isRunning { session.stopRunning() }
        guard device != nil else { return }
        device = nil
        onDeviceChange?(nil)
    }
}

extension PhoneCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameAt >= minimumInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastFrameAt = now
        onFrame?(pixelBuffer)
    }
}
