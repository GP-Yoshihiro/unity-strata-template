# 環境立ち上げ・総合レビュー（2026-10-31）

対象: `unity-strata-template`（ZIP から新規リポジトリを作って使う Unity 汎用ひな形）
実施環境: クラウドのコンテナ（Linux、Unity・Unity Hub・pwsh・Strata なし、Unity のサーバーへの通信は不可）

凡例: 🔴 動かない／壊れる　🟠 条件次第で事故になる　🟡 改善推奨　✅ 本ブランチで修正済み　📝 提案のみ（未実装）

---

## 1. 立ち上げ結果（このコンテナで実行）

| 手順 | 結果 |
|---|---|
| `tools/setup.sh` | 修正前は **`Permission denied` で停止**（後述 1-1）。修正後は最後まで完了 |
| git フック / LFS / `.history/` | 有効化・作成できた（履歴リポジトリは非公開でアクセス不可 → ローカル保存に切り替わることを確認） |
| Unity | 未インストール → 警告を出して続行（修正後）。`install` / `upgrade` は Unity Hub の代わりの偽物で動作を確認 |
| コンテキスト索引 | pwsh がないため `strata-index.ps1` は動かせず。同じハッシュ計算を移植して **保存済みの contentHash と一致することを確認**し、そのうえで更新 |
| Strata | 未インストール（このコンテナでは GPU もモデルもないため対象外） |
| チームルールの claim | pwsh がないため `tools/task.* claim` は実行できず。作業は指定ブランチ `claude/gallant-ptolemy-jekpyi` で実施 |

**各 PC で人が行う残りの手順**: `tools\setup.cmd` → `tools\unity.cmd install` → Unity Hub に一度サインイン（ライセンス）→ `tools\unity.cmd test All` → `tools\strata.cmd plan` / `up` → `tools\strata.cmd check` → `tools\loop.cmd -Once`。

---

## 2. 指摘と対応

### 2-1. セットアップ／ZIP からの新規リポジトリ化
| | 内容 | 対応 |
|---|---|---|
| 🔴 | `tools/setup.sh`・`find-unity.sh`・`unity.sh` に git 上の実行権限がなく、README どおり `tools/setup.sh` を実行すると macOS/Linux で `Permission denied` | ✅ 実行権限を付与。setup.sh 内は `bash tools/...` で呼ぶ（ZIP 展開で権限が落ちても動く）。CI で権限と `bash -n` を検査 |
| 🔴 | `setup.cmd`・`strata.cmd`・`codex-local.cmd` が `where pwsh >/dev/null`。cmd には `/dev/null` がなく、推奨の `C:\dev\` に置くと **`C:\dev\null` というファイルを作る**（無い場合はリダイレクト失敗で pwsh があっても Windows PowerShell 5.1 にフォールバック） | ✅ `>nul` に修正。CI で再発を検出 |
| 🔴 | 「何度実行しても安全」なはずの setup.sh が **2 回目で停止**（`git lfs install --local` が `.githooks/pre-push` を上書きできずエラー、`set -e` で中断） | ✅ `git lfs install --local --skip-repo`（フィルターのみ。LFS フックは `.githooks` が連結済み） |
| 🟠 | Unity が見つからないと setup が中断し、スキル同期・索引更新・Strata 確認が行われない | ✅ 警告して続行し、`tools/unity.* install` を案内 |
| 🟠 | ZIP 取り込み時、`git lfs install` より前に `git add -A` → 画像・モデルが **LFS でなく通常の blob で最初のコミットに入る** | ✅ LFS フィルターを先に有効化 |
| 🟠 | setup.ps1 の「自分のリポジトリか」判定が `'/'→'\'` 置換後に `GetFullPath` しており、macOS/Linux の pwsh では常に不一致 → **既存の clone を ZIP と誤認して全変更をコミットし新ブランチを作る**おそれ。同じ比較を使う `Test-HistoryRepo` も常に false で、mac/Linux では履歴が共有されない | ✅ ZIP 判定は `.git` の有無に変更（setup.sh と同じ）。パス比較は `Test-SamePath` に統一 |
| 🟠 | 新規リポジトリは pre-push フックが `main` への push を拒否するため、**最初の main を push できない** | ✅ setup が初回 push のコマンドを表示。README にチェックリスト |
| 🟡 | `team.config.json`（履歴リポジトリ）・`CODEOWNERS`・README の URL が作者の `GP-Yoshihiro` のまま。別プロジェクトで使うと他人の履歴リポジトリを参照し続ける | ✅ origin と履歴リポジトリの所有者が違えば setup が警告。README に「ZIP から新規プロジェクトを作るときのチェックリスト」 |
| 🟡 | `git init -b` は git 2.28 未満で失敗 | ✅ `git symbolic-ref` で同等の処理 |
| 📝 | GitHub の「Download ZIP」は、リポジトリ設定で「Include Git LFS objects in archives」を有効にしない限り LFS 実体を含まない | 素材を LFS で入れる前に設定を有効化するか、テンプレートには素材を入れない運用に |

### 2-2. Unity（最新版への対応・インストール・実行ファイルのパス）
| | 内容 | 対応 |
|---|---|---|
| 🔴 | PlayMode テストが `IEnumerator` を使うのに `using System.Collections;` がなく **コンパイルエラー**。バッチのテスト実行はどれか 1 つのアセンブリでもコンパイルに失敗すると止まるため、**EditMode を含むすべてのテストとループが失敗**する | ✅ 追加。`LogAssert.Expect` を `AddComponent` の前に移動。索引を更新。同じ落とし穴を `Docs/agent-lessons.md` に記載 |
| 🟠 | 見つからないときのフォールバックが「同じ major.minor、無ければ**一番新しい版**」。古い版や別の major でも黙って開き、**プロジェクトが勝手にアップ／ダウングレード**されてチーム全体に波及する | ✅ 同じ major.minor の**新しいパッチ版だけ**（警告付き）。それ以外はエラーにして `install` / `upgrade` を案内 |
| 🟠 | Unity が終了コード 0 で結果 XML を出さないと**テスト合格扱い**（ループが「合格」の PR を出す） | ✅ 結果 XML がなければ失敗扱い |
| 🟠 | `Start-Process -Wait` は子プロセスの終了まで待つため、Unity が残す `Unity.Licensing.Client` などで**バッチ実行が戻らない**ことがある。タイムアウトもなく、無人ループが止まる | ✅ Unity 本体だけを待つ。`UNITY_TIMEOUT_MINUTES`（既定 60 分）を超えたらプロセスツリーごと停止し終了コード 124 |
| 🟡 | インストール手段がなく「Hub で入れてください」だけ | ✅ `tools/unity.* install [版] [--module ...]`（Unity Hub CLI。`ProjectVersion.txt` の changeset も渡す）、`tools/unity.* upgrade <版>`（インストール → 一度バッチで開いて移行 → 版を確認）、`find-unity -Hub` / `--hub` |
| ✅ | 実行ファイルの解決順（引数 → 環境変数 → `.unity-path.local` → Hub の既定・副インストール先・手動登録 → PATH）は Windows/macOS/Linux とも妥当。偽のエディタ配置で 6 パターンを確認 | — |
| 📝 | **版の選択**: 現在の `6000.6.7f1` は Unity 6.6（Update リリース）。最新の LTS は Unity 6.3（2027-12 までサポート）。Unity 6.0 LTS は 2026-10 にサポート終了。チーム・24 時間運用では更新頻度の低い LTS を推奨。変更する場合は `upgrade` を専用タスクで | 判断は人間に委ねる |
| 📝 | CI では Unity のテストを実行していない（ライセンスが必要）。自己ホストランナー、または GameCI ＋ `UNITY_LICENSE` シークレットで PR ごとに EditMode を回すと、ループ以外（人間）の変更も守れる | 提案 |

### 2-3. Strata とメイン AI（Claude / Codex）の接続
| | 内容 | 対応 |
|---|---|---|
| 🟠 | `tools\agent.cmd claude` は `claude -p` のみで権限モードの指定がない。非対話では許可の確認に答えられず、**無人ループで Claude を使うと編集できない** | ✅ `--permission-mode acceptEdits`。`.claude/settings.json` を追加（`.history/` の読み取り・`.meta` の編集・force push・`--no-verify` を拒否。Codex の ACL と同じ保護を Claude 側にも） |
| 🟠 | `tools\agent.cmd codex` は、プロジェクトが「信頼済み」でないと `.codex/config.toml` が無視され読み取り専用になる | ✅ `codex exec --sandbox workspace-write` を明示 |
| 🟡 | スキル `unity-workflow` が廃止済みの `Tasks/backlog.json`・`Tasks/completed.json`・`--profile strata` を案内（現行は `Tasks/items/` と `tools\codex-local.cmd`）。`cache_config.json` の L3 も同様 | ✅ 修正し `.claude/skills` に同期 |
| 📝 | 既定モデル `Qwen3.8-Flash-Next Coder IQ1_M`（約 1.75 bit 量子化）は実装役としては品質が低め。おすすめの分担: ログ要約・下書き・一次レビューは Strata、**実装は `-Agent claude` / `codex`**（クラウド）か、VRAM に余裕があれば IQ3 以上 | 提案 |
| 📝 | Strata は Anthropic 互換 API もあるので、`ANTHROPIC_BASE_URL=http://127.0.0.1:8080` で Claude Code 自体をローカルモデルで動かす `claude-local` も作れる（`codex-local` と同じ形）。実機での確認が必要なため未実装 | 提案 |
| 📝 | `strata launch --status/--stop/--no-tui`、`/metrics`、`connect codex --check` は公開 README に記載がなく、このコンテナでは確認できない。実機で `strata --help` と `tools\strata.cmd check` で確認を | 実機で確認 |
| 📝 | `codex-local` は `approval_policy = "never"` かつサンドボックス内ネットワーク許可。タスク本文経由のプロンプトインジェクションで外部送信される余地がある。ループのエージェントは Unity を実行しないので、`strata ask`（localhost）以外を遮断できるならより安全 | 提案 |

### 2-4. 24 時間稼働（無人ループ）と能力向上の仕組み
| | 内容 | 対応 |
|---|---|---|
| 🔴 | タイムアウト時の停止が `taskkill.exe` 固定 → **macOS/Linux でループが例外終了** | ✅ `Stop-ProcessTree`（Windows は taskkill、それ以外は .NET の Kill(true)） |
| 🟠 | タスクの `paths` 外の変更も `git add -A` でそのままコミット（ルール 2 が無人時に守られない） | ✅ エージェント実行後に範囲外の変更を取り消し、次のラウンドでエージェントに通知 |
| 🟠 | コミットが pre-commit で拒否されると、変更が作業ツリーに残ったまま `done` になり、**実装のない「合格」PR**が出たうえ、**次のタスクに持ち越される** | ✅ 変更なし／コミット拒否は `block` 扱い。残った変更は `Logs/loop-unsaved-*.patch` に保存して作業ツリーをリセット |
| 🟡 | 能力向上の仕組みが「日次改善の指示書」だけで、誰も実行しない（スケジュールもデータの受け渡しもない）。サンドボックスのエージェントは `.history/` を読めないので指示書どおりに集計もできない | ✅ 下記「能力向上ループ」を実装 |
| 🟡 | `team.config.json` の `staleClaimHours` がどこでも使われていない（落ちたループの claim が永久に `doing`） | ✅ `task list` で `doing (stale 30h)` と表示 |

**能力向上ループ（実装済み）**
1. **記録**: ループがタスクごとに `rounds / passed / csErrors / outOfScope / timeouts / minutes` を非公開履歴の `metrics/loop-YYYY-MM.jsonl` に追記（プロンプト本文は含めない）。
2. **知識**: `Docs/agent-lessons.md`（既知の落とし穴、1 行 1 ルール）を毎回のプロンプト先頭に入れる。L1 層なのでプロンプトの先頭が毎回同じになり、Strata のプロンプトキャッシュも効く。Claude / Codex の対話利用でも AGENTS.md から参照。
3. **改善パス**: 24 時間ごと（`-ImproveEveryHours`、キューが空なら最短 6 時間、`-ImproveNow` で即時）に、集計結果・claim 状況・ループログと `Prompts/PROMPT_DAILY_IMPROVEMENT.md` をエージェントに渡し、日計レポート・lessons の追記整理・指示書の補正・タスク分割を作らせる。
4. **人間のゲート**: 改善パスは常に **draft PR**。ループは default ブランチ上のタスク・lessons・指示書しか使わないので、**人間がマージするまで自己改変は反映されない**（暴走しない）。

### 2-5. チーム開発
| | 内容 | 対応 |
|---|---|---|
| ✅ | claim（`refs/claims/<id>` の原子的作成）、paths の重複拒否、1 タスク 1 ファイル、PR マージで自動解放、トレーラーによる帰属、履歴の非公開分離は、複数の人間とエージェントの同時作業に対して設計がしっかりしている | — |
| 📝 | フォークからの PR では `release-claims` のトークンが読み取り専用になり claim が解放されない（stale 表示で気付ける）。フォーク運用をするなら `pull_request_target` 化を検討 | 提案 |
| 📝 | PowerShell は CI で構文チェックのみ。`Test-PathOverlap` / `Test-InTaskPaths` / 版の比較などを Pester で単体テストすると、Windows 以外での退行（今回の `GetFullPath` のような）を防げる | 提案 |
| 📝 | CODEOWNERS・ブランチ保護は 1 人運用向け（承認 0）。メンバーが増えたら README の `gh api` で承認 1・Code Owner 必須に | 既存の README どおり |
| 📝 | ループは毎周 `git pull` するので、ループ実行中に `tools/` の変更がマージされると次の周から新しいスクリプトで動く。大きな変更の前は `tools\loop.cmd -Stop` | 運用 |

---

## 3. このブランチで確認したこと
- `setup.sh` を 2 回連続で実行して完走（修正前は 1 回目で停止）。
- `find-unity.sh`: 「該当なし／古い版と別 minor のみ／新しいパッチのみ／完全一致／`UNITY_VERSION` 指定／`STRICT=1`」の 6 パターン。
- `unity.sh install`（偽の Hub。changeset と `--module` の受け渡し、インストール済みならスキップ）、`unity.sh upgrade`（複製したプロジェクトで `ProjectVersion.txt` が更新されることを確認）、結果 XML なし → 終了コード 1。
- paths の範囲判定（フォルダ、`*`、`**`、フォルダの `.meta`、タスク自身のファイル）を同じアルゴリズムの移植で 11 パターン。
- コンテキスト索引: 保存済み contentHash の再現 → 更新後の値を検証。`check-meta.sh` OK。PowerShell の ASCII 検査 OK。
- **未確認（pwsh・Unity・Strata がないため）**: PowerShell スクリプトの実行（CI の構文チェックで検証される）、Unity 実機でのテスト、Strata 実機。マージ前に Windows の PC で `tools\setup.cmd`（2 回）→ `tools\unity.cmd test All` → `tools\loop.cmd -Once` の確認を推奨。

---

## 4. 追加対応: 対話式ブートストラップ（ご要望の最終形）

`bootstrap.cmd`（実体 `tools/bootstrap.ps1`）を PowerShell から 1 回実行すると、次の順に対話で進みます。各手順は `-Step <名前>` で個別にやり直せます。進み具合は `.bootstrap.local.json`（git 管理外）に保存されるので、中断しても続きから再開できます。

| # | ご要望 | 実装 |
|---|---|---|
| 1 | PowerShell から環境立ち上げを実行 | `.\bootstrap.cmd`（ダブルクリックでも可）。Git / Git LFS / GitHub CLI がなければ winget で導入し、git のユーザー名設定と GitHub ログインも行う |
| 2 | ひな形を新規リポジトリに（名前・公開設定） | 所有者（個人・組織）、**リポジトリ名**、**公開設定（private / public / internal）**を選んで `gh repo create`。ZIP を Downloads など深い場所に展開していたら `C:\dev\<名前>` へのコピーを提案。CODEOWNERS・README・`team.config.json`（非公開の履歴リポジトリ `<名前>-history` も作成）・製品名を自分用に書き換えて、最初の main を push。clone した場合、ひな形は remote `template` として残すので、ひな形の更新を取り込める |
| 3 | Unity の版の選択とインストール（ユーザーが選ぶ） | 「このひな形の版／最新 LTS 2 件／最新 Update 2 件／インストール済み／手入力」から選択（Unity の公開リリース API を使い、取得できなければ手入力）。ビルド用モジュールも複数選択 → Unity Hub CLI でインストール → Hub を開いてライセンス有効化 → 版が違えば `upgrade` でプロジェクトを移行 |
| 4 | Strata の立ち上げとモデル選択（賢さ順＋GPU 負荷） | Strata がなければ公式インストーラーで導入（確認あり）。GPU・VRAM・RAM・空き容量を調べ、`tools/bootstrap/strata-models.json` の 20 モデルを**賢い順**に表示。各モデルに **GPU 負荷（超高・高・中・低）**、必要メモリ、ダウンロード量、**この PC で動くか（o / ~ / x と理由）**を付け、動く中で最も賢いものをおすすめにする。選んだモデルは公式に記載のある `strata launch --plan` で確認してから起動 |
| 5 | メイン AI と Strata の接続 | Claude Code / Codex / 両方を選択して CLI を導入。起動中の Strata から実際のモデル ID を取得してローカル Codex 設定（モデル名・文脈長）を更新し、`strata connect codex --check` と往復テストを行う。Claude Code からはスキル経由で `strata ask` を使う。Claude Code 自体をローカルモデルで動かす `claude-local`（実験的）も追加。24 時間ループのエージェントを選んで `team.config.json` に保存 |
| 6 | Unity の開発環境整備 | IDE（VS は `.vsconfig` のワークロード追加、VS Code は Unity 拡張、Rider）、パッケージの複数選択（Input System、uGUI、URP、Cinemachine など。新しい `BatchEntry.AddPackages` でエディタに合った版を自動で選ぶ）、初回インポート、EditMode テスト、UnityYAMLMerge の登録 |
| 7 | スキル・プラグイン（＋spec-kit） | エージェントスキルの同期、Claude Code プラグインを `--scope project` で入れてチームで共有。**spec-kit**: uv → `specify-cli` → `specify init --here`（使える引数はヘルプから自動判定）。このプロジェクト用の **Constitution**（Unity の作法・テスト先行・タスク分割・秘匿情報）を書き込み、`tools\task.cmd import <tasks.md>` で spec-kit のタスクを `Tasks/items` に起票できるようにした |
| 8 | 使用の確認（ファイル or プロンプト） | `tools\try.cmd`。**指示書ファイルのパス**か**プロンプト入力**（複数行可）を選び、エージェントを選んで実行。Strata は回答だけ。ほかのエージェントは使い捨てタスクを claim → 編集 → `.meta` 生成 → Unity テスト → 範囲外の変更を表示 → 「draft PR／ブランチに残す／すべて破棄」。セットアップ後もいつでも使える |
| 9 | 仕上げ | main ブランチの保護（PR 必須・`repo-checks` 必須）と結果のまとめ。保護をかけるまでは、ブートストラップのコミットを直接 main に push する（以降は PR 経由） |

### 確認状況
- **このコンテナで確認済み**:
  - `unity.sh` の `install` / `upgrade` / `packages`（偽の Hub・エディタで）
  - spec-kit の `tasks.md` 解析（正規表現を移植して 4 パターン）
  - 画面文言のキーがすべて `messages.ja.json` にあること
  - `.ps1` が ASCII であること
  - コンテキスト索引のハッシュ
- **未確認**（pwsh・Windows・GPU がないため）: `bootstrap.ps1` / `try.ps1` の実行そのもの（構文は CI の PowerShell 構文チェックで検証）。最初の 1 回は Windows で通しで実行し、止まった手順を `-Step` で再実行してください。
- **公式情報で確認できず、実行時にフォールバックするもの**:
  - Unity リリース API の `stream=LTS/TECH` → 取れなければ手入力
  - Strata のモデル ID の大文字・小文字と `--context` → `--plan` で順に試す
  - Claude Code プラグイン名（unity / unity-perf / github） → 失敗したら `/plugin` での手動導入を案内。一覧は `catalog.json` で変更可
  - spec-kit の `--integration` / `--ai` → ヘルプから自動判定

---

## 5. 配布前の安全性チェック（ウイルス・不正コード）

人に渡す前提で、リポジトリ全体（このブランチ）を検査しました。**ウイルス・不正なコードは見つかりませんでした。**

| 観点 | 結果 |
|---|---|
| 実行ファイル・バイナリの同梱（exe / dll / bat / vbs / js / zip など） | なし（全ファイルがテキスト・JSON・Unity YAML） |
| 難読化・隠れた実行（`-EncodedCommand`、Base64、`Invoke-Expression`、`DownloadString`、certutil / mshta / rundll32 / bitsadmin） | なし |
| 常駐化・設定改ざん（タスクスケジューラ、Run レジストリ、Defender の除外設定） | なし |
| 見えない文字による偽装（双方向制御文字・ゼロ幅文字 = Trojan Source） | なし |
| 秘密情報（GitHub トークン、API キー、秘密鍵） | なし |
| 通信先 | GitHub、Unity（unity.com / services.api.unity.com）、astral.sh（uv）、claude.ai（Claude Code）、127.0.0.1（ローカルの Strata）のみ。外部へのデータ送信はなし |
| Unity プロジェクトを開いたときの自動実行（`InitializeOnLoad` など）、外部プロセス・通信・ファイル削除 API | なし（`BatchEntry` はバッチ実行で明示的に呼んだときだけ動く） |
| Unity パッケージの取得元 | Unity 公式レジストリのみ |
| git フック（コミット・push 時に自動で動く） | リポジトリ内の `tools/check-meta.sh`・`strata-index.ps1` と Git LFS だけを呼ぶ |
| 削除・強制操作 | リポジトリ内に限定（無人ループと `try` の破棄、空の履歴フォルダの作り直し）。破棄の前には未コミットの変更をパッチに保存する、またはユーザーが「破棄」を選ぶ |

**対応したこと**
- ブートストラップの外部インストーラー（Strata・uv・Claude Code）は、`irm URL | iex` でダウンロードしたスクリプトを保存せずそのまま実行していました。これをやめ、**いったんファイルに保存し、場所と SHA256 を表示して、確認してから実行**するようにしました。受け取った人が実行前に中身を確認したりウイルス対策ソフトで検査したりでき、`irm | iex` という形をウイルス対策ソフトに誤検知されることも避けられます。
- Windows PowerShell 5.1 で GitHub や Unity の API に接続できるよう、TLS 1.2 を有効にしました。

**受け取る人に伝えておくこと**
- `tools\*.cmd` と `bootstrap.cmd` は `-ExecutionPolicy Bypass` で PowerShell を起動します（このリポジトリのスクリプトを、実行ポリシーの設定に関係なく動かすため。一般的な手法です）。
- ブートストラップは、確認を求めたうえで winget・npm・uv と各公式インストーラーからソフトを入れます。入れるものは画面に表示されます。
- 既存のローカル Codex 設定（`tools/templates/codex-local.config.toml`）は、無人運用のため `approval_policy = "never"` で、サンドボックス内のネットワークも許可しています。信頼できないタスク本文を無人ループに渡さないでください。
