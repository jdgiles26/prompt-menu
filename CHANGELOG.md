# Changelog

## 0.2.0

- The prompt streams into the dialog as the model writes it, with a seconds counter while the model loads.
- Try Again stops a model that's still running before starting a new one.
- The settings window shows whether the runner program was found, and re-checks as you type a path.
- Custom instructions: `defaults write local.promptmenu systemPrompt "…"`. Leave it empty for the built-in prompt.
- Max tokens and temperature are kept within safe ranges.
- Fixed: quitting the app (⌘Q, logout, SIGTERM) while a model ran left the runner running in the background.
- Fixed: a runner that left a child process holding its output open could keep the dialog waiting forever.
- Tests that enforce the project's promises: no network code, no entitlements, and docs that list every runner.
- Docs: architecture, flow maps, development guide, and rules for AI agents (`AGENTS.md`).

## 0.1.0

- Services → Rewrite as Agent Prompt, using MLX, llamafile or llama.cpp as a local runner.
