# 適合テスト計画 (CONFORMANCE) — TDD で SPEC を緑にする

2026-08-19 制定。[SPEC.md](SPEC.md) の各行をテストに写し、**赤いテストを先に
そろえてから**実装を仕様に合わせる。この文書は「どうテストするか」と
「今なにが赤か」だけを扱う。仕様の中身は書かない (SPEC が唯一の規範)。

## 0. 進め方の規則

1. **仕様行 → 赤テスト → 実装 → 緑**の順。仕様に無い挙動を書かない。
   テストに無い仕様行を実装しない。
2. テスト名は SPEC の ID を含める (例: `REQ_seed_negative_one_is_random`,
   `LIF_2_health_returns_503_while_loading`)。逆引きできることが目的。
3. クライアント (pi / OpenCode) の症状が見つかったら: 参照実装を確認 →
   SPEC に行を追加/修正 → 赤テスト → 実装 (SPEC §13)。**症状 → 実装直行を禁止。**
   この規則が守られているかは、修正コミットに SPEC の ID が書いてあるかで分かる。
4. 実装を先に書いてしまったら、テストを後追いで足すのではなく、
   いったん戻して赤から始める。

## 1. テスト階層

重みも Metal も要らない層を厚くする。C0〜C2 は `swift test` で常時回る。
C3 だけがモデルを積む。

| 層 | 対象 | 実行 | 中身 |
| --- | --- | --- | --- |
| **C0** | 要求スキーマ | `swift test` (モデル不要) | JSON 要求 → 受理されたパラメータ or エラー、の表駆動テスト。SPEC §4 の**表 1 行 = 最低 1 ケース** (既定値 / clamp の両端 / hard の両端 / null / 未知キー / 別名)。参照実装の `server-schema.cpp` と同じく、スキーマ自体を宣言的な表として実装し、この表とテストが 1:1 になるようにする |
| **C1** | HTTP 契約 | `swift test` (スタブ backend) | `ServerInferenceBackend` をスタブに差した本物の HTTP サーバーに対して: エンドポイントの生死 (EP-*)、ロード中 503 (LIF-2)、SSE の並びと ping (RSP-2)、エラー封筒 (ERR-*)、`/props` の中身 (EP-4)。境界の型 `ValidatedChatRequest` と protocol `ServerInferenceBackend` は現行実装から**そのまま引き継ぐ** (§4) |
| **C2** | トークン列の不変条件 | `swift test` (tokenizer のみ、重み不要) | **INV-1: 描き直し == 生成** を思考 ON/OFF × tools 有無 × 画像有無の全組合せで (SPEC §7)。プロンプトキャッシュは「この 2 要求の LCP は N トークン」という主張で検定する — 「この形は hit する」という主張は書かない。opencode 実セッションのフィクスチャは入力として残し、主張だけ LCP 長に書き換える |
| **C3** | 実機スモーク | 手動スクリプト (モデル要) | temp 0 + md5 の流儀で: tools 宣言 → tool call が出る (GEN-1) / `json_object` → 妥当な JSON が返る (GEN-3) / 思考予算切れ → 本文が空でない (RSN-4) / 2 ターン目の `cached_tokens` > 0 (CACHE-*) / tools × 画像 × 思考の同時要求 (MSG-6) / tools を宣言した要求でも投機が走る (GEN-14: `timings.draft_n > 0`)。`Scripts/` に curl ベースで置き、期待値は HTTP 番号と JSON 述語で書く |

**暫定実装の扱い**: GEN-3 / GEN-4 のように「最終は文法拘束、それまで 501」と
段階のある行は、**最終挙動のテストを C3 に書き、暫定期間はスキップ印を付けて
赤のまま数える**。暫定の 501 は C0/C1 で検定する (「200 で違う形」だけは
どの段階でも即バグ)。

## 2. 既知の赤 (2026-08-19 起点)

旧 16-SPEC-PROBE (git 履歴と scratchpad 退避分) の実測を SPEC の ID に写した
初期状態。**このリストを上から緑にしていくのが作業のすべて**であり、
緑になった行はこの表から消す (履歴は git log)。

**いま赤なのは 1 行**、2026-08-21 に足した **RSN-4 の「文脈の残り以上の
`max_tokens` は締切を作らない」**である (P7)。P6 の 2 行 (**GEN-14** と
**RSP-3 の `draft_*`**) は緑になった (下記)。

**RSN-4 の締切の作りかた** (2026-08-21 に赤として登録)。P6 のあと pi を実機で
動かして分かったこと: **思考 ON の pi の要求は 1 本も投機デコードを通らない。**
pi は `models.json` の `maxTokens`(= `context_window` と同じ 65536) を要求に
そのまま載せてくるので `request.maximumCompletionTokens > 0` が真になり、
`ServerReasoningPlan.deadline` が有限になり、`forcesClosingTag` が真になり、
DEV-14 で要求まるごと plain 経路に落ちる。実測 (2026-08-21、`--ctx-size 65536`):
prompt=8889 → 文脈の残り 56647 → 実効の生成上限も **56647** (`max_tokens: -1`
と同じ値) → 締切 42485 に対し**実際の生成は 1293 トークン**。締切は 33 倍先に
あって発火しえないのに、MTP は丸ごと失われていた。SPEC RSN-4 は元から
「コンテキストの上限はクライアントが選んだ予算ではない」と言っているので、
その行を `max_tokens: -1` の綴りだけでなく**実効値**で読むよう明確にした。
赤テストは `ServerReasoningPlanTests`。

**GEN-14 / RSP-3 の `draft_n`・`draft_n_accepted`** (2026-08-21 に赤として登録、
**2026-08-22 に緑**)。登録時に分かっていたこと: **`tools` を宣言した要求は 1 本も
投機デコードを通っていなかった。**`tools` があれば文法が付き、文法が付けば
`ServerGenerationPlan.allowsSpeculativeDecoding` が偽になり (旧 DEV-14)、
要求まるごと plain 経路に落ちる。遅延文法 (`tool_choice: auto` でトリガ未発火)
でも同じ。コーディングエージェントは毎要求 `tools` を宣言するので、
**§5 完了の定義が名指ししている経路 (pi の既定セッション + MTP) だけが
構造的に MTP を使えない**状態だった。実測 (2026-08-21、M3 Pro / 32 スロット /
`--ctx-size 65536` / 19K 文脈 / temp 0、各 n=1): tools あり **9.8 tok/s** に対し
tools なし **16.8 tok/s** (`accept=1.357`)。参照実装は文法と投機を併用しており、
しかも**文法状態の巻き戻しをしていない** (`common/sampling.cpp:678`) ので、
逸脱として残す理由が無かった。

直した形 (P6 の M1〜M5):

- `runSpeculativeCompletion` が位置ごとに**文法込みで**引き (GEN-7 の棄却
  サンプリングをそのまま呼ぶ)、引いたトークンをその場で `accept` する。
  巻き戻しは要らない — 状態が進むのは採用したトークンだけで、採用した
  トークンは必ず emit される。prefill の種トークン (生成位置 0) も同じ扱い。
- 拘束があって融合 greedy ヘッドなら `logitsUnavailable` で断る (GEN-7)。
- **GEN-6 を採用時の粒度にした** (`onDrawnToken`)。投機ループはブロックを
  丸ごと採用してから emit するので、`onProgress` から抑止を動かすと遅延文法が
  チャンネルの最大 `bs - 1` トークン後ろを走り、閉じの直後の tool call を
  文法が眠ったまま通してしまう。
- `ServerGenerationPlan.allowsSpeculativeDecoding` は常に真になった。
  DEV-14 に残るのは強制挿入 (RSN-4) と `repeat_penalty != 1` の 2 つだけ。
- `timings` に `draft_n` / `draft_n_accepted` が載る。門は参照実装と同じ
  `n_draft_tokens > 0` なので、**走らなかった要求にはキーごと無い**。

テストは C2 (`SpeculativeCompletionLoopTests` — 拘束付きの投機ランが**同じ
拘束の** plain ランと同一のトークン列を出すことを、ドラフター 3 通りで。
採用したトークンだけが `accept` されること。採用時フックが順に 1 回ずつ
鳴ること)、`ServerGrammarWiringTests` (採用時の判定と emit 時の判定が一致)、
C0/C1 (`ServerGenerationPlanTests`、`ServerTimingsTests`、
`ServerDraftTimingsWireTests`)。**実機ではまだ見ていない** — C3 の `GEN-14`
検査 (15 個目) がそれを見る。**速くなったかどうかも測っていない**:
GEN-14 は「併用できる」までが契約で、常に速いとは言っていない。

緑になった行: **INV-1** (2026-08-20、P1-D2、SPEC §12 DEV-12 のサーバー変種 +
MSG-5 の `reasoning_content` 入力)。**MSG-5** の入力側も同時。
**CACHE-1 / CACHE-2 / CACHE-3 / CACHE-5 / CACHE-6 / FLAG-4 の
`--prompt-cache-mode`** (2026-08-21、P1-D3。`PromptCacheLCPTests` +
`ServerPromptCacheTests`)。**CACHE-4** (2026-08-21、P1-D4。`PromptCacheLCPTests` +
`ServerImageRequestTests`) — 走査がチャンク (ダイジェスト + トークン数) を比較し、
別建てのダイジェスト検定は撤去した。写真が違う要求は全体 miss ではなく
**その写真の手前までヒット**する。
**深い巻き戻しの正しさは式からの導出で、実測していない** (SPEC §12 DEV-13)。C3 送り。

**LIF-1 / LIF-2 / LIF-3 / LIF-4 / LIF-5 / LIF-6 / LIF-7、EP-1 / EP-4 / EP-7 / EP-8、
ERR-2 の 401・405・415 と 413 の撤去 (DEV-11)、FLAG-5 (`--api-key`)、FLAG-6
(`--cors-origins`)** (2026-08-22、P3。`ServerLifecycleTests` +
`ServerLifecycleEndpointTests` + `ServerPropsTests` + `ServerLifecycleAuthTests` +
`ServerLifecycleCORSTests` + `HTTPServerTests`)。ポートは先に開き、ロード中は
経路表より手前で 503 を返す。ロード失敗はプロセス終了。

**GEN-1 / GEN-2 / GEN-3 / GEN-4 / GEN-5 / GEN-6 / GEN-7 / GEN-8 / GEN-9 /
GEN-10 / GEN-11 / GEN-12 / GEN-13** (2026-08-22、P2 の G1〜G4c-2)。GBNF エンジンと
JSON Schema → 文法の変換を移植し、棄却サンプリングで生成に効かせ、
501 を実挙動へ置き換えた。テストは `GrammarEngineTests` +
`JSONSchemaGrammar*Tests` + `GrammarTokenConstraintTests` +
`GenerationConstraintTests` + `ChatGrammarBuilderTests` +
`ServerGenerationPlanTests` + `ChatRequestConstraintTests`。
**ただし機構そのもの (GEN-5/6/7) を実機で見たわけではない** — 見えるのは
C3 だけで、まだ走っていない。

**RSN-1 / RSN-2 / RSN-3 / RSN-4 / RSN-5 / RSN-6、FLAG-1 の `--reasoning-budget`
と `--reasoning-format`、FLAG-4 の `--thinking`** (2026-08-22、P4。
`ServerReasoningTests` + `ReasoningBudgetForcerTests` +
`RawCompletionForcedTokenTests`)。予算切れの終了タグ強制は**復号ループの中で
見ただけで、モデルの上では見ていない** — C3 の `RSN-4-max-tokens` と
`RSN-4-budget` がそれを見る。`--reasoning-format none` は「受理して無視」
だったのを実挙動にした (R4)。**既定が変わった**: `--thinking` は off、
`--reasoning-budget` は -1 (無制限)。

**FLAG-1 の `-c/--ctx-size`、FLAG-2 の丸め (両方のフラグ)** (2026-08-22。
`ServerContextSizeFlagTests` + `ServerExpertCacheSlotFlagTests` +
`ExpertCacheBudgetTests`)。`--max-context` は退役し、名指しで新しい綴りを
案内する。`-c/--ctx-size` と `--expert-cache-slots` は列挙で断らず下に丸める。

**RSP-3 / RSP-5 / EP-4 の `build_info` / EP-5 / EP-6、FLAG-7** (2026-08-22、P5。
`ServerTimingsTests` + `ServerBuildIdentityTests` + `ServerTokenizeRoutesTests` +
`ServerSlotsMetricsTests` + `ServerEndpointGateTests`)。5 つの経路はロードゲート・
API キー・CORS preflight の内側にあることをテストで固定してある。

**C3 を実機で走らせた** (2026-08-21、`Scripts/c3_smoke.sh`、当時 14 検査。
`--ctx-size 65536 --expert-cache-slots 32 --draft-block-size 4`)。
**1 回目は 13 緑 / 1 赤**、赤は `GEN-4-required` の **500** — tool call の文法が
マーカーを**綴りのリテラル**で書いていたため、思考 ON のモデルが開きを
`<`, `|`, `tool`, … と通常トークンで綴り、閉じに本物の `<tool_call|>` トークンを
使い、tool call を**トークン ID** で切り出す `StructuredAssistantDecoder` が
「開きの無い閉じ」を見て落ちた。マーカーを文法要素 `TOKEN` (`<[id]>`) に変えて
(SPEC GEN-8 / §12 **DEV-22**)、**2 回目は 14 検査すべて緑**。
回帰は C0 (`ChatGrammarBuilderTests` の「マーカートークンだけが call を開く」) と
C2 (`ServerGrammarWiringTests` の「required では思考ブロックの後に許されるのが
マーカートークン 1 個だけ」) の 2 段で固定した。

すでに適合している (壊さないことをテストで固定する): RSP-2 (SSE の並び)、
R2 (`null` = 未指定)、R1 (未知キー無視)、RSP-1 (usage + cached_tokens)、
ERR-1 の封筒の形、および P0 で緑にした REQ-* 全行 (C0 の 41 本)。

## 3. 実装順

害の大きい順。**各段の入口で赤テストをそろえ、出口は「その段のテストが全部緑」。**

| 段 | 中身 | 主な赤 |
| --- | --- | --- |
| ~~**P0**~~ | **済** (2026-08-19)。`ChatRequestSchema` の宣言的な表 + `ChatRequestParser`。`OpenAIRequestValidator` と `OpenAIChatRequest` は削除、メッセージ・tools の検査だけ `ChatMessageValidator` に残した | REQ-* 全行 + GEN-3 の 501 化 |
| ~~**P1**~~ | **D1〜D4 済** (2026-08-20/21)。判定は `commonPrefixLength` 1 本、意味ゲート・ブリッジ合成・ミス 11 分類・`--prompt-cache-mode` は削除。描き直しは SPEC §12 DEV-12 のサーバー変種が生成と一致させる (INV-1)。部分再利用は `runner.rewind(to:)` で通し、深さの上界は §12 **DEV-13**。画像はチャンクとして走査の中で比較する (CACHE-4)。**残り: (D5) 名前を SPEC に合わせる。****未実測: 深い巻き戻しの正しさと、D2 の品質影響 — どちらも C3** | — |
| ~~**P2**~~ | **済** (2026-08-22)。**G1** GBNF エンジン → **G2** JSON Schema → GBNF (2 方言、8 段) → **G3** エンジン結線 (棄却サンプリング GEN-7、投機は落とす DEV-14) → **G4a** 語彙水準の拘束 → **G4b** 文法の組み立て → **G4c** 要求と推論の結線 → **G5** C3 スモーク。実装中に出た仕様の穴は GEN-8〜GEN-13 と DEV-14〜DEV-20 として先に SPEC へ入れた | — |
| **P3** | ライフサイクルとエンドポイント。listen 先行 + ロード中 503、`/v1/health`、`/props`、採らないパスの 501 | LIF-*, EP-1/4/7 |
| ~~**P4**~~ | **済** (2026-08-22)。`--reasoning-budget` / `--reasoning-format` へ改名し、`--thinking` を退役。予算切れで終了タグを強制挿入する (RSN-4)。`max_tokens` の分け方は §12 **DEV-21** | — |
| ~~**P5**~~ | **済** (2026-08-22)。`timings`、`system_fingerprint`、`/tokenize` 系、`/slots`・`/metrics`、`--api-key`、CORS、`-c/--ctx-size` と `--expert-cache-slots` の丸め | — |
| ~~**P6**~~ | **済** (2026-08-22)。M1 検証を「位置ごとに文法込みで引き、その場で `accept` し、食い違いで打ち切る」に変えた → M2 拘束のある要求は融合 greedy ヘッドを断る (GEN-7) → M3 `ServerGenerationPlan.allowsSpeculativeDecoding` は常に真、`ServerInference` が拘束を投機ループへ渡す、GEN-6 の抑止を採用時の粒度にした → M4 `draft_n` / `draft_n_accepted` を `timings` に載せた → M5 C3 に `GEN-14` を足した (15 検査目)。**実機と速度はまだ見ていない** | — |

CLI 対話モード (旧 S4) と既定値の自動選択 (旧 S5) は **P2 のあと**。
今の受理規則・キャッシュを CLI に複製すると乖離が 2 か所に増えるため。

## 4. 引き継ぐもの / 巻き直すもの

「接続部分」= エンジンと HTTP の境界は実証済みなので残す。仕様を独自判断で
作っていた層だけを巻き直す。

| 引き継ぐ (接続部分) | 理由 |
| --- | --- |
| `ServerInferenceBackend` protocol + `ValidatedChatRequest` 境界 | C1 のスタブ差し込み点そのもの。実機で S1〜S3 を通した実績 |
| `EngineBackend` のロード・生成・`prepare`、待ち行列 (`--queue-limit`) | エンジン結線 |
| テンプレート描画の入口 (`applyChatTemplate` / `encodeToolChat`、tools × 画像 × 思考対応) | S2/S3 で実測済み。INV-1 の修正はこの中で行う |
| SSE 書き出し・`: ping`・シグナル処理 (`ServerTerminationSignals`) | RSP-2 は実測で適合済み |
| 画像デコード (`ServerImageInput`) | MSG-3 の data URI 経路 |

| 巻き直す | 置換先 |
| --- | --- |
| `OpenAIRequestValidator` (`OpenAIModels.swift` の検査群) | 宣言的スキーマ表 (P0)。`server-schema.cpp` と 1:1 で差分照合できる形に |
| `ServerPromptCache` (意味ゲート 8 個・ブリッジ合成・ミス 11 分類) | トークン LCP (P1)。判定は数十行になるはず |
| `GemmaToolSchema` の入口検査 | 文法拘束への近似落とし (P2) |
| `HTTPServer` のルーティング表 | EP 表 + LIF 状態機械 (P3) |
| `--thinking` / `--prompt-cache-mode` / `--max-context` のフラグ面 | FLAG-* (P0/P3/P4 の中で) |

既存テスト 895 本のうち、「この形は hit する」系のキャッシュテストと
検査 400 系のテストは仕様ごと消える。フィクスチャ (opencode 実セッション) は
C2 の入力として残す。

## 5. 完了の定義

- §2 の表が空 (P6 まで) — 最低ラインは P0〜P3。
- pi の既定セッション (tools ON + 画像 + Reasoning ON + MTP) が、
  サーバー側の修正なしで通しで動く (旧ゴール G1)。**「MTP」は「フラグが
  立っている」ではなく「実際に走っている」で見る** — tools を宣言した要求の
  応答に `timings.draft_n > 0` があること (GEN-14 / RSP-3)。2026-08-21 に
  ここを数字で見たら 1 本も走っていなかった。**通しで動くことと、動くときに
  MTP が効いていることは別の主張であり、後者を見ていなかった。**
- OpenAI 公式 Python SDK の素朴なコード (README の例のように `model` に
  適当な名前を渡すもの) がそのまま動く。
- 新しいクライアントの症状が出たとき、直す場所が「SPEC に行を足す」以外に
  存在しない。
