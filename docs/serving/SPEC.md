# サーバー仕様 (SPEC) — TurboFieldfareServer

2026-08-19 制定。**この文書が `TurboFieldfareServer` の唯一の規範仕様である。**
実装・テスト・運用文書はすべてここから導出する。ここに書いていない挙動は
実装しない。実装がこの文書と食い違えば、それはバグである — 直すのは実装か、
§13 の手順を踏んだこの文書への行追加であり、その場しのぎの実装変更ではない。

各規範項目には ID (`REQ-*`, `EP-*`, …) を振る。適合テストは ID を名前に含める
([CONFORMANCE.md](CONFORMANCE.md))。この文書は実験ログではなく**生きた文書**
なので、変更は本文を直し、履歴は git log に任せる。

---

## 0. 規範の優先順位

仕様は自分で決めない。次の順で引く:

1. **ワイヤ形式** (`/v1/*` の要求・応答・エラーの形) — **OpenAI API**
   (platform.openai.com/docs/api-reference/chat)。
2. **挙動の詳細と拡張** (受理規則・クランプ・プロンプトキャッシュ・`/props`・
   `/health`・思考・文法拘束・llama 拡張パラメータ) — **参照実装
   `~/LLM/llama.cpp` の `tools/server`**。ピン: コミット `34af94cd9`。
   一次資料は `server-schema.cpp` (要求スキーマ)、`README.md` (API 仕様書)、
   `server-common.cpp` (OAI 層の変換)、`server-context.cpp` (キャッシュ)。
   ピンを上げるときは、これらの差分を読んでこの文書の該当行を先に更新する。
3. **機体の制約** (M3 Pro 18GB / macOS 15 / Metal / 単一モデル・単一スロット) —
   §12 の逸脱登録簿に登録した行だけが、上の 2 つから外れてよい。

## 1. 受理の大原則

| ID | 規則 |
| --- | --- |
| R1 | **未知の JSON キーは無視する。**400 にしない。 |
| R2 | **`null` は未指定と同じ。**既定値が使われる (参照実装 `has_value`)。 |
| R3 | **調整パラメータ** (出力の質にだけ影響するサンプリング系) は、範囲外なら §4 の表のとおり**クランプ**する。拒否 (400) は表で **hard** と書いた範囲だけ。実装が無い調整パラメータは受理して無視してよいが、必ず §12 に登録する。 |
| R4 | **契約パラメータ** (応答の形・内容の構造を決める: `tools`, `tool_choice`, `response_format`, `logprobs`, `n`, `stream` など) は、**実装どおり動くか、明示エラー** (§10)。要求と違う形の応答を 200 で返すことは、どのパラメータでも常に仕様違反。R4 は R3 より強い。 |
| R5 | **`model` は検査しない。**単一モデルのサーバーは受けた値をそのまま応答に写す (参照実装 `server-common.cpp:1410`)。 |
| R6 | **この文書の変更は、参照実装 (または OpenAI API) の該当箇所を確認してから行う。**クライアントの症状から仕様を逆算しない。 |

## 2. ライフサイクル (LIF)

| ID | 規範 |
| --- | --- |
| LIF-1 | プロセスは**モデルのロード前にポートを開く**。 |
| LIF-2 | ロード完了まで、全エンドポイントは **503** + `unavailable_error` (§10) を返す。`/health` の本文は `{"error":{"message":"Loading model","type":"unavailable_error","param":null,"code":"model_loading"}}`。クライアントは「接続拒否」と「ロード中」を区別できる。 |
| LIF-3 | ロード完了後、`/health` は `200 {"status":"ok"}`。 |
| LIF-6 | **ロード中の 503 は経路表より手前で判定する。**未知パスもロード中は 404 ではなく 503 を返す (参照実装 `server-http.cpp:255` のミドルウェアと同じ位置)。**例外は CORS の preflight (`OPTIONS`) だけ** — ロードゲートより手前で答える。ブラウザは preflight を通せなければ 503 の本文すら読めないので、ここで止めるとロード中であることを表示することもできない (FLAG-6)。 |
| LIF-7 | **ロードに失敗したらプロセスは終了する** (stderr に理由、`exit 1`)。ポートは既に開いているので、クライアントから見ると 503 `model_loading` のあと接続断になる。503 を返し続けて生き残らない — 単一モデルのサーバーにできることが無いため。 |
| LIF-4 | 生成スロットが埋まり待ち行列 (`--queue-limit`) も満杯のときは 503 + `unavailable_error`。 |
| LIF-5 | SIGINT / SIGTERM で終了する。進行中の SSE は切断してよい。二度目のシグナルで即死。 |

## 3. エンドポイント (EP)

| ID | エンドポイント | 規範 | 段 |
| --- | --- | --- | --- |
| EP-1 | `GET /health`, `GET /v1/health` (別名) | §2 のとおり。**API キー不要** | 実装済 |
| EP-2 | `GET /v1/models` | OpenAI 形。1 モデルを返す。**API キー不要** (参照実装 `get_public_endpoints` と同じ) — クライアントは設定が済む前に health とモデル一覧を引くため | 実装済 |
| EP-8 | `/v1` を外した別名: `GET /models`、`POST /chat/completions` | 参照実装が同じものを両方の綴りで出しているため合わせる。中身は EP-2 / EP-3 と同一 | P3 |
| EP-3 | `POST /v1/chat/completions` | §4〜§9 | 実装済 (乖離多数 — [CONFORMANCE §2](CONFORMANCE.md)) |
| EP-4 | `GET /props` | `default_generation_settings` (§4 の既定値の実効値)、`total_slots`、`model_path`、`chat_template`、`modalities` (`{"vision": true}`)、`build_info`、実効 `n_ctx`。クライアントの能力判定はここを見る。`build_info` はビルドを一意に指す文字列で、RSP-5 の `system_fingerprint` と**同じ値**を使う | 実装済 |
| EP-5 | `POST /tokenize`, `/detokenize`, `/apply-template` | 参照実装と同形。トークン数の事前計算用。`/apply-template` は **DEV-12 のサーバー変種**で描く | 実装済 |
| EP-6 | `GET /slots`, `GET /metrics` | 参照実装と同形・同じく起動フラグでゲート (FLAG-7)。runbook の「詰まってないか」を stderr で見るのをやめる | 実装済 |
| EP-7 | **採らない既知パス** (§12 DEV-7) は **501** + `not_supported_error` を返す。未知パスだけが 404。**`OPTIONS` は preflight として先に答える**ので、501 のパスにも 404 のパスにも同じ preflight 応答が返る (FLAG-6) — 経路の存在は preflight からは読み取れない | P3 |

採らない既知パス: `/v1/embeddings` `/embedding` `/reranking` `/rerank` `/infill`
`/v1/responses` `/v1/messages` `/v1/chat/completions/control` `POST /props`
`/lora-adapters` `/slots/{id}?action=…` `/v1/completions` `/completion`。
理由と再考条件は §12。

## 4. `/v1/chat/completions` — 要求パラメータ (REQ)

規則の読み方: **clamp [a,b]** = 範囲外は端に丸めて受理 / **hard [a,b]** =
範囲外は 400 (`invalid_request_error`, `param` にフィールド名) / **透過** =
検査せずそのまま使う / **無視** = 受理して効かせない (§12 DEV-5 登録済み)。
既定値の実効値は `/props` の `default_generation_settings` が真実 (EP-4)。

| ID | パラメータ | 型 | 既定 | 規則 |
| --- | --- | --- | --- | --- |
| REQ-model | `model` | str | — | R5: 検査しない。応答へそのまま写す |
| REQ-messages | `messages` | arr | 必須 | §5 |
| REQ-stream | `stream` | bool | false | |
| REQ-stream-usage | `stream_options.include_usage` | bool | false | |
| REQ-max-tokens | `max_tokens`、別名 `max_completion_tokens` | int | -1 | hard [-1, ∞)。**-1 = 無制限** (コンテキスト残量まで)、**0 = prefill のみ** |
| REQ-temp | `temperature` | num | 1.0 | clamp [0, ∞) |
| REQ-top-p | `top_p` | num | 1.0 | clamp [0, 1] |
| REQ-top-k | `top_k` | int | 0 | clamp [0, ∞)。**0 = 無効**。サンプラ実装の上限 256 への丸めは DEV-9 |
| REQ-seed | `seed` | int64 | -1 | 透過。**-1 = ランダム**。符号付きでデコードする (`UInt64` デコードで 400 にしない) |
| REQ-stop | `stop` | str \| arr | [] | 透過 (最大 4 は設けない — 参照実装に無い制限を足さない) |
| REQ-repeat-penalty | `repeat_penalty` | num | 1.0 | 透過 (llama 拡張。engine の repetitionPenalty へ)。旧名 `repetition_penalty` は採らない — R1 により無視される |
| REQ-n | `n` | int | 1 | hard [1, 1] (単一スロット。参照実装も `[1, n_parallel]`) |
| REQ-logprobs | `logprobs` / `top_logprobs` | — | — | 契約 (R4)。実装まで **501** `not_supported_error` (§12 DEV-6) |
| REQ-tools | `tools` | arr | [] | §6 |
| REQ-tool-choice | `tool_choice` | str \| obj | "auto" | `auto` / `none` / `required` / `{"type":"function","function":{"name":…}}` の 4 形を受理 (§6 GEN-4)。それ以外の値は 400 |
| REQ-parallel | `parallel_tool_calls` | bool | true | 透過 (テンプレートへ) |
| REQ-response-format | `response_format` | obj | text | `text` / `json_object` / `json_schema` (§6 GEN-3)。それ以外の type は 400 (参照実装 `server-common.cpp:1157`) |
| REQ-reasoning-effort | `reasoning_effort` | str | — | **"none" = 思考無効。それ以外は検査せずテンプレートへ透過** (参照実装 `server-common.cpp:1296`)。既知 7 語の列挙検査は廃止 |
| REQ-template-kwargs | `chat_template_kwargs` | obj | {} | テンプレートへ透過。`enable_thinking` は §8 |
| REQ-cache-prompt | `cache_prompt` | bool | true | §7 |
| REQ-reasoning-budget | `reasoning_budget_tokens` | int | -1 | hard [-1, ∞)。§8 (llama 拡張) |
| REQ-reasoning-format | `reasoning_format` | str | auto | §8 (llama 拡張) |
| REQ-timings | `timings_per_token` | bool | false | §9 RSP-3 |
| REQ-ignored | `min_p` `typical_p` `presence_penalty` `frequency_penalty` `repeat_last_n` `mirostat*` `dry_*` `xtc_*` `dynatemp_*` `samplers` `logit_bias` `ignore_eos` | — | — | **無視** (engine に該当サンプラが無い。§12 DEV-5)。engine に実装が入った時点でこの表の行に昇格させる |

## 5. メッセージと入力 (MSG)

| ID | 規範 |
| --- | --- |
| MSG-1 | role は `system` / `user` / `assistant` / `tool`。 |
| MSG-2 | `content` は文字列または parts 配列 (`text` / `image_url`)。 |
| MSG-3 | `image_url.url` は `data:image/…;base64` を受ける。**リモート URL とローカルパスは採らない** (§12 DEV-4) — 400 で「data URI のみ」と明言する。 |
| MSG-4 | `input_audio` / `input_video` parts は **501** `not_supported_error` (§12 DEV-8)。 |
| MSG-5 | assistant の `tool_calls`、`tool` role + `tool_call_id`、`reasoning_content` の入力 (思考の持ち回り) を受理し、テンプレートに渡す。 |
| MSG-6 | tools × 画像 × 思考は**同時に成立する** (テンプレートは 3 つ同時に描ける — S2 実測、commit b45fceb 時点)。組合せを入口で 400 にしない。 |

## 6. 生成の拘束 (GEN)

| ID | 規範 |
| --- | --- |
| GEN-1 | `tools` 宣言時、tool call は**文法で拘束して生成**する (JSON schema → 文法、参照実装 `server-schema.cpp:251` / `server-common.cpp:1246` の機構)。文法が描くのは**テンプレートが描くのと同じ構文**であり、このモデルではそれは `<\|tool_call>call:NAME{…}<tool_call\|>` の方言 (裸のキー、文字列は `"…"` または `<\|"\|>…<\|"\|>`) である。事後パース (`GemmaToolCallParser`) は拘束の後も応答の組み立てに使ってよい — 形は同じ。 |
| GEN-2 | **スキーマの入口検査で 400 にしない。**表現できないスキーマ要素は拘束できる近似 (generic JSON) に落とす。参照実装が例外を投げる入力 (壊れた `pattern`、未知の `type`、解決できない `$ref` など) もこちらは近似に落として受理し、落としたことを記録する (DEV-16)。`validateSchemaKeys` / `GemmaToolSchema.adapted` の入口拒否は廃止。 |
| GEN-3 | `response_format` は GEN-1 と同じ文法機構で拘束する。`json_schema` は `response_format.json_schema.schema` を読む。**`json_object` は schema が無ければ「任意の JSON オブジェクト」に拘束する** (DEV-18) — OpenAI の `json_object` はオブジェクトを返す契約であり、空スキーマを `object` に写す参照実装とも一致する。JSON を頼まれて Markdown を 200 で返すことは R4 違反であり、どの段階でも許されない。 |
| GEN-4 | `tool_choice` は 4 形すべてを文法で実現する: `none` は文法なし、`auto` は**遅延文法** (GEN-5)、`required` と名前指定は**最初から拘束する** (非遅延)。名前指定は文法が関数名そのものを固定する (DEV-17)。**文法では作れない拒否は要求の側で 400 にする**: 名前指定が**宣言されていないツール**を指した場合と、`required` なのに `tools` が空の場合 — どちらも `invalid_request_error`。文法を空にして黙って自由生成に落とすことは R4 違反。 |
| GEN-8 | **tool call の文法は、テンプレートが描き直す正準形だけを許す。**すなわち: 空白を一切入れない、オブジェクトのキーは**裸**で**昇順** (テンプレートの `dictsort`)、文字列は `<\|"\|>…<\|"\|>` のみ (JSON の `"…"` は**生成では許さない** — 読む側 `GemmaToolCallParser` は互換のため両方受ける)。理由は §7 **INV-1**: 完了した tool call ターンは引数を parse 済みの値から描き直すので、生成が正準形でなければ描き直しと必ずずれ、毎ターン LCP が切れる。数値の正準化 (`1.50` と `1.5`) までは踏み込まない — ずれても縮むのは LCP だけで、応答は変わらない。 **両端のマーカーは文法要素 `TOKEN` (トークン ID) で書く** — `<\|tool_call>` / `<tool_call\|>` の綴りは通常トークンの列 (`<`, `\|`, `tool`, …) でも作れてしまい、リテラルで書くとその列も文法を通る。読む側 (`StructuredAssistantDecoder`) は tool call を**トークン ID** で切り出すので綴りの列は call にならず、描き直しもマーカートークンを書くので INV-1 の理由もそのまま当てはまる。実測では `tool_choice: required` でモデルが開きを綴り、閉じに本物の `<tool_call\|>` を使って 500 になった (SPEC §12 **DEV-22**)。 |
| GEN-9 | **GEN-8 の帰結、文字列の中身。**テンプレートは文字列を**素のまま**書く (`'<\|"\|>' + argument + '<\|"\|>'`、エスケープ無し) ので、tool call の文法の文字列本体は `[^"\\]*` — **`"` と `\` を含まない任意の文字列**とする。JSON のエスケープ形 (`\"` `\n` `\uXXXX`) は生成では許さない (書けば描き直しと必ずずれる)。除く 2 文字は、ちょうど**テンプレートと `GemmaToolCallParser` の組が曖昧になる**文字である — `"` は終端子 `<\|"\|>` の一部で、`\` は読む側がエスケープ導入と解釈する。その 2 文字を含む値は生成できないが、それは元々この組で往復できない値である。**`pattern` 経由で作られる文字クラスまでは絞り込まない** — tool call のスキーマに `pattern` はまず来ず、`response_format` は `.json` 方言なので影響しない。 |
| GEN-11 | **GEN-8 の帰結、数の桁。**tool call の文法の数値は、**描き直しが通る桁数に制限する**。`JSONValue.jinjaSendableValue()` は `Decimal` が `Double` へ往復しないと `malformed` を投げるので、桁の多い小数を生成させると**次のターンの描き直しが 500 で落ちる** — 単に LCP が縮むだけの数値のずれ (GEN-8) と違い、これは応答の失敗である。生成できない数があることは害が小さいので、方言側で桁を絞る。 |
| GEN-10 | **GEN-8 の帰結、`null`。**テンプレートの `format_argument` に none の枝が無く、null は `null` とは描かれない。よって tool call の文法では `null` を**汎用の値の選択肢から外す**。スキーマが null を明示的に要求している場合だけ `null` を許し、そのときは近似として記録する (GEN-2) — 文法を充足不能にして生成を止めるほうが害が大きいため。 |
| GEN-12 | **`response_format` と `tool_choice` がぶつかったとき。**`response_format` が `text` 以外で、かつ `tool_choice` が `required` / 名前指定なら **400** — 「必ずツールを呼べ」と「この JSON の形で答えろ」は同時に満たせない。`tool_choice` が `auto` / `none` のときは `response_format` が勝ち、ツールの文法は載せない (ツール呼び出しは元々任意だったので何も奪っていない)。後者は参照実装と同じ (`has_response_format` の枝が先に取られる)。**片方を黙って捨てて 200 を返さない** (R4)。 |
| GEN-13 | **非遅延の文法は思考ブロックを飲み込む。**`response_format` や `tool_choice: required` は最初のトークンから拘束するが、思考が有効なら最初に出てくるのは思考ブロックである。よって非遅延の文法の `root` は**先頭に省略可能な思考ブロックを持つ** (参照実装も `ctx.reasoning_parser + …` で同じことをしている)。中身は「閉じトークン以外の任意のトークンの繰り返し」— GBNF の `!<[N]>` (TOKEN_NOT) で書ける。GEN-6 の抑止は**遅延文法だけ**の話なので、ここを塞がないと思考 ON + `response_format` の要求が最初のトークンで詰まる (GEN-7 の「どのトークンも許されない」= 500)。 |
| GEN-14 | **文法拘束は投機デコードを止めない。**ブロックの検証は位置ごとに「**文法込みで** target が引くトークン」を引き (GEN-7 の棄却サンプリングをそのまま使う)、引いたトークンをその場で文法状態へ `accept` し、下書きと食い違った位置で打ち切る (参照実装 `common/sampling.cpp:678` `common_sampler_sample_and_accept_n`)。**文法状態の巻き戻しは要らない** — 状態が進むのは採用したトークンだけで、食い違った位置より後ろのブロックは捨てるため。遅延文法のトリガ判定 (GEN-5) と思考中の抑止 (GEN-6) も同じ 1 か所を通るので、判定は「そのトークンを採用した時点」で行う。拘束下では融合 greedy ヘッドは使えない (GEN-7 と同じ理由) ので、ブロックは logits 行で検証する。**この行は性能の都合ではなく契約である**: 常用のクライアントは毎要求 `tools` を宣言するので、文法のある要求を投機から外すことは、そのクライアントから MTP を丸ごと奪うことと同じである (CONFORMANCE §5 の完了の定義がその経路を名指ししている)。 |
| GEN-5 | **遅延文法 (lazy)。**`tool_choice: auto` では、トリガに達するまで文法を一切適用しない (参照実装 `llama_grammar_apply_impl` の `awaiting_trigger`)。トリガはツール呼び出しの開始トークン `<\|tool_call>` である。トリガが出るまでは自由に本文を書けて、出た瞬間から呼び出し構文が拘束される。 |
| GEN-6 | **思考中は遅延文法を適用も供給もしない** (参照実装 `sampling.cpp:452` の `grammar_should_apply`)。思考ブロックの中に出たトリガでは文法は起動しない。思考が閉じた時点から通常どおり供給する。 |
| GEN-7 | **拘束の入れ方は棄却サンプリング** (参照実装 `common_sampler_sample`)。通常どおり 1 トークン引き、それが文法に適合すればそのまま採る。適合しなければ、全語彙を文法でマスクして引き直す。どのトークンも許されない状態は `server_error` (500) — 生成を無言で打ち切らない。 |

## 7. プロンプトキャッシュ (CACHE)

| ID | 規範 |
| --- | --- |
| CACHE-1 | 再利用判定は**トークン列の最長共通接頭辞 (LCP) のみ** (参照実装 `server-context.cpp:3125` の `get_common_prefix` 1 行)。会話の形 (role の並び・tools・思考・画像の有無) を判定に使わない。意味ゲートとブリッジ合成 (`ServerPromptCache` の現行設計) は廃止。 |
| CACHE-2 | **部分一致はそのまま使う。**不一致点から後ろだけを prefill する。all-or-nothing にしない。 |
| CACHE-3 | 全トークン一致時は末尾 1 トークンを捨てて再デコードする (参照実装 `n_past--`)。 |
| CACHE-4 | 画像は LCP 走査の中でチャンク (ダイジェスト + トークン数) の一致でまとめて飛ばす (参照実装 `server-common.cpp:678` の `get_common_prefix`)。**両側が同じ写真なら走査はチャンクごと飛び越え、違えばその写真の先頭で止まる** — 2 枚の写真は同じ soft token に展開されるので、トークンだけを見る走査では区別できない。写真が違っても全体が miss になるのではなく、**その写真の手前までは再利用する** (CACHE-2)。 |
| CACHE-5 | 要求ごとの `cache_prompt: false` で不参加 (既定 true)。プロセスフラグ `--prompt-cache-mode` は廃止 (FLAG-4)。 |
| CACHE-6 | **ミス理由の分類はしない。**観測値は `usage.prompt_tokens_details.cached_tokens` と `timings.cache_n` の数字 1 種類のみ。11 種の `ServerPromptCacheMiss` は削除。 |
| CACHE-7 | `--cache-reuse` (KV の位置ずらし流用) は当面採らない。LCP が安定してから backlog で検討 (参照実装でも画像経路では無効)。 |

**INV-1 (不変条件): 描き直し == 生成。**完了した assistant ターンを含む会話を
テンプレートで描き直したトークン列は、そのターンを生成し終えた時点の
(プロンプト + 生成) トークン列と**一致する**。思考 ON/OFF × tools 有無 ×
画像有無の全組合せで成立させる。これが崩れると LCP が本来より短くなるが、
**補正はキャッシュ側でやらない** (ブリッジ合成の再導入禁止) —
テンプレート/エンコーダ側を直す。検定はトークン列を 2 通り作って比べるだけで、
モデルの重みも Metal も要らない。**2026-08-20 に 4 組合せとも成立した**
(`PromptTokenInvariantTests`、P1-D2)。**成立させているのは同梱テンプレートでは
なく §12 DEV-12 のサーバー変種**であり、`reasoning_content` の入力 (MSG-5) が
その前提である — クライアントが思考を返さなければ、そのターンの思考ブロックは
描き直せず LCP はそこで止まる (仕様どおりの縮退であって、補完はしない)。
直した破れの幅は思考 OFF が 12 トークン、思考 ON が 20 トークン + 思考の長さ、
どちらも**毎ターン**だった。

## 8. 思考 (RSN)

| ID | 規範 |
| --- | --- |
| RSN-1 | プロセス既定は `--reasoning-budget N` (**-1 = 無制限 (既定)、0 = 無効**)。独自フラグ `--thinking on\|off` は廃止 (FLAG-4)。 |
| RSN-2 | 要求ごとの制御は `reasoning_effort` (REQ-reasoning-effort) と `chat_template_kwargs.enable_thinking`。参照実装と同じく両方受け、食い違いを 400 にしない。解決順は参照実装 (`server-common.cpp:1278-1304`) と同じ: `enable_thinking` があればそれ、無ければ `reasoning_effort` の有無 (`none` 以外 = 思考する)、最後に `reasoning_effort: "none"` と予算 0 が上書きして閉じる。 |
| RSN-3 | 思考は `reasoning_content` に分離して返す (`--reasoning-format auto`、既定)。`--reasoning-format none` で生テキストのまま返す。 |
| RSN-4 | **思考の予算が尽きたら終了タグを強制挿入して本文へ移らせる** (参照実装 `reasoning_budget_forced`)。予算 = `reasoning_budget_tokens`、および `max_tokens` の残り。**`max_tokens` の分け方は DEV-21** (答えの分を先に取り置く)。`max_tokens: -1` (無制限) は締切を作らない — 無制限は無制限であり、コンテキストの上限はクライアントが選んだ予算ではない。**同じ理由で、`max_tokens` が文脈の残り以上の要求も締切を作らない。**実効の生成上限は `min(max_tokens, 文脈の残り)` であり、これが文脈の残りに等しい要求は `-1` を送った要求と 1 トークンも違う生成をしない。違うのは綴りだけなので、締切の有無が変わってはいけない。**締切を作るのは、クライアントの `max_tokens` が文脈の残りより実際に短いときだけである。**この区別は性能に直結する — 締切を持つ要求は DEV-14 により投機デコードを落とすので、能力値をそのまま載せてくるクライアント (pi の `models.json` の `maxTokens` は `context_window` と同じ数) が、発火しえない締切と引き換えに MTP を丸ごと失う (実測 2026-08-21: 締切が実際の生成の 33 倍先にあるのに plain 経路へ落ちた)。`finish_reason: length` で本文 0 字・思考だけの応答を返さない (旧 16 §5 で実測済みの欠陥)。 |
| RSN-5 | tools 宣言時も思考は有効 (MSG-6)。 |
| RSN-6 | **予算はチャンネルが開いた時点で動き出す。**このテンプレートは `strip_thinking` がチャンネルブロックを一律に思考として扱うので、ラベルを見ずに `<\|channel>` で武装してよい。`final` などのラベル付きブロックが出てくるようになったら、ここを読み直す。 |

## 9. 応答 (RSP)

| ID | 規範 | 段 |
| --- | --- | --- |
| RSP-1 | 非ストリーム応答は OpenAI の chat.completion 形。`usage` は常に載せ、`prompt_tokens_details.cached_tokens` を含む | 実装済 |
| RSP-2 | SSE: `delta.role` チャンク → `delta.content` / `delta.reasoning_content` / `delta.tool_calls` → `finish_reason` チャンク → (include_usage 時) `choices: []` + `usage` → `data: [DONE]`。無音時は `: ping` コメント (5 秒) | 実装済 (旧 16 §3 で適合を実測) |
| RSP-3 | `timings` オブジェクト (`cache_n`, `prompt_n`, `prompt_ms`, `prompt_per_second`, `predicted_n`, `predicted_ms`, `predicted_per_token_ms`, `predicted_per_second`) を非ストリーム応答と最終チャンクに載せる。`timings_per_token: true` で毎チャンク。コンテキスト使用量は `prompt_n + cache_n + predicted_n` で計算できる。**投機デコードが走った要求では `draft_n` と `draft_n_accepted` も載せ、走らなかった要求ではキーごと出さない** (参照実装 `tools/server/server-common.cpp:82`)。投機が走ったかどうかをワイヤから見られるのはここだけであり、GEN-14 の適合テストはこの 2 つを見る | 実装済 |
| RSP-4 | `finish_reason`: `stop` / `length` / `tool_calls` | 実装済 |
| RSP-5 | `system_fingerprint`: ビルドのハッシュ。EP-4 の `build_info` と**同じ値**を 1 か所から読む | 実装済 |

## 10. エラー (ERR)

| ID | 規範 |
| --- | --- |
| ERR-1 | 封筒は `{"error":{"message","type","param","code"}}`。`code` は**文字列または null** (OpenAI 形)。参照実装は `code` に HTTP 番号を入れるが、`/v1/*` のワイヤ形式は OpenAI が上位規範なので合わせない (§12 DEV-1)。 |
| ERR-2 | `type` ↔ HTTP: `invalid_request_error` 400 / `not_found_error` 404 / `not_supported_error` **501** / `unavailable_error` **503** / `exceed_context_size_error` 400 / `server_error` 500 (参照実装 `server-common.cpp:25-54` と同じ対応)。**401 / 405 / 415 も `invalid_request_error`** とし、`code` を `invalid_api_key` / `method_not_allowed` / `unsupported_media_type` で区別する (OpenAI もこれらに専用の type を持たない。参照実装の `authentication_error` は `code` に HTTP 番号を入れる形なので DEV-1 により採らない)。**413 は使わない** (DEV-11) — 本文超過は 400。 |
| ERR-3 | JSON デコード失敗の 400 は、**どのフィールドが**問題かを `message` と `param` に含める。型不一致に「malformed JSON request」を使わない (旧 16 §1-a の `seed: -1` の欠陥)。 |
| ERR-4 | プロンプトがコンテキストに入らないときは `exceed_context_size_error`。`message` にプロンプトのトークン数と実効 `n_ctx` を入れる。 |

## 11. 起動フラグ (FLAG)

| ID | 規範 |
| --- | --- |
| FLAG-1 | 参照実装に同名概念があるフラグは名前を合わせる: `-c/--ctx-size` (旧 `--max-context`)、`--reasoning-budget`、`--reasoning-format`。**旧名は別名として残さず退役させる**が、`--thinking` と同じく**名指しで断って新しい綴りを案内する** — 「不明なフラグ」で突き放すと、動く命令行を持った運用者がどこを直せばよいか分からない。リポジトリの中の呼び出し元 (`Scripts/`、`docs/`) は同じ変更で追随させる。 |
| FLAG-2 | `--ctx-size` は自由な整数を受け、この機体で確保できる対応値へ**下に丸める** (§12 DEV-2)。実効値は `/props` の `n_ctx` で分かる。列挙外を 400 で拒否しない。`--expert-cache-slots` も同様に丸める。 |
| FLAG-3 | 機体・エンジン固有で参照実装に対応物が無いフラグはそのまま: `--expert-cache-slots` `--expert-cache-policy` `--draft-block-size` `--prefill` `--prefill-chunk-tokens` `--image-tokens` `--max-image-*` `--verification` `--rdadvise` `--model-id` `--queue-limit`。 |
| FLAG-4 | 廃止: `--thinking` (→ `--reasoning-budget`)、`--prompt-cache-mode` (→ 要求ごとの `cache_prompt`)。 |
| FLAG-5 | `--api-key` はキー 1 つ、またはカンマ区切りの並び。フラグを繰り返すと追加される (入れ替え作業が 1 行に収まる)。受ける綴りは `Authorization: Bearer <key>` / 同ヘッダの裸の値 / `X-Api-Key` の 3 つ (参照実装と同じ)。**検査の位置はロードゲート (LIF-2/LIF-6) の後、経路表の前** (参照実装 `server-http.cpp:302` と同じ順) — ロード中のキー無し要求は 401 ではなく 503 であり、認証されていない相手は 501 と 404 の差から経路の地図を作れない。**キー不要は EP-1 と EP-2 だけ。**`/props` は要る (能力の答えであって起動時の足場ではない)。失敗は **401** + `invalid_request_error` + `code: invalid_api_key` (ERR-2)。フラグが無ければ検査しない — 守りは 127.0.0.1 バインドのみ (現行どおり)。 |
| FLAG-7 | EP-6 のゲートは参照実装と同じ綴り: `--slots` / `--no-slots` (**既定は有効**) と `--metrics` (**既定は無効**)。切ってあるときは EP-7 と同じ **501** `not_supported_error` を返し、`message` にどのフラグで開くかを書く。 |
| FLAG-6 | `--cors-origins` はカンマ区切りのオリジン並び、または `*`。**フラグが無ければ CORS ヘッダを一切出さない** (DEV-20)。並びのときは要求の `Origin` を照合し、**一致した 1 つだけ**を `Access-Control-Allow-Origin` に返し、`Vary: Origin` を添える (並びをそのまま返す参照実装の書き方はブラウザが受けない — DEV-20)。`*` のときは `*` を返し `Vary` は要らない。**`Access-Control-Allow-Credentials` は決して出さない** — こちらの認証は明示ヘッダであって cookie ではないので、資格情報を伴う要求を許す理由が無い。preflight (`OPTIONS`) はロードゲートより先・API キーより先に答え (LIF-6、ブラウザは preflight に `Authorization` を付けない)、どのパスにも同じ応答を返す。広告する内容は `Access-Control-Allow-Methods: GET, POST, OPTIONS` (DELETE は持たない) と `Access-Control-Allow-Headers: authorization, content-type, x-api-key`。`Access-Control-Max-Age` は出さない。`--cors-methods` / `--cors-headers` / `--cors-credentials` / `--api-key-file` は採らない。 |

## 12. 逸脱登録簿 (DEV)

参照実装 / OpenAI から**意図して**外れる箇所はここに全部載る。
ここに無い乖離はバグである。

| ID | 逸脱 | 参照実装 | こちら | 理由 | 再考条件 |
| --- | --- | --- | --- | --- | --- |
| DEV-1 | エラー封筒 | `code` = HTTP 番号 | `code` = 文字列/null、`param` あり | `/v1/*` は OpenAI 本家の形が上位規範 (§0) | OpenAI が形を変えたら |
| DEV-2 | `--ctx-size` / `--expert-cache-slots` の値域 | 自由な整数 | 対応値の集合へ**下に丸める** | Metal ワーキングセットの実測に基づく確保 (16GB 機) | メモリ算術が動的になったら |
| DEV-3 | スロット数 | `--parallel N`、`--slot-prompt-similarity` | 生成 1 スロット固定。`--slot-prompt-similarity` は採らない | 18GB にモデル + KV 1 本が上限 | ハードが変わったら |
| DEV-4 | 画像のリモート URL / ローカルパス | fetch する (`--media-path`) | data URI のみ。400 で明言 | ローカル専用サーバーが外へ HTTP を出さない・任意パスを読まない | 認証と allowlist を設計したら |
| DEV-5 | 未実装サンプラ (`min_p` `typical_p` `presence/frequency_penalty` `repeat_last_n` `mirostat*` `dry_*` `xtc_*` `dynatemp_*` `samplers` `logit_bias` `ignore_eos`) | 実装済み | 受理して無視 (R3) | engine のサンプラは temperature / top-k / top-p / repetition penalty のみ (`GenerationConfig`) | engine に該当サンプラが入ったら REQ 表へ昇格 |
| DEV-6 | `logprobs` | 実装済み (`n_probs`) | 501 | engine が logits を露出していない。契約パラメータなので無視ではなくエラー (R4) | logits 露出を実装したら |
| DEV-7 | embeddings / rerank / infill / completions (非 chat) / responses / messages / control / lora / マルチモデル / MCP | あり | 採らない (EP-7 の 501) | このモデル・この用途 (pi / OpenCode / ブラウザデモ) に不要。面積を増やさない | 実クライアントの需要が出たら |
| DEV-8 | 音声・動画入力 | あり (mtmd) | 501 | モデルが vision のみ | モデルが変わったら |
| DEV-9 | `top_k` の上限 | INT32_MAX | 256 へ丸め | サンプラ実装の partial-sort 上限。クランプであり拒否ではない | サンプラを一般化したら |
| DEV-10 | `top_p` のサンプラ写像 | 全語彙で nucleus を取る | `top_p < 1` かつ `top_k` 未指定なら `top_k = 256` を補う。`top_p = 0` は貪欲 (`top_k = 1`) として実行 | サンプラが全語彙 nucleus を実装していない (`GenerationConfig.validate`)。R3 の「範囲外は端に丸める」の延長で、拒否ではない | 全語彙 nucleus を実装したら |
| DEV-12 | チャットテンプレート | 同梱 `chat_template.jinja` をそのまま描く | **サーバーだけリポジトリ所有の変種**を描く (`Sources/TurboFieldfare/Templates/server_chat_template.jinja`、`GFTokenizer.ChatTemplateVariant.serverRedraw`)。同梱版との差分は 1 ハンク: 完了した model ターンに、生成時に KV へ入っていた thought channel (思考 OFF なら空、思考 ON なら思考ブロック) を描き直す | 同梱版は思考ブロックを「最後の user より後」かつ「`tool_calls` を持つ」ターンにしか描かないので、完了した回答を描き直すと必ず生成時とずれる = INV-1 が破れ、毎ターン LCP が 12〜20+ トークン短くなる。CLI・アプリ・KernelCheck は同梱版のまま (既定 `.modelBundled`) なので、それらのトークン列は 1 ビットも動かない | 同梱テンプレートが完了ターンを生成どおりに描くようになったら |
| DEV-13 | 部分再利用の深さ | 共通接頭辞ならいくらでも遡って再開できる | **KV カーソルを戻せるのはリングの余裕まで** (`min(maxContext, slidingWindow + prefillChunkTokens) - slidingWindow`、既定 **2048 トークン**)。それより深い分岐は接頭辞を捨てて全 prefill | FP16 リングは SWA 層の物理スロットを `capacity` ごとに再利用するので、`[N, position)` を書いた時点で `[N-capacity, position-capacity)` は潰れている。カーネルが読む `[N-slidingWindow, N)` を守る条件がこの式 (`KVCacheManager.maximumSafeRewind`) | リング容量が変わったら自動で追随する。リングを切れば (`fp16RingEnabled = false`) 制限は消える |
| DEV-21 | 思考の予算に `max_tokens` が効くときの分け方 | 予算は `reasoning_budget_tokens` だけ。`max_tokens` は分けない | `max_tokens` のうち **`max(1, max_tokens/4)` を答えのために取り置き**、残りを思考の締切にする | RSN-4 は「`max_tokens` の残りも予算のうち」と言うが、分け方までは決めていない。取り置きが無いと、思考が `max_tokens` を丸ごと使い切ってから終了タグを差し込むことになり、本文 0 字という直そうとしている欠陥がそのまま残る。1/4 に強い根拠は無く、**測って動かしてよい数字** | 実測で答えが切れる/思考が短すぎるとわかったら |
| DEV-14 | 投機デコードを落とす要求 | 強制挿入 (`rbudget`) もサンプラ chain の中にあるので、どの要求も投機と併用できる | **思考の終了タグを強制しうる要求 (RSN-4) と `repeat_penalty != 1` の要求は投機デコードを使わない** (plain 経路に落ちる)。**文法はこの列から外れた — GEN-14 で併用する** | 強制挿入は「引かずに置くトークン」、repetition penalty は「まだ確定していない履歴に依存する引き」であり、どちらもブロック内の後続位置が検証された前提を崩す。参照実装はどちらもサンプラとして chain に入れてあるので併用できるが、こちらの `ReasoningBudgetForcer` は復号ループの側にあり、サンプラの中にいない。**2026-08-21 に GEN-14 で文法だけを外した** — 文法は引き直し (GEN-7) を持ち込むが、引き直しても位置ごとに引き直すのは target 自身であり、食い違った位置から後ろは捨てるので前提は崩れない (参照実装 `common_sampler_sample_and_accept_n` がそう書いてある)。この 2 つを外に残したのは、実装の形が違うからであって理由が同じだからではない | 強制挿入をサンプラ側へ移したら (思考 ON の常用セッションに MTP が要ると分かった時点で読み直す)。repetition penalty はサンプラが履歴をブロック内で確定できるようになったら |
| DEV-15 | オブジェクトのプロパティ順 | 宣言順 | **キーの昇順**。必須・省略可のどちらも | (1) `JSONValue.object` は順序を持たない Swift の Dictionary である。(2) テンプレートが tool_call の引数を `dictsort` で描くので、生成もキー昇順でなければ tool_call ターンで INV-1 (描き直し == 生成) が破れる | JSONValue が順序を持つようになり、かつテンプレートが宣言順で描くようになったら |
| DEV-16 | 表現できないスキーマ | 例外を投げる (400) | 近似に落として受理し、落とした箇所を記録する | GEN-2。契約は「拘束する」ではなく「頼まれた形で返す」であり、拘束しきれない部分があることは 400 の理由にならない。入口で断ると、クライアントが載せてくる巨大なスキーマの端の 1 行でタスク全体が通らなくなる | — |
| DEV-17 | 名前指定の `tool_choice` | 文字列としてデコードするため object 形は型エラーを握りつぶして `auto` に落ちる (実質未実装) | OpenAI どおり、その関数だけを文法で固定する | 参照実装のこれは欠陥であり、規範ではない。ワイヤ形式の上位規範は OpenAI (§0) で、そこでは名前指定は「その関数を必ず呼ぶ」である | 参照実装が object 形を実装したら合わせて読み直す |
| DEV-18 | schema の無い `json_object` | jinja 経路では**何も拘束しない** (自由文が通る) | 「任意の JSON **オブジェクト**」に拘束する | OpenAI の `json_object` は「妥当な JSON を返す」という契約であり、R4 がその 200 を守らせる。参照実装の非 jinja 経路も同じく空スキーマを文法に落としている | — |
| DEV-19 | 文字クラスの中の `-` の逃がし方 | `\-` と書く (`GRAMMAR_RANGE_LITERAL_ESCAPE_RE`) — **自分のパーサが読めない**綴り | `\x2D` と書く | 参照実装のこれは欠陥である。`parse_char` の受けるエスケープは `\x \u \U \t \r \n \\ \" \[ \]` だけで `\-` は無い。参照実装のテストにプロパティ名へ `-` を含むものが無いので露見していないだけ。位置に依存する「末尾に `-` を置く」書き方も、クラスを差集合で組み直した瞬間に壊れる | 参照実装が直したら |
| DEV-20 | CORS の既定と並びの返し方 | 既定が `--cors-origins *` かつ credentials 有効。並びは**カンマ区切りのまま** `Access-Control-Allow-Origin` に入れる | フラグが無ければヘッダを出さない。並びは `Origin` と照合して一致した 1 つだけを返し `Vary: Origin` を添える。credentials は出さない | 既定の `*` + credentials はローカル専用サーバーの守り (127.0.0.1 バインド) を、ブラウザで開いた任意のページに開けてしまう。並びをそのまま返すほうは参照実装の欠陥で、その値をブラウザが受け付けない (ACAO は 1 つのオリジンか `*` のみ) | 参照実装が直したら照合の側だけ読み直す |
| DEV-11 | 413 Payload Too Large | 無し (本文上限は 500) | 使わない。本文超過・画像サイズ超過・画像枚数超過はすべて 400 `invalid_request_error` | ERR-2 の型 ↔ HTTP 表に 413 の型が無く、型を増やすより 400 に寄せるほうが面積が小さい | 実クライアントが 413 を区別する必要が出たら |
| DEV-22 | tool call のマーカーの拘束 | 文法にマーカーの**綴りをリテラル**で書く (`"<\|tool_call>call:NAME"`) | マーカーの**トークン ID** を文法要素 `TOKEN` (`<[id]>`) で書く。名前と引数はこれまでどおりテキスト | 参照実装のパーサは detokenize 済みの**テキスト**を PEG で読むので、綴りで書かれたマーカーもそのまま call として読める。本実装は tool call を**トークン ID** で切り出す (`StructuredAssistantDecoder`) ので、綴りの列は call にならない。リテラルはその列も通してしまい、実際に通した — `tool_choice: required` × 思考 ON で、モデルが開きを `<`, `\|`, `tool`, … と綴り、閉じに本物の `<tool_call\|>` トークンを使い、復号器が「開きの無い閉じ」を見て 500 になった (C3 `GEN-4-required`、2026-08-21) | 読む側がテキストベースになったら |

## 13. この文書の変え方

1. 参照実装 (ピン §0) または OpenAI API の該当箇所を読む。
2. この文書に行を足す / 直す (ID を振る)。逸脱なら §12 にも登録する。
3. その行の**赤い適合テスト**を書く ([CONFORMANCE.md](CONFORMANCE.md) の階層に従う)。
4. 実装して緑にする。
5. クライアント (pi / OpenCode) の症状が出発点のときも、必ず 1 から始める (R6)。
