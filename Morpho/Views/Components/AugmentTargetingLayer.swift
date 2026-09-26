//
//  AugmentTargetingLayer.swift
//  Morpho
//
//  Click-and-augment on the Deck's viewfinder. Two ways in:
//    • press and hold an outlined object → that region locks;
//    • drag a box around anything → on release the box locks (snapping to a
//      detected region it mostly covers).
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

    /// How long a still finger takes to lock the region under it.
    static let holdDuration: TimeInterval = 0.35
    /// Movement beyond this turns a hold into a marquee drag.
    static let holdSlop: CGFloat = 12
    /// Smaller boxes are treated as a tap.
    static let minimumMarquee: CGFloat = 24

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

                // Hand-drawn targets that matched no region aren't in the
                // detection overlay, so their outlines are drawn here.
                ForEach(session.augmentations.filter { !$0.target.isDetected }) { augmentation in
                    ManualAugmentationOutline(augmentation: augmentation, display: display)
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
            .frame(width: container.width, height: container.height)
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
        .accessibilityHint("Press and hold an outlined object, or drag a box around one, then say what to change")
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
                }
            }
            .onEnded { value in
                lockTask?.cancel()
                let finished = press
                let box = marquee
                press = PressTracker()
                marquee = nil

                if finished.locked {
                    session.targetingHoldActive = false
                    conductor.endTargetingHold()
                } else if finished.moved {
                    if let box, box.width >= Self.minimumMarquee, box.height >= Self.minimumMarquee,
                       let target = engine.lockTarget(manualRect: TargetGeometry.normalizedRect(box, in: display), snappingTo: regions) {
                        conductor.beginTargeting(target)
                    }
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

/// A fixed patch of the frame carrying a cast, with its title.
private struct ManualAugmentationOutline: View {
    let augmentation: TargetedAugmentation
    let display: CGRect

    var body: some View {
        let rect = TargetGeometry.displayRect(augmentation.target.boundingBox, in: display)
        let radius = min(rect.width, rect.height) * 0.12
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius)
                .stroke(.black.opacity(0.35), lineWidth: 4.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            RoundedRectangle(cornerRadius: radius)
                .stroke(Theme.iridescent, lineWidth: 2.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .bold))
                Text(augmentation.shortTitle)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.iridescent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: .capsule)
            .fixedSize()
            .offset(x: max(rect.minX, 8), y: max(rect.minY - 30, 8))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
