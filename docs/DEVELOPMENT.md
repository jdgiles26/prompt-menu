# Development

## Setup

| Need | Check | Get it |
|---|---|---|
| macOS 13+ | `sw_vers` | — |
| Command Line Tools (swiftc, codesign) | `xcrun swiftc --version` | `xcode-select --install` |
| A runner, for manual testing only | `command -v mlx_lm.generate` | `pip install mlx-lm` (or see README) |
| A model, for manual testing only | `ls ~/.cache/huggingface/hub` | `mlx_lm.generate --model mlx-community/Llama-3.2-3B-Instruct-4bit --prompt hi` |

Full Xcode isn't needed. There's no Xcode project and no Package.swift; every build is a single `swiftc` call.

## Commands

| Task | Command | Notes |
|---|---|---|
| Run the tests | `scripts/test.sh` | Builds `Tests/` + `Sources/Core` and runs them. Exits non-zero on any failure. Runs from any folder. |
| Build | `scripts/build.sh build` | Writes `build/Prompt Menu.app` (git-ignored). |
| Install and register the Services item | `scripts/install.sh` | Builds into `~/Applications`, then runs `lsregister` and `pbs -update`. |
| Uninstall | `scripts/install.sh --uninstall` | |
| Check the plist | `plutil -lint Resources/App-Info.plist` | CI runs this too. |
| Check the signature | `codesign --verify --strict --deep "build/Prompt Menu.app"` | CI runs this too. |

## Tests

The tests use a home-made runner (`Tests/main.swift`) because XCTest isn't part of the Command Line Tools. A test is a `func testSomething() throws` listed in the `tests` array in `Tests/main.swift`.

| Helper | Use |
|---|---|
| `check(cond, "message")` | A failing check is recorded and the test continues. |
| `checkEqual(actual, expected)` | Prints both values when they differ. |
| `checkThrows(.someRewriteError) { … }` | Passes only if exactly that error is thrown. |
| `throw TestFailure(description:)` | Stops a test that can't continue. |
| `makeTempFolder()` | A new folder, deleted after the run. |
| `makeScript(name, in: folder, body)` | An executable `#!/bin/sh` script: a fake runner. |

**Fake runners, never real models.** The tests stand in for `mlx_lm.generate`, `llamafile` and `llama-completion` with shell scripts in temp folders, passed through `searchDirs:` or `executable:`. A test must never depend on a model being installed, on `PATH`, or on the network.

**Never use the real settings in tests.** Use `UserDefaults(suiteName: "PromptMenuTests-<uuid>")` and remove it afterwards, as `testSettings` does. The `settings` global is the user's real preferences.

**Paths are relative to the repository root.** `scripts/test.sh` changes to the root first, and the guardrail tests read `Sources/`, `Resources/` and the docs from there.

### Adding a test

1. Write `func testX() throws` in the matching file (`PromptTests`, `BackendTests`, `RunnerTests`, `ServiceTests` or `GuardrailTests`).
2. Add `("short name", testX)` to `tests` in `Tests/main.swift`.
3. Run `scripts/test.sh` and confirm it **fails** before you implement.

## Manual checks

The UI can't be tested automatically. After any change to `Sources/PromptMenu` or `Resources/App-Info.plist`:

1. `scripts/install.sh`
2. Open Prompt Menu from `~/Applications`. The settings window should show `Runner: ✓ found …`.
3. Click **Try It**. A dialog opens with a spinner and a seconds counter, text streams in, and it ends with "Done in Ns".
4. Highlight text in TextEdit → right-click → Services → **Rewrite as Agent Prompt**. The same dialog appears in front.
5. While it's running, click **Close**. Then `pgrep -f mlx_lm.generate` prints nothing, because the runner was stopped.
6. Run it again and press **Try Again** while it's running. Only one runner process is left.
7. **Copy** (⌘↩) puts the edited text on the clipboard and closes the dialog.
8. While a rewrite is running, quit with ⌘Q (or `pkill -f MacOS/PromptMenu`). `pgrep -f mlx_lm.generate` prints nothing: the runner didn't outlive the app.
9. Close every window. `pgrep -f "MacOS/PromptMenu"` prints nothing, because the app quit.
10. Set a bad runner path in settings. The hint shows ✗. Try It shows "Couldn't find …".

To trigger the service without clicking, from a small Swift script:

```swift
import Cocoa
let pb = NSPasteboard(name: .init("PromptMenuTest"))
pb.clearContents(); pb.setString("add dark mode, keep login untouched", forType: .string)
print(NSPerformService("Rewrite as Agent Prompt", pb))
```

## Debugging

| Symptom | Likely cause | Fix |
|---|---|---|
| No item under Services | Services cache is stale, or the item is turned off | `scripts/install.sh` again (it runs `pbs -update`); turn it on in System Settings → Keyboard → Keyboard Shortcuts → Services → Text; log out and back in as a last resort. |
| The item exists but nothing happens | `NSMessage` and the method don't match | `scripts/test.sh` (`testServicesEntry`). Check `Console.app` for the `PromptMenu` process. |
| The dialog is created but not visible | The panel hides when its app isn't frontmost | Keep `panel.hidesOnDeactivate = false` and `orderFrontRegardless()`. |
| `Couldn't find mlx_lm.generate` | The program is outside the searched folders | Set the full path in settings (`which mlx_lm.generate` in Terminal). |
| `exit code 1` mentioning `LocalEntryNotFoundError` or "offline" | The MLX model isn't downloaded, and Prompt Menu won't download it | Download once: `mlx_lm.generate --model <id> --prompt hi`. |
| Text appears all at once at the end, not streamed | The runner buffers its stdout | MLX needs `PYTHONUNBUFFERED=1` (already set). For other runners, check that they flush. |
| `timedOut` | The model is too big for this Mac, or swapping | Use a smaller model or fewer max tokens. The timeout is `rewrite(timeout:)`, 300 s by default. |
| The output includes runner noise | A new runner version prints something new | Add a case to `testCleanOutput` first, then extend the `noise` patterns in `cleanOutput`. |

See what a runner is called with:

```sh
defaults read local.promptmenu
# then run the same command by hand, e.g.
HF_HUB_OFFLINE=1 mlx_lm.generate --model mlx-community/Llama-3.2-3B-Instruct-4bit \
  --system-prompt "…" --prompt "fix the login bug" --verbose True
```

Reset all settings: `defaults delete local.promptmenu`

## Releasing

1. Bump `CFBundleShortVersionString` (semver) **and** `CFBundleVersion` (+1) in `Resources/App-Info.plist`.
2. Add an entry to `CHANGELOG.md`.
3. `scripts/test.sh && scripts/build.sh build`, then do the manual checks above.
4. Commit `Bump version to X.Y.Z`, then tag `vX.Y.Z` and push the tag.

## CI

`.github/workflows/ci.yml` runs on every push to `main` and on every pull request, on macOS 15 and macOS 26. It runs the tests, builds the app, lints the plist and verifies the signature. CI has no runner or model installed, which is why the tests only use fake runners.

## Style

- Swift 5 language mode (`-swift-version 5`) with a macOS 13 deployment target. Keep both: they're in `build.sh`, `test.sh` and the plist.
- Write comments that explain why, in plain sentences, like the existing ones. Don't comment what the code already says.
- Free functions in `Core` are fine. Don't add protocols or classes for one implementation.
- Messages users see are written as full sentences that say what to do next (see `RewriteError.errorDescription`).
- No third-party dependencies.
