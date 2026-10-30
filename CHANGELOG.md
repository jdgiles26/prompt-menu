# Changelog

## Unreleased

- **Explain This for Me**, a sixth Services item: an in-depth explanation of the highlighted text or code, or of text and code files right-clicked in Finder (the first 8,000 characters), with the point first and the detail in short, easy-to-scan pieces. It has room for 2,048 tokens, or the setting if that's higher.
- In Explain dialogs the rewrite tools (Agentic Pattern, Fill Gaps, Add Project, the check, Review) are hidden.
- **Ask a follow-up** in every dialog: a small chat under the result that answers any question about the text and the result, with the conversation so far as context. It uses the same local model and is never saved.
- **Model menu** in the dialog: the models already on this Mac, MLX and GGUF, with their sizes. If the saved model was deleted, the dialog offers these instead of failing. Nothing is downloaded.
- **Fill Gaps…** answers `[CONFIRM: …]` questions in place, without a model, with an optional Polish pass.
- **Compare Models…** runs the draft with each ticked model, one at a time, after an estimate.
- **Review…** has the models judge the versions blind (shuffled, asked twice in reverse order, no votes for their own draft, the check as one more voter), then harden the winner as security, scope and verifiability reviewers. Only edits that keep the check score and every fact are kept. **Review Log** shows each step.
- **Add Project…** adds the headings and commands from a chosen folder's AGENTS.md, CLAUDE.md and README.
- llama.cpp: `--log-disable` is no longer passed; with `llama-completion` build 10470 it also hid the reply.
- Fixed: the check crashed on a prompt that repeats a heading (a model stuck in a loop).

## 0.3.0

- Three more Services items: **Rewrite as Bug Report**, **Rewrite as Code Review Request** and **Rewrite as Commit Message**, each with its own sections.
- **Rewrite as Agent Prompt (Replace Selection)** replaces the highlighted text with the prompt, with a small progress window and no dialog.
- The MLX model stays loaded for 5 minutes after use, so the next rewrite starts writing in under a second instead of about 10 (measured with Llama 3.2 3B). A menu-bar icon shows while it's loaded, with **Unload Model Now**. Set the time in settings or with `keepLoadedMinutes`; 0 turns it off. The worker talks to the app over a pipe, not the network, and exits with the app. If it can't start, the model runs once as before.
- **Agentic Pattern…** in the dialog restructures the prompt around a workflow from [Awesome Agentic Patterns](https://github.com/nibzard/awesome-agentic-patterns) (203 patterns, snapshot of commit 40359c7, Apache-2.0). It shortlists five, lets you search all of them, and, when the model is loaded, marks the one the model suggests.
- A **check** badge scores each result without a model: missing sections, facts dropped from your text, open `[CONFIRM: …]` questions, and whether DONE WHEN can be checked.
- **Versions**: every result in a dialog is kept (first draft, each pattern, your edits), and you can switch between them.
- Small models' "Here is the rewritten prompt:" first line is removed.
- Fixed: Try Again was greyed out while a model ran, although 0.2.0 said it could stop one.
- Fixed: closing the dialog in the moment before the runner started left the runner running.
- Fixed: a second dialog opened exactly on top of the first instead of offset from it.

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
