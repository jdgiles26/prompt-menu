# Prompt Menu

Highlight rough notes in any Mac app, right-click → **Services → Rewrite as Agent Prompt**, and get them back as a structured prompt for an AI coding or research agent:
ROLE, OBJECTIVE, CONTEXT, STEPS, CONSTRAINTS and DONE WHEN, with `[CONFIRM: …]` where something's missing.

The model runs on your Mac. Prompt Menu has no network code: it starts a local model runner as a command-line program, reads what it prints, and shows the result in a dialog you can edit and copy.

## Runners

| Runner | Install | Model setting |
|---|---|---|
| **MLX** (default, Apple Silicon) | `pip install mlx-lm` | A Hugging Face repo id you've already downloaded, e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit`. Download it once with `mlx_lm.generate --model <id> --prompt hi`. Prompt Menu runs it with `HF_HUB_OFFLINE=1`, so it never downloads anything itself. |
| **llamafile** (Mozilla.ai, 0.10+) | Download from [mozilla-ai/llamafile](https://github.com/mozilla-ai/llamafile/releases) | A `.gguf` path, or leave empty and set a model-bundled `.llamafile` as the runner path. Runs in `--cli` mode. |
| **llama.cpp** | `brew install llama.cpp` | A `.gguf` path. Runs `llama-completion` for a single turn. |

Prompt Menu looks for runners on your `PATH`, in Homebrew's folders, `~/.local/bin` and pip's `~/Library/Python/*/bin`. Set a full path in settings if yours is elsewhere.

## Install

Needs macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
scripts/install.sh              # builds into ~/Applications and registers the Services item
scripts/install.sh --uninstall
```

Open **Prompt Menu** from ~/Applications to pick a runner and model, or click **Try It**. Settings can also be changed with `defaults write local.promptmenu <key> <value>` (`backend`, `model`, `executable`, `maxTokens`, `temperature`).

If the item doesn't show under Services, turn it on in System Settings → Keyboard → Keyboard Shortcuts → Services → Text. You can give it a shortcut there too.

## How it works

- `Sources/Core` has no UI and is fully tested: the system prompt and input limits (`Prompt.swift`), the command line for each runner (`Backend.swift`), running it with a timeout (`Runner.swift`), and the settings (`Settings.swift`).
- `Sources/PromptMenu` is the app: the Services provider (`Service.swift`), the result dialog (`ResultPanel.swift`) and the settings window. It's a menu-bar-less app that quits when its last window closes, so no model stays in memory.
- `Resources/App-Info.plist` declares the Services item. `scripts/build.sh` compiles with plain `swiftc`, so no Xcode project is needed.

## Tests

```sh
scripts/test.sh
```

They run against fake runner scripts, so they need no model. The build layout, the test runner and parts of the app shell are adapted from [Finder Menu](https://github.com/nikgrbn/finder-menu).

## Why not in-process MLX?

[mlx-swift](https://github.com/ml-explore/mlx-swift) could run models inside the app, but its Metal shaders only build with full Xcode (`xcodebuild`), and this project builds with the Command Line Tools alone. It's a good next step if you have Xcode installed: it would remove the Python dependency and keep the model loaded between rewrites.
