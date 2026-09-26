# On-device neural-network capabilities — iOS 27.1 on iPhone Duo

Reference for Morpho. Everything here runs on the device's Neural Engine or
CPU/GPU without a network round trip unless a row says otherwise. Verified
against the iOS 27.1 SDK documentation on 2026-09-25; entries marked
UNVERIFIED could not be confirmed in the docs and should be checked before
use.

Sections: [Device](#0-the-device-itself) · [Language](#1-language) ·
[Vision & imaging](#2-vision--imaging) · [Audio & speech](#3-audio--speech) ·
[Core ML & compute](#4-core-ml--compute) · [Simulator matrix](#5-simulator-matrix) ·
[Morpho fit](#6-where-each-one-fits-morpho)

## 0. The device itself

Not neural, but the sensors and surfaces the neural features plug into.
(From Apple's iPhone Duo developer guide, iOS 27.1 SDK.)

| Capability | API | Notes |
|---|---|---|
| Hinge angle & status | SwiftUI `onHingeChange(isEnabled:_:)` → `DeviceHingeContext` (`hinge?.status` = `.closed` / `.partiallyOpen` / `.fullyOpen`, continuous `angle`); UIKit `UIHingeInteraction` → `UIHinge` | For interactions and effects only; layout uses size classes and reserved regions. Reset derived state when status leaves `.partiallyOpen`. |
| Reserved regions | `GeometryProxy.reservedRegions(kind:)` with `ReservedRegion.Kind.division` (the fold; zero width when flat) and `.occlusion` (cameras; outer always present, inner only while active). Each region has `frame`, `margins`, `isActive`. `.includeInactive` query option. UIKit: `UIViewReservedRegion`. | Morpho already snaps the Rift Slider and orb to these. |
| Arrangement views | `ArrangementView { primary } secondary: { }` with `.arrangementViewStyle(.split / .overlay / .automatic)` | Director mode uses `.overlay`; secondary lands in the upper fold region. |
| Two front cameras | Virtual front camera (`isVirtualDevice`, `activePrimaryConstituent`) limited to 1080p60, no depth; full capability via `builtInInnerUltraWideCamera` / `builtInOuterUltraWideCamera` (square sensors), switch with `AVCaptureDeviceDirectionCoordinator` (AVKit); `dynamicAspectRatio` fills the inner display. | Physical device only. In the simulator Morpho's camera is the USB-tethered iPhone 17e. |
| Scene accessory on the outer display | `sceneAccessory` modifier with `CameraCaptureAccessory`; `onAvailabilityChange` | Shows UI on the outer display while a camera app is full screen inside (teleprompter, subject preview). Candidate for a "what the subject sees" panel. |
| Displays | Outer 5.4″ (compact width / regular height portrait), inner 7.6″ (regular / regular) | Vertical system bars on the outer display and inner-landscape. |

## 1. Language

Verified against the iOS 27.1 SDK Swift interfaces, ObjC headers and
`.swiftdoc` comments (the docs reader returned metadata only).

### 1.1 Foundation Models — the on-device LLM (`import FoundationModels`, iOS 26+)

**`SystemLanguageModel`**
- `SystemLanguageModel.default`; `init(useCase: .general | .contentTagging, guardrails: .default | .permissiveContentTransformations)`; `availability` → `.available` / `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`; `isAvailable`; `supportedLanguages`; `supportsLocale(_:)`; `contextSize` (swiftdoc: **4,096 tokens**, covering instructions, prompt, tools and output; see TN3193); `Observable`.
- iOS 26.4: `tokenCount(for:)` overloads (prompt, `Instructions`, tools, `GenerationSchema`, transcript entries).
- **iOS 27**: `capabilities: LanguageModelCapabilities` (`.vision`, `.guidedGeneration`, `.reasoning`, `.toolCalling`); `variant` `.core3` (on-device) / `.coreAdvanced3` (runs on Private Cloud Compute); `executorConfiguration`; conforms to the new `LanguageModel` protocol; error `assetsUnavailable`.
- **Adapters** (`init(adapter:)`, `SystemLanguageModel.Adapter`, `compile()`): iOS 26.0, deprecated 26.4, **obsoleted in 27.0**. The iOS 27 replacement is the custom-provider API below.
- No permission or usage string; requires Apple Intelligence enabled on an eligible device.

**`LanguageModelSession`**
- Inits: `(model:tools:instructions:)` with `String`, `Instructions`, or `@InstructionsBuilder`; `(model:tools:transcript:)`. **iOS 27**: `model: some LanguageModel`, `init(profile:history:)`, `init(model:dynamicInstructions:history:)`.
- State: `transcript`, `isResponding`, `prewarm(promptPrefix:)`; **iOS 27** `usage` (`input.totalTokenCount`, `input.cachedTokenCount`, `output.reasoningTokenCount`), `transcriptErrorHandlingPolicy` (`.revertTranscript` / `.preserveTranscript`), `properties: SessionPropertyValues`.
- Generate: `respond(to: String | Prompt, options:)` → `Response<String>`; `respond(to:generating: Content.Type, includeSchemaInPrompt:options:)` → `Response<Content: Generable>`; `respond(to:schema: GenerationSchema)` → `Response<GeneratedContent>`; `@PromptBuilder` variants. **iOS 27** overloads add `contextOptions:` and `metadata:`.
- Stream: matching `streamResponse(…)` → `ResponseStream<Content>`; each `Snapshot` has `content: Content.PartiallyGenerated`, `rawContent`, `transcriptEntries`, and (27) `usage`; `collect()` returns the final response.
- Transcript entries `.instructions / .prompt / .toolCalls / .toolOutput / .response`, **iOS 27** `.reasoning`; segments `.text / .structure`, iOS 27 `.attachment`; iOS 27 `history: HistoryView`.
- Errors (`GenerationError`, iOS 26): `exceededContextWindowSize`, `assetsUnavailable`, `guardrailViolation`, `unsupportedGuide`, `unsupportedLanguageOrLocale`, `decodingFailure`, `rateLimited`, `concurrentRequests`, `refusal(Refusal, Context)` (`explanation` / `explanationStream`); `ToolCallError(tool:underlyingError:)`. **iOS 27**: `LanguageModelSession.Error` (`.concurrentRequests`, `.transcriptMutationWhileResponding`) and provider-level `LanguageModelError` (`contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`, `unsupportedLanguageOrLocale`, `timeout`).
- `logFeedbackAttachment(sentiment:issues:desiredOutput:)`.

**Guided generation** — `@Generable(description:)` (iOS 27 adds `name:` and `representNilExplicitlyInGeneratedContent:`), `@Guide(description:)`, `@Guide(description:, GenerationGuide…)`, `@Guide(description:, Regex)`. `GenerationGuide`: `constant`, `anyOf`, `pattern`, `minimum / maximum / range` (Int, Float, Double, Decimal), `minimumCount / maximumCount / count / element` for arrays. Runtime schemas: `GenerationSchema`, `DynamicGenerationSchema`, `GeneratedContent`, `PartiallyGenerated`.

**Tool calling** — `protocol Tool { name; description; parameters: GenerationSchema; includesSchemaInInstructions; Arguments: ConvertibleFromGeneratedContent; Output: PromptRepresentable; call(arguments:) }`; the session invokes tools itself. **iOS 27**: `GenerationOptions.toolCallingMode` (`.allowed / .required / .disallowed`), capability `.toolCalling`, `.reasoning` transcript entries, and built-in tools `OCRTool`, `BarcodeReaderTool` (module `_Vision_FoundationModels`) and `SpotlightSearchTool` (§1.5).

**Options** — `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`; `sampling` `.greedy`, `.random(top:seed:)`, `.random(probabilityThreshold:seed:)`; iOS 27 `toolCallingMode`. **iOS 27** `ContextOptions(includeSchemaInPrompt:reasoningLevel:)` with `ReasoningLevel` `.light / .moderate / .deep / .custom(String)`.

**iOS 27 additions**
- **Dynamic profiles and instructions**: `LanguageModelSession.DynamicProfile`, `Profile { DynamicInstructions }`, builders (`AnyDynamicInstructions`, `TupleDynamicInstructions`, `ConditionalDynamicInstructions`, `DynamicInstructionsForEach`), modifiers `.model(_:)`, `.temperature`, `.samplingMode`, `.maximumResponseTokens`, `.reasoningLevel`, `.toolCallingMode`, `.historyTransform`, `.transcriptErrorHandlingPolicy`, `.onPrompt / .onResponse / .onReasoning / .onToolCall / .onToolOutput / .onActivate / .onDeactivate`; `@SessionProperty`, `@SessionPropertyEntry`, `SessionPropertyValues`.
- **Image input** (see §2.6): `Attachment<ImageAttachmentContent>` from `CGImage`, `CIImage`, `CVPixelBuffer`, `imageURL:` or `UIImage` (`_FoundationModels_UIKit`); `ImageReference` as a `Generable` tool argument; gate on `capabilities.contains(.vision)`.
- **Custom model provider**: `protocol LanguageModel`, `LanguageModelExecutor`, `LanguageModelExecutorGenerationRequest`, `LanguageModelExecutorGenerationChannel`; pairs with the **CoreAI** framework (§4) per "Running a Core AI model in a Foundation Models session".
- **`PrivateCloudComputeLanguageModel`** — **not on-device**: `availability`, `quotaUsage`, async `contextSize`; errors `NetworkFailure`, `QuotaLimitReached`, `ServiceUnavailable`; needs a managed entitlement.

- Simulator: likely. `FoundationModels.framework` plus the private `ModelCatalog` runtime are in the iOS 27.1 simulator runtime and the host is an Apple-silicon Mac with Apple Intelligence; STAGING notes availability is flaky, so always gate on `availability` and keep the template fallback.
- Morpho fit: the Alchemist's core. One prewarmed session per Deck mode (or one session with dynamic profiles), `@Generable` edit commands whose fields are constrained with `.anyOf(realmNames)` and `.range`, Deck controls exposed as `Tool`s with `.required` routing, `.greedy` sampling with a low `maximumResponseTokens` and `.light` reasoning for latency, and a keyframe attachment so "make *that* sky purple" resolves against what the camera sees. `contentTagging` is a cheap way to turn casual speech into style tags.

### 1.2 NaturalLanguage (iOS 12+; no 26/27 header changes; no permissions)

- `NLTagger(tagSchemes:)`: `tags(in:unit:scheme:options:)`, `tag(at:…)`, `tagHypotheses(at:…maximumCount:)`, `dominantLanguage`, `setModels(_:forTagScheme:)`, `setGazetteers`, `requestAssets(for:tagScheme:)`. Schemes: `.tokenType`, `.lexicalClass`, `.nameType`, `.nameTypeOrLexicalClass`, `.lemma`, `.language`, `.script`, `.sentimentScore` (13; −1…1 per sentence or paragraph; language list UNVERIFIED).
- `NLLanguageRecognizer`: `dominantLanguage(for:)`, `languageHypotheses(withMaximum:)`, `languageHints`, `languageConstraints`.
- `NLTokenizer(unit:)` word / sentence / paragraph / document.
- `NLEmbedding` (13 word, 14 sentence): `wordEmbedding(for:)`, `sentenceEmbedding(for:)`, `distance(between:and:)`, `neighbors(for:maximumCount:)`, `vector(for:)`; custom embeddings via `write` / `init(contentsOf:)`.
- `NLContextualEmbedding` (17; BERT-style token vectors): `contextualEmbedding(with: NLLanguage | NLScript)`, `contextualEmbeddings(for:)`, `load()`, `embeddingResult(for:language:)` → `enumerateTokenVectors`, `hasAvailableAssets`, `requestAssets`, `maximumSequenceLength`, `dimension`. iOS 17: 27 languages over Latin, Cyrillic and CJK models; iOS 18 adds Arabic, Indic scripts, Thai. Assets download on demand.
- `NLModel` (12): Create ML text classifiers and word taggers, pluggable into `NLTagger`; `NLGazetteer` (13).
- Simulator: likely (no Apple Intelligence gate); contextual-embedding asset download UNVERIFIED.
- Morpho fit: a zero-latency pre-pass before the LLM — `NLLanguageRecognizer` to pick the prompt language, `.lexicalClass` to strip fillers ("uhh", "kinda"), `NLEmbedding.sentenceEmbedding` to fuzzy-match casual speech to the nearest Realm preset (a smarter `PromptTemplates.curated`).

### 1.3 Translation (iOS 18+; on-device after language packs install)

- `TranslationSession` (no public init; obtained through SwiftUI): `translate(_: String)`, `translate(_: AttributedString)` (26.4), `translate(batch: [Request])` → `BatchResponse` (async sequence), `translations(from:)`, `prepareTranslation()`, `isReady`, `canRequestDownloads`; `Configuration(source:target:)`. **iOS 26.4**: `Strategy.highFidelity` (Apple Intelligence models when available, else `.lowLatency` traditional models), `preferredStrategy`; `AttributeScopes.TranslationAttributes` (`SkipTranslationAttribute`).
- `LanguageAvailability` (18): `supportedLanguages`, `status(from:to:)` / `status(for:to:)` → `.installed / .supported / .unsupported`.
- SwiftUI: `.translationPresentation(isPresented:text:…)` (17.4, system overlay), `.translationTask(_:action:)` / `.translationTask(source:target:action:)` (18), `preferredStrategy:` (26.4). `TranslationUIProvider` (18.4) is the default-translation-app extension point.
- Errors: `unsupportedSourceLanguage`, `unsupportedTargetLanguage`, `unsupportedLanguagePairing`, `unableToIdentifyLanguage`, `nothingToTranslate`, `alreadyCancelled`, `notInstalled`, `internalError`.
- The system prompts the user to download packs; no usage string. Simulator: unknown (framework present; pack download UNVERIFIED).
- Morpho fit: medium; translate non-English casting into English before the prompt compiler; the batch API suits multi-clause commands.

### 1.4 Writing Tools, Smart Reply, Genmoji (system UI over Apple Intelligence)

- **Writing Tools** — no programmatic rewrite or summarize API; Foundation Models is the programmatic route. SwiftUI `.writingToolsBehavior(.automatic / .complete / .limited / .disabled)` (18), `.writingToolsAffordanceVisibility` (18.4). UIKit `UITextInputTraits.writingToolsBehavior`, `allowedWritingToolsResultOptions` (18), `UIWritingToolsCoordinator` (18.2) for custom text views, iOS 26 `includesTextListMarkers`. **iOS 27** grammar-check hooks: `TextReplacementReason.accepted / .rejected / .temporary`, `TextAnimation.indicateGrammar`, `startTextAnimation(_:for:in:writingDirection:)`, `UITextInputTraits.grammarCheckingType`. Some operations may use Private Cloud Compute (UNVERIFIED).
- **Smart Reply** (18.4): `UISmartReplySuggestion` (`smartReply`), `UITextInput.insertInputSuggestion(_:)`; keyboard-generated for messaging and mail contexts.
- **Genmoji**: `NSAdaptiveImageGlyph` (18; `imageContent`, `contentIdentifier`, `contentDescription`), `NSAdaptiveImageGlyphAttributeName`, `UITextInput.supportsAdaptiveImageGlyph`; created through Image Playground's `onAdaptiveImageGlyphCreation` (§2.4). `ImagePlaygroundConcept.extracted(from:title:)` performs on-device concept extraction from text.
- Morpho fit: low. A Genmoji badge per Realm minted from the spoken prompt is a flourish, not core.

### 1.5 Core Spotlight semantic search and App Intents routing

- `CSUserQuery(userQueryString:userQueryContext:)` (16; semantic ranking 18): `CSUserQueryContext.disableSemanticSearch`, `enableRankedResults`, `maxRankedResultCount`, `CSUserQuery.prepare()`, engagement feedback `userEngaged(with:visibleItems:userInteractionType:)`, async `responses` / `suggestions`. On-device; Apple Intelligence eligibility for semantic mode UNVERIFIED.
- **iOS 27 `SpotlightSearchTool: Tool`** (`_CoreSpotlight_FoundationModels`): `Configuration(sources: [.coreSpotlight | .files …], guide: Guide(level: .complete | .focused(domain) | .dynamic(GuidanceProfile), format: .structured | .compact), contactResolver:, customStages:, maximumResponseSize:)`; `SearchReply.Content` `items / scoredItems / groupedItems / count / table / statistic / text`. New Swift `SearchableItem`, `SearchableItemAttribute`, `CSSearchableIndex.protectionClass`.
- **App Intents / Siri**: `AppShortcut(intent:phrases:)` with `AppShortcutPhrase` interpolation is the only public speech-to-intent parser (Siri matches spoken phrases to intents). Assistant Schemas: `@AssistantIntent(schema:)`, `@AssistantEntity`, `@AssistantEnum` across reader, wordProcessor, photos, camera, browser, books, presentation, whiteboard, files, mail, system, spreadsheet, visualIntelligence, journal (per-domain availability UNVERIFIED). iOS 27 entity indexing: `IndexedEntity`, `@ComputedProperty`, `@DeferredProperty(indexingKey:)`.
- Morpho fit: medium; index Reel takes so `SpotlightSearchTool` can answer "bring back the neon one" inside the Alchemist session, and App Shortcut phrases give hands-free "morph to noir" without the mic UI.

### 1.6 Adjacent: MediaIntelligence (NEW iOS 27; vision only)

`FaceGroupAnalyzer`, `VideoAnalyzer`, `KeyFrameAnalysisRequest`, `MediaIntelligenceVideoAsset` exist in the iOS 27.1 SDK. Details, availability in the simulator and model behavior: UNVERIFIED (surfaced only by the docs index and interface names). Worth a look for picking Reel keyframes and grouping faces across takes.

## 2. Vision & imaging

Verified against the iOS 27.1 SDK Swift interfaces and ObjC headers, with
the simulator SDK compared for parity. Simulator SDK parity: Vision,
VisionKit, ImagePlayground, FoundationModels and Core ML interfaces are
identical between device and simulator. **Absent from the simulator SDK
entirely**: VisualIntelligence, CreateML, Cinematic, CoreAI (guard with
`#if canImport` or weak-link).

### 2.1 Vision framework — Swift-native request API (`import Vision`, iOS 18+)

- Entry: `ImageRequestHandler(cgImage | ciImage | cvPixelBuffer(+AVDepthData) | cmSampleBuffer | url | data, orientation:)` → `perform(request) async throws`, variadic `perform(r1, r2, …)`, `performAll(_:)` as an `AsyncSequence`. Files: `VideoProcessor(url).addRequest(_:cadence: .timeInterval | .frameInterval)`; for the live feed run a handler per frame.
- Every request has `regionOfInterest: NormalizedRect` (lower-left origin by default; `NormalizedRect`/`NormalizedPoint` carry a `CoordinateOrigin`), `revision`, `supportedComputeStageDevices` and `setComputeDevice(_:for:)` with `MLComputeDevice.cpu / .gpu / .neuralEngine`. `supportedComputeStageDevices` is the only public signal of whether a request can use the Neural Engine. No permissions; all on-device.

All 34 request types in the iOS 27.1 SDK (first Swift-API version iOS 18 unless noted):

| Group | Request → observation | Notes |
|---|---|---|
| Segmentation | `GenerateForegroundInstanceMaskRequest` → `InstanceMaskObservation` (`allInstances`, `generateMask(for:)`, `generateMaskedImage(for:imageFrom:croppedToInstancesExtent:)`, `generateScaledMask`, `instanceAtPoint`) | subject lifting; ML |
| | `GeneratePersonSegmentationRequest` (stateful; `qualityLevel .accurate/.balanced/.fast`, `frameAnalysisSpacing`, `outputPixelFormatType`) → `PixelBufferObservation` | ML |
| | `GeneratePersonInstanceMaskRequest` → `InstanceMaskObservation` (up to 4 people) | ML |
| | **NEW iOS 27** `GenerateIterativeSegmentationRequest` (`DownloadableAssetsRequest`): `init(seedPoint:)`, `init(seedBox:)`, `init(seedScribbleBuffer:)`, `addIncludedPoint` / `addExcludedPoint`, `qualityLevel`; `assetStatus` (`.notReady/.downloading/.ready/.error`), `downloadAssets()` / `downloadAssets(progress:)` → `PixelBufferObservation?` | tap, box, or scribble prompting; one-time asset download; new errors `VNErrorResourceUnavailable` / `ResourceCorrupted` |
| | `DetectDocumentSegmentationRequest` → `DetectedDocumentObservation` | ML |
| | `GenerateAttentionBasedSaliencyImageRequest`, `GenerateObjectnessBasedSaliencyImageRequest` → `SaliencyImageObservation` | ML |
| Text & documents | `RecognizeTextRequest` (rev3): `recognitionLevel .fast/.accurate`, `recognitionLanguages`, `automaticallyDetectsLanguage`, `usesLanguageCorrection`, `customWords`, `minimumTextHeightFraction`, **`regionOfInterest`** → `[RecognizedTextObservation]` (`topCandidates(_:)`, `RecognizedText.string/confidence/boundingBox(for:)`) | "select a patch → text" = set `regionOfInterest`; ML, Neural-Engine capable |
| | **iOS 26** `RecognizeDocumentsRequest`: `textRecognitionOptions`, `barcodeDetectionOptions` → `DocumentObservation.document: Container` with `Container.Text` (alignment), `Container.Table` (`rows/columns/cell(row:col:)`), `Container.List` (`items`, marker type), `Container.DataDetectorMatch` (URLs, phones, emails, dates), each with `boundingRegion` | ML |
| | `DetectTextRectanglesRequest` → `TextObservation` (character boxes); `DetectBarcodesRequest` (rev4) → `BarcodeObservation` | classical/legacy; ML localisation + classical decode |
| People | `DetectFaceRectanglesRequest` (rev3, **rev4 in iOS 27**), `DetectFaceLandmarksRequest` (rev3, **rev4 in 27**), `DetectHumanRectanglesRequest` (rev2, **rev3 in 27**) → `FaceObservation` (`landmarks`, `roll/yaw/pitch`, `captureQuality`), `HumanObservation` | ML |
| | `DetectFaceCaptureQualityRequest`, `DetectHumanBodyPoseRequest` (2D), `DetectHumanBodyPose3DRequest` (stateful → `HumanBodyPose3DObservation`), `DetectHumanHandPoseRequest` (`Chirality`), `DetectAnimalBodyPoseRequest` | ML |
| | `RecognizeAnimalsRequest` (rev2, **rev3 in 27** with `Identifier .dog/.cat/.dogHead/.catHead`, `supportedIdentifiers`) | ML |
| Classification | `ClassifyImageRequest` (rev2, ~1,300 taxonomy labels, `supportedIdentifiers`) → `[ClassificationObservation]` | ML |
| | `GenerateImageFeaturePrintRequest` → `FeaturePrintObservation.distance(to:)` | embedding for similarity / reference matching; ML |
| | `CalculateImageAestheticsScoresRequest` → `overallScore` (-1…1), `isUtility` | ML |
| | **iOS 26** `DetectLensSmudgeRequest` → `SmudgeObservation.confidence` | ML |
| | `CoreMLRequest(model: CoreMLModelContainer)` → feature-value / classification / pixel-buffer / detected-object observations; `ImageCropAndScaleAction` | your own model |
| Geometry | `DetectRectanglesRequest`, `DetectContoursRequest` → `ContoursObservation`, `DetectHorizonRequest` → `HorizonObservation` | classical |
| Tracking | `TrackObjectRequest(detectedObject:)`, `TrackRectangleRequest(detectedRectangle:trackingLevel:)`, `DetectTrajectoriesRequest(trajectoryLength:)` → `TrajectoryObservation` (all stateful, `frameAnalysisSpacing`) | classical |
| Registration | `TrackTranslationalImageRegistrationRequest`, `TrackHomographicImageRegistrationRequest` via `TargetedImageRequestHandler` | classical |
| Optical flow | `TrackOpticalFlowRequest` (stateful, `computationAccuracy .low…veryHigh`) → `OpticalFlowObservation`. No Swift-native `GenerateOpticalFlowRequest`; ObjC `VNGenerateOpticalFlowRequest` (iOS 14, `keepNetworkOutput` iOS 16) remains | hybrid |

Other iOS 27 Vision changes: `PixelBufferObservation.pixelBuffer` and `OpticalFlowObservation.pixelBuffer` now expose `CVReadOnlyPixelBuffer`; `VisionResult` / `RequestDescriptor` gained `generateIterativeSegmentation` cases; watchOS 27 gains most requests.

Simulator: likely runs on CPU/GPU (`.neuralEngine` is never offered); iterative-segmentation asset download in the simulator UNVERIFIED; face, body, pose and segmentation are slow there, so measure on device.

Morpho fit: the highest-value group. Per-frame `GeneratePersonSegmentationRequest(.fast)` or `GenerateForegroundInstanceMaskRequest` for subject masks that gate or anchor Lucy edits; `RecognizeTextRequest` + `regionOfInterest` for "highlight a patch → text"; `RecognizeDocumentsRequest` when the scene contains signage, menus or tables; `GenerateImageFeaturePrintRequest` to match a reference image against the live frame; `GenerateIterativeSegmentationRequest` (tap, box, scribble) is the natural "pick this object" control on iOS 27 after a one-time asset download; `TrackObjectRequest` propagates a box between expensive frames.

### 2.2 VisionKit (iOS 16+)

- `ImageAnalyzer` (`isSupported`, `supportedTextRecognitionLanguages`): `analyze(UIImage | CGImage | CIImage | CVPixelBuffer | url, orientation:, configuration: Configuration(AnalysisTypes))` → `ImageAnalysis` (`transcript`, `hasResults(for:)`). `AnalysisTypes`: `.text`, `.machineReadableCode`, `.visualLookUp`.
- `ImageAnalysisInteraction` (UIKit interaction) / `ImageAnalysisOverlayView`: `InteractionTypes` `.automatic / .automaticTextOnly / .textSelection / .dataDetectors / .imageSubject / .visualLookUp`; subject lifting via `subjects`, `highlightedSubjects`, `subject(at:)`, `image(for: Set<Subject>)`, `Subject.bounds / .image`. No 26/27 additions.
- `DataScannerViewController(recognizedDataTypes:qualityLevel:recognizesMultipleItems:isHighFrameRateTrackingEnabled:…)`: live scanner that **owns the camera** (needs `NSCameraUsageDescription`, can't be fed frames); `recognizedItems: AsyncStream<[RecognizedItem]>`, `regionOfInterest`, `zoomFactor`, `isSupported` / `isAvailable`.
- Simulator: `ImageAnalyzer` likely (CPU); `DataScannerViewController` unusable without a capable camera. Morpho fit: medium; `ImageAnalyzer` on a paused frame gives Live Text, Visual Look Up and subject lifting with system UI for free, but prefer Vision directly on the live path.

### 2.3 Visual Intelligence (iOS 26; device only)

`SemanticContentDescriptor` (`labels: [String]`, `pixelBuffer: CVReadOnlyPixelBuffer?` — the crop the person selected in the system camera or screenshot UI). App side: `AppIntents.IntentValueQuery` (`values(for:)` returning your `AppEntity`s; iOS 27 adds `allowedExecutionTargets`) and `AssistantSchemas.VisualIntelligenceIntent.semanticContentSearch`. The system invokes the app; the app cannot run visual intelligence on its own frames and never receives a caption. Framework absent from the simulator SDK. Morpho fit: low for the live loop; a growth hook at most.

### 2.4 Image Playground (iOS 18.1+; Apple Intelligence)

- SwiftUI `imagePlaygroundSheet(isPresented:concepts: | concept:, sourceImage: | sourceImageURL:, onCompletion:, onAdaptiveImageGlyphCreation:, onCancellation:)`, `imagePlaygroundGenerationStyle(_:in:)` (18.4), `imagePlaygroundOptions(_:)` (26.4); environment `supportsImagePlayground`, `imagePlaygroundAllowedGenerationStyles`. UIKit `ImagePlaygroundViewController` (`isAvailable`, `concepts`, `sourceImage`, `allowedGenerationStyles`, `options`; delegate `didCreate imageURL` / `didCreate adaptiveImageGlyph` = **Genmoji**).
- `ImagePlaygroundConcept.text(_:)`, `.extracted(from:title:)`, `.drawing(PKDrawing)`, `.image(CGImage)`, `.image(URL)`.
- `ImagePlaygroundStyle`: `.animation / .illustration / .sketch / .emoji`, `.externalProvider` (iOS 26, cloud e.g. ChatGPT), `.any` (**iOS 27**), `.all`.
- `ImagePlaygroundOptions` (26.4): `personalization`, `creationVariety`; **iOS 27**: `creationStrategy .automatic/.editExisting/.generateNew`, `sizeSpecification: .closest(to: CGSize)`.
- Programmatic `ImageCreator` (18.4: `images(for:style:limit:)`) is **deprecated in iOS 27** in favor of the sheet or view controller; headless generation is being withdrawn.
- On-device diffusion except `.externalProvider`. Requires an Apple Intelligence-eligible device with it enabled; gate on `isAvailable`. Simulator: interface present, model availability UNVERIFIED (treat as unavailable). Morpho fit: low-medium; user-facing generation of a stylised reference image to feed Lucy.

### 2.5 Core Image neural filters

`CIFilter.personSegmentation()` (iOS 15; `qualityLevel` 0 accurate / 1 balanced / 2 fast → mask in the red channel, may differ in size), `CIFilter.coreMLModel()` (`model`, `headIndex`, `softmaxNormalization`) to run an image-to-image model inside a CI graph, `CIContext.depthBlurEffectFilter(forImage:disparityImage:portraitEffectsMatte:hairSemanticSegmentation:glassesMatte:…)` (portrait blur from capture mattes, not neural itself). iOS 27 Core Image changes are decode/perf only (`kCIImageSubsampleFactor`, `kCIImageUseHardwareAcceleration`, render-destination cost stats); no new ML filters in 26/27. Simulator: runs on CPU/GPU. Morpho fit: `personSegmentation` is the cheapest per-frame mask because `SimulatedLucy` already runs a CI pipeline.

### 2.6 Natural-language image description — yes, via Foundation Models in iOS 27

- `Attachment<ImageAttachmentContent>` with `init(cgImage | ciImage | cvPixelBuffer, orientation:)`, `init(imageURL:)`, `.label(_:)`; embed in a `Prompt` / `@PromptBuilder` and call `LanguageModelSession.respond(to:)` or `streamResponse(to:)`. `Transcript.Attachment.image(ImageAttachment)`. `ImageReference: Generable` lets guided-generation output point back at attached images (`resolved(in:)`).
- Gate on `SystemLanguageModel.default.capabilities.contains(.vision)` (`LanguageModelCapabilities.Capability` `.vision / .guidedGeneration / .reasoning / .toolCalling`, iOS 27); error `LanguageModelError.unsupportedCapability`. Model variants (iOS 27): `SystemLanguageModel.Variant.core3 / .coreAdvanced3`. Availability: `.available` or `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`. Cloud sibling: `PrivateCloudComputeLanguageModel` (iOS 27). Docs: "Analyzing images with multimodal prompting", "Prompt attachments", "Consider multimodal safety".
- Not realtime: single-image captioning or QA at roughly 1 Hz, guardrails apply, limited context. Simulator: interface present; model availability UNVERIFIED (gate on `availability`).
- Nothing else captions: Vision has no captioning request, VisionKit's `transcript` is OCR only, and the Accessibility framework exposes no image-description API.
- Morpho fit: high — "describe the scene, then seed a Lucy prompt", or a `@Generable` scene descriptor from a keyframe (subject, setting, lighting) that the Alchemist can anchor edits to.

### 2.7 ARKit (physical device only)

`ARBodyTrackingConfiguration` (3D skeleton), `ARFaceTrackingConfiguration` (TrueDepth; **iOS 27** `environmentTexturingEnabled`), `ARWorldTrackingConfiguration.frameSemantics` `.personSegmentation / .personSegmentationWithDepth / .bodyDetection / .sceneDepth` (LiDAR), scene reconstruction meshes, `ARFrame.segmentationBuffer / estimatedDepthData / sceneDepth`. **iOS 26**: `captureHighResolutionFrame(usingPhotoSettings:)`. **iOS 27**: `ARConfiguration.trackingObjects: Set<ARReferenceObject>`, `ARFrame.metadataObjects`, `ARSession.viewLayer`, `viewRotationAngle` + `session(_:didChangeViewRotationAngle:)` and `displayTransform(forViewRotationAngle:)` (foldable and rotation support). ARKit owns the camera; no simulator. Duo's front cameras have no depth via the virtual camera, so TrueDepth-style face tracking on them is UNVERIFIED. Morpho fit: low; conflicts with Morpho's own capture unless ARKit becomes the frame source for person-with-depth mattes.

### 2.8 Cinematic framework and capture-side ML (AVFoundation)

- Cinematic (iOS 17): `CNAssetInfo`, `CNScript` / `CNDecision` / `CNDetection` / `CNDetectionTrack` (face, body, pet detections and focus decisions baked into Cinematic-mode movies), `CNObjectTracker`, `CNRenderingSession` (rack-focus render). **iOS 27**: `CNImageRenderingSession` (single-image render), `CNCompositionInfo`, `CNAssetInfo.checkCinematicCapability(for:)` (`.renderable / .needsPreprocessing`), `preprocessAsset(with:)`, downloadable resources (`resourceStatus(forVersions:)`, `downloadResources`). Absent from the simulator SDK; needs Cinematic assets with depth tracks.
- AVFoundation **iOS 26 Cinematic Video capture**: `AVCaptureDeviceInput.isCinematicVideoCaptureSupported / Enabled`, `simulatedAperture`, `AVCaptureDevice.setCinematicVideoTrackingFocus(detectedObjectID:focusMode:)`, `setCinematicVideoFixedFocus(at:)`, `AVCaptureMetadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture`, `AVMetadataObject.groupID / objectID / cinematicVideoFocusMode`; **iOS 27** `AVMetadataObjectTypeFocusTrackedObject`. Existing ML metadata detections: `.face`, `.humanBody`, `.humanFullBody`, `.catBody`, `.dogBody`, `.salientObject`. Still photos only: `AVSemanticSegmentationMatte` `.skin / .hair / .teeth / .glasses`.
- Morpho fit: medium on a physical Duo. `AVCaptureMetadataOutput` face, body and salient-object rectangles are nearly free on the capture thread and can drive Lucy region hints without a Vision pass; Cinematic Video focus tracking gives a stable subject ID stream. Front cameras on Duo are 1080p60 with no depth.

## 3. Audio & speech

Verified against the iOS 27.1 SDK headers and `.swiftinterface` files (the
docs reader returned metadata only), plus runtime probes on the macOS 26 host
and an inspection of the iOS 27.1 simulator runtime.

### 3.1 SpeechAnalyzer stack — Speech framework (iOS 26, extended in 27)

The engine Morpho already uses. All on-device: the models are Apple-managed
assets shared across apps; there is no server path in this API.

- **`SpeechAnalyzer`** (actor): `init(modules:options:)`, `init(inputSequence:modules:…)`, `init(inputAudioFile:modules:…finishAfterFile:)`; `start(inputSequence:)` / `start(inputAudioFile:finishAfterFile:)`; `analyzeSequence(_:)`; `finalize(through:)`, `finalizeAndFinishThroughEndOfInput()`, `finish(after:)`, `cancelAnalysis(before:)`, `cancelAndFinishNow()`; `volatileRange`; `setContext(AnalysisContext)`; `static bestAvailableAudioFormat(compatibleWith:)`. Options: `priority`, `modelRetention` (`.whileInUse` / `.lingering` / `.processLifetime`), **iOS 27** `ignoresResourceLimits`.
- **`AnalyzerInput`**: `init(buffer: AVAudioPCMBuffer, bufferStartTime:)`; **iOS 27** `init(buffer: CMReadySampleBuffer<…>)`, `bufferDuration`, `bufferFormat`. The analyzer never converts audio: feed it a format from `bestAvailableAudioFormat` (host probe: mono 16 kHz Int16; 8 kHz also accepted).
- **`SpeechTranscriber`**: `init(locale:preset:)` or `init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`. `TranscriptionOption.etiquetteReplacements`. `ReportingOption`: `.volatileResults`, `.alternativeTranscriptions`, `.fastResults` (more frequent, less accurate finals). `ResultAttributeOption`: `.audioTimeRange`, `.transcriptionConfidence` (delivered as `AttributedString` attributes). Presets: `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription`, `.timeIndexedProgressiveTranscription` (mutable structs). `static isAvailable`, `supportedLocales`, `installedLocales`. `Result`: `text: AttributedString`, `alternatives`, `range`, `isFinal`; an empty string revokes prior volatile results. Host probe: 30 locales (de, en ×9, es ×4, fr ×4, it ×2, ja, ko, pt ×2, yue, zh ×3).
- **`DictationTranscriber`** (iOS 26): same module protocol, uses the system-dictation models; broader locale list (54 on host). `ContentHint`: `.shortForm`, `.farField`, `.atypicalSpeech`, `.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)`. Options add `.punctuation`, `.emoji`; reporting adds `.frequentFinalization`. Presets `.phrase`, `.shortDictation`, `.progressiveShortDictation`, `.longDictation`, `.progressiveLongDictation`, `.timeIndexedLongDictation`. Apple recommends it as the fallback when `SpeechTranscriber.isAvailable` is false.
- **`SpeechDetector`** (iOS 26): voice activity detection. `init(detectionOptions: .init(sensitivityLevel: .low/.medium/.high), reportResults:)`; `Result.speechDetected`. Only works alongside a transcriber module; by default it gates transcription to save power, with `reportResults: true` it streams VAD.
- **`AnalysisContext`**: `contextualStrings[.general] = [String]` for phrase biasing (used by `DictationTranscriber`); custom language models via `SFSpeechLanguageModel` (iOS 17; iOS 26 adds `Configuration.weight`).
- **`AssetInventory`** (iOS 26): `status(forModules:)` (`.unsupported/.downloading/.supported/.installed`), `assetInstallationRequest(supporting:)` → `downloadAndInstall()` with `progress`; `reserve(locale:)` / `release`, `maximumReservedLocales` (5 on host).
- **iOS 27 helpers**: `AnalyzerInputConverter` (`converter(compatibleWith:)`, `convert(_:at:)`, `flush()`) replaces hand-rolled `AVAudioConverter` code; `AssetInputSequenceProvider.provider(from: AVAsset, …)` for files; `CaptureInputSequenceProvider.providerWithSession(from: AVCaptureDevice, …)` / `provider(from:in: AVCaptureSession, …)` exposes `analyzerInputs` straight from a capture session. New error `SFSpeechError.Code.cannotConfigureAudioSystem`. `SpeechModels.endRetention()`.
- Semantics: terminating the input stream does **not** finish a session; call a `finish` method. `finalize(through:)` forces finals through that time; `cancelAnalysis(before:)` is the "can't wait" catch-up.
- Permissions: microphone (`AVAudioApplication.requestRecordPermission`). Whether the speech-recognition prompt is also required for `SpeechAnalyzer`: UNVERIFIED (nothing in headers requires it).
- Simulator: likely. `Speech.framework`, CoreSpeech, ASRBridge and `mobileassetd` are present in the iOS 27.1 simulator runtime; not executed there yet. `isAvailable` may be false on the simulated device class, in which case fall back to `DictationTranscriber`.
- Morpho fit: keep `.progressiveTranscription` for the transcript overlay and add `.fastResults` while casting; `finalize(through:)` on hold-to-talk release; `SpeechDetector` to gate open-mic; `.audioTimeRange` attributes to align spoken casts to clip time; `AnalyzerInputConverter` to delete the converter code in `SpeechPipeline.swift`.

### 3.2 Legacy `SFSpeechRecognizer` (iOS 10; on-device since 13)

`supportsOnDeviceRecognition`, `SFSpeechRecognitionRequest.requiresOnDeviceRecognition` (less accurate on-device), `addsPunctuation` (16), `customizedLanguageModel` (17), `SFVoiceAnalytics` (jitter, shimmer, pitch, voicing). Needs `NSSpeechRecognitionUsageDescription` (the app crashes on `requestAuthorization` without it). Superseded by §3.1 on iOS 26+; only an iOS ≤ 25 fallback.

### 3.3 `AVSpeechSynthesizer` — AVFAudio (iOS 7; no 26/27 additions)

On-device voices with `Quality.default/.enhanced/.premium`; `voiceTraits` `.isPersonalVoice` / `.isNoveltyVoice` (17); **Personal Voice** (17): `requestPersonalVoiceAuthorization`, `personalVoiceAuthorizationStatus`. SSML via `AVSpeechUtterance(ssmlRepresentation:)` (16); markers via `willSpeakMarker` (17); offline render `write(_:toBufferCallback:)`. Custom voices through `AVSpeechSynthesisProviderAudioUnit` extensions. Simulator: system voices likely; Personal Voice effectively no. Morpho fit: low; optional spoken confirmation of a cast.

### 3.4 SoundAnalysis (iOS 13; built-in classifier iOS 15)

`SNClassifySoundRequest(classifierIdentifier: .version1)` — **303 labels** on host — or `init(mlModel:)` for a custom Core ML classifier. `windowDuration` (default 3.0 s, range 0.5–15 s), `overlapFactor`, `knownClassifications`. Live: `SNAudioStreamAnalyzer(format:)` + `analyze(_:atAudioFramePosition:)`; files: `SNAudioFileAnalyzer`. Results: `SNClassificationResult.classifications[].identifier/confidence`, `timeRange`. Mic permission only. Simulator: likely (AudioAnalytics backend present). Morpho fit: ambient context (music, applause, laughter) to suggest Realms; a custom classifier for non-speech triggers like a snap or clap.

### 3.5 Audio Mix — Cinematic framework + `AUAudioMix` (iOS 26)

Neural separate-and-remix of dialogue and background, **only for spatial-audio (first-order ambisonic) recordings that carry Apple's recorded analysis metadata**. Not applicable to arbitrary mono/stereo audio.

- `CNAssetSpatialAudioInfo` (iOS 26): `static isSupported`, `assetContainsSpatialAudio(asset:)`, `init(asset:)`, `defaultRenderingStyle`, `defaultEffectIntensity`, `audioMix(effectIntensity:renderingStyle:) -> AVAudioMix` (use on `AVPlayerItem`, `AVAssetReaderAudioMixOutput`, or export), `assetWriterInputSettings(for: .stereo/.spatial)`.
- `CNSpatialAudioRenderingStyle`: `.cinematic`, `.studio` (dialogue-forward with proximity), `.inFrame` (foreground = in camera field of view), `.standard`, plus `…BackgroundStem` / `…ForegroundStem` variants for isolated stems.
- AudioToolbox twin: `kAudioUnitSubType_AUAudioMix` ('amix') with `kAUAudioMixProperty_SpatialAudioMixMetadata`, `kAUAudioMixParameter_Style`, `kAUAudioMixParameter_RemixAmount`.
- Qualifying captures: `AVCaptureDeviceInput.multichannelAudioMode = .firstOrderAmbisonics` (iOS 18, built-in mic only) through `AVCaptureMovieFileOutput`, or `AVCaptureAudioDataOutput` with `spatialAudioChannelLayoutTag` (iOS 26) written by `AVAssetWriter` plus a metadata track from `AVCaptureSpatialAudioMetadataSampleGenerator` (iOS 26, iPhone only: `analyzeAudioSample(_:)` per buffer, then one `newTimedMetadataSampleBufferAndResetAnalyzer()` per recording).
- Simulator: **no**. `Cinematic.framework` is absent from the simulator SDK and runtime, and there is no simulated FOA microphone.
- Morpho fit: only if the Recorder captures FOA audio plus metadata on a physical device; then every Reel take could be remixed dialogue-forward at playback or export. The tethered-camera pipeline in the simulator can't use it.

### 3.6 Voice processing, isolation, and capture — AVFAudio / AVFoundation / AudioToolbox

- **Voice processing I/O** (DSP: echo cancellation + AGC + noise suppression as one unit, iOS 13): `AVAudioEngine.inputNode.setVoiceProcessingEnabled(_:)`, `isVoiceProcessingAGCEnabled`, `isVoiceProcessingInputMuted`, `setMutedSpeechActivityEventListener` (17), `voiceProcessingOtherAudioDuckingConfiguration` (17: `enableAdvancedDucking`, `duckingLevel`).
- **`AUSoundIsolation`** ('vois', iOS 16): an app-controllable **ML voice isolator** usable as `AVAudioUnitEffect(audioComponentDescription:)`. Params `kAUSoundIsolationParam_WetDryMixPercent`, `kAUSoundIsolationParam_SoundToIsolate` = `kAUSoundIsolationSoundType_Voice` (16) or `_HighQualityVoice` (iOS 18, "high quality voice isolation model"). Simulator: unknown.
- **System microphone modes** (iOS 15): `AVCaptureDevice.MicrophoneMode` `.standard/.wideSpectrum/.voiceIsolation` — user-selected in Control Center; apps read `preferredMicrophoneMode` / `activeMicrophoneMode` and can call `showSystemUserInterface(.microphoneModes)`.
- **Echo-cancelled input without VPIO** (iOS 18.2): `AVAudioSession.setPrefersEchoCancelledInput(_:)`, `isEchoCancelledInputAvailable`; 2024+ iPhones, `.playAndRecord` + `.default` mode.
- **Capture extras**: `AVCaptureDeviceInput.isWindNoiseRemovalEnabled` (18, multichannel only), `isAudioZoomEnabled` (26.4). Session mode `.shortFormVideo` (26), `.bluetoothHighQualityRecording` option (26), `.dualRoute` / `.farFieldInput` (26.2). **iOS 27**: async `AVAudioSession.activate(options:)`, `didBecomeActive/Inactive` notifications with `DeactivationContext` / `ResumptionContext`, throwing `connectNode` / `installTap(onBus:…error:)` variants, `AVAudioFormat(formatDescription:)`.
- `AVAudioUnitEQ/Reverb/Delay/Distortion/TimePitch/Varispeed`, `AVAudioEnvironmentNode`: classical DSP, not neural (iOS 27 adds a `.outdoorGeneral` reverb preset).
- Simulator: VPIO and `AVAudioEngine` work with the host mic; FOA, wind removal, audio zoom and echo-cancelled input are hardware features and don't.
- Morpho fit: enable VPIO on the engine input so Decart playback through the speaker doesn't leak into open-mic; tap the same node for the amplitude ring; optionally insert `AUSoundIsolation` ahead of the transcriber.

### 3.7 ShazamKit (iOS 15)

`SHSession()` matches against Shazam's catalog (needs the ShazamKit capability and network); `SHSession(catalog: SHCustomCatalog)` matches **on-device**; `SHManagedSession` (17) manages the mic. `SHSignatureGenerator.signature(from: AVAsset)`. **iOS 27**: `SHMediaItem.songs()` → MusicKit `Song`s. Spectral-fingerprint matching, not a neural model. Morpho fit: low.

### 3.8 MusicUnderstanding (NEW in iOS 27)

`import MusicUnderstanding`. `actor MusicUnderstandingSession` — `init(asset:)` (local media, no HLS) or `init(audioProvider:)` (an `AsyncSequence` of `AVReadOnlyAudioPCMBuffer`); `analyze(for: Set<AnalysisType>)` once per session; streaming `loudnessResults`. `AnalysisType`: `.rhythm` (`RhythmResult.beats: [CMTime]`, `bars`, `beatsPerMinute`), `.key` (tonic + mode over ranges), `.loudness` (LUFS integrated/momentary/short-term/peak), `.pace`, `.structure` (sections, segments, phrases), `.instrumentActivity` (`.vocal/.drum/.bass/.other` activity curves; detection, not stem separation). Errors: `sessionInProgress`, `emptyAnalysisSet`, `invalidAsset`, `hasProtectedContent`. On-device (no network API; model type UNVERIFIED). Simulator: likely (present in the simulator SDK and runtime). No permissions. Morpho fit: beat and bar times for beat-synced transmutation sweeps and cut points on Reel takes; the live `audioProvider` variant could drive a BPM-locked pulse in the waveform ring.

### 3.9 Not in the iOS 27.1 SDK

No public API for speech-to-speech, runtime voice conversion or cloning (Personal Voice is TTS only), audio super-resolution, or general music source separation. Noise suppression exists only as VPIO, `AUSoundIsolation`, and wind-noise removal above.

## 4. Core ML & compute

- **Core ML** (`import CoreML`; nothing new in iOS 27's public Swift interface): `MLModel.load(contentsOf:configuration:)`, `MLModel.compileModel(at:)`, `MLModelAsset` (18), `MLModelConfiguration` (`computeUnits .cpuOnly / .cpuAndGPU / .all / .cpuAndNeuralEngine`, `optimizationHints` 17.4, `functionName` for multifunction models 18, `preferredMetalDevice`). Prediction: `prediction(from:options:) async`, **stateful models** via `prediction(from:using: MLState)` / `newState()` (18), `MLTensor` (18; iOS 26 adds `pointwiseMin / Max`), `MLComputePlan` (per-op cost and device), `MLModelStructure`, `MLComputeDevice`, `MLShapedArray`; iOS 26 `MLMultiArrayDataType.int8`. On-device personalization: `MLUpdateTask` (13). Compression happens at conversion time with coremltools. Simulator: CPU/GPU only, never the Neural Engine.
- **CoreAI (NEW iOS 27; device only)**: `AIModel`, `InferenceFunction`, `AIModelCache`, `ComputeUnitKind`, `SpecializationOptions`; docs "Integrating on-device AI models in your app with Core AI", "Compiling Core AI models ahead of time", "Running a Core AI model in a Foundation Models session". Only partially visible in the Swift interface (re-exports `CoreAIDelegates`) and absent from the simulator SDK; details beyond these types UNVERIFIED.
- **Create ML on iOS** (`import CreateML`, iOS 15+, device only, absent from the simulator SDK): `MLImageClassifier`, `MLHandPoseClassifier`, `MLHandActionClassifier`, `MLStyleTransfer`, `MLSoundClassifier`, `MLTextClassifier`, tabular models, `MLTrainingSession` with checkpoints. Not on iOS: `MLObjectDetector`, `MLActionClassifier`, `MLActivityClassifier`, `MLWordTagger`. `CreateMLComponents` (iOS 16, present in the simulator SDK): `ImageFeaturePrint`, `HumanBodyPoseExtractor`, `HumanHandPoseExtractor`, `HumanBodyActionPeriodPredictor`, image augmenters. No 26/27 additions. Morpho fit: low; on-device training is possible but not realtime.
- **Vision's `CoreMLRequest`** and **Core Image's `CIFilter.coreMLModel()`** are the two ways to drop a custom model into the existing frame pipeline (see §2).
- Morpho fit: medium; bring a small segmentation or style model only if Vision's built-ins fall short. Stateful models plus `MLTensor` suit temporal video networks.

## 5. Simulator matrix (iOS 27.1 simulator runtime, inspected)

"Likely" means the framework and its backing daemons are present in the
simulator runtime and the interface matches the device SDK, but it was not
executed there during this research. Nothing runs on a simulated Neural
Engine; everything falls back to CPU/GPU.

| Capability | Simulator |
|---|---|
| Foundation Models (text) | interface present; model availability flaky (STAGING notes) — always gate on `availability` |
| Foundation Models vision input (iOS 27) | UNVERIFIED; gate on `capabilities.contains(.vision)` |
| NaturalLanguage | likely (no Apple Intelligence gate); contextual-embedding assets UNVERIFIED |
| Translation, Writing Tools, Spotlight semantic search | unknown (Apple Intelligence or asset-download gated) |
| Vision requests (text, segmentation, faces, poses, classification) | likely, CPU/GPU, slow for heavy requests |
| Vision `GenerateIterativeSegmentationRequest` asset download | UNVERIFIED |
| VisionKit `ImageAnalyzer` | likely; `DataScannerViewController` no (needs a camera) |
| Visual Intelligence | no (framework absent from simulator SDK) |
| Image Playground | interface present; Apple Intelligence model UNVERIFIED, treat as unavailable |
| Core Image `personSegmentation`, `coreMLModel` | yes (CPU/GPU) |
| Core ML | yes, CPU/GPU only |
| CoreAI (iOS 27), Create ML training, Cinematic, ARKit | no (absent or device-only) |
| SpeechAnalyzer / SpeechTranscriber / DictationTranscriber / SpeechDetector | likely (Speech, CoreSpeech, ASRBridge, mobileassetd present); fall back to `DictationTranscriber` if `isAvailable` is false |
| `SFSpeechRecognizer` on-device | unknown |
| `AVSpeechSynthesizer` system voices | likely; Personal Voice no |
| SoundAnalysis built-in classifier | likely |
| Audio Mix (Cinematic / `AUAudioMix`), FOA capture, wind removal, audio zoom, echo-cancelled input | no |
| `AVAudioEngine` voice processing | likely (host mic); `AUSoundIsolation` unknown |
| ShazamKit custom catalog | likely |
| MusicUnderstanding (iOS 27) | likely (present in simulator SDK and runtime) |
| iPhone Duo hinge, reserved regions, arrangement views | yes (Bitrig fold controls; `simctl` posture notification) |
| Duo inner/outer physical cameras | no; Morpho uses the USB-tethered iPhone 17e instead |

## 6. Where each one fits Morpho

Ranked by how directly each capability serves the voice → Lucy 2.5 loop and
the Deck's upcoming core controls. All run on-device.

**Tier 1 — directly useful now**

1. **Speech**: keep `SpeechTranscriber` with `.progressiveTranscription`, add `.fastResults` during casting, `finalize(through:)` on hold-to-talk release, `SpeechDetector` to gate open-mic, `.audioTimeRange` attributes to align casts with clip time, `AnalyzerInputConverter` (iOS 27) to replace the hand-rolled converter in `SpeechPipeline.swift`, `DictationTranscriber` fallback with `.customizedLanguage` biased toward Realm and incantation vocabulary.
2. **Foundation Models**: the Alchemist already uses guided generation; iOS 27 adds image input, so a keyframe can be described or turned into a `@Generable` scene descriptor (subject, setting, lighting) that anchors edits by visible detail, exactly what Lucy's prompting guide asks for. Tool calling can let the model pick a Realm or set Rig parameters from speech. Gate on `capabilities`.
3. **Vision segmentation**: `GeneratePersonSegmentationRequest(.fast)` or `GenerateForegroundInstanceMaskRequest` per frame (or every Nth frame with `TrackObjectRequest` in between) gives subject masks to gate where a simulated or live edit applies, and to compose "keep the person unchanged" locally. On iOS 27, `GenerateIterativeSegmentationRequest` (tap, box, scribble) is the natural "pick this object" control on the Stage.
4. **Vision text**: `RecognizeTextRequest` with `regionOfInterest` for "highlight a patch → text"; `RecognizeDocumentsRequest` when the scene has signage, menus, or tables. Recognized text can become a prompt ("replace the sign text with…") or a data-detector action.
5. **Voice processing**: `setVoiceProcessingEnabled(true)` on the engine input so speaker playback of the transformed feed doesn't leak into open-mic; optional `AUSoundIsolation` (`_HighQualityVoice`) ahead of the transcriber.

**Tier 2 — strong additions**

6. **`GenerateImageFeaturePrintRequest`** to match the Polaroid reference image against the live frame (confirm the referenced object is in view before casting a character swap).
7. **`ClassifyImageRequest` / `CalculateImageAestheticsScoresRequest`** to suggest Realms from scene content and to pick the best still for the Reel thumbnail.
8. **SoundAnalysis** (303 built-in classes) for ambient context (music, applause, laughter) that nudges Realm suggestions; a custom classifier for non-speech triggers (snap, clap).
9. **MusicUnderstanding (iOS 27)** for beat and bar times to sync the transmutation sweep or cut Reel takes on the beat; the live `audioProvider` variant can drive a BPM-locked pulse in the waveform ring.
10. **NaturalLanguage** as a zero-latency pre-pass: `NLLanguageRecognizer` to pick the prompt language, `.lexicalClass` to strip fillers, `NLEmbedding.sentenceEmbedding` to fuzzy-match casual speech to the nearest Realm before the LLM runs. **Translation** (`translate(batch:)`, `.highFidelity` on 26.4+) to bring non-English casting into English first. **App Shortcut phrases** for hands-free "morph to noir", and `SpotlightSearchTool` (27) over an indexed Reel for "bring back the neon one".

**Tier 3 — physical-device or later**

11. **Audio Mix** (dialogue-forward remix of Reel takes) requires FOA capture with Apple's metadata on a physical iPhone; the simulator tether can't produce it.
12. **Capture-side metadata** (`AVCaptureMetadataOutput` faces, bodies, salient objects; iOS 26 Cinematic Video focus tracking) is nearly free on a physical Duo and could replace some Vision passes.
13. **Image Playground** for user-generated reference images (sheet only; headless `ImageCreator` is deprecated in iOS 27).
14. **Duo hinge angle** (`onHingeChange`) for an effect tied to opening the device, and a `CameraCaptureAccessory` scene accessory to show the subject a preview on the outer display.

**Not available as public on-device APIs in iOS 27.1**: speech-to-speech, runtime voice cloning, audio super-resolution, general music source separation, image captioning outside Foundation Models, and running Visual Intelligence on the app's own frames.
