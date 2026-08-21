import CryptoKit
import Foundation
import TurboFieldfare

public enum ServerInferenceEvent: Equatable, Sendable {
    case content(String)
    /// Thought-channel text, emitted only for a request that rendered the
    /// channel open. It is streamed as `reasoning_content`, never as content.
    case reasoning(String)
    case toolCall(ParsedToolCall)
}

/// What the MTP round bookkeeping saw for one request, for the log line only.
///
/// 22-GOAL-RESET §6 keeps these out of any pass/fail column: accepted tokens are
/// tokens the target itself drew, so this says how the wall clock was spent and
/// never what the answer was.
public struct ServerSpeculativeSummary: Equatable, Sendable {
    public let blockTokens: Int
    public let rounds: Int
    /// SPEC §9 RSP-3's `draft_n`: proposals the drafter made.
    public let proposed: Int
    /// RSP-3's `draft_n_accepted`.
    public let accepted: Int

    public init(blockTokens: Int, rounds: Int, proposed: Int, accepted: Int) {
        self.blockTokens = blockTokens
        self.rounds = rounds
        self.proposed = proposed
        self.accepted = accepted
    }

    /// Mean accepted draft length per round (14-M3.5 §4's `a`).
    public var meanAcceptedLength: Double {
        rounds > 0 ? Double(accepted) / Double(rounds) : 0
    }
}

public struct ServerCompletion: Equatable, Sendable {
    public let content: String
    /// The thought channel's text, empty unless the request rendered it open.
    /// Its tokens are counted in `usage.completionTokens` like any other
    /// generated token, because that is what they are.
    public let reasoningContent: String
    public let toolCalls: [ParsedToolCall]
    public let finishReason: String
    public let usage: OpenAIUsage
    /// Non-nil only when this request actually ran the speculative loop.
    public let speculative: ServerSpeculativeSummary?
    /// SPEC §6 GEN-2 / §12 DEV-16: what this request asked for that could only
    /// be approximated — the declared tool schemas the template could not
    /// render, and the schema elements the grammar could not constrain. For
    /// the request-lifecycle log line only; never part of the response.
    public let approximations: [String]
    /// SPEC §9 RSP-3: what this completion cost. Nil only for a backend that
    /// measures nothing — the stubs the HTTP contract is checked against.
    public let timings: ServerTimings?

    public init(content: String,
                toolCalls: [ParsedToolCall],
                finishReason: String,
                usage: OpenAIUsage,
                speculative: ServerSpeculativeSummary? = nil,
                reasoningContent: String = "",
                approximations: [String] = [],
                timings: ServerTimings? = nil) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
        self.speculative = speculative
        self.approximations = approximations
        self.timings = timings
    }
}

enum StructuredOutputFailureKind: String, Equatable, Sendable {
    case decoderConsume = "decoder_consume"
    case decoderFinish = "decoder_finish"
    case orphanToolResponse = "orphan_tool_response"
}

enum StructuredOutputFailureCause: String, Equatable, Sendable {
    case malformed
    case unknownTool = "unknown_tool"
    case oversized
    case unexpected
    case none

    static func classify(_ error: Error) -> Self {
        guard let parserError = error as? GemmaToolCallParserError else {
            return .unexpected
        }
        switch parserError {
        case .malformed: return .malformed
        case .unknownTool: return .unknownTool
        case .oversized: return .oversized
        }
    }
}

struct StructuredOutputFailureDiagnostics: Equatable, Sendable {
    let renderedPromptTokens: Int
    let effectivePromptTokens: Int
    let resultPromptTokens: Int
    let cachedPromptTokens: Int
    let computedPrefillTokens: Int
    let completionTokens: Int
    let maxCompletionTokens: Int
    let rawStop: String
    let kvPosition: Int
    let kvBackedTokens: Int
    let boundaryTokens: Int
    let decodedCalls: Int
    let visibleBytes: Int
    let stopStringMatched: Bool
    let toolStartCount: Int
    let toolEndCount: Int
    let toolResponseCount: Int
    let toolResponseEndCount: Int
    let lastToolStartOffset: Int
    let lastToolEndOffset: Int
    let lastToolResponseOffset: Int
    let lastToolResponseEndOffset: Int
    let effectiveCountMatchesResult: Bool
    let effectivePrefixMatchesKV: Bool
    let kvPositionMatchesHistory: Bool
    let completionCountMatchesHistory: Bool
    let prefillAccountingMatches: Bool
    let renderedPromptHash: String
    let effectivePromptHash: String
    let generatedHash: String

    init(
        renderedPromptIDs: [Int32],
        effectivePromptIDs: [Int32],
        result: RawDecodeResult,
        maxCompletionTokens: Int,
        decodedCalls: Int,
        visibleBytes: Int,
        stopStringMatched: Bool,
        toolStartID: Int32,
        toolEndID: Int32,
        toolResponseID: Int32,
        toolResponseEndID: Int32
    ) {
        let safePrefillCount = min(
            max(result.prefillTokens, 0),
            result.kvBackedTokenIDs.count)
        let committedGenerated = result.kvBackedTokenIDs.dropFirst(safePrefillCount)
        let boundary = result.uncommittedBoundaryTokenIDs[...]
        let generatedSegments = [committedGenerated, boundary]

        var toolStartCount = 0
        var toolEndCount = 0
        var toolResponseCount = 0
        var toolResponseEndCount = 0
        var lastToolStartOffset = -1
        var lastToolEndOffset = -1
        var lastToolResponseOffset = -1
        var lastToolResponseEndOffset = -1
        var offset = 0
        for segment in generatedSegments {
            for tokenID in segment {
                if tokenID == toolStartID {
                    toolStartCount += 1
                    lastToolStartOffset = offset
                }
                if tokenID == toolEndID {
                    toolEndCount += 1
                    lastToolEndOffset = offset
                }
                if tokenID == toolResponseID {
                    toolResponseCount += 1
                    lastToolResponseOffset = offset
                }
                if tokenID == toolResponseEndID {
                    toolResponseEndCount += 1
                    lastToolResponseEndOffset = offset
                }
                offset += 1
            }
        }

        let (prefillAccounted, prefillOverflow) = result.cachedPromptTokens
            .addingReportingOverflow(result.computedPrefillTokens)

        self.renderedPromptTokens = renderedPromptIDs.count
        self.effectivePromptTokens = effectivePromptIDs.count
        self.resultPromptTokens = result.prefillTokens
        self.cachedPromptTokens = result.cachedPromptTokens
        self.computedPrefillTokens = result.computedPrefillTokens
        self.completionTokens = result.newTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.rawStop = Self.rawStop(result.reason)
        self.kvPosition = result.kvPosition
        self.kvBackedTokens = result.kvBackedTokenIDs.count
        self.boundaryTokens = result.uncommittedBoundaryTokenIDs.count
        self.decodedCalls = decodedCalls
        self.visibleBytes = visibleBytes
        self.stopStringMatched = stopStringMatched
        self.toolStartCount = toolStartCount
        self.toolEndCount = toolEndCount
        self.toolResponseCount = toolResponseCount
        self.toolResponseEndCount = toolResponseEndCount
        self.lastToolStartOffset = lastToolStartOffset
        self.lastToolEndOffset = lastToolEndOffset
        self.lastToolResponseOffset = lastToolResponseOffset
        self.lastToolResponseEndOffset = lastToolResponseEndOffset
        self.effectiveCountMatchesResult = effectivePromptIDs.count == result.prefillTokens
        self.effectivePrefixMatchesKV = result.kvBackedTokenIDs.count >= effectivePromptIDs.count
            && result.kvBackedTokenIDs.prefix(effectivePromptIDs.count)
                .elementsEqual(effectivePromptIDs)
        self.kvPositionMatchesHistory = result.kvPosition == result.kvBackedTokenIDs.count
        self.completionCountMatchesHistory = offset == result.newTokens
        self.prefillAccountingMatches = !prefillOverflow
            && prefillAccounted == result.prefillTokens
        self.renderedPromptHash = Self.i32leSHA256([renderedPromptIDs[...]])
        self.effectivePromptHash = Self.i32leSHA256([effectivePromptIDs[...]])
        self.generatedHash = Self.i32leSHA256(generatedSegments)
    }

    static func i32leSHA256(_ segments: [ArraySlice<Int32>]) -> String {
        var hasher = SHA256()
        var bytes = Data()
        bytes.reserveCapacity(4_096)
        for segment in segments {
            for tokenID in segment {
                var littleEndian = UInt32(bitPattern: tokenID).littleEndian
                withUnsafeBytes(of: &littleEndian) {
                    bytes.append(contentsOf: $0)
                }
                if bytes.count == 4_096 {
                    hasher.update(data: bytes)
                    bytes.removeAll(keepingCapacity: true)
                }
            }
        }
        if !bytes.isEmpty { hasher.update(data: bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var logDescription: String {
        [
            "rendered_prompt_tokens=\(renderedPromptTokens)",
            "effective_prompt_tokens=\(effectivePromptTokens)",
            "result_prompt_tokens=\(resultPromptTokens)",
            "cached_prompt_tokens=\(cachedPromptTokens)",
            "computed_prefill_tokens=\(computedPrefillTokens)",
            "completion_tokens=\(completionTokens)",
            "max_completion_tokens=\(maxCompletionTokens)",
            "raw_stop=\(rawStop)",
            "kv_position=\(kvPosition)",
            "kv_backed_tokens=\(kvBackedTokens)",
            "boundary_tokens=\(boundaryTokens)",
            "decoded_calls=\(decodedCalls)",
            "visible_bytes=\(visibleBytes)",
            "stop_string_matched=\(stopStringMatched)",
            "tool_start_count=\(toolStartCount)",
            "tool_end_count=\(toolEndCount)",
            "tool_response_count=\(toolResponseCount)",
            "tool_response_end_count=\(toolResponseEndCount)",
            "last_tool_start_offset=\(lastToolStartOffset)",
            "last_tool_end_offset=\(lastToolEndOffset)",
            "last_tool_response_offset=\(lastToolResponseOffset)",
            "last_tool_response_end_offset=\(lastToolResponseEndOffset)",
            "effective_count_matches_result=\(effectiveCountMatchesResult)",
            "effective_prefix_matches_kv=\(effectivePrefixMatchesKV)",
            "kv_position_matches_history=\(kvPositionMatchesHistory)",
            "completion_count_matches_history=\(completionCountMatchesHistory)",
            "prefill_accounting_matches=\(prefillAccountingMatches)",
            "rendered_prompt_i32le_sha256=\(renderedPromptHash)",
            "effective_prompt_i32le_sha256=\(effectivePromptHash)",
            "generated_i32le_sha256=\(generatedHash)",
        ].joined(separator: " ")
    }

    private static func rawStop(_ reason: StopReason) -> String {
        switch reason {
        case .eos: "eos"
        case .endOfTurn: "end_of_turn"
        case .maxTokens: "max_tokens"
        case .stopString: "stop_string"
        case .toolCalls: "tool_calls"
        }
    }
}

struct StructuredOutputFailure: Error, CustomDebugStringConvertible, Sendable {
    let kind: StructuredOutputFailureKind
    let cause: StructuredOutputFailureCause
    let diagnostics: StructuredOutputFailureDiagnostics

    var debugDescription: String {
        "structured_output_failure kind=\(kind.rawValue) "
            + "cause=\(cause.rawValue) \(diagnostics.logDescription)"
    }
}

public struct ServerPreparedRequest: Sendable {
    public let request: ValidatedChatRequest
    fileprivate let promptIDs: [Int32]?
    /// Set when the request carried images. Built here rather than at generation
    /// time so the resize and patchify run before the coordinator's single
    /// generation slot is taken, not while holding it.
    fileprivate let vision: VisionPrefillInput?

    public var promptTokenCount: Int? { promptIDs?.count }

    init(request: ValidatedChatRequest,
         promptIDs: [Int32]? = nil,
         vision: VisionPrefillInput? = nil) {
        self.request = request
        self.promptIDs = promptIDs
        self.vision = vision
    }
}

public protocol ServerInferenceBackend: Sendable {
    func prepare(_ request: ValidatedChatRequest) async throws -> ServerPreparedRequest
    func generate(_ request: ValidatedChatRequest,
                  onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion
    func generate(_ prepared: ServerPreparedRequest,
                  onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion
    /// SPEC §9 RSP-3 with `timings_per_token: true`. Same generation, with the
    /// running timings published into `monitor` as each token lands so the
    /// route can put them on the chunk that token produced.
    func generate(_ prepared: ServerPreparedRequest,
                  monitor: ServerTimingsMonitor?,
                  onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion
    /// SPEC §3 **EP-5** `/tokenize`. `addSpecial` is the reference's
    /// `add_special`.
    func tokenize(_ text: String, addSpecial: Bool) async throws -> [Int32]
    /// EP-5 `/detokenize`.
    func detokenize(_ tokens: [Int32]) async throws -> String
    /// EP-5 `/apply-template`, rendered with the variant this server actually
    /// prefills with (SPEC §12 DEV-12).
    func applyChatTemplate(_ request: ValidatedChatRequest) async throws -> String
    /// SPEC §3 **EP-6** `/metrics`: the totals since the process started.
    func metrics() async -> ServerMetricsSnapshot
}

public extension ServerInferenceBackend {
    func prepare(_ request: ValidatedChatRequest) async throws -> ServerPreparedRequest {
        ServerPreparedRequest(request: request)
    }

    func generate(
        _ prepared: ServerPreparedRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        try await generate(prepared.request, onEvent: onEvent)
    }

    /// A backend that takes no measurements has nothing to publish, so the
    /// monitor stays empty and the generation is the ordinary one.
    func generate(
        _ prepared: ServerPreparedRequest,
        monitor: ServerTimingsMonitor?,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        try await generate(prepared, onEvent: onEvent)
    }

    // EP-5 / EP-6 on a backend that holds no tokenizer and takes no
    // measurements: the empty answer. Only the stubs the HTTP contract is
    // checked against are in that position — a backend with a model overrides
    // all four.
    func tokenize(_ text: String, addSpecial: Bool) async throws -> [Int32] { [] }

    func detokenize(_ tokens: [Int32]) async throws -> String { "" }

    func applyChatTemplate(_ request: ValidatedChatRequest) async throws -> String { "" }

    func metrics() async -> ServerMetricsSnapshot { .zero }
}

public actor ServerCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let queueLimit: Int
    private var admittedCount = 0
    private var active = false
    private var waiters: [Waiter] = []
    private var shuttingDown = false

    public init(queueLimit: Int) {
        self.queueLimit = queueLimit
    }

    public func run<T: Sendable>(
        onQueued: @escaping @Sendable () -> Void = {},
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await runPreparing(
            onQueued: onQueued,
            prepare: { () },
            operation: { _ in try await operation() })
    }

    func runPreparing<Prepared: Sendable, T: Sendable>(
        onQueued: @escaping @Sendable () -> Void = {},
        prepare: @escaping @Sendable () async throws -> Prepared,
        operation: @escaping @Sendable (Prepared) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard admittedCount <= queueLimit else { throw ServerRequestError.queueFull }
        admittedCount += 1
        defer { admittedCount -= 1 }

        let prepared = try await prepare()
        try Task.checkCancellation()
        try await acquire(onQueued: onQueued)
        defer { release() }
        return try await operation(prepared)
    }

    private func acquire(onQueued: @escaping @Sendable () -> Void) async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        if !active {
            active = true
            return
        }
        guard waiters.count < queueLimit else { throw ServerRequestError.queueFull }
        onQueued()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            active = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    public func shutdown() {
        shuttingDown = true
        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    public var queuedCount: Int { waiters.count }
    public var isActive: Bool { active }

    /// SPEC §3 **EP-6**: the answer `/slots` and the two request gauges of
    /// `/metrics` are made of. It comes from here because this is the only
    /// thing that knows whether the one generation slot (DEV-3) is busy and how
    /// many requests are stacked behind it.
    public var queueState: ServerQueueState {
        ServerQueueState(slots: [ServerSlotState(id: 0, isProcessing: active)],
                         processingCount: active ? 1 : 0,
                         deferredCount: waiters.count)
    }
}

public actor ServerModelSession: ServerInferenceBackend {
    private let context: MetalContext
    private let model: Model
    private let tokenizer: GFTokenizer
    private let runner: RealForwardRunner
    private let scratch: RawCompletionScratch
    /// Allocated once, only when the server was started with
    /// `--draft-block-size > 0`; nil keeps the pre-MTP memory profile and the
    /// pre-MTP code path (04-PHASES §3 gate 4).
    private let speculative: SpeculativeScratch?
    private let prefillConfig: PrefillRuntimeConfig
    private let maxContext: Int
    private let promptCacheDomain: ServerPromptCacheDomain
    private let imagePolicy: ServerImagePolicy
    /// SPEC §8 RSN-1 / FLAG-1: `--reasoning-budget`, the thought budget a
    /// request falls back to when it names none (`-1` = unlimited).
    private let reasoningBudget: Int
    /// RSN-3 / FLAG-1: `--reasoning-format`.
    private let reasoningFormat: ReasoningFormat
    /// SPEC §6 GEN-1: the id → piece table every grammar constraint matches
    /// against. Built once beside the tokenizer at load (~0.4 s and ~25 MB for
    /// 262 144 ids) and shared by every request; building it per request would
    /// cost more than the generation it constrains.
    private let grammarVocabulary: GrammarVocabulary
    /// The marker text and ids the tool-call grammar is written around, read
    /// off the tokenizer once for the same reason.
    private let grammarMarkers: ChatGrammarMarkers
    private var promptCache = ServerPromptCache()
    /// EP-6 `/metrics`: the totals since this session was loaded, summed from
    /// what RSP-3 measures per request so the two cannot disagree.
    private var accumulatedMetrics = ServerMetricsSnapshot.zero

    public static func load(modelDirectory: URL,
                            maxContext: Int,
                            runtimeConfiguration: RuntimeConfiguration,
                            integrityPolicy: ModelIntegrityPolicy = .fullSha256,
                            draftBlockSize: Int = 0,
                            imagePolicy: ServerImagePolicy = .default,
                            reasoningBudget: Int = -1,
                            reasoningFormat: ReasoningFormat = .auto) async throws -> ServerModelSession {
        let tokenizerFolder = GFTokenizer.tokenizerFolder(forModelDirectory: modelDirectory)
        guard let tokenizerFolder else {
            throw GFTokenizerError.missingToolTemplate
        }
        let templateURL = tokenizerFolder.appendingPathComponent("chat_template.jinja")
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            throw GFTokenizerError.missingToolTemplate
        }
        let tokenizer = try await GFTokenizer.load(from: tokenizerFolder)
        let context = try MetalContext()
        let runtime = runtimeConfiguration
        let model = try Model.load(
            directoryURL: modelDirectory,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: integrityPolicy)
        let runner = try RealForwardRunner(model: model,
                                           context: context,
                                           maxContext: maxContext,
                                           runtimeConfiguration: runtime)
        let scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
        // Refused at startup rather than per request: a server told to
        // speculate against a model with no drafter section is misconfigured,
        // and finding out on the first completion is worse than not starting.
        var speculative: SpeculativeScratch?
        if draftBlockSize > 0 {
            guard runner.isDraftInstalled else {
                throw ServerArgumentError.invalid(
                    "--draft-block-size \(draftBlockSize) needs a model installed with the "
                    + "drafter section; reinstall with --include-draft or run with "
                    + "--draft-block-size 0")
            }
            speculative = try SpeculativeScratch(
                context: context,
                vocab: model.config.vocabSize,
                hiddenSize: model.config.hiddenSize,
                blockTokens: draftBlockSize,
                fusedGreedy: runner.usesFusedGreedyHead)
        }
        // SPEC INV-1: the domain names the rendering this KV was built with,
        // which is the server's own variant (`ServerChatTemplate`) rather than
        // the file the checkpoint ships. Hashing the checkpoint's copy would
        // let an entry outlive a change to the template that produced it.
        var templateSource = Data(ServerPromptRenderer.variant.identity.utf8)
        templateSource.append(Data(try ServerChatTemplate.jinja().utf8))
        let templateDigest = SHA256.hash(data: templateSource)
            .map { String(format: "%02x", $0) }
            .joined()
        let runtimeIdentity = [
            String(runtime.expertCacheSlots),
            runtime.expertCachePolicy.rawValue,
            runtime.rdadvisePolicy.rawValue,
            runtime.prefillPolicy.rawValue,
            String(runtime.prefillChunkTokens),
            runtime.headPath.rawValue,
        ].joined(separator: ":")
        let runtimeDigest = SHA256.hash(data: Data(runtimeIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let promptCacheDomain = ServerPromptCacheDomain(
            modelID: model.modelID,
            sourceSnapshotHash: model.sourceSnapshotHash,
            runtimeProfileHash: runtimeDigest,
            maximumContext: maxContext,
            kvStorage: PrefillKVStorageMode.fp16.rawValue,
            fp16RingEnabled: runtime.fp16RingEnabled,
            templateSHA256: templateDigest)
        return ServerModelSession(context: context,
                                  model: model,
                                  tokenizer: tokenizer,
                                  runner: runner,
                                  scratch: scratch,
                                  speculative: speculative,
                                  prefillConfig: runtime.prefillConfig,
                                  maxContext: maxContext,
                                  promptCacheDomain: promptCacheDomain,
                                  imagePolicy: imagePolicy,
                                  reasoningBudget: reasoningBudget,
                                  reasoningFormat: reasoningFormat)
    }

    private init(context: MetalContext,
                 model: Model,
                 tokenizer: GFTokenizer,
                 runner: RealForwardRunner,
                 scratch: RawCompletionScratch,
                 speculative: SpeculativeScratch?,
                 prefillConfig: PrefillRuntimeConfig,
                 maxContext: Int,
                 promptCacheDomain: ServerPromptCacheDomain,
                 imagePolicy: ServerImagePolicy,
                 reasoningBudget: Int,
                 reasoningFormat: ReasoningFormat) {
        self.context = context
        self.model = model
        self.tokenizer = tokenizer
        self.grammarVocabulary = GrammarVocabulary.shared(for: tokenizer)
        self.grammarMarkers = ChatGrammarMarkers(tokenizer: tokenizer)
        self.runner = runner
        self.scratch = scratch
        self.speculative = speculative
        self.prefillConfig = prefillConfig
        self.maxContext = maxContext
        self.promptCacheDomain = promptCacheDomain
        self.imagePolicy = imagePolicy
        self.reasoningBudget = reasoningBudget
        self.reasoningFormat = reasoningFormat
    }

    public func generate(
        _ request: ValidatedChatRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        let prepared = try await prepare(request)
        return try await generate(prepared, monitor: nil, onEvent: onEvent)
    }

    /// SPEC CACHE-2: how far the KV cursor may be moved back to serve a
    /// prefix shorter than this KV. Under FP16 ring storage that is finite,
    /// and the arithmetic belongs to the KV, not to this file.
    private var maximumRewind: Int { runner.maximumSafeRewind }


    public func prepare(_ request: ValidatedChatRequest) async throws -> ServerPreparedRequest {
        let rendered = try renderPrompt(request)
        return ServerPreparedRequest(request: request,
                                     promptIDs: rendered.promptIDs,
                                     vision: rendered.vision)
    }

    public func generate(
        _ prepared: ServerPreparedRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        try await generate(prepared, monitor: nil, onEvent: onEvent)
    }

    public func generate(
        _ prepared: ServerPreparedRequest,
        monitor: ServerTimingsMonitor?,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        let request = prepared.request
        var completed = false
        defer {
            if !completed {
                promptCache.invalidate()
                runner.reset()
            }
        }
        let needsToolTemplate = usesToolTemplate(request)
        // SPEC §6: what this request asks generation to be constrained to.
        // The decision is a pure function of the validated request and the
        // markers (`ServerGenerationPlan`); this file only builds what it
        // describes and hands it down.
        let plan = ServerGenerationPlan(request: request, markers: grammarMarkers)
        // Since S3 both templates render the thought channel, so what the
        // request asked for is what the prompt does (11-S2 §1).
        let thinking = request.enableThinking
        let promptIDs: [Int32]
        let vision: VisionPrefillInput?
        if let alreadyRendered = prepared.promptIDs {
            promptIDs = alreadyRendered
            vision = prepared.vision
        } else {
            let rendered = try renderPrompt(request)
            promptIDs = rendered.promptIDs
            vision = rendered.vision
        }

        let effectivePromptIDs: [Int32]
        let completionStart: RawCompletionStart
        // The image side of what still has to be prefilled. On a miss that is
        // the whole prompt's; on a hit the cache rebases it onto the tokens the
        // continuation adds, and nil means the pictures are already in the KV.
        var prefillVision = vision
        // CACHE-5: a request that opted out neither reads nor writes.
        let match = request.cachePrompt
            ? promptCache.match(domain: promptCacheDomain,
                                request: request,
                                renderedPromptIDs: promptIDs,
                                vision: vision,
                                maximumRewind: maximumRewind)
            : .miss
        switch match {
        case .miss:
            promptCache.invalidate()
            effectivePromptIDs = promptIDs
            completionStart = .reset
        case .hit(let effective, let cached, let continuationVision):
            // CACHE-2/CACHE-3: the served prefix can be shorter than what the
            // KV holds. The rows past it belong to a continuation this request
            // did not send, and attention reads `[0, cursor]` — so the cursor
            // is what has to move, before the runner is asked to continue.
            if cached < runner.continuationPosition {
                do {
                    try runner.rewind(to: cached)
                } catch {
                    promptCache.invalidate()
                    runner.reset()
                    effectivePromptIDs = promptIDs
                    completionStart = .reset
                    break
                }
            }
            effectivePromptIDs = effective
            completionStart = .resume(cachedPromptTokens: cached)
            prefillVision = continuationVision
        }
        guard effectivePromptIDs.count < maxContext else {
            throw ServerRequestError.invalid(
                message: "effective prompt exceeds the configured context",
                param: "messages",
                code: "context_length_exceeded")
        }

        var config = request.generationConfig
        // REQ-max-tokens: -1 asks for everything the context has left, and any
        // other value is still bounded by it.
        let contextRemaining = maxContext - effectivePromptIDs.count
        config.maxNewTokens = request.maximumCompletionTokens < 0
            ? contextRemaining
            : min(request.maximumCompletionTokens, contextRemaining)
        config.stopStrings = []

        // REQ-max-tokens: 0 is "prefill only". There is nothing to sample, so
        // the answer is an empty one with the prompt accounted for.
        if request.maximumCompletionTokens == 0 {
            completed = true
            return ServerCompletion(
                content: "",
                toolCalls: [],
                finishReason: "length",
                usage: OpenAIUsage(promptTokens: promptIDs.count,
                                   completionTokens: 0,
                                   totalTokens: promptIDs.count,
                                   cachedTokens: 0),
                approximations: plan.approximations,
                // RSP-3 over a request that ran nothing: the partition still has
                // to be the one `usage` reports, and every wall clock is zero
                // because no clock ran.
                timings: ServerTimings(cacheTokens: 0,
                                       promptTokens: promptIDs.count,
                                       promptMilliseconds: 0,
                                       predictedTokens: 0,
                                       predictedMilliseconds: 0))
        }

        // SPEC §8: what this request asks of the thought channel. Like
        // `ServerGenerationPlan` it is a decision and not a mechanism, so all
        // of RSN-1/3/4 is checkable without weights; built here because its
        // `max_tokens` half needs the budget the context left.
        //
        // RSN-4's forced sequence is the closing tag **this template writes**,
        // taken from the tokenizer rather than spelled out: the state it leaves
        // behind is then byte for byte the one a thinking-off prompt creates on
        // purpose (`<|channel>thought\n<channel|>`), which is the reason to
        // expect an answer after it.
        let forcedReasoningEnd = [tokenizer.channelEndID]
        let reasoning = ServerReasoningPlan(request: request,
                                            defaultBudget: reasoningBudget,
                                            defaultFormat: reasoningFormat,
                                            maxNewTokens: config.maxNewTokens,
                                            contextRemaining: contextRemaining,
                                            forcedTokenCount: forcedReasoningEnd.count)
        let forcer = reasoning.forcesClosingTag
            ? ReasoningBudgetForcer(startTokenID: tokenizer.channelStartID,
                                    endTokenID: tokenizer.channelEndID,
                                    forcedTokenIDs: forcedReasoningEnd,
                                    budget: reasoning.budget,
                                    deadline: reasoning.deadline)
            : nil

        // GEN-1 / GEN-3 / GEN-5: the constraint itself. Built after the
        // prefill-only exit because parsing the grammar is real work and that
        // request samples nothing.
        //
        // GEN-2 forbids a client error for schema *content* — anything
        // unrepresentable was already approximated by the builder — so a
        // grammar that will not parse is our bug, and it becomes a 500 that
        // names the request shape rather than a silent fall back to
        // unconstrained text (R4).
        let constraint: GrammarTokenConstraint?
        if let grammarText = plan.grammar {
            // GEN-7 applies the constraint by masking logits, and the fused
            // greedy head answers with a GPU argmax without ever writing them.
            // The server always builds its runner with `forceLogitsHead: true`
            // (`ServerArguments.resolvedRuntimeConfiguration`), which is why
            // this holds; the guard turns that cross-file assumption into a
            // checked dependency instead of an implicit one, and refusing is
            // the only honest answer — the alternative is free-form text under
            // a constrained request.
            guard !runner.usesFusedGreedyHead else {
                throw ServerGrammarBuildFailure(
                    shape: plan.shape,
                    underlying: GenerationConstraintError.logitsUnavailable(
                        "this server built its runner with the fused greedy head, so a "
                        + "constrained request cannot be masked; start it with the "
                        + "logits head (forceLogitsHead: true)"))
            }
            do {
                constraint = try GrammarTokenConstraint(
                    grammarText,
                    vocabulary: grammarVocabulary,
                    // GEN-5: a lazy grammar needs nothing at this call site
                    // beyond its trigger — `RawCompletion` already feeds every
                    // generated token to `accept`, which is where the trigger
                    // is watched for.
                    trigger: plan.trigger.map { .token($0.tokenID) })
            } catch {
                throw ServerGrammarBuildFailure(shape: plan.shape, underlying: error)
            }
        } else {
            constraint = nil
        }
        // GEN-6: the constraint never infers the thought channel, so the
        // decoder's verdict for each token drives it from `onProgress` below.
        let suppression = constraint?.isLazy == true
            ? ServerThoughtSuppression(tokenizer: tokenizer)
            : nil

        // With thinking on, the generation prompt leaves the thought channel
        // for the model to open, so its markers arrive in the stream and the
        // raw deltas would carry the reasoning into the answer. The decoder is
        // what knows the channel state, so this path needs it too — not only
        // the tool path it was written for.
        let decoder = needsToolTemplate || thinking
            ? StructuredAssistantDecoder(
                tokenizer: tokenizer,
                allowedTools: Set(request.tools.map(\.name)),
                emitsReasoning: thinking)
            : nil
        var stopMatcher = StreamingStopMatcher(stops: request.generationConfig.stopStrings)
        // RSP-3, `timings_per_token`. The prompt half of the timings is settled
        // before a single token is drawn — the cache decided how much of the
        // prompt is computed — so the only thing left to follow is the count of
        // generated tokens and the clock. Started just before the completion
        // call below, because the decode loop reports its own prefill
        // measurement only when it returns.
        let cachedPromptTokens: Int = switch completionStart {
        case .reset: 0
        case .resume(let cached): cached
        }
        var live: ServerLiveTimings?
        var content = ""
        var reasoningContent = ""
        var calls: [ParsedToolCall] = []
        var decodingError: Error?
        var shouldStop = false

        func onProgress(_ progress: RawDecodeProgress) {
            guard decodingError == nil else { return }
            // RSP-3: published before the events this token produced are
            // handled, so the chunk a route writes from inside `onEvent` reads
            // the timings of the token it is writing.
            if let monitor, let timings = live?.observe(progress, at: Date()) {
                monitor.record(timings)
            }
            do {
                func handle(_ events: [StructuredAssistantEvent]) {
                    for event in events {
                        // RSN-3: `auto` keeps the thought channel separate;
                        // `none` puts it back in the answer as raw text. The
                        // decoder still splits the channel either way — it is
                        // what knows where the block ends — and this is the one
                        // place the format decides where the text goes.
                        switch reasoning.route(event) {
                        case .content(let text):
                            let visible = stopMatcher.push(text)
                            if !visible.isEmpty {
                                content += visible
                                onEvent(.content(visible))
                            }
                            if stopMatcher.isStopped { shouldStop = true }
                        case .reasoning(let text):
                            // Stop strings match the answer, not the thinking:
                            // a client's stop sequence is about the text it
                            // will show, and cutting a request short on a word
                            // the model happened to think would surprise it.
                            reasoningContent += text
                            onEvent(.reasoning(text))
                        case .toolCall(let call):
                            calls.append(call)
                            onEvent(.toolCall(call))
                        }
                    }
                }
                switch progress {
                case .prefill:
                    break
                case .token(_, let tokenID, let delta):
                    let events = if let decoder {
                        try decoder.consume(tokenID: tokenID, delta: delta)
                    } else {
                        delta.isEmpty ? [] : [StructuredAssistantEvent.content(delta)]
                    }
                    // GEN-6: the thought channel decides whether the lazy
                    // grammar is supplied at all, and the decoder is what knows
                    // the channel. `RawCompletion` accepts the token into the
                    // constraint before it calls back here, so the state set
                    // now is the state the *next* token is judged by — which is
                    // exactly the rule: `<channel|>` itself is still inside the
                    // block, and everything after it is not.
                    if let constraint, let suppression {
                        constraint.setSuppressed(
                            suppression.observe(tokenID: tokenID, events: events))
                    }
                    handle(events)
                case .tail(let text):
                    // The flush tail is not tied to a token ID, so it must
                    // go through the decoder's channel state explicitly;
                    // appending it directly would leak text held back
                    // inside the thought channel or a tool call.
                    let events = if let decoder {
                        try decoder.consumeTail(text)
                    } else {
                        text.isEmpty ? [] : [StructuredAssistantEvent.content(text)]
                    }
                    handle(events)
                }
            } catch {
                decodingError = error
                shouldStop = true
            }
        }

        // The speculative loop emits the tokens the target itself drew, at the
        // same sampler positions a plain decode would have used (D5), so both
        // branches produce the same text, the same stop reason, and the same
        // rewound K/V — only the wall clock differs (docs/mtp/25-M5.6-RESULTS.md).
        // A repetition penalty makes the draw depend on history the round has
        // not committed, which cannot be verified, so such a request takes the
        // plain path instead of being refused (SPEC §12 DEV-14).
        //
        // SPEC §6 **GEN-14**: a grammar does not. It is threaded into the
        // speculative loop, which draws every position of the block with the
        // constraint applied and accepts as it goes — the redraw GEN-7 can
        // perform is still that position's own draw by the target, so the block
        // stays verifiable. This is the line CONFORMANCE §5 measures the
        // everyday client by: it declares `tools` on every request, so a
        // grammar in this condition would have meant that client never
        // speculating at all.
        let result: RawDecodeResult
        var speculativeSummary: ServerSpeculativeSummary?
        if monitor != nil {
            live = ServerLiveTimings(
                cacheTokens: cachedPromptTokens,
                promptTokens: effectivePromptIDs.count - cachedPromptTokens,
                startedAt: Date())
        }
        // RSN-4 is DEV-14's other member, for the reason a grammar no longer is:
        // a forced token is *placed* rather than drawn, so the block was never
        // verified against it. `runRawCompletion` is where the forcer is
        // consulted, and `runSpeculativeCompletion` has no parameter for it — a
        // request that reached the loop with one would silently generate an
        // unbudgeted thought block.
        if let speculative, config.repetitionPenalty == 1.0, plan.allowsSpeculativeDecoding,
           reasoning.allowsSpeculativeDecoding {
            let spec = try await runSpeculativeCompletion(
                producer: runner,
                tokenizer: tokenizer,
                promptIds: effectivePromptIDs,
                config: config,
                // GEN-7 / GEN-14. The same object the plain branch passes, used
                // the same way; a `GenerationConstraintError` or a `GBNFError`
                // out of here is left to escape into a 500 `server_error`
                // rather than a silently unconstrained answer.
                constraint: constraint,
                context: context,
                scratch: scratch,
                speculative: speculative,
                prefillConfig: prefillConfig,
                vision: prefillVision,
                start: completionStart,
                shouldStop: { shouldStop },
                // GEN-6, at the granularity GEN-14 requires. `onProgress` sees
                // a token a whole block after the round adopted it, and the
                // suppression it drives decides whether the *next* draw is
                // constrained — so the lazy grammar would run up to `bs - 1`
                // tokens behind the thought channel. This fires on adoption,
                // before the next draw, and reads the two boundary tokens
                // directly because the decoder's events do not exist yet
                // (RSN-6 licenses reading them without the label). The same
                // token is observed again with its events when it is emitted,
                // and no draw happens in between.
                onDrawnToken: { tokenID in
                    if let constraint, let suppression {
                        constraint.setSuppressed(suppression.observe(tokenID: tokenID))
                    }
                },
                // Passed as a literal rather than as `onProgress` itself:
                // region isolation rejects sending an actor-isolated function
                // value, and accepts a closure it can see is non-escaping.
                onProgress: { onProgress($0) })
            result = spec.decode
            speculativeSummary = ServerSpeculativeSummary(
                blockTokens: spec.speculative.blockTokens,
                rounds: spec.speculative.rounds,
                proposed: spec.speculative.proposed,
                accepted: spec.speculative.accepted)
        } else {
            result = try await runRawCompletion(
                producer: runner,
                tokenizer: tokenizer,
                promptIds: effectivePromptIDs,
                config: config,
                // GEN-7. A `GenerationConstraintError` or a `GBNFError` out of
                // here is left to escape: GEN-7 calls a no-allowed-token state
                // an error, so it becomes a 500 `server_error` rather than a
                // silently truncated or unconstrained answer.
                constraint: constraint,
                // RSN-4. Nil unless this request's thought channel is open and
                // bounded; the loop's behaviour is unchanged for every other
                // request, down to the draw.
                forcer: forcer,
                context: context,
                scratch: scratch,
                prefillConfig: prefillConfig,
                vision: prefillVision,
                start: completionStart,
                shouldStop: { shouldStop },
                onProgress: { onProgress($0) })
        }
        func structuredFailure(
            kind: StructuredOutputFailureKind,
            cause: StructuredOutputFailureCause
        ) -> StructuredOutputFailure {
            StructuredOutputFailure(
                kind: kind,
                cause: cause,
                diagnostics: StructuredOutputFailureDiagnostics(
                    renderedPromptIDs: promptIDs,
                    effectivePromptIDs: effectivePromptIDs,
                    result: result,
                    maxCompletionTokens: config.maxNewTokens,
                    decodedCalls: calls.count,
                    visibleBytes: content.utf8.count,
                    stopStringMatched: stopMatcher.isStopped,
                    toolStartID: tokenizer.toolCallStartID,
                    toolEndID: tokenizer.toolCallEndID,
                    toolResponseID: tokenizer.toolResponseID,
                    toolResponseEndID: tokenizer.toolResponseEndID))
        }
        if let decodingError {
            throw structuredFailure(
                kind: .decoderConsume,
                cause: .classify(decodingError))
        }
        do {
            try decoder?.finish()
        } catch {
            throw structuredFailure(
                kind: .decoderFinish,
                cause: .classify(error))
        }
        if needsToolTemplate, result.reason == .toolCalls, calls.isEmpty {
            throw structuredFailure(kind: .orphanToolResponse, cause: .none)
        }
        let tail = stopMatcher.finish()
        if !tail.isEmpty {
            content += tail
            onEvent(.content(tail))
        }
        let reason: String
        if !calls.isEmpty {
            reason = "tool_calls"
        } else if result.reason == .maxTokens {
            reason = "length"
        } else {
            reason = "stop"
        }
        if request.cachePrompt {
            // CACHE-4: the spans of the *whole* prompt, not the rebased ones a
            // resumed prefill ran on — the entry describes the KV from 0.
            promptCache.publish(domain: promptCacheDomain,
                                request: request,
                                result: result,
                                vision: vision)
        }
        completed = true
        // EP-6 `/metrics`: the totals are the sum of what RSP-3 reported for
        // each finished completion, and of nothing else. (The `max_tokens: 0`
        // exit above adds nothing — it decodes no token and spends no time.)
        // RSP-3 / GEN-14: `draft_n` / `draft_n_accepted` come from the summary
        // the speculative loop reported, and are absent for a request that took
        // the plain path — the only place on the wire where a client can see
        // whether MTP actually ran.
        let timings = ServerTimings(result, speculative: speculativeSummary)
        accumulatedMetrics = accumulatedMetrics.adding(timings)
        return ServerCompletion(
            content: content,
            toolCalls: calls,
            finishReason: reason,
            usage: OpenAIUsage(promptTokens: result.prefillTokens,
                               completionTokens: result.newTokens,
                               totalTokens: result.prefillTokens + result.newTokens,
                               cachedTokens: result.cachedPromptTokens),
            speculative: speculativeSummary,
            reasoningContent: reasoningContent,
            approximations: plan.approximations,
            // RSP-3. The authoritative measurement is the decode loop's own,
            // which is why the finished response never carries the running one
            // the monitor published.
            timings: timings)
    }

    private func renderPrompt(
        _ request: ValidatedChatRequest
    ) throws -> (promptIDs: [Int32], vision: VisionPrefillInput?) {
        let promptIDs: [Int32]
        var vision: VisionPrefillInput?
        if let requested = request.vision {
            let prepared = try renderVisionPrompt(requested, request: request)
            promptIDs = prepared.tokens
            vision = prepared.vision
        } else {
            promptIDs = try ServerPromptRenderer(tokenizer: tokenizer).promptIDs(request)
        }
        guard promptIDs.count < maxContext else {
            throw ServerRequestError.invalid(
                message: "prompt exceeds the configured context",
                param: "messages",
                code: "context_length_exceeded")
        }
        return (promptIDs, vision)
    }

    /// Decode, resize, and patchify the attached images, then widen each
    /// `<|image|>` placeholder to the span the tower will fill.
    ///
    /// Every failure here is the caller's request being unsatisfiable — an
    /// undecodable JPEG, a model with no tower, prefill turned off — so each is
    /// mapped to a typed request error. Letting a `VisionError` escape would
    /// report a 400 as a 500.
    private func renderVisionPrompt(
        _ requested: ValidatedVisionRequest,
        request: ValidatedChatRequest
    ) throws -> (tokens: [Int32], vision: VisionPrefillInput) {
        guard model.hasVisionTower else {
            throw ServerRequestError.invalid(
                message: "this model was installed without a vision tower; add one with "
                    + "`TurboFieldfareRepack --add-vision --input-gturbo <model.gturbo>`",
                param: "messages",
                code: "vision_not_installed")
        }
        // The unchunked replay path embeds one token at a time and has nowhere
        // to scatter a soft token into (`RawCompletion`), so an image would fail
        // deep inside prefill. Refuse it here, where the message can name the
        // flag that caused it.
        guard prefillConfig.mode == .chunked else {
            throw ServerRequestError.invalid(
                message: "images require chunked prefill; this server was started with --prefill off",
                param: "messages",
                code: "vision_prefill_disabled")
        }
        do {
            let config = try VisionPreprocessorConfig(maxSoftTokens: imagePolicy.maxSoftTokens)
            let images = try requested.images.map {
                try VisionImagePreprocessor.preprocess(data: $0.data, config: config)
            }
            // Both templates place the same `<|image|>` marker, so the
            // assembler that widens it into soft-token spans is shared: only
            // the rendering in front of it differs (11-S2 §1).
            let tokens: [Int32]
            if usesToolTemplate(request) {
                tokens = try tokenizer.encodeToolChat(
                    messages: request.toolChatMessages,
                    tools: request.tools,
                    enableThinking: request.enableThinking,
                    variant: ServerPromptRenderer.variant)
            } else {
                let rendered = try tokenizer.applyChatTemplate(
                    multimodal: requested.messages,
                    enableThinking: request.enableThinking,
                    variant: ServerPromptRenderer.variant)
                tokens = tokenizer.encode(rendered, addBOS: false)
            }
            let ids = try VisionMediaTokenIDs(tokenizer: tokenizer)
            return try VisionPromptAssembler.makePrefillPrompt(tokens: tokens,
                                                               images: images,
                                                               ids: ids)
        } catch let error as VisionError {
            throw ServerRequestError.invalid(
                message: "\(error)",
                param: "messages",
                code: "invalid_image")
        } catch let error as GFTokenizerError {
            throw ServerRequestError.invalid(
                message: "\(error)",
                param: "messages",
                code: "invalid_message")
        }
    }

    private func usesToolTemplate(_ request: ValidatedChatRequest) -> Bool {
        ServerPromptRenderer.usesToolTemplate(request)
    }

    // MARK: - EP-5 / EP-6

    /// EP-5's three endpoints need the tokenizer and nothing this actor owns
    /// beyond it, so the work is `ServerTextEndpoints`' and this only forwards.
    private var textEndpoints: ServerTextEndpoints {
        ServerTextEndpoints(tokenizer: tokenizer)
    }

    public func tokenize(_ text: String, addSpecial: Bool) -> [Int32] {
        textEndpoints.tokenize(text, addSpecial: addSpecial)
    }

    public func detokenize(_ tokens: [Int32]) -> String {
        textEndpoints.detokenize(tokens)
    }

    public func applyChatTemplate(_ request: ValidatedChatRequest) throws -> String {
        try textEndpoints.applyChatTemplate(request)
    }

    /// EP-6 `/metrics`.
    public func metrics() -> ServerMetricsSnapshot { accumulatedMetrics }
}
