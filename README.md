# Prompt Menu

**Turn rough notes into a prompt an AI agent can act on, from any Mac app, with a model that runs on your Mac.**

Highlight text anywhere (Notes, Mail, Slack, a browser, your editor), right-click → **Services → Rewrite as Agent Prompt**. A dialog opens and the rewritten prompt streams in:

```text
ROLE: …          who the agent should act as
OBJECTIVE: …     the exact outcome wanted
CONTEXT: …       facts from your text, nothing invented
STEPS: …         a numbered plan, ending with checking the result
CONSTRAINTS: …   what not to touch
DONE WHEN: …     checkable signs it's finished
```

Wherever your notes leave something out, the model writes `[CONFIRM: what to ask]` instead of guessing. Edit the result in the dialog, then **Copy** (⌘↩).

- 🔒 **Local only.** No network code at all, and a test fails the build if any appears. The model runs as a local program.
- 🧩 **Your choice of runner:** Apple **MLX**, Mozilla.ai's **llamafile**, or **llama.cpp**.
- 🪶 **Small.** About 750 lines of Swift, built with the Command Line Tools. No Xcode project, no dependencies.

## Requirements

- macOS 13 or later; Apple Silicon recommended (MLX needs it)
- Xcode Command Line Tools: `xcode-select --install`
- One runner and one model (see below)

## Install

```sh
git clone https://github.com/jdgiles26/prompt-menu.git
cd prompt-menu
scripts/install.sh               # builds into ~/Applications and registers the Services item
```

Then open **Prompt Menu** from `~/Applications` to pick a runner and model, and click **Try It**.

To remove it: `scripts/install.sh --uninstall`

If **Rewrite as Agent Prompt** doesn't appear under Services, turn it on in **System Settings → Keyboard → Keyboard Shortcuts → Services → Text**. You can give it a keyboard shortcut there too.

## Runners

| Runner | Program | Install | Model setting |
|---|---|---|---|
| **MLX** (default) | `mlx_lm.generate` | `pip install mlx-lm` | A Hugging Face repo id that's already downloaded, e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit`. Download once with `mlx_lm.generate --model <id> --prompt hi`. |
| **llamafile** 0.10+ | `llamafile` | [mozilla-ai/llamafile releases](https://github.com/mozilla-ai/llamafile/releases) | A `.gguf` path, or leave empty and set a model-bundled `.llamafile` as the runner path. |
| **llama.cpp** | `llama-completion` | `brew install llama.cpp` | A `.gguf` path to an instruct model. |

Prompt Menu looks for the program on your `PATH`, in Homebrew's folders, `~/.local/bin`, `~/bin` and pip's `~/Library/Python/*/bin`. The settings window shows what it found; set a full path if yours is elsewhere.

**Which model?** On an 8 GB Mac, a 3B–4B instruct model at 4-bit (about 2 GB) is the practical size: text starts streaming in about 8 seconds and a full prompt takes 15–20. With 16 GB or more, 7B–9B models follow the outline noticeably better.

**Status:** MLX is tested end to end with a real model. The llamafile and llama.cpp command lines are covered by tests but haven't yet been run against real models; reports welcome.

MLX runs with `HF_HUB_OFFLINE=1`, so Prompt Menu never downloads a model itself. Only what's already on disk is used.

## Settings

The settings window covers the runner, runner path, model and max tokens. Everything is also available from Terminal:

```sh
defaults write local.promptmenu backend mlx            # mlx | llamafile | llama.cpp
defaults write local.promptmenu model mlx-community/Qwen3-4B-4bit
defaults write local.promptmenu executable /opt/homebrew/bin/llama-completion   # empty = search
defaults write local.promptmenu maxTokens -int 1024    # 16–8192
defaults write local.promptmenu temperature -float 0.3 # 0–2
defaults write local.promptmenu systemPrompt "Rewrite the text as …"   # empty = built-in prompt
```

## Privacy

- No network code: the build's tests scan `Sources/` for networking APIs and URLs.
- No entitlements, no permissions requested, no telemetry, no logs of your text.
- Your text goes to the runner as a command-line argument and stays on this Mac. The app quits when its last window closes, so no model stays in memory.

## Documentation

| Doc | For |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it's built: modules, types, decisions |
| [docs/FLOW_MAPS.md](docs/FLOW_MAPS.md) | Diagrams of every flow: service call, rewrite, streaming, errors, settings |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Building, testing, debugging, releasing |
| [AGENTS.md](AGENTS.md) | Rules for AI agents working in this repo |
| [docs/AGENTIC_DEVELOPMENT.md](docs/AGENTIC_DEVELOPMENT.md) | Guardrails, what to touch and not touch, and the change-impact map |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

## Credits

The build layout, test runner and parts of the app shell are adapted from [Finder Menu](https://github.com/nikgrbn/finder-menu) by nikgrbn (MIT).

## License

MIT. See [LICENSE](LICENSE).
