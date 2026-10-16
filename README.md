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
- ⚡ **Fast repeats.** The MLX model stays loaded for 5 minutes after use, so the next rewrite starts writing in under a second instead of about 10.
- 🧭 **Agentic patterns.** One click restructures the prompt around a proven workflow from [Awesome Agentic Patterns](https://github.com/nibzard/awesome-agentic-patterns), such as Plan-Then-Execute or Spec-As-Test.
- ✅ **A built-in check.** Each result gets a score for missing sections, facts dropped from your text, open questions and a checkable finish, with no model involved.
- 🪶 **Small.** Swift built with the Command Line Tools. No Xcode project, no dependencies.

## The Services items

| Item | What you get |
|---|---|
| **Rewrite as Agent Prompt** | ROLE · OBJECTIVE · CONTEXT · STEPS · CONSTRAINTS · DONE WHEN, in a dialog |
| **Rewrite as Bug Report** | TITLE · SUMMARY · STEPS TO REPRODUCE · EXPECTED · ACTUAL · ENVIRONMENT · SCOPE |
| **Rewrite as Code Review Request** | CHANGE · CONTEXT · REVIEW FOCUS · OUT OF SCOPE · TESTING · DONE WHEN |
| **Rewrite as Commit Message** | An imperative subject of at most 72 characters, and a body that says what and why |
| **Rewrite as Agent Prompt (Replace Selection)** | The agent prompt, replacing the highlighted text directly, with no dialog. A small window shows progress. |

## The dialog

- **Versions.** Every result is kept: `1 · First draft`, `2 · Plan-Then-Execute Pattern`, `3 · Edited`… Pick any of them from the menu at the top left. Your edits are saved as their own version before a pattern is applied.
- **Check.** The badge shows a score out of 100 and the number of `[CONFIRM: …]` questions. Click it for the list of problems.
- **Agentic Pattern…** Shows the five patterns that best fit the prompt, plus a search over all of them. If the model is already loaded, it suggests one (★). **Apply** rewrites the current text around that workflow, adding a `WORKFLOW PATTERN: …, because …` line, and keeps everything else as a new version.
- **Try Again** repeats the last step: the first draft, or the last pattern. **Copy** (⌘↩) copies the text as shown, edits included.

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

**Which model?** On an 8 GB Mac, a 3B–4B instruct model at 4-bit (about 2 GB) is the practical size. Measured with Llama 3.2 3B: the first rewrite starts writing after about 10 seconds, and while the model stays loaded the next one starts in under a second; a full prompt takes 7–15 seconds. With 16 GB or more, 7B–9B models follow the outline, and pick patterns, noticeably better.

**Keeping the model loaded.** With MLX, the model stays in memory for 5 minutes after each use (about 2 GB for a 3B model) and a menu-bar icon shows while it's loaded. Click it to see the time left or choose **Unload Model Now**; Prompt Menu quits once nothing is open and the model is unloaded. Set the time in settings, or 0 to unload right after each rewrite. llamafile and llama.cpp always run once per rewrite.

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
defaults write local.promptmenu systemPrompt "Rewrite the text as …"   # empty = built-in agent prompt
defaults write local.promptmenu keepLoadedMinutes -int 5                # 0–120; 0 = unload right away (MLX)
```

`systemPrompt` replaces the instructions for **Rewrite as Agent Prompt** and Replace Selection only; the other styles keep theirs.

## Privacy

- No network code: the build's tests scan `Sources/` for networking APIs and URLs, and the MLX worker script for network and download calls.
- No entitlements, no permissions requested, no telemetry, no logs of your text.
- Your text goes to the runner as a command-line argument, or to the kept-loaded MLX worker through a pipe that only Prompt Menu holds. It stays on this Mac. The worker exits when Prompt Menu does.
- The model stays in memory only for the keep-loaded time (5 minutes by default, 0 to turn it off). Then Prompt Menu quits if nothing is open.
- The pattern catalog is built into the app. Nothing is fetched.

## Documentation

| Doc | For |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it's built: modules, types, decisions |
| [docs/FLOW_MAPS.md](docs/FLOW_MAPS.md) | Diagrams of every flow: service call, rewrite, streaming, errors, settings |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Building, testing, debugging, releasing |
| [AGENTS.md](AGENTS.md) | Rules for AI agents working in this repo |
| [docs/AGENTIC_DEVELOPMENT.md](docs/AGENTIC_DEVELOPMENT.md) | Guardrails, what to touch and not touch, and the change-impact map |
| [docs/FEATURE_FUTURE.md](docs/FEATURE_FUTURE.md) | Designed but not built yet: comparing models, a multi-model review pipeline, a fill-the-gaps wizard, sending to an agent CLI |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

## Credits

The build layout, test runner and parts of the app shell are adapted from [Finder Menu](https://github.com/nikgrbn/finder-menu) by nikgrbn (MIT).

The agentic patterns are from [Awesome Agentic Patterns](https://github.com/nibzard/awesome-agentic-patterns) by Nikola Balic and contributors, used under the Apache License 2.0. `Resources/patterns.json` contains their titles, metadata and an excerpt of each Solution section; see `Resources/NOTICE-agentic-patterns.txt`.

## License

MIT. See [LICENSE](LICENSE).
