<!-- 無人ループ（tools/loop.ps1）が毎回プロンプト先頭に入れる「既知の落とし穴」。1 行 1 ルール、新しいものを上に、80 行以内。
     日次の改善パス（draft PR）が失敗データから追記・整理する。人間がレビューしてからマージすること。 -->
# Agent lessons (project pitfalls)

- `[UnityTest]` methods return `IEnumerator`: add `using System.Collections;` (missing it breaks compilation of the whole test run).
- Call `LogAssert.Expect(...)` before the code that logs (e.g. before `AddComponent`, whose `Awake` runs immediately).
- One compile error in any assembly fails every test platform: keep each change compiling on its own.
- New runtime code goes under `Assets/Scripts/Runtime` (asmdef `Game.Runtime`, namespace `Game`); tests under `Assets/Tests/EditMode` (namespace `Game.Tests`).
- Pure logic belongs in plain C# classes without `UnityEngine` so EditMode tests can cover it; keep `MonoBehaviour`s thin.
- Never create, edit, move or delete `.meta` files; the runner generates them. Move/delete assets only via `Game.Editor.BatchEntry`.
- Stay inside the task's `paths`; the runner reverts anything else and the change is lost.
- Do not paste whole files in replies; summarise the change.
