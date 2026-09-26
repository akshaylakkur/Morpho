//
//  SceneSegmenter.swift
//  Morpho
//
//  The autodetection layer (controller phase, step 1). On-device Vision
//  segments the live feed into regions, tracks each region from pass to pass
//  so only things that persist get drawn, traces a dashed outline around
//  each, and names it in a word or two. Passes run back to back, as fast as
//  the device allows, so the outlines follow the video. Only the Deck draws
//  the result; the Stage on the upper screen never sees any of this.
//
//  Two segmentation backends, chosen at runtime by what Vision can execute:
//    • foregroundInstances — GenerateForegroundInstanceMaskRequest: one mask
//      per salient object of any kind. Needs a GPU/ANE inference context
//      (physical Duo).
//    • cpuComposite — fast person segmentation split by human rectangles,
//      objectness saliency (boxes or heat-map blobs), and classical rectangle
//      detection, all pinned to the CPU. This is what the Duo simulator runs.
//  Both produce the same label plane, so tracking, naming and outlining are
//  shared.
//
//  Naming ladder: Foundation Models with image input when the device has it,
//  else Vision's image classifier when it actually discriminates, else
//  heuristics (Person / Document / Object).
//

import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import Observation
import OSLog
import Vision

nonisolated private let log = Logger(subsystem: "app.morpho", category: "SceneSegmenter")

/// One tracked, confirmed region of the live frame.
nonisolated struct DetectedRegion: Identifiable, Equatable, Sendable {
    let id: Int
    /// One or two words, e.g. "Person", "Coffee Mug". Empty until named.
    var label: String
    /// Normalized to the frame, origin at the upper-left. Smoothed over passes.
    var boundingBox: CGRect
    /// Traced mask boundary, normalized upper-left points in order.
    var outline: [CGPoint]
    /// Fraction of the frame the region covers.
    var coverage: CGFloat
    /// 0…1; how sure the detector was about this region on its last sighting.
    var confidence: CGFloat
    /// Significance multiplier of the region's source (people > objects > rectangles).
    var kindWeight: CGFloat = 1
    /// Index into `DetectionPalette`; fixed for the life of the region.
    var paletteIndex: Int
}

/// Everything the Deck needs to draw one pass.
nonisolated struct SceneSegmentation: Sendable {
    var regions: [DetectedRegion]
    /// Pixel size of the frame that was analyzed (for aspect mapping).
    var frameSize: CGSize
    var analyzedAt: Date
}

/// Tunables the controller exposes.
nonisolated struct SegmentationSettings: Sendable, Equatable {
    /// Most regions drawn at once; the rest are dropped by score.
    var maxRegions = 6
    /// Detections below this confidence never become regions.
    var minimumConfidence: CGFloat = 0.55
    /// Regions smaller than this fraction of the frame are noise.
    var minimumCoverage: CGFloat = 0.006
    /// Passes a region must be seen in before it's drawn.
    var confirmationPasses = 2
    /// Passes a region may go unseen before it's dropped.
    var maximumMisses = 4
}

/// Highlight colors, drawn from the iridescent identity gradient.
nonisolated enum DetectionPalette {
    static let rgb: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (89, 204, 255),   // sky
        (158, 122, 255),  // violet
        (242, 140, 230),  // pink
        (89, 242, 204),   // mint
        (255, 184, 64),   // amber
        (38, 217, 199),   // teal
    ]
}

// MARK: - Observable front

@Observable
final class SceneSegmenter {
    /// The latest pass; nil while nothing is detected or the layer is off.
    private(set) var current: SceneSegmentation?
    private(set) var isRunning = false
    /// Set after Vision has failed repeatedly on every backend. The loop keeps
    /// probing slowly in case it recovers.
    private(set) var isUnavailable = false
    private(set) var lastErrorDescription: String?
    /// Wall time of the last successful pass, for tuning.
    private(set) var lastPassDuration: TimeInterval = 0
    /// Clutter controls; the Deck may adjust these live.
    var settings = SegmentationSettings()

    private let worker = SegmentationWorker()
    private let namer = RegionNamer()
    private var passes = 0

    /// Consecutive failures before the layer reports itself unavailable.
    static let failuresBeforeUnavailable = 6

    /// Runs until the calling task is cancelled: take the newest frame,
    /// analyze it, publish, repeat. `frames` returns nil to pause.
    func run(frames: @MainActor () -> CGImage?) async {
        isRunning = true
        defer {
            isRunning = false
            current = nil
        }
        await worker.attach(namer: namer)

        var consecutiveFailures = 0

        while !Task.isCancelled {
            guard let frame = frames() else {
                if current != nil { current = nil }
                await worker.reset()
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }

            let started = Date.now
            let outcome = await worker.analyze(frame, settings: settings)
            guard !Task.isCancelled else { break }

            switch outcome {
            case .success(let result):
                if consecutiveFailures > 0 || isUnavailable {
                    log.notice("Segmentation recovered after \(consecutiveFailures) failure(s)")
                }
                consecutiveFailures = 0
                isUnavailable = false
                lastErrorDescription = nil
                lastPassDuration = Date.now.timeIntervalSince(started)
                current = result
                passes += 1
                if passes % 100 == 1 {
                    log.notice("pass \(self.passes): \(Int(self.lastPassDuration * 1000)) ms, \(result.regions.count) region(s): \(result.regions.map(\.label).joined(separator: ", "))")
                }
                // Let the main actor breathe between passes.
                try? await Task.sleep(for: .milliseconds(16))

            case .failure(let error):
                consecutiveFailures += 1
                lastErrorDescription = error.localizedDescription
                if consecutiveFailures == 1 || consecutiveFailures % 20 == 0 {
                    log.error("Segmentation pass failed (\(consecutiveFailures)): \(error.localizedDescription)")
                }
                if consecutiveFailures >= Self.failuresBeforeUnavailable, !isUnavailable {
                    isUnavailable = true
                    current = nil
                    await worker.reset()
                    log.fault("Segmentation unavailable: \(error.localizedDescription)")
                }
                // Back off instead of spinning: 250 ms doubling to 3 s.
                let backoff = min(0.25 * pow(2, Double(consecutiveFailures - 1)), 3)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }
}

// MARK: - Worker

/// Off the main actor: Vision requests, tracking, outline tracing, naming.
actor SegmentationWorker {
    enum Backend: String {
        /// Not yet decided; the first pass probes.
        case undecided
        case foregroundInstances
        case cpuComposite
    }

    private var backend: Backend = .undecided

    // Primary backend.
    private var foregroundRequest = GenerateForegroundInstanceMaskRequest()
    private var humanRequest = DetectHumanRectanglesRequest()
    // Composite backend. The fast semantic person mask is realtime-grade on
    // the CPU; the per-person instance model is not (tens of seconds per hit),
    // so people are split into instances with human rectangles instead.
    private var personSegmentationRequest: GeneratePersonSegmentationRequest = {
        let request = GeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        return request
    }()
    private var saliencyRequest = GenerateObjectnessBasedSaliencyImageRequest()
    /// Faces run everywhere (even where the person models return nothing) and
    /// are the strongest "this matters" signal in a frame.
    private var faceRequest = DetectFaceRectanglesRequest()
    /// Cleared once a face is seen with an all-zero person mask: that mask is
    /// dead on this runtime, so people are drawn from faces instead.
    private var personMaskUsable = true
    /// Classical rectangle detection catches flat objects (paper, screens,
    /// keyboards) that saliency rates low; cheap and runs anywhere, but noisy,
    /// so it's gated hard and ranked last.
    private var rectangleRequest: DetectRectanglesRequest = {
        var request = DetectRectanglesRequest()
        request.maximumObservations = 3
        request.minimumSize = 0.2
        request.minimumConfidence = 0.7
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1.0
        return request
    }()
    /// Rectangles smaller than this fraction of the frame are clutter.
    static let minimumRectangleCoverage: CGFloat = 0.02
    // Naming.
    private var classifyRequest = ClassifyImageRequest()
    /// False when the classifier returns the same answer for any input (the
    /// simulator's CPU path does); labels then come from heuristics.
    private var classifierUsable = true
    private var textRequest: RecognizeTextRequest = {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        return request
    }()
    private var namer: RegionNamer?
    private var namerAvailable = false
    /// Names produced asynchronously by the language model, applied next pass.
    private var pendingNames: [Int: String] = [:]
    private var namingInFlight = false

    // Tracking.
    private struct Track {
        var region: DetectedRegion
        var hits = 1
        /// Sightings needed before the region is drawn.
        var requiredHits = 2
        var misses = 0
        var lastNamedAt: Date?
        var namedByModel = false
    }
    private var tracks: [Track] = []
    private var nextID = 1
    private var passCount = 0
    private var compositePasses = 0

    /// Long side the frame is downscaled to before analysis.
    static let analysisLongSide = 768
    /// Two regions in consecutive passes are the same object above this IoU.
    static let matchIoU: CGFloat = 0.3
    /// A human rectangle explains a region above this overlap of the region.
    static let personOverlap: CGFloat = 0.35
    /// A candidate mostly inside a bigger one of the same kind retraces it.
    static let nestedOverlap: CGFloat = 0.85
    /// Composite backend: heat-map pixels below this fraction of the box's peak are background.
    static let saliencyRelativeThreshold: Float = 0.45
    /// Composite backend: label plane long side when no person mask sets one.
    static let compositePlaneLongSide = 320
    /// Composite backend: heat-map cells above this fraction of the global peak form blobs.
    static let heatBlobThreshold: Float = 0.55
    /// How often a label is re-derived, by source.
    static let classifierRefresh: TimeInterval = 3
    static let modelRefresh: TimeInterval = 8
    /// Bounding-box smoothing: weight of the newest sighting.
    static let boxSmoothing: CGFloat = 0.55
    /// Most outline points kept per region.
    static let maxOutlinePoints = 220

    // MARK: Lifecycle

    func attach(namer: RegionNamer) async {
        self.namer = namer
        namerAvailable = await namer.isAvailable
        if namerAvailable {
            log.notice("Region naming: on-device language model with image input")
        }
    }

    func reset() {
        tracks.removeAll()
        pendingNames.removeAll()
    }

    // MARK: Entry

    func analyze(_ frame: CGImage, settings: SegmentationSettings) async -> Result<SceneSegmentation, Error> {
        let frameSize = CGSize(width: frame.width, height: frame.height)
        let image = Self.downscaled(frame, longSide: Self.analysisLongSide) ?? frame
        let handler = ImageRequestHandler(image)

        let plane: LabelPlane
        do {
            plane = try await segment(image, handler: handler)
        } catch {
            return .failure(error)
        }

        // 1. Candidates: bounds, coverage and confidence per instance, gated.
        var candidates: [Candidate] = []
        if let scan = plane.scan {
            for instance in plane.instances {
                guard let box = scan.boundingBox(of: instance.value) else { continue }
                let coverage = scan.coverage(of: instance.value)
                guard coverage >= settings.minimumCoverage else { continue }
                guard instance.knownLabel != nil || instance.confidence >= settings.minimumConfidence else { continue }
                candidates.append(Candidate(instance: instance, box: box, coverage: coverage))
            }
        }
        // Bigger and surer first; a candidate retracing a kept one is dropped.
        candidates.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for candidate in candidates {
            let retraces = kept.contains { other in
                other.instance.kind == candidate.instance.kind && Self.containment(of: candidate.box, in: other.box) >= Self.nestedOverlap
            }
            if !retraces { kept.append(candidate) }
        }

        // 2. Match candidates to tracks by overlap (keyed by region id, since
        // the track array is about to be pruned); unmatched tracks age.
        var sightedIDs: [Int: Candidate] = [:]
        var claimed = Set<Int>()
        for candidate in kept {
            var best: (index: Int, iou: CGFloat)?
            for index in tracks.indices where !claimed.contains(index) {
                let iou = Self.iou(candidate.box, tracks[index].region.boundingBox)
                if iou >= Self.matchIoU, iou > (best?.iou ?? 0) { best = (index, iou) }
            }
            if let best {
                claimed.insert(best.index)
                sightedIDs[tracks[best.index].region.id] = candidate
            } else {
                let id = nextID
                nextID += 1
                let region = DetectedRegion(
                    id: id,
                    label: candidate.instance.knownLabel ?? "",
                    boundingBox: candidate.box,
                    outline: [],
                    coverage: candidate.coverage,
                    confidence: candidate.instance.confidence,
                    kindWeight: candidate.instance.kind.weight,
                    paletteIndex: id % DetectionPalette.rgb.count
                )
                // Starts at zero hits; this pass's sighting makes it one.
                tracks.append(Track(region: region, hits: 0, requiredHits: settings.confirmationPasses + candidate.instance.kind.extraConfirmation))
                sightedIDs[id] = candidate
            }
        }
        for index in tracks.indices where sightedIDs[tracks[index].region.id] == nil {
            tracks[index].misses += 1
        }
        tracks.removeAll { $0.misses > settings.maximumMisses }

        // 3. Update sighted tracks: smoothed box, fresh outline, confidence.
        if let scan = plane.scan {
            for index in tracks.indices {
                guard let candidate = sightedIDs[tracks[index].region.id] else { continue }
                var track = tracks[index]
                track.hits += 1
                track.misses = 0
                let smoothed = track.hits <= 1 ? candidate.box : Self.blend(track.region.boundingBox, candidate.box, weight: Self.boxSmoothing)
                track.region.boundingBox = smoothed
                track.region.coverage = candidate.coverage
                track.region.confidence = candidate.instance.confidence
                track.region.outline = scan.outline(of: candidate.instance.value, maxPoints: Self.maxOutlinePoints)
                if let known = candidate.instance.knownLabel, track.region.label != known, !track.namedByModel {
                    track.region.label = known
                }
                tracks[index] = track
            }
        }

        // 4. Apply names that arrived from the language model.
        for index in tracks.indices {
            if let name = pendingNames.removeValue(forKey: tracks[index].region.id) {
                tracks[index].region.label = name
                tracks[index].namedByModel = true
                tracks[index].lastNamedAt = .now
            }
        }

        // 5. Confirmed tracks only, best first, capped.
        let confirmed = tracks
            .filter { $0.hits >= $0.requiredHits && $0.region.outline.count >= 3 }
            .sorted { Self.score($0.region) > Self.score($1.region) }
            .prefix(settings.maxRegions)
            .map(\.region)
        let visibleIDs = Set(confirmed.map(\.id))

        // 6. Name what's visible and unnamed or stale, a little per pass.
        await nameRegions(visibleIDs: visibleIDs, sightings: sightedIDs, image: image, handler: handler)

        passCount += 1
        if passCount % 200 == 1 {
            log.notice("pass \(self.passCount) [\(self.backend.rawValue)]: \(kept.count) candidate(s), \(self.tracks.count) track(s), \(confirmed.count) drawn")
        }

        return .success(SceneSegmentation(
            regions: tracks.filter { visibleIDs.contains($0.region.id) }.map(\.region),
            frameSize: frameSize,
            analyzedAt: .now
        ))
    }

    private struct Candidate {
        let instance: LabelPlane.Instance
        let box: CGRect
        let coverage: CGFloat
        var score: CGFloat { instance.kind.weight * coverage.squareRoot() * instance.confidence }
    }

    /// Significance: people outrank objects, which outrank flat rectangles.
    private static func score(_ region: DetectedRegion) -> CGFloat {
        region.kindWeight * region.coverage.squareRoot() * region.confidence
    }

    // MARK: Backends

    /// Runs whichever backend this runtime supports and returns a label plane.
    private func segment(_ image: CGImage, handler: ImageRequestHandler) async throws -> LabelPlane {
        switch backend {
        case .foregroundInstances:
            return try await segmentForegroundInstances(handler: handler)

        case .cpuComposite:
            return try await segmentComposite(image: image, handler: handler)

        case .undecided:
            // Probe the primary path on the default compute devices.
            do {
                let plane = try await segmentForegroundInstances(handler: handler)
                backend = .foregroundInstances
                log.notice("Segmentation backend: foreground instances")
                return plane
            } catch {
                log.notice("Foreground instance masks unavailable here (\(error.localizedDescription)); pinning Vision to the CPU")
            }

            // No GPU/ANE inference context. Pin everything to the CPU and, if the
            // foreground model has a CPU path, try it once more.
            pinAllToCPU()
            classifierUsable = await Self.classifierDiscriminates(classifyRequest)
            if !classifierUsable {
                log.notice("Image classifier is degenerate on this runtime; labels will come from heuristics")
            }
            if Self.supportsCPU(foregroundRequest) {
                if let plane = try? await segmentForegroundInstances(handler: handler) {
                    backend = .foregroundInstances
                    log.notice("Segmentation backend: foreground instances (CPU)")
                    return plane
                }
            }

            // Otherwise compose people + salient objects, which the simulator can run.
            let plane = try await segmentComposite(image: image, handler: handler)
            backend = .cpuComposite
            log.notice("Segmentation backend: CPU composite (person mask + saliency + rectangles)")
            return plane
        }
    }

    /// Primary: one instance per salient object, plus human rectangles to name people.
    private func segmentForegroundInstances(handler: ImageRequestHandler) async throws -> LabelPlane {
        let (observation, humans) = try await handler.perform(foregroundRequest, humanRequest)
        let humanBoxes = humans.map { Self.upperLeft($0.boundingBox) }
        guard let observation, let scan = MaskScan(observation.allInstancesMask) else {
            return LabelPlane(scan: nil, instances: [], humanBoxes: humanBoxes)
        }
        var instances: [LabelPlane.Instance] = []
        for index in observation.allInstances where index > 0 && index < 256 {
            let value = UInt8(index)
            let isPerson = scan.boundingBox(of: value).map { Self.isPerson($0, humanBoxes: humanBoxes) } ?? false
            instances.append(LabelPlane.Instance(
                value: value,
                kind: .object,
                confidence: 0.8,
                knownLabel: isPerson ? "Person" : nil,
                source: .maskedInstance(index, observation)
            ))
        }
        return LabelPlane(scan: scan, instances: instances, humanBoxes: humanBoxes)
    }

    /// Composite: people from faces (and the person mask where it works),
    /// other objects from objectness saliency and rectangle detection, all
    /// painted into one label plane.
    private func segmentComposite(image: CGImage, handler: ImageRequestHandler) async throws -> LabelPlane {
        let (faces, saliency, rectangles) = try await handler.perform(faceRequest, saliencyRequest, rectangleRequest)
        let faceBoxes = faces.map { Self.upperLeft($0.boundingBox).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let personMask: PixelBufferObservation? = personMaskUsable ? try await handler.perform(personSegmentationRequest) : nil

        var scan: MaskScan
        var instances: [LabelPlane.Instance] = []
        var personBoxes: [CGRect] = []

        compositePasses += 1
        if compositePasses % 300 == 1 {
            let personPixels = personMask.flatMap { MaskScan(observation: $0) }.map { plane in
                plane.labels.reduce(into: 0) { if $1 >= 128 { $0 += 1 } }
            } ?? -1
            log.notice("composite \(self.compositePasses): faces=\(faces.count) personPixels=\(personPixels) salient=\(saliency.salientObjects.count) rectangles=\(rectangles.count) confidences=\(rectangles.map { String(format: "%.2f", $0.confidence) })")
        }

        if let personMask, var personScan = MaskScan(thresholding: personMask, at: 128) {
            // A working mask: split it into people by face.
            let count = personScan.splitForeground(among: faceBoxes)
            scan = personScan
            for value in 1...max(1, count) {
                let label = UInt8(value)
                guard let box = scan.boundingBox(of: label) else { continue }
                personBoxes.append(box)
                let face = faces.first { Self.containment(of: Self.upperLeft($0.boundingBox), in: box) >= 0.5 }
                let confidence = face.map { CGFloat($0.confidence) } ?? 0.7
                instances.append(LabelPlane.Instance(value: label, kind: .person, confidence: confidence, knownLabel: "Person", source: .none))
            }
        } else {
            if personMask != nil, !faces.isEmpty {
                // A face in frame and not one person pixel: the mask is dead here.
                personMaskUsable = false
                log.notice("Person mask returns nothing with a face in frame; drawing people from faces from now on")
            }
            let aspect = CGFloat(image.height) / CGFloat(image.width)
            let width = aspect <= 1 ? Self.compositePlaneLongSide : Int(CGFloat(Self.compositePlaneLongSide) / aspect)
            let height = aspect <= 1 ? Int(CGFloat(Self.compositePlaneLongSide) * aspect) : Self.compositePlaneLongSide
            scan = MaskScan(width: max(1, width), height: max(1, height))

            // Head-and-shoulders silhouette per face.
            var value: UInt8 = 1
            for (face, box) in zip(faces, faceBoxes) where !box.isNull && box.width > 0 && value < 250 {
                let painted = scan.paintSilhouette(value: value, face: box)
                guard painted > 0, let bounds = scan.boundingBox(of: value) else { continue }
                personBoxes.append(bounds)
                instances.append(LabelPlane.Instance(value: value, kind: .person, confidence: CGFloat(face.confidence), knownLabel: "Person", source: .none))
                value += 1
            }
        }

        // Salient objects that aren't just a person again. When Vision offers
        // no object boxes, carve blobs out of the heat map instead.
        let heat = FloatPlane(saliency.heatMap)
        var boxes = saliency.salientObjects.map {
            Self.upperLeft($0.boundingBox).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if boxes.isEmpty, let heat {
            boxes = heat.blobs(relativeThreshold: Self.heatBlobThreshold, minimumCoverage: 0.004, limit: 3)
        }

        var nextValue = UInt8(min(instances.count + 1, 254))
        for box in boxes {
            guard !box.isNull, box.width > 0, box.height > 0, nextValue < 255 else { continue }
            let coveredByPerson = personBoxes.contains { Self.containment(of: box, in: $0) >= 0.5 }
                || faceBoxes.contains { Self.containment(of: $0, in: box) >= 0.5 }
            guard !coveredByPerson else { continue }

            // Saliency confidence: the heat peak inside the box, on a 0…1 scale.
            let peak = heat?.peak(in: box) ?? 0
            let confidence = CGFloat(min(1, peak / 0.6))
            let painted = scan.paint(value: nextValue, in: box, heat: heat, relativeThreshold: Self.saliencyRelativeThreshold)
            guard painted > 0 else { continue }
            instances.append(LabelPlane.Instance(value: nextValue, kind: .object, confidence: confidence, knownLabel: nil, source: .crop(box)))
            nextValue += 1
        }

        // Flat rectangular objects, unless they retrace a region we already
        // have or lie on a person (faces and clothing throw false rectangles).
        var claimed = personBoxes + boxes
        for rectangle in rectangles {
            guard nextValue < 255 else { break }
            let quad = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
                .map { $0.toImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft) }
            let box = Self.upperLeft(rectangle.boundingBox).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, box.width * box.height >= Self.minimumRectangleCoverage else { continue }
            let retraces = claimed.contains { Self.iou(box, $0) >= 0.5 }
            let onPerson = personBoxes.contains { Self.containment(of: box, in: $0) >= 0.5 }
                || faceBoxes.contains { Self.containment(of: $0, in: box) >= 0.3 || Self.containment(of: box, in: $0) >= 0.3 }
            guard !retraces, !onPerson else { continue }

            let painted = scan.paintQuad(value: nextValue, quad: quad, within: box)
            guard painted > 0 else { continue }
            claimed.append(box)
            instances.append(LabelPlane.Instance(
                value: nextValue,
                kind: .rectangle,
                confidence: CGFloat(rectangle.confidence),
                knownLabel: nil,
                source: .crop(box)
            ))
            nextValue += 1
        }

        return LabelPlane(scan: scan, instances: instances, humanBoxes: personBoxes)
    }

    // MARK: Naming

    /// Language model first (one request in flight, results land next pass),
    /// then Vision's classifier, then heuristics.
    private func nameRegions(visibleIDs: Set<Int>, sightings: [Int: Candidate], image: CGImage, handler: ImageRequestHandler) async {
        // Re-check every pass: the namer stands down after repeated failures.
        let modelReady: Bool
        if let namer { modelReady = await namer.isAvailable } else { modelReady = false }
        if modelReady != namerAvailable {
            namerAvailable = modelReady
            log.notice("Language-model naming \(modelReady ? "available" : "unavailable"); \(modelReady ? "model" : "fallback") labels from here")
        }

        var classifierBudget = 2
        for index in tracks.indices where visibleIDs.contains(tracks[index].region.id) {
            let track = tracks[index]
            guard let candidate = sightings[track.region.id] else { continue }
            // People are known from the mask; the model can still refine them later.
            if candidate.instance.kind == .person, !track.region.label.isEmpty, !modelReady { continue }

            let refresh = track.namedByModel ? Self.modelRefresh : Self.classifierRefresh
            let stale = track.lastNamedAt.map { Date.now.timeIntervalSince($0) > refresh } ?? true
            guard track.region.label.isEmpty || stale else { continue }

            guard let crop = try? Self.crop(for: candidate.instance, image: image, handler: handler) else { continue }

            if modelReady, let namer, !namingInFlight {
                namingInFlight = true
                tracks[index].lastNamedAt = .now
                let id = track.region.id
                Task { [weak self] in
                    let name = await namer.name(crop)
                    await self?.deliverName(name, for: id)
                }
                // Until the model answers, show the best fallback rather than nothing.
                if tracks[index].region.label.isEmpty, let label = await fallbackLabel(for: crop, kind: candidate.instance.kind) {
                    tracks[index].region.label = label
                }
                continue
            }

            guard classifierBudget > 0, !track.namedByModel else { continue }
            if let label = await fallbackLabel(for: crop, kind: candidate.instance.kind) {
                if track.region.label.isEmpty || !candidate.instance.kind.isPerson {
                    tracks[index].region.label = label
                }
            } else if tracks[index].region.label.isEmpty {
                tracks[index].region.label = "Object"
            }
            tracks[index].lastNamedAt = .now
            classifierBudget -= 1
        }
    }

    private func deliverName(_ name: String?, for id: Int) {
        namingInFlight = false
        if let name { pendingNames[id] = name }
    }

    /// Vision's classifier when it works here; else printed text makes it a
    /// document and everything else is an object.
    private func fallbackLabel(for crop: CGImage, kind: LabelPlane.Instance.Kind) async -> String? {
        if kind == .person { return "Person" }
        do {
            if classifierUsable {
                let results = try await classifyRequest.perform(on: crop)
                let confident = results
                    .filter { $0.hasMinimumPrecision(0.15, forRecall: 0.7) }
                    .max { $0.confidence < $1.confidence }
                let best = confident ?? results.filter { $0.confidence >= 0.1 }.max { $0.confidence < $1.confidence }
                if let best { return Self.displayLabel(best.identifier) }
            }
            let text = try await textRequest.perform(on: crop)
            return text.count >= 2 ? "Document" : "Object"
        } catch {
            return nil
        }
    }

    /// The pixels to name: the masked instance, or a crop of the frame.
    private static func crop(for instance: LabelPlane.Instance, image: CGImage, handler: ImageRequestHandler) throws -> CGImage? {
        switch instance.source {
        case .none:
            return nil
        case .maskedInstance(let index, let observation):
            let masked = try observation.generateMaskedImage(
                for: IndexSet(integer: index),
                imageFrom: handler,
                croppedToInstancesExtent: true
            )
            return cgImage(from: masked)
        case .crop(let normalized):
            // A little context around the object helps both namers.
            let padded = normalized.insetBy(dx: -normalized.width * 0.08, dy: -normalized.height * 0.08)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixelRect = CGRect(
                x: padded.minX * CGFloat(image.width),
                y: padded.minY * CGFloat(image.height),
                width: padded.width * CGFloat(image.width),
                height: padded.height * CGFloat(image.height)
            ).integral
            return image.cropping(to: pixelRect)
        }
    }

    /// "coffee_cup" → "Coffee Cup"; never more than two words.
    static func displayLabel(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .prefix(2)
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    /// Two frames the classifier must tell apart: flat black and flat white.
    /// A classifier that ranks them identically isn't seeing the pixels.
    private static func classifierDiscriminates(_ request: ClassifyImageRequest) async -> Bool {
        func flat(_ gray: CGFloat) -> CGImage? {
            guard let context = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return context.makeImage()
        }
        guard let black = flat(0), let white = flat(1),
              let a = try? await request.perform(on: black),
              let b = try? await request.perform(on: white)
        else { return false }
        let top = { (results: [ClassificationObservation]) in
            results.sorted { $0.confidence > $1.confidence }.prefix(5).map(\.identifier)
        }
        return top(a) != top(b)
    }

    private static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent)
    }

    // MARK: Geometry

    private static func isPerson(_ box: CGRect, humanBoxes: [CGRect]) -> Bool {
        humanBoxes.contains { containment(of: box, in: $0) >= personOverlap }
    }

    /// Fraction of `inner`'s area that lies inside `outer`.
    private static func containment(of inner: CGRect, in outer: CGRect) -> CGFloat {
        guard inner.width > 0, inner.height > 0 else { return 0 }
        let overlap = inner.intersection(outer)
        guard !overlap.isNull else { return 0 }
        return (overlap.width * overlap.height) / (inner.width * inner.height)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let inter = overlap.width * overlap.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    private static func blend(_ old: CGRect, _ new: CGRect, weight: CGFloat) -> CGRect {
        CGRect(
            x: old.minX + (new.minX - old.minX) * weight,
            y: old.minY + (new.minY - old.minY) * weight,
            width: old.width + (new.width - old.width) * weight,
            height: old.height + (new.height - old.height) * weight
        )
    }

    /// Vision boxes are lower-left normalized; the Deck draws upper-left.
    private static func upperLeft(_ rect: NormalizedRect) -> CGRect {
        rect.toImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft)
    }

    // MARK: Compute device

    private func pinAllToCPU() {
        Self.pinToCPU(&foregroundRequest)
        Self.pinToCPU(&humanRequest)
        Self.pinToCPU(&personSegmentationRequest)
        Self.pinToCPU(&saliencyRequest)
        Self.pinToCPU(&faceRequest)
        Self.pinToCPU(&rectangleRequest)
        Self.pinToCPU(&classifyRequest)
        Self.pinToCPU(&textRequest)
    }

    private static func supportsCPU<R: VisionRequest>(_ request: R) -> Bool {
        request.supportedComputeStageDevices.values.contains { devices in
            devices.contains { device in
                if case .cpu = device { return true }
                return false
            }
        }
    }

    /// Assigns the CPU device to every compute stage the request supports.
    private static func pinToCPU<R: VisionRequest>(_ request: inout R) {
        for (stage, devices) in request.supportedComputeStageDevices {
            let cpu = devices.first { device in
                if case .cpu = device { return true }
                return false
            }
            if let cpu {
                request.setComputeDevice(cpu, for: stage)
            }
        }
    }

    // MARK: Input

    /// Vision would downscale internally anyway; doing it once here keeps the
    /// crops and the per-pass cost predictable.
    private static func downscaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longSide else { return image }
        let scale = CGFloat(longSide) / CGFloat(longest)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Label plane

/// What a backend hands back: a plane of instance values plus what it already
/// knows about each instance.
nonisolated private struct LabelPlane {
    enum Source {
        case none
        /// Classify the masked, cropped instance from the primary observation.
        case maskedInstance(Int, InstanceMaskObservation)
        /// Classify this normalized (upper-left) crop of the analyzed image.
        case crop(CGRect)
    }

    struct Instance {
        enum Kind {
            case person, object, rectangle
            var isPerson: Bool { self == .person }
            /// Multiplier on significance when ranking and capping regions.
            var weight: CGFloat {
                switch self {
                case .person: 1.6
                case .object: 1.0
                case .rectangle: 0.55
                }
            }
            /// Noisier sources must persist longer before they're drawn.
            var extraConfirmation: Int { self == .rectangle ? 1 : 0 }
        }
        let value: UInt8
        let kind: Kind
        /// 0…1 detector confidence.
        let confidence: CGFloat
        let knownLabel: String?
        let source: Source
    }

    let scan: MaskScan?
    let instances: [Instance]
    /// Upper-left normalized boxes of people, for naming.
    let humanBoxes: [CGRect]
}

/// A copy of an instance-label plane, one byte per pixel (0 = background).
nonisolated private struct MaskScan: Sendable {
    let width: Int
    let height: Int
    var labels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        labels = [UInt8](repeating: 0, count: width * height)
    }

    /// Raw copy of an 8-bit observation, values untouched (for diagnostics).
    init?(observation: PixelBufferObservation) {
        self.init(observation)
    }

    /// Copies an 8-bit instance mask out of a Vision observation.
    init?(_ observation: PixelBufferObservation) {
        let copied: (Int, Int, [UInt8])? = observation.pixelBuffer.withUnsafeBuffer { buffer -> (Int, Int, [UInt8])? in
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            var labels = [UInt8](repeating: 0, count: width * height)
            labels.withUnsafeMutableBytes { destination in
                for y in 0..<height {
                    destination.baseAddress!.advanced(by: y * width)
                        .copyMemory(from: base.advanced(by: y * bytesPerRow), byteCount: width)
                }
            }
            return (width, height, labels)
        }
        guard let (width, height, labels) = copied, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        self.labels = labels
    }

    /// Copies an 8-bit confidence mask, mapping values at or above `cut` to
    /// label 1 and everything else to background. Nil when nothing clears it.
    init?(thresholding observation: PixelBufferObservation, at cut: UInt8) {
        guard var scan = MaskScan(observation) else { return nil }
        var any = false
        for index in scan.labels.indices {
            if scan.labels[index] >= cut {
                scan.labels[index] = 1
                any = true
            } else {
                scan.labels[index] = 0
            }
        }
        guard any else { return nil }
        self = scan
    }

    /// Reassigns every label-1 pixel to instance 1…N by the human box
    /// (upper-left normalized) that contains it, or the nearest box center.
    /// With no boxes the foreground stays one instance. Returns N.
    mutating func splitForeground(among boxes: [CGRect]) -> Int {
        guard boxes.count > 1 else { return 1 }
        let centers = boxes.map { CGPoint(x: $0.midX, y: $0.midY) }
        for y in 0..<height {
            let row = y * width
            let v = (CGFloat(y) + 0.5) / CGFloat(height)
            for x in 0..<width where labels[row + x] == 1 {
                let u = (CGFloat(x) + 0.5) / CGFloat(width)
                let point = CGPoint(x: u, y: v)
                var owner = boxes.firstIndex { $0.contains(point) }
                if owner == nil {
                    var best = CGFloat.greatestFiniteMagnitude
                    for (index, center) in centers.enumerated() {
                        let distance = hypot(center.x - u, center.y - v)
                        if distance < best { best = distance; owner = index }
                    }
                }
                labels[row + x] = UInt8(min((owner ?? 0) + 1, 254))
            }
        }
        return min(boxes.count, 254)
    }

    func boundingBox(of label: UInt8) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where labels[row + x] == label {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    func coverage(of label: UInt8) -> CGFloat {
        var count = 0
        for value in labels where value == label { count += 1 }
        return CGFloat(count) / CGFloat(width * height)
    }

    /// Paints `value` over the background pixels inside `box` (upper-left
    /// normalized) whose saliency clears a fraction of the box's peak. Falls
    /// back to the whole box when the heat map has nothing to say there.
    /// Returns the number of pixels painted.
    mutating func paint(value: UInt8, in box: CGRect, heat: FloatPlane?, relativeThreshold: Float) -> Int {
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let x1 = min(width - 1, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int(box.minY * CGFloat(height)))
        let y1 = min(height - 1, Int(box.maxY * CGFloat(height)))
        guard x0 <= x1, y0 <= y1 else { return 0 }

        let peak = heat?.peak(in: box) ?? 0
        let cut = peak > 0.05 ? peak * relativeThreshold : -1

        var painted = 0
        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 where labels[row + x] == 0 {
                if let heat, cut >= 0 {
                    let sample = heat.sample(u: (CGFloat(x) + 0.5) / CGFloat(width), v: (CGFloat(y) + 0.5) / CGFloat(height))
                    guard sample >= cut else { continue }
                }
                labels[row + x] = value
                painted += 1
            }
        }
        return painted
    }

    /// Paints a head-and-shoulders silhouette for a face box (normalized,
    /// upper-left): an ellipse around the head and a wider one for the
    /// shoulders below it. Returns the number of pixels painted.
    mutating func paintSilhouette(value: UInt8, face: CGRect) -> Int {
        // Head: the face box grown to include hair and chin.
        let head = (center: CGPoint(x: face.midX, y: face.midY - face.height * 0.08),
                    rx: face.width * 0.72, ry: face.height * 0.78)
        // Shoulders: a wide ellipse whose top sits at the chin.
        let shoulders = (center: CGPoint(x: face.midX, y: face.maxY + face.height * 1.05),
                         rx: face.width * 1.7, ry: face.height * 0.95)
        var painted = 0
        for y in 0..<height {
            let v = (CGFloat(y) + 0.5) / CGFloat(height)
            let row = y * width
            for x in 0..<width where labels[row + x] == 0 {
                let u = (CGFloat(x) + 0.5) / CGFloat(width)
                let inHead = Self.inside(u, v, head.center, head.rx, head.ry)
                let inShoulders = v >= face.maxY && Self.inside(u, v, shoulders.center, shoulders.rx, shoulders.ry)
                if inHead || inShoulders {
                    labels[row + x] = value
                    painted += 1
                }
            }
        }
        return painted
    }

    private static func inside(_ u: CGFloat, _ v: CGFloat, _ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> Bool {
        guard rx > 0, ry > 0 else { return false }
        let dx = (u - center.x) / rx, dy = (v - center.y) / ry
        return dx * dx + dy * dy <= 1
    }

    /// Paints `value` over background pixels inside a convex quad (normalized,
    /// upper-left, corners in order). Returns the number of pixels painted.
    mutating func paintQuad(value: UInt8, quad: [CGPoint], within box: CGRect) -> Int {
        guard quad.count == 4 else { return 0 }
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let x1 = min(width - 1, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int(box.minY * CGFloat(height)))
        let y1 = min(height - 1, Int(box.maxY * CGFloat(height)))
        guard x0 <= x1, y0 <= y1 else { return 0 }

        // Inside test: the point is on the same side of every edge.
        func inside(_ p: CGPoint) -> Bool {
            var sign = 0
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                let s = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
                if s == 0 { continue }
                if sign == 0 { sign = s } else if sign != s { return false }
            }
            return true
        }

        var painted = 0
        for y in y0...y1 {
            let row = y * width
            let v = (CGFloat(y) + 0.5) / CGFloat(height)
            for x in x0...x1 where labels[row + x] == 0 {
                let u = (CGFloat(x) + 0.5) / CGFloat(width)
                guard inside(CGPoint(x: u, y: v)) else { continue }
                labels[row + x] = value
                painted += 1
            }
        }
        return painted
    }

    /// Traces the outer boundary of `label` (Moore neighborhood, clockwise)
    /// starting from its top-left pixel, as normalized upper-left points.
    /// Collinear runs are collapsed and the result is thinned to `maxPoints`.
    func outline(of label: UInt8, maxPoints: Int) -> [CGPoint] {
        func at(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && labels[y * width + x] == label
        }
        // Top-left-most pixel of the label.
        var start: (x: Int, y: Int)?
        scan: for y in 0..<height {
            for x in 0..<width where labels[y * width + x] == label {
                start = (x, y)
                break scan
            }
        }
        guard let start else { return [] }

        // Clockwise Moore neighborhood, starting due west.
        let neighbors = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        var points: [(Int, Int)] = [start]
        var current = start
        var backtrack = 0 // index of the neighbor we came from (west for the start)
        let limit = width * height * 2

        while points.count < limit {
            var found: Int?
            for step in 0..<8 {
                let index = (backtrack + step) % 8
                let candidate = (current.x + neighbors[index].0, current.y + neighbors[index].1)
                if at(candidate.0, candidate.1) {
                    found = index
                    break
                }
            }
            guard let found else { break } // isolated pixel
            let next = (current.x + neighbors[found].0, current.y + neighbors[found].1)
            // Continue the search from the neighbor just before the one we entered from.
            backtrack = (found + 6) % 8
            current = next
            if current == start { break }
            points.append(current)
        }
        guard points.count >= 3 else { return [] }

        // Drop points that continue a straight run.
        var simplified: [(Int, Int)] = []
        for (index, point) in points.enumerated() {
            let previous = points[(index + points.count - 1) % points.count]
            let following = points[(index + 1) % points.count]
            let incoming = (point.0 - previous.0, point.1 - previous.1)
            let outgoing = (following.0 - point.0, following.1 - point.1)
            if incoming != outgoing { simplified.append(point) }
        }
        if simplified.count > maxPoints {
            let stride = Double(simplified.count) / Double(maxPoints)
            simplified = (0..<maxPoints).map { simplified[Int(Double($0) * stride)] }
        }
        return simplified.map {
            CGPoint(x: (CGFloat($0.0) + 0.5) / CGFloat(width), y: (CGFloat($0.1) + 0.5) / CGFloat(height))
        }
    }
}

/// A copy of a one-component float plane (the saliency heat map).
nonisolated private struct FloatPlane: Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init?(_ observation: PixelBufferObservation) {
        let copied: (Int, Int, [Float])? = observation.pixelBuffer.withUnsafeBuffer { buffer -> (Int, Int, [Float])? in
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            var values = [Float](repeating: 0, count: width * height)
            values.withUnsafeMutableBytes { destination in
                for y in 0..<height {
                    destination.baseAddress!.advanced(by: y * width * MemoryLayout<Float>.size)
                        .copyMemory(from: base.advanced(by: y * bytesPerRow), byteCount: width * MemoryLayout<Float>.size)
                }
            }
            return (width, height, values)
        }
        guard let (width, height, values) = copied, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        self.values = values
    }

    /// Nearest sample at normalized (upper-left) coordinates.
    func sample(u: CGFloat, v: CGFloat) -> Float {
        let x = min(width - 1, max(0, Int(u * CGFloat(width))))
        let y = min(height - 1, max(0, Int(v * CGFloat(height))))
        return values[y * width + x]
    }

    /// Highest value inside a normalized box.
    func peak(in box: CGRect) -> Float {
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let x1 = min(width - 1, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int(box.minY * CGFloat(height)))
        let y1 = min(height - 1, Int(box.maxY * CGFloat(height)))
        guard x0 <= x1, y0 <= y1 else { return 0 }
        var peak: Float = 0
        for y in y0...y1 {
            for x in x0...x1 { peak = max(peak, values[y * width + x]) }
        }
        return peak
    }

    /// Connected components of cells above `relativeThreshold` × the global
    /// peak, as normalized (upper-left) boxes, largest first.
    func blobs(relativeThreshold: Float, minimumCoverage: CGFloat, limit: Int) -> [CGRect] {
        guard let peak = values.max(), peak > 0.05 else { return [] }
        let cut = peak * relativeThreshold
        var visited = [Bool](repeating: false, count: width * height)
        var found: [(box: CGRect, area: Int)] = []

        for start in values.indices where !visited[start] && values[start] >= cut {
            var stack = [start]
            visited[start] = true
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, area = 0
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                area += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for neighbor in [index - 1, index + 1, index - width, index + width] {
                    guard neighbor >= 0, neighbor < values.count, !visited[neighbor], values[neighbor] >= cut else { continue }
                    if abs(neighbor - index) == 1, neighbor / width != y { continue }
                    visited[neighbor] = true
                    stack.append(neighbor)
                }
            }
            let coverage = CGFloat(area) / CGFloat(width * height)
            guard coverage >= minimumCoverage else { continue }
            found.append((CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(maxX - minX + 1) / CGFloat(width),
                height: CGFloat(maxY - minY + 1) / CGFloat(height)
            ), area))
        }

        return found.sorted { $0.area > $1.area }.prefix(limit).map(\.box)
    }
}
