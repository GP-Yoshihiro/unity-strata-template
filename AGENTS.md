# AGENTS.md — AI エージェント共通ルール（Codex / Claude Code）

このファイルが唯一の正本です（Claude Code は `CLAUDE.md` 経由で読みます）。人間と複数の AI が同時に作業する前提です。

## まず読むもの
- 環境がまだ無い（フック未設定・Unity 未導入など）→ スキル **environment-setup** の手順で立ち上げる。
- 24 時間の無人運用 → スキル **autonomous-loop**。
- 作業前に `Docs/agent-lessons.md`（既知の落とし穴）を読む。

## プロジェクト
- Unity（版は `ProjectSettings/ProjectVersion.txt`）。ゲームコード `Assets/Scripts/Runtime`（asmdef `Game.Runtime`、namespace `Game`）、バッチ入口 `Assets/Scripts/Editor`（`Game.Editor.BatchEntry`）、テスト `Assets/Tests/EditMode`・`PlayMode`。
- タスク `Tasks/items/<id>.json`（仕様は `Tasks/README.md`）。設定 `team.config.json`（`mainAgent`、`loopAgent`）。
- Strata（ローカルモデル）: `.strata/launch.json`（起動）、`.strata/models.json`（モデル一覧）、`.strata/cache_config.json` と `.strata/strata_index.json`（コンテキスト層と索引。このテンプレート独自）。
- spec-kit（任意）: `.specify/`。`tasks.md` は `tools\task.cmd import` でタスク化してから claim する。

## コマンド（Windows。Unity / Strata のパスは自動解決されるので絶対パスを書かない）
| 目的 | コマンド |
|---|---|
| テスト / `.meta` 生成 / 任意メソッド | `tools\unity.cmd test EditMode`（`PlayMode` / `All`）/ `refresh` / `exec Ns.Class.Method` |
| Unity の導入 / 版の更新 / パッケージ追加 | `tools\unity.cmd install` / `upgrade <version>` / `packages add <id>[,<id>]` |
| タスク | `tools\task.cmd list` / `new` / `claim <id>` / `done <id>` / `block <id> -Note "理由"` / `release <id>` / `import <tasks.md>` |
| エージェント実行 | `tools\agent.cmd claude｜codex｜codex-local｜claude-local｜strata "指示"` |
| 24 時間ループ | `tools\loop.cmd` / `-Once` / `-Stop` |
| ローカルモデル | `tools\strata.cmd up` / `status` / `health` / `stop` / `ask "質問" -File <path>` |
| コンテキスト索引 | `tools\strata-index.cmd` / `-Verify` |

終了コード: `0` 成功 / `2` テスト失敗 / `124` タイムアウト / その他 Unity 起動・設定エラー（結果 XML が無ければ失敗扱い）。結果は `Logs/`。

## チーム作業ルール
1. **着手前に必ず claim する**（`tools\task.cmd claim <id> -Agent <種別>`）。claim は origin の `refs/claims/<id>` を原子的に作るので、二重着手や `paths` が重なる着手は拒否される。拒否されたら作業しない。
2. **触ってよいのは claim したタスクの `paths` だけ。** 範囲外が必要なら `tools\task.cmd new` で起票する。
3. **1 タスク = 1 ブランチ（`task/<id>-...`）= 1 PR。** main への直接 push はフックが拒否する。同じ PC で並列に動くなら `claim -Worktree`。
4. シーン・プレハブは `paths` に明記して claim で守る。バイナリ素材は `git lfs lock` してから編集する。
5. 終わったら `tools\task.cmd done <id>` → push → PR（claim は PR がマージ／クローズされると自動で解放される）。人の判断が要るなら `block`。他人の claim を `-Force` で外さない。
6. `--no-verify` は使わない。トークンや個人情報をリポジトリ・コミット・PR に書かない。

## 実装ルール
1. `.meta` を手で作成・編集・削除しない（生成は `refresh`、移動・削除は `exec Game.Editor.BatchEntry.MoveAsset -from <a> -to <b>` / `DeleteAsset -path <p>`）。`.meta` も一緒にコミットする。
2. Unity がエディタで開いている間はバッチ実行できない（`Temp/UnityLockfile`）。失敗したらユーザーに閉じてもらう。
3. コミット前: EditMode テストが 0 終了、`tools\strata-index.cmd -Verify` が 0 終了。
4. コードは `cs:Namespace.Type`（索引）で参照し、全文をプロンプトや応答に貼らない。ログは `error CS\d{4}` と失敗テスト名だけを渡す。
5. `Library/`、`Temp/`、`Obj/`、`UserSettings/`、`Logs/*`、`.codex-local/` はコミットしない。マシン固有の設定は `.unity-path.local` か環境変数に置く。

## Strata への委譲
指揮役は Claude Code / Codex、作業役は Strata。ログの要約・下書き・diff の一次レビューは `tools\strata.cmd ask` に、まとまった作業は `tools\agent.cmd codex-local` に任せる（必ず別ワークツリーで）。結果は必ず自分で確かめる（ローカルモデルは誤りやすい）。プロンプトは L1 → L2 → L3 の順（`.strata/cache_config.json`）に並べる。

## 24 時間ループから起動されたエージェント
ファイルの編集だけを行い、タスクの `paths` の外には出ない。Unity・`tools\unity.*`・`git commit`・`git push` は実行しない（ループがサンドボックスの外で行う）。

## サンドボックス（Codex）
Unity のバッチ実行はプロジェクト外（ライセンス、`%APPDATA%\UnityHub`、ネットワーク）に触れるため、Codex の Windows サンドボックス内では動かない。テストはループに任せるか、承認付きで実行する。リポジトリは `C:\dev\<name>` のような浅いパスに置く。
