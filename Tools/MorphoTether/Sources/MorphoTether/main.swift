//
//  main.swift
//  MorphoTether
//
//  Relays a USB-attached iPhone's camera into the iPhone Duo simulator.
//  The Mac opens the phone as a Continuity Camera over the cable and gets
//  the live sensor feed; `--mode screen` streams the phone's display
//  instead (the QuickTime path). No network is involved either way.
//
//  Frames leave this process only over loopback (127.0.0.1) to clients that
//  present the per-launch token published in
//  ~/Library/Application Support/Morpho/tether.json (mode 0600).
//

import AVFoundation
import Foundation

let options: TetherOptions
do {
    options = try TetherOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    Log.error("\(error)")
    FileHandle.standardError.write(Data((TetherOptions.usage + "\n").utf8))
    exit(64)
}

if options.showHelp {
    print(TetherOptions.usage)
    exit(0)
}

if options.mode == .screen || options.listDevices {
    PhoneCapture.enableScreenCaptureDevices()
}

/// Blocks until the person answers the camera prompt (or the timeout passes).
func requestCameraAccessIfNeeded(timeout: TimeInterval) -> AVAuthorizationStatus {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
        return AVCaptureDevice.authorizationStatus(for: .video)
    }
    Log.info("Requesting camera access — approve the macOS prompt to continue…")
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + timeout)
    return AVCaptureDevice.authorizationStatus(for: .video)
}

if options.listDevices {
    let status = requestCameraAccessIfNeeded(timeout: 120)
    print("Camera authorization: \(status.rawValue) (0 undetermined · 1 restricted · 2 denied · 3 authorized)")
    // CoreMediaIO surfaces the phone's display a few seconds after the property
    // flips, and AVFoundation learns about it on the main run loop — so pump it.
    var screens: [AVCaptureDevice] = []
    let deadline = Date().addingTimeInterval(12)
    while screens.isEmpty, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        screens = PhoneCapture.discover(mode: .screen)
    }
    let cameras = PhoneCapture.discover(mode: .camera)
    print("--- camera mode (Continuity Camera) ---")
    if cameras.isEmpty { print("none — is the phone unlocked, on the same Apple Account, with Continuity Camera enabled?") }
    for device in cameras {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        print("\(device.localizedName)  model=\(device.modelID)  \(dimensions.width)×\(dimensions.height)  id=\(device.uniqueID)")
    }
    print("--- screen mode (display capture) ---")
    if screens.isEmpty { print("none — is the phone plugged in, unlocked, and trusted?") }
    for device in screens {
        print("\(device.localizedName)  model=\(device.modelID)  id=\(device.uniqueID)")
    }
    exit(0)
}

let descriptorURL = options.descriptorPath.map { URL(fileURLWithPath: $0) } ?? TetherDescriptor.defaultURL
let token = TetherDescriptor.makeToken()
let encoder = FrameEncoder(maxSize: options.maxSize, quality: options.quality, rotation: options.rotation, crop: options.crop)
let capture = PhoneCapture(mode: options.mode, deviceFilter: options.deviceFilter, fps: options.fps)
let server: FrameServer
do {
    server = try FrameServer(port: options.port, token: token)
} catch {
    Log.error("Could not create the loopback listener: \(error)")
    exit(70)
}

func shutdown(exitCode: Int32) -> Never {
    capture.stop()
    server.stop()
    TetherDescriptor.remove(at: descriptorURL)
    Log.info("Tether stopped")
    exit(exitCode)
}

func publishDescriptor() {
    guard server.port != 0 else { return }
    do {
        try TetherDescriptor.write(to: descriptorURL, port: server.port, token: token, device: capture.deviceName)
    } catch {
        Log.error("Could not publish \(descriptorURL.path): \(error)")
        shutdown(exitCode: 73)
    }
}

// Counters live on the capture queue (single producer), so no locking needed.
var snapshotWritten = false
var relayedFrames = 0

capture.onFrame = { pixelBuffer in
    guard let encoded = encoder.encode(pixelBuffer) else { return }

    if let path = options.snapshotPath, !snapshotWritten {
        snapshotWritten = true
        do {
            try encoded.data.write(to: URL(fileURLWithPath: path))
            Log.info("Snapshot \(encoded.width)×\(encoded.height) written to \(path)")
        } catch {
            Log.error("Snapshot failed: \(error)")
        }
        if options.once { shutdown(exitCode: 0) }
    }

    server.broadcast(encoded.data)
    relayedFrames += 1
    if relayedFrames == 1 {
        Log.info("First frame \(encoded.width)×\(encoded.height), \(encoded.data.count / 1024) KB")
    } else if relayedFrames % 300 == 0 {
        Log.info("\(relayedFrames) frames relayed · \(encoded.width)×\(encoded.height) · \(encoded.data.count / 1024) KB/frame · \(server.clientCount) client(s)")
    }
}

capture.onDeviceChange = { _ in
    publishDescriptor()
}

server.start {
    Log.info("Listening on 127.0.0.1:\(server.port) (loopback only)")
    publishDescriptor()
    Log.info("Published \(descriptorURL.path)")
}

capture.start()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler { shutdown(exitCode: 0) }
interruptSource.resume()
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminateSource.setEventHandler { shutdown(exitCode: 0) }
terminateSource.resume()

RunLoop.main.run()
