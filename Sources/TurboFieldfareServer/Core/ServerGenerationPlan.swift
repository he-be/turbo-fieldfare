import Foundation
import TurboFieldfare

/// SPEC §6: one request's *decision* about how generation is constrained, with
/// none of the inference loop in it.
///
/// `ServerModelSession` cannot be tested without weights, so the part of
/// G4c that is a decision lives here instead of inside it: given a
/// `ValidatedChatRequest` and the tokenizer's markers, this says whether there
/// is a grammar, what it spells, whether it is lazy and what triggers it
/// (GEN-5), whether the speculative loop may still run (GEN-14), and what the
/// client asked for that could only be approximated (GEN-2 / DEV-16). What is
/// left in `ServerModelSession` is the construction of a
/// `GrammarTokenConstraint` from this and the handing of it to whichever
/// decode loop the request takes.
///
/// The grammar itself is `ChatGrammarBuilder`'s; this type only chooses the
/// arguments and carries the answer.
struct ServerGenerationPlan: Equatable, Sendable {
    /// GBNF text rooted at `root`, or `nil` when this request asks for no
    /// constraint at all (GEN-4's `none`, a `text` response format with no
    /// tools, a named choice with nothing to name).
    let grammar: String?
    /// GEN-5: `true` means the grammar is not applied until `trigger` fires.
    let isLazy: Bool
    /// GEN-5. Non-nil exactly when `isLazy`.
    let trigger: ChatGrammarTrigger?
    /// GEN-2 / DEV-16: what the client asked for that could only be
    /// approximated. The declaration side (`GemmaToolSchemaResult`, tagged
    /// `tools/`) comes first and the grammar side (`ChatGrammarConstraint`,
    /// tagged `grammar/`) after, because the two degrade independently. Never
    /// an error — the server logs them.
    let approximations: [String]
    /// The request shape an error message may name, in the vocabulary of the
    /// request rather than of the conversation. **Never prompt text.**
    let shape: String

    var isConstrained: Bool { grammar != nil }

    /// GEN-14: a grammar is no longer a reason to leave the speculative path.
    ///
    /// Constant `true`, and kept as a property rather than deleted, because
    /// this is the type that answers "how is this request constrained" and the
    /// answer to "and may it still speculate" is part of that — it read
    /// `!isConstrained` until 2026-08-21, and the line that changed is the one
    /// CONFORMANCE §5 measures the everyday client by. The speculative loop
    /// draws every position with the constraint applied and accepts as it goes
    /// (参照実装 `common_sampler_sample_and_accept_n`), so the redraw GEN-7 can
    /// perform is still that position's own draw by the target.
    ///
    /// The two requests that still take the plain path are DEV-14's remainder,
    /// and neither is decided here: RSN-4's forced closing tag is
    /// `ServerReasoningPlan.allowsSpeculativeDecoding`, and
    /// `repeat_penalty != 1` is read off the generation config.
    var allowsSpeculativeDecoding: Bool { true }

    /// GEN-7: masking needs logits, and the fused greedy head answers with a
    /// GPU argmax without ever writing them.
    var requiresLogitsHead: Bool { isConstrained }

    init(request: ValidatedChatRequest, markers: ChatGrammarMarkers) {
        // GEN-12 is settled before this point: `ChatRequestParser` refuses a
        // constraining `response_format` beside a `required` or named
        // `tool_choice` with a 400, so the collision never reaches the plan.
        // What is left here is the case the reference implementation also
        // takes silently — `auto` / `none`, where the response format wins and
        // no tool grammar is emitted.
        let constraint = ChatGrammarBuilder.constraint(
            tools: request.tools,
            toolChoice: request.toolChoice,
            parallelToolCalls: request.parallelToolCalls,
            responseFormat: Self.responseFormat(request.responseFormat),
            markers: markers)
        self.grammar = constraint?.grammar
        self.isLazy = constraint?.isLazy ?? false
        self.trigger = constraint?.trigger
        self.approximations =
            request.toolSchemaSimplifications.map { "tools/" + $0 }
            + (constraint?.approximations ?? []).map { "grammar/" + $0 }
        self.shape = Self.shape(request)
    }

    /// The parser's `ChatResponseFormat` and the grammar stage's
    /// `ChatGrammarBuilder.ResponseFormat` are the same three shapes seen from
    /// the wire and from the grammar; this is the one place they are joined.
    private static func responseFormat(
        _ format: ChatResponseFormat
    ) -> ChatGrammarBuilder.ResponseFormat {
        switch format {
        case .text: return .text
        case .jsonObject(let schema): return .jsonObject(schema: schema)
        case .jsonSchema(let schema): return .jsonSchema(schema: schema)
        }
    }

    private static func shape(_ request: ValidatedChatRequest) -> String {
        let choice: String
        switch request.toolChoice {
        case .auto: choice = "auto"
        case .none: choice = "none"
        case .required: choice = "required"
        // The name is the client's own identifier for a function it declared,
        // not conversation text.
        case .function(let name): choice = "function:\(name)"
        }
        let format: String
        switch request.responseFormat {
        case .text: format = "text"
        case .jsonObject: format = "json_object"
        case .jsonSchema: format = "json_schema"
        }
        return "tool_choice=\(choice) response_format=\(format) "
            + "tools=\(request.tools.count) "
            + "parallel_tool_calls=\(request.parallelToolCalls)"
    }
}

/// SPEC §8: one request's *decision* about the thought channel, with none of
/// the decode loop in it — `ServerGenerationPlan`'s sibling.
///
/// Everything RSN-1 … RSN-5 asks of a single request is a pure function of the
/// validated request, the two process defaults (`--reasoning-budget`,
/// `--reasoning-format`), and the completion budget the session resolved. That
/// is what this is, so the whole reasoning surface is checkable without a
/// model; what is left in `ServerModelSession` is building a
/// `ReasoningBudgetForcer` from `budget`/`deadline` and routing the decoder's
/// events through `route`.
struct ServerReasoningPlan: Equatable, Sendable {
    /// RSN-1 / RSN-2: whether this request's prompt left the thought channel
    /// open. The resolution order is `ChatRequestParser.enableThinking`'s and
    /// is not repeated here.
    let isThinking: Bool
    /// RSN-3.
    let format: ReasoningFormat
    /// RSN-4, first half: tokens the thought block may spend.
    /// `ReasoningBudgetForcer.unlimited` for no bound.
    let budget: Int
    /// RSN-4, second half: the last generation index at which the forced
    /// closing tag may start and still leave the answer its reserve.
    /// `Int.max` when `max_tokens` set no bound.
    let deadline: Int

    /// RSN-3: `auto` splits the thought out into `reasoning_content`; `none`
    /// leaves it in the answer as raw text.
    var separatesReasoning: Bool { format == .auto }

    /// RSN-4: whether this request needs a `ReasoningBudgetForcer` at all. A
    /// request whose thought channel is closed cannot overrun it, and one with
    /// neither half of the budget bounded asked for exactly that.
    var forcesClosingTag: Bool {
        isThinking && (budget >= 0 || deadline != Int.max)
    }

    /// DEV-14's remaining rule: forcing changes the token at a position without
    /// drawing it, and every later position of a verified block was drafted
    /// against a prefix that then never happened. The caller branches to
    /// `runRawCompletion`, as it does for a repetition penalty. A grammar left
    /// this list on 2026-08-21 (GEN-14) — it *is* drawn, so the block stays
    /// verifiable; forcing is not.
    var allowsSpeculativeDecoding: Bool { !forcesClosingTag }

    /// - Parameters:
    ///   - defaultBudget: `--reasoning-budget` (RSN-1).
    ///   - defaultFormat: `--reasoning-format` (RSN-3).
    ///   - maxNewTokens: the completion budget the session resolved — the
    ///     request's `max_tokens` already clamped to what the context has left.
    ///   - contextRemaining: what the context had left after the prompt, i.e.
    ///     the ceiling `maxNewTokens` was clamped to. RSN-4's second half is
    ///     decided by comparing the two: a request whose `max_tokens` did not
    ///     bind is a request with no client-chosen budget.
    ///   - forcedTokenCount: how many tokens the forced sequence spends.
    init(request: ValidatedChatRequest,
         defaultBudget: Int,
         defaultFormat: ReasoningFormat,
         maxNewTokens: Int,
         contextRemaining: Int,
         forcedTokenCount: Int) {
        // RSN-1 / RSN-2. The channel is already resolved: `ChatRequestParser`
        // walked the reference's four steps, with the process default (which
        // is `--reasoning-budget != 0`) as their base.
        self.isThinking = request.enableThinking
        // RSN-3. `none` from either side turns the split off. The wire default
        // is `auto` and this layer cannot tell it from an absent field, so an
        // explicit `reasoning_format: "auto"` does not override a process
        // default of `none` — the only cell where the two disagree, and the
        // one that needs `ChatRequestDefaults` to carry the format to be right.
        self.format = request.reasoningFormat == .none ? .none : defaultFormat
        // RSN-4, first half. `-1` in the request means "whatever the server was
        // started with", exactly as the reference resolves it
        // (`server-common.cpp:1340`).
        self.budget = request.reasoningBudgetTokens < 0
            ? defaultBudget
            : request.reasoningBudgetTokens
        // RSN-4, second half. A `max_tokens` the client named bounds the block
        // even when no budget did: the tag has to start early enough to leave
        // the answer its reserve.
        //
        // The test is whether that number actually **bound** anything, not
        // whether it was written down. `maxNewTokens` is
        // `min(max_tokens, contextRemaining)` (`max_tokens: -1` resolving to
        // the whole remainder), so the client's number bound the request
        // exactly when the result came out below the ceiling. When it did not,
        // this request generates token for token what `max_tokens: -1` would,
        // and RSN-4's own sentence applies to it unchanged: the context ceiling
        // is not a budget the client chose.
        //
        // Reading the spelling instead of the effective value is what cost pi's
        // thinking sessions their speculative decoding — it sends
        // `models.json`'s `maxTokens`, the same number as `context_window`, so
        // every request carried a deadline tens of thousands of tokens past any
        // answer it would write, and DEV-14 dropped every one of them onto the
        // plain path (CONFORMANCE §2, 2026-08-21).
        self.deadline = maxNewTokens < contextRemaining
            ? maxNewTokens - Self.answerReserve(maxNewTokens: maxNewTokens) - forcedTokenCount
            : Int.max
    }

    /// RSN-3. The one place the format changes what the client sees.
    func route(_ event: StructuredAssistantEvent) -> StructuredAssistantEvent {
        guard !separatesReasoning, case .reasoning(let text) = event else { return event }
        return .content(text)
    }

    /// RSN-4: how much of `max_tokens` the answer is guaranteed.
    ///
    /// The thought block is not allowed to spend the last quarter of the
    /// completion budget, floored at one token. Some reserve is forced by
    /// arithmetic — "本文 0 字を返さない" cannot hold if the closing tag lands on
    /// the final position — and a fixed fraction is the least-invented rule
    /// that scales with the request instead of pinning a magic token count.
    /// The reference implementation has no equivalent: its budget is the
    /// explicit `reasoning_budget_tokens` alone, and RSN-4's second half is
    /// this server's own line.
    static func answerReserve(maxNewTokens: Int) -> Int {
        max(1, maxNewTokens / 4)
    }
}

/// GEN-6: whether the grammar is suppressed right now because the model is
/// inside its thought block.
///
/// The constraint deliberately does not infer this
/// (`GrammarTokenConstraint.setSuppressed`), and this type does not decide
/// thought-from-visible either — **`StructuredAssistantDecoder` owns the
/// channel state**, and says which side of it a token's text fell on by
/// emitting `.reasoning` or `.content`. This carries that verdict forward, and
/// names the two boundary tokens directly for the one thing an event cannot
/// express: the state the boundary token *leaves behind*.
///
/// `<channel|>` is why that matters. The detokenizer holds text back at a
/// structural marker, so the token that closes the block arrives carrying the
/// last of the thought text — a `.reasoning` event on the very token after
/// which the grammar must be live again. The server template writes
/// `<|tool_call>` immediately after that close, so reading the event alone
/// would keep the grammar asleep through the exact call it exists to
/// constrain.
///
/// `<|channel>` is the mirror: the channel is open but unlabelled, so nothing
/// is visible text yet. Suppressing is the safe side — the decoder releases it
/// on the first text it routes to content, which is what a `final` / `answer`
/// label produces.
///
/// A class, not a value: it is driven from the decode loop's progress closure,
/// which cannot mutate a captured struct through a `#expect`-style borrow, and
/// its one reader is the constraint object beside it.
final class ServerThoughtSuppression: @unchecked Sendable {
    let channelStartID: Int32
    let channelEndID: Int32
    /// Generation starts outside the thought block: with thinking off the
    /// prompt itself closed the channel, and with thinking on the model has
    /// not opened it yet.
    private(set) var isSuppressed = false

    init(channelStartID: Int32, channelEndID: Int32) {
        self.channelStartID = channelStartID
        self.channelEndID = channelEndID
    }

    convenience init(tokenizer: GFTokenizer) {
        self.init(channelStartID: tokenizer.channelStartID,
                  channelEndID: tokenizer.channelEndID)
    }

    /// Advance by one generated token and its decoded events, and answer with
    /// the state that token leaves behind.
    @discardableResult
    func observe(tokenID: Int32, events: [StructuredAssistantEvent]) -> Bool {
        // The boundary tokens first: their events describe the text held back
        // from *before* them, which is the channel they are leaving.
        guard !observe(tokenID: tokenID) else { return isSuppressed }
        for event in events {
            switch event {
            case .reasoning: isSuppressed = true
            case .content, .toolCall: isSuppressed = false
            }
        }
        return isSuppressed
    }

    /// GEN-14: the same rule for a token that has been *adopted* but not yet
    /// emitted, where there are no decoder events to read — the speculative
    /// loop draws a whole block before the queue emits any of it, and a lazy
    /// grammar that learned the channel closed a block late would sleep through
    /// the very call it exists to constrain.
    ///
    /// Only the two boundary tokens can be read without the decoder, and they
    /// are the two that matter: RSN-6 says this template's channel blocks are
    /// thought as a whole, so `<|channel>` arms and `<channel|>` releases
    /// without anyone reading the label. The answer says whether this token was
    /// one of them; a token that was not leaves the state alone here and is
    /// judged again, with its events, when it is emitted. No draw happens
    /// between those two points, so the emitted verdict is always the one the
    /// next draw sees.
    @discardableResult
    func observe(tokenID: Int32) -> Bool {
        if tokenID == channelEndID {
            isSuppressed = false
        } else if tokenID == channelStartID {
            isSuppressed = true
        } else {
            return false
        }
        return true
    }
}

/// GEN-2: a grammar that will not *build* is a bug on our side.
///
/// Schema content can never be a client error (GEN-2 / DEV-16 — anything
/// unrepresentable is approximated instead), so reaching this means the
/// grammar this server wrote is not one this server can parse. It escapes
/// `ServerModelSession` untyped, which the HTTP layer turns into a 500
/// `server_error`; the point of the type is that the stderr line names the
/// request shape that produced it, and that the failure is never swallowed
/// into an unconstrained generation (which would be R4's answer-in-the-wrong-
/// shape with a 200).
struct ServerGrammarBuildFailure: Error, CustomDebugStringConvertible, Sendable {
    let shape: String
    let underlying: String

    init(shape: String, underlying: Error) {
        self.shape = shape
        self.underlying = String(reflecting: underlying)
    }

    var debugDescription: String {
        "grammar_build_failure shape=\(shape) error=\(underlying)"
    }
}

/// GEN-2 / DEV-16: the approximations as one field of the request-lifecycle
/// stderr line (docs/OPENAI_SERVER.md).
///
/// The strings come from `tools` and `response_format` — the schemas the
/// client declared — and never from `messages`, so the line keeps its promise
/// of carrying counts and shapes but no prompt text. They are still client
/// input, so they are flattened to one line and bounded before they are
/// written.
enum ServerApproximationLog {
    static let limit = 512

    static func field(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        var joined = items.map(flatten).joined(separator: "; ")
        if joined.count > limit {
            joined = String(joined.prefix(limit - 1)) + "…"
        }
        return joined
    }

    /// One line, printable: a schema fragment may carry newlines or control
    /// bytes, and a log line that a client can break is a log line that lies.
    private static func flatten(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            ($0.value < 0x20 || $0.value == 0x7F) ? " " : $0
        }))
    }
}
