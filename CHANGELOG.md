# Changelog

## Unreleased

- Fixed: the dialog's model menu could show the first model on the list instead of the one in use (the popup ticked its own pick after the menu was rebuilt). It showed whenever the current model wasn't first alphabetically.
- **Agentic patterns fill their phases with your task.** For an agent prompt the model is asked for one line per phase, not the whole prompt, so it can't just copy the old list; code it writes and bare names are dropped. Building something ("add", "implement"…) now offers Spec-As-Test (when tests are asked for) or Plan-Then-Execute first.
- Explanations put each bullet on its own line when the model runs them together.
- Image text is read with Vision's fast mode: the accurate one spent about 40 s getting ready the first time.
- The dialog is a little wider, and a long status or version name no longer widens it (tabbed dialogs share one width).
- With a kept-loaded model of about 7B or more, the ★ pattern suggestion chooses from all 203 patterns, in two steps.
- CI warns when the pattern catalog is more than 180 days old.
- **Send To…** in rewrite dialogs starts Claude Code, Codex, Gemini CLI or Aider (whichever are installed) in Terminal, in a folder you pick, with the prompt. Or **Copy Command** for any terminal. Add other CLIs in `harnesses.json`. The prompt goes by the clipboard and is never written to disk.
- **Every built-in prompt checked against a real model, and repaired in code where it fell short.** Agent prompts keep every limit you stated and drop limits the model made up; CONSTRAINTS and DONE WHEN are proper bullet lists. Files, folders and numbers your text never gave get a `[CONFIRM: …]` instead of passing as facts. Commit messages lose "Subject:", "Body:" and "Fix:" labels and get their "Verified:" line from your notes. A RED phase can no longer say its tests pass. Code Review asks for specific checks, and Explain for real edge cases rather than generic advice.
- **An edit asked for in the chat becomes a new version**, whole, even when the model returns only the changed section.
- **Images are explained by their text**, read on this Mac, plus their size in pixels.
- Explain reads Finder items off the main thread behind a "Reading …" window, and gives up with a message after 45 s instead of freezing.
- A model that runs out of memory says so, instead of only "exit code 1".
- The bug report's check looks for its SCOPE section too.
- **Explain This for Me works on any file and any folder.** It's offered on everything in Finder, including folders, files with no extension and `.db` files. Folders are described by their layout, totals and telling files such as the README. SQLite databases, found by their contents, by their tables, columns, row counts and a few sample rows. PDFs, RTF and Word files by their text, binary plists decoded, archives by what's inside, and any other file by its type, details and readable fragments. It only reads, puts time limits on folders, databases and system tools, and leaves databases untouched. From a folder it never reads secret-looking files or private keys, and secret-looking database columns are hidden. Several selected items now share the size limit.
- The window for a blocked item now says **Choose…** and accepts folders too.
- The README, ARCHITECTURE and FLOW_MAPS now explain what the app does, how it works, its benefits and assets, and its privacy promises and limits, with new diagrams for the whole app, each kind of Finder item and where data goes.
- Fixed: the app didn't compile on macOS 15's toolchain (`ModelsSheet.swift`, "ambiguous use of operator '+'"), which had kept CI red since at least Oct 30.
- **Fixed: Explain This for Me on a file in a Finder folder could seem to do nothing, or open Settings.** macOS blocks reading some files without asking, such as those in another app's folder under `~/Library/Group Containers`. The failure went to an error string that Finder doesn't show, and then Settings opened. Now every failed request opens a window that says why, and a blocked file offers **Choose File…**, which lets macOS allow that file. A launch for a Service never opens Settings.
- Explain This for Me is offered on more text files in Finder: anything macOS knows as text (HTML, YAML…), plus `.toml`, `.sql`, `.env`, `.ini`, `.conf` and `.cfg`, which the app now declares as text. PDFs, images and other binary files don't offer it. It also reads UTF-16 text, and says when a file is empty instead of having the model make something up.
- **Agentic rewrites are real workflows.** Applying a pattern used to copy the draft's steps and add the pattern's name. Now the app builds the workflow itself: phases with a gate after each, for all 203 patterns, with the model adding only the task's details, so a poor reply still gives a working workflow. The status says when the model added details to only some phases.
- **Rewrite as Agent Prompt** always gives all six sections and a work loop (check each step, up to 3 attempts, then stop and report). The original request is repeated and takes priority, so limits the model drops or invents can't change the task, and no name or number is lost. A custom `systemPrompt` keeps its own format. Replace Selection gets the same treatment.
- **The check** also scores what an agent needs to work alone: a check of each step, a way to recover from a failure, and a point to stop (5 each), and a named pattern with no gated phases (15).
- **Agentic Pattern…** offers workflows suited to the kind of task (a bug fix, a migration, research, a review) first.
- `scripts/install.sh` quits the running copy, which would otherwise keep answering Services with its old code, and unregisters `build/`'s copy.
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
