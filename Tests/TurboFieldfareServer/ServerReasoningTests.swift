import Foundation
import Testing
@testable import TurboFieldfare
@testable import TurboFieldfareServerCore

/// Emits a thought channel and an answer, in the order a reasoning generation
/// produces them.
private actor ReasoningBackend: ServerInferenceBackend {
    func generate(
        _ request: ValidatedChatRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        onEvent(.reasoning("weighing it"))
        onEvent(.content("hello"))
        return ServerCompletion(
            content: "hello",
            toolCalls: [],
            finishReason: "stop",
            usage: OpenAIUsage(promptTokens: 3, completionTokens: 5, totalTokens: 8),
            reasoningContent: "weighing it")
    }
}

/// Answers without reasoning, so the response must not carry the field at all.
private actor PlainBackend: ServerInferenceBackend {
    func generate(
        _ request: ValidatedChatRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        onEvent(.content("hello"))
        return ServerCompletion(
            content: "hello",
            toolCalls: [],
            finishReason: "stop",
            usage: OpenAIUsage(promptTokens: 3, completionTokens: 1, totalTokens: 4))
    }
}

/// Records what the request asked the template to do.
private actor ThinkingRecordingBackend: ServerInferenceBackend {
    private(set) var sawThinking: Bool?

    func generate(
        _ request: ValidatedChatRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        sawThinking = request.enableThinking
        onEvent(.content("ok"))
        return ServerCompletion(
            content: "ok",
            toolCalls: [],
            finishReason: "stop",
            usage: OpenAIUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2))
    }
}

@Suite("Server reasoning requests")
struct ServerReasoningRequestTests {
    private func request(_ body: String) -> Data { Data(body.utf8) }

    /// pi's `qwen-chat-template` thinking format sends exactly this, including
    /// the `preserve_thinking` key this template has no use for.
    @Test func chatTemplateKwargsTurnTheThoughtChannelOn() throws {
        let validated = try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":true,"preserve_thinking":true}}
            """#))
        #expect(validated.enableThinking)
    }

    /// REQ-reasoning-effort: this template has one thought channel and no
    /// budget, so a level is read for its on/off sense — and the set of levels
    /// is not enumerated. "none" is the one word with a fixed meaning.
    @Test func REQ_reasoning_effort_any_level_asks_to_reason() throws {
        for effort in ["minimal", "low", "medium", "high", "max", "ultra", "off"] {
            let validated = try ChatRequestParser.parse(
                request("""
                {"model":"m","messages":[{"role":"user","content":"hi"}],
                 "reasoning_effort":"\(effort)"}
                """))
            #expect(validated.enableThinking, "\(effort) should reason")
            #expect(validated.reasoningEffort == effort)
        }
    }

    @Test func REQ_reasoning_effort_none_turns_the_channel_off() throws {
        let validated = try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "reasoning_effort":"none"}
            """#),
            defaults: ChatRequestDefaults(thinking: .on))
        #expect(!validated.enableThinking)
    }

    /// RSN-2. Two spellings reach this server and neither is refused for
    /// disagreeing with the other: `enable_thinking` is the template's own
    /// switch and wins, and `reasoning_effort: "none"` is applied after it,
    /// which is the order the reference implementation resolves them in
    /// (`server-common.cpp:1278-1304`).
    @Test func RSN_2_both_spellings_resolve_without_a_refusal() throws {
        let kwargsWin = try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "reasoning_effort":"high","chat_template_kwargs":{"enable_thinking":false}}
            """#))
        #expect(!kwargsWin.enableThinking)

        let noneWins = try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "reasoning_effort":"none","chat_template_kwargs":{"enable_thinking":true}}
            """#))
        #expect(!noneWins.enableThinking)

        let agreeing = try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "reasoning_effort":"high","chat_template_kwargs":{"enable_thinking":true}}
            """#))
        #expect(agreeing.enableThinking)
    }

    /// RSN-2, the order itself and not just its outcomes. The SPEC line names
    /// four steps (`server-common.cpp:1278-1304`); this walks them in order,
    /// each against a process default that says the opposite, so a step that
    /// stopped running would be visible.
    @Test func RSN_2_the_resolution_order_is_the_references() throws {
        // 1. the process default, when the request is silent.
        #expect(try ChatRequestParser.parse(
            request(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#),
            defaults: ChatRequestDefaults(thinking: .on)).enableThinking)

        // 2. `enable_thinking` overrides it, in both directions.
        #expect(!(try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":false}}
            """#),
            defaults: ChatRequestDefaults(thinking: .on)).enableThinking))

        // 3. only when `enable_thinking` is absent does `reasoning_effort`'s
        //    presence decide — any level other than "none" asks to reason.
        #expect(try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "reasoning_effort":"low"}
            """#),
            defaults: ChatRequestDefaults(thinking: .off)).enableThinking)

        // 4. "none" and a zero budget close the channel last, over anything
        //    the earlier steps decided.
        #expect(!(try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "reasoning_effort":"none","chat_template_kwargs":{"enable_thinking":true}}
            """#),
            defaults: ChatRequestDefaults(thinking: .on)).enableThinking))
        #expect(!(try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":true},"reasoning_budget_tokens":0}
            """#),
            defaults: ChatRequestDefaults(thinking: .on)).enableThinking))
    }

    /// RSN-1: a budget of zero says "do not reason" the third way.
    @Test func REQ_reasoning_budget_zero_closes_the_channel() throws {
        let validated = try ChatRequestParser.parse(
            request(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":true},"reasoning_budget_tokens":0}
            """#))
        #expect(!validated.enableThinking)
        #expect(validated.reasoningBudgetTokens == 0)
    }

    @Test func malformedChatTemplateKwargsAreRefused() throws {
        for body in [
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"chat_template_kwargs":{"enable_thinking":"yes"}}"#,
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"chat_template_kwargs":[1]}"#,
        ] {
            let decoded = request(body)
            let error = #expect(throws: ServerRequestError.self) {
                try ChatRequestParser.parse(decoded)
            }
            #expect(error?.param == "chat_template_kwargs")
        }
    }

    @Test func theProcessDefaultAppliesOnlyWhenTheRequestIsSilent() throws {
        let silent = request(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}]}
        """#)
        #expect(try ChatRequestParser.parse(
            silent, defaults: ChatRequestDefaults(thinking: .on)).enableThinking)
        #expect(!(try ChatRequestParser.parse(silent).enableThinking))

        let opinionated = request(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":false}}
        """#)
        #expect(!(try ChatRequestParser.parse(
            opinionated, defaults: ChatRequestDefaults(thinking: .on)).enableThinking))
    }

    /// RSN-1 / FLAG-1. The process default is `--reasoning-budget N`:
    /// `-1` is unlimited and the default, `0` closes the thought channel, and
    /// `N > 0` is a ceiling on it. The value range is REQ-reasoning-budget's,
    /// so the flag and the request field refuse the same numbers.
    @Test func RSN_1_the_process_default_is_the_reasoning_budget_flag() throws {
        let byDefault = try ServerArguments.parse(["--model", "m.gturbo"])
        #expect(byDefault.reasoningBudget == -1)
        #expect(byDefault.thinkingPolicy == .on, "-1 は無制限であって無効ではない")

        let off = try ServerArguments.parse(
            ["--model", "m.gturbo", "--reasoning-budget", "0"])
        #expect(off.reasoningBudget == 0)
        #expect(off.thinkingPolicy == .off)

        let capped = try ServerArguments.parse(
            ["--model", "m.gturbo", "--reasoning-budget", "128"])
        #expect(capped.reasoningBudget == 128)
        #expect(capped.thinkingPolicy == .on)

        for value in ["-2", "half", ""] {
            #expect(throws: ServerArgumentError.self) {
                try ServerArguments.parse(["--model", "m.gturbo", "--reasoning-budget", value])
            }
        }
    }

    /// FLAG-1. `--reasoning-format` takes the reference implementation's
    /// spelling, and RSN-3's two values.
    @Test func FLAG_1_reasoning_format_is_a_process_flag() throws {
        #expect(try ServerArguments.parse(["--model", "m.gturbo"]).reasoningFormat == .auto)
        #expect(try ServerArguments.parse(
            ["--model", "m.gturbo", "--reasoning-format", "none"]).reasoningFormat == .none)
        #expect(try ServerArguments.parse(
            ["--model", "m.gturbo", "--reasoning-format", "auto"]).reasoningFormat == .auto)
        #expect(throws: ServerArgumentError.self) {
            try ServerArguments.parse(["--model", "m.gturbo", "--reasoning-format", "deepseek"])
        }
    }

    /// FLAG-4. Retired means it stops being accepted: `--thinking` is a usage
    /// error like any other unknown flag (exit 2 + usage, from `main.swift`),
    /// but it is refused by name so the message can say what replaced it —
    /// "unknown flag" would leave an operator with a working command line and
    /// no idea which half to change.
    @Test func FLAG_4_thinking_is_retired_and_the_error_names_its_replacement() throws {
        for arguments in [["--model", "m.gturbo", "--thinking", "on"],
                          ["--model", "m.gturbo", "--thinking", "off"],
                          ["--model", "m.gturbo", "--thinking"]] {
            let error = #expect(throws: ServerArgumentError.self) {
                try ServerArguments.parse(arguments)
            }
            #expect(error?.description.contains("--reasoning-budget") == true,
                    "\(arguments) の誤りが置き換え先を示していない")
        }
        // The other half of FLAG-4, retired with the prompt cache in P1.
        let cacheMode = #expect(throws: ServerArgumentError.self) {
            try ServerArguments.parse(["--model", "m.gturbo", "--prompt-cache-mode", "off"])
        }
        #expect(cacheMode?.description.contains("cache_prompt") == true)
        // An unknown flag is still just an unknown flag.
        #expect(throws: ServerArgumentError.self) {
            try ServerArguments.parse(["--model", "m.gturbo", "--reasoning", "on"])
        }
        #expect(!ServerArguments.usage.contains("--thinking"))
        #expect(ServerArguments.usage.contains("--reasoning-budget"))
        #expect(ServerArguments.usage.contains("--reasoning-format"))
    }

    /// Since S3 the tool-calling template reasons too: `enableThinking` is
    /// passed through instead of being pinned to false, and the marker lands in
    /// the same system turn that carries the tool declarations.
    ///
    /// RSN-5: 宣言された tools は思考を閉じない。
    @Test func RSN_5_tools_do_not_close_the_thought_channel() async throws {
        let tokenizer = try await GFTokenizer.load()
        let tools = [GFTokenizer.FunctionDefinition(
            name: "read",
            description: "Read a file",
            parameters: .object(["type": .string("object")]))]
        let messages = [GFTokenizer.Message(role: .user, content: "read /tmp/a")]

        let reasoning = try tokenizer.encodeToolChat(
            messages: messages, tools: tools, enableThinking: true)
        #expect(tokenizer.decode(reasoning, skipSpecialTokens: false).contains("<|think|>"))

        let plain = try tokenizer.encodeToolChat(messages: messages, tools: tools)
        #expect(!tokenizer.decode(plain, skipSpecialTokens: false).contains("<|think|>"))

        // …and the request side agrees: declaring tools is not one of the
        // things RSN-2 lets close the channel, whichever way it was opened.
        let declared = try ChatRequestParser.parse(request(#"""
        {"model":"m","messages":[{"role":"user","content":"read /tmp/a"}],
         "chat_template_kwargs":{"enable_thinking":true},
         "tools":[{"type":"function","function":{"name":"read","description":"Read a file",
          "parameters":{"type":"object"}}}]}
        """#))
        #expect(declared.enableThinking)
        #expect(declared.tools.count == 1)
        #expect(ServerPromptRenderer.usesToolTemplate(declared))
    }

    /// A tool request with no image renders byte for byte as it did before the
    /// parts path existed — the body is still sent as a string.
    @Test func textOnlyToolPromptsAreUnchangedByThePartsPath() async throws {
        let tokenizer = try await GFTokenizer.load()
        let tools = [GFTokenizer.FunctionDefinition(
            name: "read",
            description: "Read a file",
            parameters: .object(["type": .string("object")]))]
        let asMessages = try tokenizer.encodeToolChat(
            messages: [GFTokenizer.Message(role: .user, content: "read /tmp/a")],
            tools: tools)
        let asParts = try tokenizer.encodeToolChat(
            messages: [GFTokenizer.ToolChatMessage(role: .user, parts: [.text("read /tmp/a")])],
            tools: tools)
        #expect(asMessages == asParts)
    }

    @Test func decoderSurfacesTheThoughtChannelAsReasoning() async throws {
        let tokenizer = try await GFTokenizer.load()
        let decoder = StructuredAssistantDecoder(tokenizer: tokenizer,
                                                 allowedTools: [],
                                                 emitsReasoning: true)
        #expect(try decoder.consume(tokenID: tokenizer.channelStartID, delta: "").isEmpty)
        // The label line names the channel and carries no text of its own.
        #expect(try decoder.consume(tokenID: tokenizer.bosID, delta: "thought\n").isEmpty)
        #expect(try decoder.consume(tokenID: tokenizer.bosID, delta: "weighing") == [
            .reasoning("weighing"),
        ])
        #expect(try decoder.consumeTail(" it") == [.reasoning(" it")])
        #expect(try decoder.consume(tokenID: tokenizer.channelEndID, delta: "") == [])
        #expect(try decoder.consume(tokenID: tokenizer.bosID, delta: "answer") == [
            .content("answer"),
        ])
    }

    /// The label line names the channel; text that arrives in the same delta
    /// after the newline belongs to the channel it just named.
    @Test func reasoningInTheLabelDeltaIsNotLost() async throws {
        let tokenizer = try await GFTokenizer.load()
        let decoder = StructuredAssistantDecoder(tokenizer: tokenizer,
                                                 allowedTools: [],
                                                 emitsReasoning: true)
        #expect(try decoder.consume(tokenID: tokenizer.channelStartID, delta: "").isEmpty)
        #expect(try decoder.consume(tokenID: tokenizer.bosID, delta: "thought\nfirst") == [
            .reasoning("first"),
        ])
    }

    /// Without the flag the decoder behaves exactly as it did before reasoning
    /// existed: the thought channel is dropped, not relabeled.
    @Test func decoderStillHidesThoughtWhenReasoningIsNotRequested() async throws {
        let tokenizer = try await GFTokenizer.load()
        let decoder = StructuredAssistantDecoder(tokenizer: tokenizer, allowedTools: [])
        #expect(try decoder.consume(tokenID: tokenizer.channelStartID, delta: "").isEmpty)
        #expect(try decoder.consume(tokenID: tokenizer.bosID, delta: "thought\nhidden").isEmpty)
        #expect(try decoder.consume(tokenID: tokenizer.bosID, delta: "more").isEmpty)
    }
}

/// SPEC §8 as one request's decision (`ServerReasoningPlan`): the budget
/// arithmetic of RSN-4 and the routing of RSN-3, both without a model.
@Suite("Server reasoning plan")
struct ServerReasoningPlanTests {
    /// **`contextRemaining` has no default on purpose.** RSN-4's second half
    /// turns on which of the two numbers bound the request, so a test that did
    /// not say what the context had left would not be saying what it is
    /// testing. `maxNewTokens` is always `min(max_tokens, contextRemaining)`,
    /// the way `ServerModelSession` computes it.
    private func plan(_ body: String,
                      defaultBudget: Int = -1,
                      defaultFormat: ReasoningFormat = .auto,
                      maxNewTokens: Int,
                      contextRemaining: Int,
                      thinking: ServerThinkingPolicy = .on) throws -> ServerReasoningPlan {
        let request = try ChatRequestParser.parse(
            Data(body.utf8), defaults: ChatRequestDefaults(thinking: thinking))
        return ServerReasoningPlan(request: request,
                                   defaultBudget: defaultBudget,
                                   defaultFormat: defaultFormat,
                                   maxNewTokens: maxNewTokens,
                                   contextRemaining: contextRemaining,
                                   forcedTokenCount: 1)
    }

    private let thinkingRequest = #"""
    {"model":"m","messages":[{"role":"user","content":"hi"}],
     "chat_template_kwargs":{"enable_thinking":true}}
    """#

    /// RSN-4, first half: the request's own budget, and the process default it
    /// falls back to. `-1` in the request means "whatever the server was
    /// started with", exactly as in the reference (`server-common.cpp:1340`).
    @Test func RSN_4_the_request_budget_falls_back_to_the_process_default() throws {
        #expect(try plan(thinkingRequest, defaultBudget: 128,
                         maxNewTokens: 4_096, contextRemaining: 4_096).budget == 128)
        #expect(try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true},"reasoning_budget_tokens":24}
        """#, defaultBudget: 128, maxNewTokens: 4_096, contextRemaining: 4_096).budget == 24)
        #expect(try plan(thinkingRequest, defaultBudget: -1,
                         maxNewTokens: 4_096, contextRemaining: 4_096).budget == -1)
    }

    /// RSN-4, second half: `max_tokens` bounds the thought block even when no
    /// budget was named. The deadline is the last index at which the forced tag
    /// may start and still leave the answer its reserve — with `max_tokens: 80`
    /// (CONFORMANCE §2's measurement) that is 80 - 20 - 1.
    @Test func RSN_4_max_tokens_bounds_the_thought_block_on_its_own() throws {
        let measured = try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true},"max_tokens":80}
        """#, maxNewTokens: 80, contextRemaining: 4_096)
        #expect(measured.budget == -1)
        #expect(measured.deadline == 80 - ServerReasoningPlan.answerReserve(maxNewTokens: 80) - 1)
        #expect(measured.deadline == 59)
        #expect(measured.forcesClosingTag)
        // DEV-14's rule: a forced token invalidates a verified block.
        #expect(!measured.allowsSpeculativeDecoding)
    }

    /// `max_tokens: -1` is unlimited (REQ-max-tokens), so there is no deadline
    /// to derive from it. With an unlimited budget too, nothing is forced —
    /// which is what "無制限" means — and speculative decoding stays available
    /// for pi's default session (tools + 画像 + Reasoning + MTP).
    @Test func RSN_4_an_unbounded_request_forces_nothing() throws {
        let unbounded = try plan(thinkingRequest, maxNewTokens: 4_096,
                                 contextRemaining: 4_096)
        #expect(unbounded.budget == -1)
        #expect(unbounded.deadline == Int.max)
        #expect(!unbounded.forcesClosingTag)
        #expect(unbounded.allowsSpeculativeDecoding)
    }

    /// RSN-4's own sentence, read off the **effective** limit rather than off
    /// the spelling: "コンテキストの上限はクライアントが選んだ予算ではない".
    ///
    /// A client that echoes the model's capability — pi puts `models.json`'s
    /// `maxTokens`, the same number as `context_window`, on every request —
    /// sends a `max_tokens` that `min(max_tokens, 文脈の残り)` collapses onto
    /// the context remainder. That request generates token for token what
    /// `max_tokens: -1` would generate, so the only thing that may not differ
    /// is whether it has a deadline.
    ///
    /// The numbers are the 2026-08-21 measurement (CONFORMANCE §2): a 65536
    /// context, a prompt of 8889, an answer of 1293 tokens, and a deadline
    /// 42485 tokens away that could never fire — yet cost the request its
    /// speculative decoding through DEV-14.
    @Test func RSN_4_a_max_tokens_at_the_context_ceiling_sets_no_deadline() throws {
        let remaining = 65_536 - 8_889
        let capability = try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true},"max_tokens":65536}
        """#, maxNewTokens: min(65_536, remaining), contextRemaining: remaining)

        #expect(capability.deadline == Int.max)
        #expect(!capability.forcesClosingTag)
        // The whole point: this is what pi's default session needs (GEN-14 gave
        // it the grammar half; this is the reasoning half).
        #expect(capability.allowsSpeculativeDecoding)

        // Token for token the same request as `max_tokens: -1`, so token for
        // token the same plan.
        let unlimited = try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true},"max_tokens":-1}
        """#, maxNewTokens: remaining, contextRemaining: remaining)
        #expect(capability == unlimited)
    }

    /// The boundary. Exactly at the ceiling the context is what binds, so no
    /// deadline; one token below it the client's number binds and there is one.
    @Test func RSN_4_the_deadline_appears_only_below_the_context_ceiling() throws {
        let remaining = 4_096
        func planned(_ maxTokens: Int) throws -> ServerReasoningPlan {
            try plan(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "chat_template_kwargs":{"enable_thinking":true},"max_tokens":\#(maxTokens)}
            """#, maxNewTokens: min(maxTokens, remaining), contextRemaining: remaining)
        }
        #expect(try planned(remaining + 1).deadline == Int.max)
        #expect(try planned(remaining).deadline == Int.max)

        let bound = try planned(remaining - 1)
        let effective = remaining - 1
        #expect(bound.deadline
                == effective - ServerReasoningPlan.answerReserve(maxNewTokens: effective) - 1)
        #expect(bound.forcesClosingTag)
        #expect(!bound.allowsSpeculativeDecoding)
    }

    /// A closed thought channel cannot overrun a budget, so it never carries a
    /// forcer — including the RSN-1 spelling that closes it, a budget of zero.
    @Test func RSN_4_a_closed_channel_forces_nothing() throws {
        let off = try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"max_tokens":80}
        """#, maxNewTokens: 80, contextRemaining: 4_096, thinking: .off)
        #expect(!off.isThinking)
        #expect(!off.forcesClosingTag)

        let zeroBudget = try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true},
         "reasoning_budget_tokens":0,"max_tokens":80}
        """#, maxNewTokens: 80, contextRemaining: 4_096)
        #expect(!zeroBudget.isThinking)
        #expect(!zeroBudget.forcesClosingTag)
    }

    /// RSN-3. `auto` (the default) splits the thought channel out into
    /// `reasoning_content`; `none` leaves it in the answer as raw text. Either
    /// side may ask for `none`: the flag sets the process default, and the
    /// request field is REQ-reasoning-format.
    @Test func RSN_3_the_reasoning_format_decides_where_the_thought_goes() throws {
        let auto = try plan(thinkingRequest, maxNewTokens: 64, contextRemaining: 4_096)
        #expect(auto.format == .auto)
        #expect(auto.separatesReasoning)
        #expect(auto.route(.reasoning("weighing")) == .reasoning("weighing"))
        #expect(auto.route(.content("hello")) == .content("hello"))

        let byFlag = try plan(thinkingRequest, defaultFormat: .none,
                              maxNewTokens: 64, contextRemaining: 4_096)
        #expect(byFlag.format == .none)
        #expect(!byFlag.separatesReasoning)
        #expect(byFlag.route(.reasoning("weighing")) == .content("weighing"))

        let byRequest = try plan(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true},"reasoning_format":"none"}
        """#, maxNewTokens: 64, contextRemaining: 4_096)
        #expect(byRequest.format == .none)
        #expect(byRequest.route(.reasoning("weighing")) == .content("weighing"))
    }
}

@Suite("Server reasoning responses")
struct ServerReasoningResponseTests {
    @Test func nonStreamingCarriesReasoningContentBesideTheAnswer() async throws {
        let server = TurboFieldfareHTTPServer(modelID: "test-model",
                                              queueLimit: 1,
                                              backend: ReasoningBackend())
        let channel = try await server.start(port: 0)
        let port = try #require(channel.localAddress?.port)
        defer { Task { try? await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"""
        {"model":"test-model","messages":[{"role":"user","content":"hi"}],
         "chat_template_kwargs":{"enable_thinking":true}}
        """#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let choices = try #require(object["choices"] as? [[String: Any]])
        let message = try #require(choices[0]["message"] as? [String: Any])
        #expect(message["content"] as? String == "hello")
        #expect(message["reasoning_content"] as? String == "weighing it")
    }

    @Test func aRequestThatDidNotReasonHasNoReasoningField() async throws {
        let server = TurboFieldfareHTTPServer(modelID: "test-model",
                                              queueLimit: 1,
                                              backend: PlainBackend())
        let channel = try await server.start(port: 0)
        let port = try #require(channel.localAddress?.port)
        defer { Task { try? await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"""
        {"model":"test-model","messages":[{"role":"user","content":"hi"}]}
        """#.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let choices = try #require(object["choices"] as? [[String: Any]])
        let message = try #require(choices[0]["message"] as? [String: Any])
        #expect(message["reasoning_content"] == nil)
    }

    @Test func streamingSendsReasoningInItsOwnDeltaField() async throws {
        let server = TurboFieldfareHTTPServer(modelID: "test-model",
                                              queueLimit: 1,
                                              backend: ReasoningBackend())
        let channel = try await server.start(port: 0)
        let port = try #require(channel.localAddress?.port)
        defer { Task { try? await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"""
        {"model":"test-model","messages":[{"role":"user","content":"hi"}],
         "stream":true,"reasoning_effort":"medium"}
        """#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""reasoning_content":"weighing it""#))
        #expect(text.contains(#""content":"hello""#))
        // The reasoning arrives before the answer and never inside it.
        let reasoningIndex = try #require(text.range(of: #""reasoning_content""#))
        let contentIndex = try #require(text.range(of: #""content":"hello""#))
        #expect(reasoningIndex.lowerBound < contentIndex.lowerBound)
        #expect(text.hasSuffix("data: [DONE]\n\n"))
    }

    @Test func theRequestsThinkingChoiceReachesTheBackend() async throws {
        let backend = ThinkingRecordingBackend()
        let server = TurboFieldfareHTTPServer(modelID: "test-model",
                                              queueLimit: 1,
                                              backend: backend,
                                              defaults: ChatRequestDefaults(thinking: .on))
        let channel = try await server.start(port: 0)
        let port = try #require(channel.localAddress?.port)
        defer { Task { try? await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"""
        {"model":"test-model","messages":[{"role":"user","content":"hi"}]}
        """#.utf8)
        _ = try await URLSession.shared.data(for: request)
        #expect(await backend.sawThinking == true)
    }
}
