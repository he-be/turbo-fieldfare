# 引き継ぎ — サーバー再実装ループ

最終更新: 2026-08-21 (P7 を緑にした)。ブランチ `macos15-support`。
**P0〜P7 が全部済み**で、CONFORMANCE §2 の赤リストは空である。
`swift test` は **1251 本で全緑** (`Scripts/test.sh`、約 117 秒)。
**次にやるのは実機の確認** — pi を普通に使ってサーバーのログに `mtp=` が
出ること、`Scripts/c3_smoke.sh` の 15 検査、tools ありの tok/s。
**P6 も P7 も一度も実機で緑を見ていない。**

この文書は**次のセッションが同じループを再開するための唯一の入口**である。
仕様は書かない ([SPEC.md](docs/serving/SPEC.md) が唯一の規範)。作業の並べ方も
書かない ([CONFORMANCE.md](docs/serving/CONFORMANCE.md) が持っている)。
ここにあるのは「今どこにいるか」と「どう再開するか」だけ。

## 1. 再開のしかた

新しいセッションで、この 3 つを添えて指示を出す:

```
@docs/serving/SPEC.md @docs/serving/README.md @docs/serving/CONFORMANCE.md
必要ならサブエージェントを複数起動しながら、TDDでサーバーの再実装作業を継続して。
適切な粒度でコミット・プッシュすること。
```

読む順序は **SPEC → CONFORMANCE → この文書の §3**。SPEC と食い違ったら
SPEC が勝つ。この文書が古かったら、直すのはこの文書のほうである。

## 2. 守る規律 (前回もこれで回した)

1. **仕様行 → 赤テスト → 実装 → 緑**。仕様に無い挙動を書かない。テストに無い
   仕様行を実装しない。実装を先に書いてしまったら戻して赤から始める。
2. **コミットに SPEC の ID を書く。**「症状 → 実装直行」をしていないことは、
   コミットメッセージに ID があるかどうかで外から分かる。
3. **仕様を自分で決めない。**参照実装 `~/LLM/llama.cpp/tools/server`
   (ピン `34af94cd9`) か OpenAI API を読んでから SPEC に行を足す (SPEC §13)。
   逸脱は必ず SPEC §12 に登録する。
4. **赤 → 緑を別コミットにする。**赤コミットでもツリーはビルドできる状態に
   保つ (未実装の入口は「未実装」を投げる)。
5. コミットメッセージは日本語。末尾に `Co-Authored-By` 行。

## 3. 現在地

| 段 | 状態 |
| --- | --- |
| **P0** 要求スキーマ | **済** (2026-08-19)。C0 の表駆動テスト |
| **P1** プロンプトキャッシュ → LCP | **D1〜D4 済**。**残り D5 (名前を SPEC に合わせる)** — 中身は薄く、後回しでよい |
| **P2** 生成の拘束 | **済** (2026-08-22)。下の §3.1 |
| **P3** ライフサイクル / EP | **済** (2026-08-22)。listen 先行 + ロード中 503、`/v1/health`、`/props`、採らないパスの 501、`/v1` 無しの別名、ERR-2 の 401/405/415、413 の撤去 |
| **P4** 思考 | **済** (2026-08-22)。`--reasoning-budget` / `--reasoning-format` へ改名、`--thinking` 退役、予算切れの終了タグ強制 (RSN-4) |
| **P6** 文法下の投機デコード | **済** (2026-08-22)。SPEC **GEN-14** + RSP-3 の `draft_n` / `draft_n_accepted`。下の §3.2。**実機と速度は未確認** |
| **P7** 思考の締切 | **済** (2026-08-21)。SPEC **RSN-4** を実効値で読む。**実機未確認** |
| **P5** 残り | **済** (2026-08-22)。`timings` (RSP-3)、`system_fingerprint` (RSP-5)、`/tokenize` `/detokenize` `/apply-template` (EP-5)、`/slots` `/metrics` (EP-6、FLAG-7 でゲート)、`--api-key` (FLAG-5)、CORS (FLAG-6)、`-c/--ctx-size` と `--expert-cache-slots` の丸め (FLAG-1/FLAG-2) |

### 次の一手 — **P6 + P7 を実機に当てる**

「pi から呼んだら必ず MTP が動く」ために外した関門は 2 つで、どちらも
実機で緑を見ていない。入っている形は §3.2。

| # | 関門 | どこで外したか |
| --- | --- | --- |
| 1 | `tools` を宣言 → 文法 → 要求まるごと plain | **P6** (SPEC GEN-14) |
| 2 | 思考 ON + 有限の予算 → RSN-4 の終了タグ強制 → plain。pi は `models.json` の `maxTokens` (= `context_window`) を毎要求載せるのでここに当たっていた | **P7** (SPEC RSN-4 を実効値で読む) |

やることは 3 つで、順に:

**0. 一番速い確認は 1 行。**サーバーを建て直して pi を普通に使い、サーバーの
ログに `mtp=` が出るか見る。出れば両方効いている。**必ず先に再ビルドすること**
(`swift build -c release --product TurboFieldfareServer`) — 2026-08-21 に
古いバイナリで C3 を走らせて 1 往復無駄にした。

**1. `Scripts/c3_smoke.sh` を 15 検査で走らせる。**15 個目が `GEN-14` で、
`tools` を宣言した要求の `timings.draft_n > 0` を見る。**サーバーは人が
建てる** (スクリプトは建てない・止めない)。前に走らせた構成:

```
.build/release/TurboFieldfareServer \
  --model scratch/gemma4-qat-sym.gturbo --port 8091 \
  --ctx-size 65536 --expert-cache-slots 32 --draft-block-size 4
```

**2. tools ありの tok/s を 3 回測る。**P6 前の数字は **9.8 tok/s** (tools なしは
16.8、`accept=1.357`) だが、**これは n=1 なので比較に使う前に取り直すこと**
(M3 Pro / 32 スロット / `--ctx-size 65536` / 19K 文脈 / temp 0)。
測り方は AGENTS.md "Test rules" と `docs/COMMUNITY_BENCHMARKS.md`。

**踏む前に読む罠**: 拘束下の棄却は debug で 0.14 秒/棄却かかる (§3.1)。
ブロック幅 4 で毎位置に棄却が出る文法だと、投機が**遅くなる**ことはありうる。
その場合は「速くならなかった」を数字で報告する — **GEN-14 は「併用できる」
までが契約で、常に速いとは言っていない。**

**3. §5 完了の定義の残り 2 つ** (下の「そのあと」)。

### そのあと — **C3 の残り 2 つ (pi と OpenAI SDK)**

残っているのは「書けたが実機で見ていない」ことで、
それは CONFORMANCE §5 完了の定義の 2 つ目と 3 つ目である:

1. ~~**`Scripts/c3_smoke.sh` を走らせる** (14 検査)~~ **済** (2026-08-21)。
   1 回目は 13 緑 / 1 赤 (`GEN-4-required` の 500)。原因は文法が tool call の
   マーカーを**綴りのリテラル**で書いていたことで、モデルは開きを通常トークンで
   綴り、閉じに本物のマーカートークンを使った — 復号器はトークン ID で切り出すので
   「開きの無い閉じ」になる。マーカーを文法要素 `TOKEN` (`<[id]>`) にして
   (SPEC GEN-8 / §12 DEV-22)、**2 回目は 14 緑**。CONFORMANCE §2 に記録済み。
2. **pi の既定セッション** (tools ON + 画像 + Reasoning ON + MTP) を通しで動かす。
   **P6 は済んだので、次はこれ。**「通しで動く」と「動くときに MTP が効いている」は別の主張で、
   2026-08-21 に数字で見たら後者が偽だった (だから P6 がある)。見るのは
   応答の `timings.draft_n`、サーバー側なら footer の `mtp=/rounds=/accept=`。
   **前提は 2026-08-21 に揃えた** — `scratch/gemma4-qat-sym.gturbo` は本体だけで、
   画像もドラフターも入っていなかった。`--add-vision` / `--add-draft` を当てて
   v1.2 にし、affine バンドルとのバイト一致まで見てある
   ([docs/mtp/45](docs/mtp/45-W2-SYM-ADOPTION.md) §9)。
   `Scripts/demo/serve.py` の既定と `Scripts/c3_smoke.sh` の例もこのバンドルに向けた。
3. **OpenAI 公式 Python SDK の素朴なコード**がそのまま動くことを見る。

そこで症状が出たら、直す道は 1 つしかない: 参照実装を確認 → SPEC に行を足す →
赤テスト → 実装 (SPEC §13)。**症状から実装へ直行しない。**

残っている小さな仕事:

- **P1-D5** — 名前を SPEC に合わせる。中身は薄い。
- `docs/serving/README.md` の「残る計画」(CLI 対話モード = 旧 S4、既定値の
  自動選択 = 旧 S5) は **P2 のあと**という条件を満たした。

### 3.1 P2 で入った形 (次が壊しやすい場所)

| 型 | 役割 |
| --- | --- |
| `GBNFGrammar` / `GrammarMatcher` | GBNF のパーサと逐次マッチャ。ピン `34af94cd9` の `llama-grammar.cpp` の移植。**ピンの GBNF は公開文書より新しく、`TOKEN` / `TOKEN_NOT` (`<[42]>`, `!<[42]>`) がある** — Gemma の特殊トークンを文法要素として直接書けるのはこれのおかげ |
| `JSONSchemaGrammar` | JSON Schema → GBNF。方言が 2 つ (`.json` と `.gemmaToolArguments`)。参照実装の 73 本の期待値をそのまま持っている — **`.json` 側が 1 バイトでも動いたら、それは移植を壊したということ** |
| `GrammarTokenConstraint` | 語彙の piece 表 + マッチャ → `GenerationConstraint`。`GrammarVocabulary.shared(for:)` は**プロセスに 1 つ** (0.4 秒 / 25 MB)。要求ごとに作らないこと |
| `GenerationConstraint` / `ConstraintGate` | サンプラ側の口。**終了トークンの扱いは gate が持つ** — 拘束の実装は停止トークンを特別扱いしてはいけない |
| `ChatGrammarBuilder` | 要求 → 文法テキスト + 遅延かどうか + トリガ |
| `ServerGenerationPlan` | 要求 → 「何で拘束するか」の決定。**推論を持たない純粋な型なので、ここが検定の本体**。`ServerInference` はこの決定を実行するだけ |
| `ReasoningBudgetForcer` / `ServerReasoningPlan` | RSN-4。予算を数えて終了タグを強制する状態機械 |

**踏みやすい罠:**

- **拘束は棄却サンプリングで入る** (GEN-7)。通常どおり 1 トークン引き、
  適合しなければ**全語彙マスクで引き直す**。マスクは debug で 0.14 秒/棄却。
  棄却が増える形の文法を書くと、そのぶん素直に遅くなる。
- **`-Float16.infinity` は softcap カーネルを通らない** (`tanh(-inf) = -1` で
  確率が 0 にならない)。マスクは host で softmax を計算し直して 0 を書く。
- **強制挿入 (RSN-4) と `repeat_penalty != 1` の要求は投機デコードを使わない**
  (DEV-14)。**文法はこの列から外れた** — GEN-14 で併用する (§3.2)。
  **`max_tokens` が「有限」かどうかは実効値で見る** (P7、RSN-4): `max_tokens`
  が文脈の残り以上なら締切は作られず、思考 ON でも投機経路に入る。ここを綴りで
  見ていたせいで pi の思考 ON セッションが MTP を丸ごと失っていた。
  本当に短い `max_tokens` を送る思考 ON の要求は、いまも plain に落ちる —
  そこまで要るなら DEV-14 の再考条件 (強制挿入をサンプラ側へ移す) に進む。
- **tool call の文法はテンプレートの正準形しか許さない** (GEN-8〜GEN-11)。
  空白なし・裸キー昇順・`<|"|>` 文字列・エスケープ無し・null 無し・桁数制限。
  **緩めると INV-1 が破れて毎ターン LCP が切れる**。数値のずれだけは受け入れている。
- **非遅延の文法は先頭に思考ブロックを飲む** (GEN-13)。ここを外すと
  思考 ON + `response_format` が最初のトークンで詰まる。

### 3.2 P6 で入った形 (GEN-14。次が壊しやすい場所)

| 場所 | 何が入ったか |
| --- | --- |
| `SpeculativeCompletion.swift` の `targetToken(row:generationIndex:)` | **唯一の本体。**位置ごとに `sampleOnce(..., constraint: gate)` で引き (GEN-7 の棄却サンプリングをそのまま呼ぶ)、引いたトークンをその場で `gate.accept` し、`onDrawnToken` に流す。**採用は必ずここ** — 呼び出し側 2 か所のどちらでやっても、次の行の引きが古い状態を見る |
| 同ファイルの入口 | `ConstraintGate` を組み、拘束があって融合 greedy ヘッドなら `logitsUnavailable` で断る。prefill の種トークン (生成位置 0) も同じ拘束・同じ採用を通る |
| `onDrawnToken` | GEN-5 のトリガ判定と GEN-6 の抑止の口。**このループでは emit がブロック 1 個ぶん遅れる**ので、`onProgress` から抑止を動かすと遅延文法がチャンネルの閉じに置いていかれる |
| `ServerThoughtSuppression.observe(tokenID:)` | 上の口が呼ぶ、**イベントの無い**判定。境界トークン (`<\|channel>` / `<channel\|>`) だけを読む。ラベルを読まなくてよい根拠は SPEC **RSN-6** |
| `ServerGenerationPlan.allowsSpeculativeDecoding` | 常に `true` になった。DEV-14 に残るのは強制挿入 (`ServerReasoningPlan`) と `repeat_penalty != 1` (生成設定) の 2 つだけ |
| `ServerTimings.draftTokens` / `draftAcceptedTokens` | RSP-3 の `draft_n` / `draft_n_accepted`。**`draft_n > 0` のときだけ書く** (参照実装の門と同じ)。`ServerLiveTimings` には載らない — 集計はループが返るときに出るため |

**踏みやすい罠:**

- **文法状態の巻き戻しは要らないし、足してはいけない。**状態が進むのは採用した
  トークンだけで、採用したトークンは必ず emit される。停止でブロックを捨てる
  ときは生成自体が終わるので、進みすぎた状態には次の引きが無い
  (参照実装 `common_sampler_sample_and_accept_n` がそう書いてある)。
- **採用と emit は別の時刻**である。C2 の
  `SpeculativeCompletionLoopTests.GEN_14_theDrawnTokenHookFiresOncePerAdoptedToken`
  がその順序を固定している。
- **速いとは限らない。**GEN-14 は「併用できる」までが契約。棄却が毎位置に出る
  文法だと投機が遅くなることはありうる (§3.1 の 0.14 秒/棄却)。

## 4. 土台 (P0〜P4 で入った、次の段が乗る場所)

| 型 | 役割 |
| --- | --- |
| `ChatRequestSchema` | SPEC §4 の表そのもの。行を足す = 仕様を足す。値規則は `handler` に載せる (参照実装の `custom_handler` に対応) |
| `ChatRequestParser` | 正規化済みの値 → `ValidatedChatRequest`。エンジン写像 (DEV-9/10) もここ |
| `ChatMessageValidator` | SPEC §5 と §6 の tools 側だけ。旧 `OpenAIRequestValidator` の残骸 |
| `ServerError.swift` | ERR-1/ERR-2。`type` を決めれば HTTP 番号は自動で決まる |
| `ServerPromptRenderer` | テキスト/tools 経路の描画。**サーバーが描く変種はここの `static let variant` 1 か所が決める** |
| `commonPrefixLength` | CACHE-1 の本体。**D3 でキャッシュ判定はこれ 1 本になった** |
| `GFTokenizer.ChatTemplateVariant` | D2 で入った。`.modelBundled` (CLI・アプリ・KernelCheck) と `.serverRedraw` (サーバー) の 2 値。**既定は `.modelBundled`** なので、足した経路を明示的に渡さない限り描画は動かない |
| `ServerChatTemplate` | リポジトリ所有の jinja (`Sources/TurboFieldfare/Templates/server_chat_template.jinja`)。SPEC §12 DEV-12 |
| `ServerReadiness` / `ServerProperties` | P3。ロード状態は経路表より手前で見る。`/props` は `ChatRequestSchema` の表を歩いて作る — **既定値の第 2 の写しを作らないこと** |
| `Scripts/c3_smoke.sh` | C3 の **15 検査**。2026-08-21 に 14 緑。**15 個目の `GEN-14` はまだ走らせていない** |

削除済み: `OpenAIRequestValidator`、`OpenAIChatRequest`、`OpenAIStop`、
`OpenAIStreamOptions`、`OpenAIReasoning`、`ServerRequestError.payloadTooLarge` /
`.unknownModel`。

## 5. 積み残し・注意 (SPEC には書けていない実務メモ)

- **同梱テンプレートが 2 本あり、テストとサーバーで別々のものを引いていた**
  (2026-08-20 実測)。`GFTokenizer.load()` (引数なし、テストが使う) は HF キャッシュの
  `~/.cache/huggingface/hub/models--google--gemma-4-26B-A4B-it/snapshots/4d7ae4984b…/chat_template.jinja`
  (390 行、sha `ae53464b…`、ヘッダに `Published: 2026-07-09`)、サーバーは
  `scratch/gemma4.gturbo/tokenizer/chat_template.jinja` (362 行、sha `36e3a42e…`) を引く。
  **D2 の変種はサーバーが実際に使っている 362 行版から取った** (差分 1 ハンクに保つため)
  ので、tools 経路については**テストとサーバーが同じテンプレートを見るようになった**のは
  D2 の副産物である。ただし 390 行版にある `arguments is none` 対応・`image_url` /
  `input_audio` の別名・continuation 判定の O(1) 化・`raise_exception` は**変種に入っていない**。
  取り込むなら SPEC に行を足してから (§13)。**症状が出るまで触らない。**
- **`repetition_penalty` は効かなくなった。**SPEC REQ-repeat-penalty が
  `repeat_penalty` のみを挙げているため、旧名は R1 で無視される。既存
  クライアントがいるなら「別名を足す」を SPEC に書くところから。
- **`max_tokens: 0` (prefill のみ) は暫定実装。**生成 0 トークンで即応答するが、
  KV の暖機はしていない。LCP 化は済んだので、いつ詰めてもよい。
- **思考の既定が変わった。**`--thinking` の既定は off だったが、後継の
  `--reasoning-budget` の既定は **-1 (無制限)** なので、何も言わないクライアントは
  これから思考する。SPEC RSN-1 のとおりだが、トークンの消費が変わる。
- **`max_tokens` の 1/4 を答えのために取り置く** (DEV-21)。RSN-4 が分け方を
  決めていなかったので実装が決めた数字であり、**測って動かしてよい**。
- **`docs/mtp/34-M9-PROPOSAL.md` は未追跡のまま置いてある。**サーバーとは
  無関係 (MTP の提案書)。前回のセッション中に外から現れたもので、意図的に
  触っていない。
- `docs/OPENAI_SERVER.md` / `docs/SERVER_RUNBOOK.md` / `docs/RUNTIME_CONTROLS.md` は
  **P5 まで追随済み** (2026-08-22)。
- **追い残し (SPEC の話ではなく実装の話)**: `GrammarMatcher` の `RejectContext.decoded` が
  `[[UInt32]]` なので語彙のコードポイント表を平坦化できず、`GrammarTokenConstraint` が
  `rejectedIndices` の候補組み立てを複製している。直すならエンジン側の型から。
- **`swift test -c release` は swift-testing の suite を走らせない** (XCTest の
  shim だけが動く)。文法マスクの release 実測ができていないのはこれが理由。

## 6. 環境メモ

- テストは `./Scripts/test.sh` (直列)。`--filter <型名>` で絞る。
  C0〜C2 は重みも Metal も要らず、サーバー全体で 8 秒。
- C3 (実機スモーク) だけモデルを積む。走らせる前に AGENTS.md の
  「Test rules」を満たすこと — 特に
  `pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|…'` が空であること。
  **既にあるモデルプロセスを止めない。**
- 参照実装: `~/LLM/llama.cpp`、ピン `34af94cd9`。**作業ツリーはピンより先に
  進んでいる** (2026-08-20 時点で `fe8156f78`)。素の `grep` はピンでないコードを
  読むので、**必ず `git show 34af94cd9:tools/server/<file>` で引くこと。**
  一次資料は
  `tools/server/server-schema.cpp` (要求スキーマ)、`server-common.cpp`
  (OAI 層とエラー封筒)、`server-context.cpp` (キャッシュ)、`README.md`。
  ピンを上げるときは差分を読んで SPEC の該当行を先に直す。
- モデル同梱テンプレート: `scratch/gemma4.gturbo/tokenizer/chat_template.jinja`。
- **実機で見ていないもの** (すべて C3 送り、`Scripts/c3_smoke.sh` に検査がある):
  棄却サンプリングと遅延文法と思考中の抑止 (GEN-5/6/7) が本物のサンプラで
  動くこと、予算切れの終了タグ強制 (RSN-4) がモデルの上で本文を書かせること、
  リングより深い巻き戻し (DEV-13)、拘束された tool call が次のターンの
  描き直しと一致すること (INV-1 × GEN-8)。**この 14 検査は 2026-08-21 に
  走って全部緑になった。**そのあと 15 個目の `GEN-14` を足したが、
  **これはまだ走らせていない** (上の §3 の次の一手)。残っているのは
  それと pi の実セッションと OpenAI SDK。**「書けた」と「通った」は別**なので、
  走らせた結果は CONFORMANCE §2 に書き足すこと。
- サブエージェントを使うときは**共有インデックスに注意**。`git add` だけでは
  他のエージェントが stage したファイルを巻き込むので、**`git commit -- <paths>`**
  で経路を限ること。実際に 2 回巻き込みが起きた。
