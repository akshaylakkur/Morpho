//
//  AugmentTargetingLayer.swift
//  Morpho
//
//  Click-and-augment on the Deck's viewfinder. Two ways in:
//    • press and hold an outlined object → that region locks;
//    • drag a box around anything and hold still (or let go) → exactly that
//      box locks, a manual crop described by its color and place.
//  The Deck never shows the edits themselves; they appear on the Stage.
//  Either way the viewfinder holds the frame the target came from, the mic
//  opens, and what's said until the speaker goes quiet becomes that target's
//  augmentation. Nothing listens before a target is locked. A
//  plain tap outside the target cancels. Purely a gesture and chrome layer:
//  the held frame itself is drawn beneath the detection outlines by the Deck.
//

import SwiftUI

struct AugmentTargetingLayer: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(VoiceConductor.self) private var conductor

    let segmentation: SceneSegmentation?
    var zoom: CGFloat = 1

    @State private var press = PressTracker()
    @State private var marquee: CGRect?
    @State private var lockTask: Task<Void, Never>?
    @State private var marqueeHoldTask: Task<Void, Never>?
    /// Where the dragging finger last settled; moving past `marqueeSettle` restarts the hold.
    @State private var marqueeAnchor: CGPoint = .zero

    /// How long a still finger takes to lock the region under it.
    static let holdDuration: TimeInterval = 0.35
    /// Movement beyond this turns a hold into a marquee drag.
    static let holdSlop: CGFloat = 12
    /// Smaller boxes are treated as a tap.
    static let minimumMarquee: CGFloat = 24
    /// A dragged box locks once the finger rests this long.
    static let marqueeHoldDuration: TimeInterval = 0.5
    /// Jitter under this doesn't count as moving the box.
    static let marqueeSettle: CGFloat = 5

    private var regions: [DetectedRegion] { segmentation?.regions ?? [] }

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let frameSize = engine.heldFrame.map { CGSize(width: $0.width, height: $0.height) }
                ?? segmentation?.frameSize
                ?? container
            let display = TargetGeometry.displayRect(frameSize: frameSize, in: container, zoom: zoom)

            ZStack(alignment: .topLeading) {
                if session.targeting.holdsFrame, let target = session.targeting.target {
                    TargetSpotlight(target: target, display: display, container: container)
                        .transition(.opacity)
                }

                if let marquee {
                    MarqueeBox(rect: marquee)
                }

                if session.targeting.isActive {
                    TargetingHUD()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 112)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Top-leading, so the marquee's offsets are in the same space as the
            // finger; centered, the box drew away from the cursor mid-drag.
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(pressGesture(display: display))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard !session.targeting.isActive else { return }
                    _ = engine.captureStill()
                }
            )
            .animation(.easeOut(duration: 0.25), value: session.targeting.isActive)
        }
        .onChange(of: session.stagePhase) { _, phase in
            if phase != .live { conductor.cancelTargeting() }
        }
        .onDisappear {
            lockTask?.cancel()
            conductor.cancelTargeting()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewfinder")
        .accessibilityHint("Press and hold an outlined object, or drag a box around anything and hold, then say what to change")
    }

    // MARK: Gesture: hold to lock a region, drag to box one, tap outside to cancel

    private func pressGesture(display: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if press.startedAt == nil {
                    press = PressTracker(start: value.startLocation, startedAt: .now)
                    scheduleLock(at: value.startLocation, display: display)
                    return
                }
                // Holding a locked target: the finger may drift; nothing changes.
                guard !press.locked else { return }
                let distance = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if press.moved || distance > Self.holdSlop {
                    if !press.moved {
                        lockTask?.cancel()
                        press.moved = true
                    }
                    marquee = CGRect(origin: value.startLocation, size: .zero)
                        .union(CGRect(origin: value.location, size: .zero))
                        .standardized
                    // Holding the box still locks it and opens the mic.
                    if hypot(value.location.x - marqueeAnchor.x, value.location.y - marqueeAnchor.y) > Self.marqueeSettle {
                        marqueeAnchor = value.location
                        scheduleMarqueeLock(display: display)
                    }
                }
            }
            .onEnded { value in
                lockTask?.cancel()
                marqueeHoldTask?.cancel()
                let finished = press
                let box = marquee
                press = PressTracker()
                marquee = nil

                if finished.locked {
                    session.targetingHoldActive = false
                    conductor.endTargetingHold()
                } else if finished.moved, let box {
                    lockMarquee(box, display: display)
                } else if session.targeting.isActive,
                          !session.targeting.holdsFrame || !targetContains(value.location, display: display) {
                    conductor.cancelTargeting()
                }
            }
    }

    private func scheduleLock(at point: CGPoint, display: CGRect) {
        lockTask?.cancel()
        lockTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard !Task.isCancelled, press.startedAt != nil, !press.moved else { return }
            let normalized = TargetGeometry.normalizedPoint(point, in: display)
            guard let region = TargetGeometry.region(at: normalized, in: regions),
                  let target = engine.lockTarget(region: region)
            else { return }
            press.locked = true
            session.targetingHoldActive = true
            conductor.beginTargeting(target)
        }
    }

    private func scheduleMarqueeLock(display: CGRect) {
        marqueeHoldTask?.cancel()
        marqueeHoldTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.marqueeHoldDuration))
            guard !Task.isCancelled, press.moved, !press.locked, let box = marquee,
                  lockMarquee(box, display: display)
            else { return }
            press.locked = true
            marquee = nil
            session.targetingHoldActive = true
        }
    }

    /// Locks exactly the drawn box (no snapping) and opens the mic.
    @discardableResult
    private func lockMarquee(_ box: CGRect, display: CGRect) -> Bool {
        guard box.width >= Self.minimumMarquee, box.height >= Self.minimumMarquee,
              let target = engine.lockTarget(manualRect: TargetGeometry.normalizedRect(box, in: display))
        else { return false }
        conductor.beginTargeting(target)
        return true
    }

    private func targetContains(_ point: CGPoint, display: CGRect) -> Bool {
        guard let target = session.targeting.target else { return false }
        return TargetGeometry.displayRect(target.boundingBox, in: display).insetBy(dx: -12, dy: -12).contains(point)
    }
}

private struct PressTracker {
    var start: CGPoint = .zero
    var startedAt: Date?
    var moved = false
    var locked = false
}

// MARK: - Chrome

/// The frame the target was taken from, drawn exactly where the live feed
/// sits so nothing shifts when the viewfinder freezes.
struct HeldFrameView: View {
    let frame: CGImage
    var zoom: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: frame, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(zoom)
                .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Dims everything but the target and traces its shape in the identity gradient.
private struct TargetSpotlight: View {
    let target: AugmentationTarget
    let display: CGRect
    let container: CGSize

    var body: some View {
        let shape = Self.shape(for: target, in: display)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: container))
                path.addPath(shape)
            }
            .fill(.black.opacity(0.42), style: FillStyle(eoFill: true))

            shape.stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .blur(radius: 6)
            shape.stroke(Theme.iridescent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func shape(for target: AugmentationTarget, in display: CGRect) -> Path {
        if target.outline.count >= 3 {
            var path = Path()
            path.move(to: TargetGeometry.displayPoint(target.outline[0], in: display))
            for point in target.outline.dropFirst() {
                path.addLine(to: TargetGeometry.displayPoint(point, in: display))
            }
            path.closeSubpath()
            return path
        }
        let rect = TargetGeometry.displayRect(target.boundingBox, in: display)
        return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.12)
    }
}

/// The box being dragged.
private struct MarqueeBox: View {
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.white.opacity(0.08))
            Rectangle()
                .stroke(.black.opacity(0.35), style: StrokeStyle(lineWidth: 4, dash: [8, 6]))
            Rectangle()
                .stroke(Theme.iridescent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
