# Plan

Source: the request to fix rewrites failing on a deleted model (offer the models already on this Mac) and to build the unfinished items in [docs/FEATURE_FUTURE.md](docs/FEATURE_FUTURE.md).

## Phase 1: models and FEATURE_FUTURE

- [x] Round 1: model menu, deleted-model recovery, `localModels` discovery (MLX + GGUF, labeled by format)
- [x] Round 2: §1 Fill Gaps, §2 Compare Models, §5 Add Project
- [x] Round 3: §3 Review (jury, harden, Review Log), checked end to end with Qwen 2.5 3B and LFM2.5 1.2B through `llama-completion`
- [x] Round 4: §4 Send to a coding agent's CLI. Built in Phase 6, round 2.
- [x] §6 smaller items: done in Phase 6, round 3, except keeping llama.cpp loaded (measured, not worth it) and mlx-swift (needs Xcode)
- [x] Committed (778afdc)

## Phase 2: Explain This for Me and the follow-up chat

Source: the request for a right-click "Explain this for me" item in an ADHD-friendly style (text, code and Finder files), and a small chat under every dialog's result that answers any follow-up with the dialog's context.

- [x] Round 1: `Style.explain`, original built-in explain prompt, `explainInput(files:)`, plist entry with `NSSendFileTypes`, `explainThisForMe` in Service.swift, checker skips dropped facts for explain
- [x] Round 2: `Chat.swift` (`ChatTurn`, `chatSystemPrompt`, `chatContext`, `maxChatCharacters`, `isNonAnswer`, `answerFollowUp`). Checked with Qwen 2.5 3B through `llama-completion`: explain check 100 in 21–25 s; 5 of 5 follow-ups answered in 6–12 s, including off-topic ones via the fallback
- [x] Round 3: chat area and `askQuestion` in ResultPanel (one model run per dialog kept), Explain hides the rewrite tools, docs
- [x] Review (torvalds-doctrine) and fixes, each with a failing test first: fixed context shares so a long text can't wipe the conversation; a `Stopper` so Close stops the fallback run too; `isNonAnswer` no longer flags "The result: 3"; `explainInput` trims bytes only where the read stopped and stops reading once full; an earlier answer repeated for a new question counts as no answer. Real-model check: an 8,000-character file explained in 22 s (check 100), three follow-ups in 7–8 s each, "Canberra" answered, and a fact from two turns back recalled
- [x] /code-review findings fixed, failing test first where Core: non-answers counted precisely (right answers like "The code doesn't include any error handling", an edited result and a repeated "No." are kept; curly-apostrophe refusals are caught); the chat prompt says not to redo the result; llamafile labels follow-ups "Question" and explanations "Text to explain" (rewrites unchanged); `explainInput` reads with the throwing `read(upToCount:)`; after a failed run the chat uses the last working version and Copy stays off; Review… and the check score are hidden for explanations. Real model: an on-topic "No, …" kept 3 of 3, pancakes answered 3 of 3, an edit request applied, Canberra answered
- [x] Manual checks 13 and 14 in DEVELOPMENT.md: the chat and Explain dialogs were clicked through in Phase 6, round 4
- [x] Committed as phase2-round1 to round3

## Phase 3: Finder Explain fix and real agentic workflows

Source: the request to review the service, permanently fix Explain This for Me from a right-click on a file in a Finder folder, and harden agentic rewrites, which "lacked true agentic workflow rewrites".

Evidence (2026-11-05): three right-clicks on `~/Library/Group Containers/group.com.docker/unleash-v2-docker-desktop.json` each logged `System Policy: PromptMenu deny(1) file-read-data`, and tccd logged `kTCCServiceSystemPolicyAppDataDetailed does not allow prompting; recording denied`. The read failed, the service only set `error.pointee`, which Finder never shows, and the 0.5 s launch timer opened Settings. Baseline with Qwen 2.5 3B: applying a pattern copied the draft's STEPS word for word, added one `WORKFLOW PATTERN:` line, and scored 85.

- [x] Round 1: Every Explain failure opens a dialog; protected files get a macOS-mediated Choose File path; a Services launch never opens Settings; empty and UTF-16 files; item offered on more text files (not PDFs or images, at the user's request)
- [x] Round 2: `install.sh` stops the old process and unregisters the build copy, so Services can't run stale code
- [x] Round 3: `Workflow.swift`: code-owned phases and gates for all 203 patterns, the model fills in task details; drafts get a work loop and every section; no fact dropped; the check scores workflow gaps; task-type shortlist
- [x] Round 4: Docs, real-model before and after, install, cold-launch check
- [x] Committed, at the user's request
- [x] A blocked file, start to finish: watched in Phase 6, round 4 (failure window, Choose…, the picker, the explanation; the grant held for the next request). Sent through Services rather than a right-click

## Phase 4: Explain anything from Finder

Source: the request that Explain This for Me run on "folders, non file extension saved files, .db files and any file and any folder".

- [x] Round 1: tests first (`ItemDescriptionTests`, reversed assertions marked with why), `ItemDescription.swift`, shared limit in `explainInput`, plist types, Choose… takes folders, prompt rule
- [x] Round 2: real checks. Finder menu shows the item on a folder, `.db`, no-extension text, no-extension SQLite and a binary; a real click on `shop.db` reached the model with its schema. Qwen 2.5 3B explained a folder (21 s), a database (11 s) and `/bin/ls` (25 s). `~` and `/` were described in about 1.2 s
- [x] The result dialog for these items seen on screen: done in Phase 6, round 4 (a folder, an image and a blocked JSON file)
- [x] Round 3: README, ARCHITECTURE and FLOW_MAPS rewritten around what the app does, how, its benefits, assets and privacy, with flows 19 to 23
- [x] Committed and pushed to main, at the user's request

## Phase 5: CI green on macos-15

Source: the user's OK to fix the compile error at `ModelsSheet.swift:42`, which failed CI's Build step on macos-15 in runs 41114695811 and 42075242383.

- [x] Round 1: the buttons get their own `[NSButton]` type before becoming the stack view's `[NSView]`. The local Swift 6.4 never hit this error, so CI's macos-15 job is the test

## Phase 6: every known issue fixed, every built-in prompt checked

Source: "fix all the known issues, bugs and ensure the built in prompts for each step and feature are functioning as i have stated i want them to work". What was stated: Explain in depth, in the easy-to-scan style, on any file or folder, with a chat that answers every follow-up; agentic rewrites that are real workflows; models found on the Mac, not hardcoded; every FEATURE_FUTURE item built.

- [x] Round 1: every built-in prompt run on Qwen 2.5 3B (draft, each style, pattern, suggestion, chat); repairs in code with tests from those replies (stated and invented limits, bullets, invented names and numbers, RED vs gate, commit message shape, echoed instructions, SCOPE); prompt changes for Commit Message, Code Review, Explain and the chat; chat edits become a version; image text via Vision; Finder reading off the main thread with a limit; out-of-memory message; Explain spinner position; chat transcript cached
- [x] Round 2: FEATURE_FUTURE §4 Send To: `Harness.swift` (defaults checked against each CLI's docs, `harnesses.json`, detection, Terminal script, Copy Command, recent folders), the Send To… menu. A generated script opened in Terminal through `NSWorkspace` and deleted itself (checked with `/usr/bin/true` as the CLI)
- [x] Round 3: FEATURE_FUTURE §6: whole-catalog pick for ~7B models (`pickPattern`, tested with a stand-in; no 7B model here), CI catalog-age warning. Not built, with reasons in DECISIONS: keeping llama.cpp loaded (measured: under 1 s to gain), mlx-swift (needs Xcode, rule 4)
- [x] Round 4: checked in the installed app through the real Services path (`NSPerformService`, because Finder's menus closed when Terminal took focus): Explain on an image, a folder and a blocked file with Choose…; the chat; a chat edit becoming a version; a pattern; Send To's menu, recent folders and Copy Command (dry-run with a stand-in `claude`); Commit Message. Fixed what that showed, test first: Vision's 30–43 s first use (now `.fast`), a long status widening every tabbed dialog off screen, a feature task getting a poor shortlist, the pattern reply filling 0 of 4 phases, and bullets run together in Explain. Not done: starting a real agent CLI (it would send the prompt to that CLI's servers), and the context menu itself, which closed before it could be clicked

- [x] Round 5: the user's model moved out of other apps' folders: the two GGUFs hard-linked into `~/models` (a default search folder; same files, no extra space), the `model` setting pointed there and `modelFolders` emptied, so Settings no longer shows `.kimi_openclaw` or `Meeting-prompter-v2`. That showed a bug: the dialog's model menu showed the first model, not the one in use. Fixed and seen in the app

- [x] Round 6: final recorded walkthrough of every feature on a clean screen (Settings and the model list, Explain on an image and a folder with a follow-up, an agent prompt with a chat edit, a pattern and Send To, Bug Report, Code Review Request, Commit Message). Fixed, test first, what it showed: a stated limit cut at the dot in `notes.json`, and a lone bullet left on its heading's line

## Open Questions

- ~~Does macOS show a privacy prompt for Explain on a Finder file?~~ Answered 2026-11-05 for another app's folder: no prompt, a silent denial; see Phase 3 and docs/DECISIONS.md. ~/Documents, ~/Desktop and ~/Downloads weren't tested; the same window and Choose File handle a denial there.

- ~~§4 writes a prompt file… Allowed?~~ Decided 2026-11-05 when the user asked to finish development: no prompt file. The prompt goes by the clipboard; the `.command` script holds only the folder and command and deletes itself; `harnesses.json` is read, never written.
- ~~Model folders~~ Decided 2026-10-26: added to the user's own settings (`modelFolders`), not as code defaults. The app was set to MLX Gemma 12B, which doesn't fit in 8 GB and was the cause of failed rewrites; it now uses llama.cpp + `~/.kimi_openclaw/models/qwen2.5-3b-instruct-q4_k_m.gguf` (rewrite done in 8 s, check 81). Both Gemma 12B copies were deleted at the user's request.

## Found Along the Way

- ~~Images get only type, size and dimensions.~~ Phase 6: their text is read with Vision; what they show otherwise still can't be seen.
- A walk from a home folder can touch ~/Documents, ~/Desktop and similar. Tested from this app's harness and through a Services launch of other folders, but not a Services launch on `~` itself, so whether macOS asks or blocks there is unverified. Blocked subfolders are marked in the layout.
- Finder only flattens Services into the context menu's top level when there are few, so its position varies. That's macOS behavior.

- ~~Files with no extension don't offer Explain in Finder.~~ Fixed in Phase 4.
- ~~AGENTS.md says "five Services items".~~ Fixed in Phase 4.
- ~~PDFKit opening a file and reads from a slow disk have no time limit, and `explainThisForMe` waits for them on the main thread.~~ Fixed in Phase 6: read off the main thread, 45 s limit.
- ~~`Prompt Menu.dmg` in the repo root holds old code.~~ Removed at the user's request (it's gone from the repo root).
- The app was installed at 13:05 on Oct 30, before the phase2-round4 commit (13:53), so those fixes never reached Services until this phase's install.
- `suggestPattern` (the ★) only runs with a kept-loaded MLX model. Kept that way on purpose in Phase 6: Qwen 2.5 3B picked worse than the keyword order (docs/DECISIONS.md).
- ~~A phase's details can contradict its gate (RED "ensure it passes").~~ Fixed in Phase 6.
- ~~The model can invent a limit such as "Do not modify any existing code".~~ Fixed in Phase 6: dropped when it's about nothing the user mentioned.

- FLOW_MAPS' table of contents was missing flow 16 (Review); added with 17 and 18.
- ~~Asked to change one line, Qwen 2.5 3B returns only the changed section; the user copies it by hand.~~ Fixed in Phase 6: merged into a new version.
- ~~The transcript is rebuilt whole on every streamed chunk, and its format is written twice.~~ Fixed in Phase 6.
- ~~A Metal out-of-memory failure shows only as exit code 1.~~ Fixed in Phase 6.
- ~~In Explain dialogs the spinner sits after the hidden Add Project button.~~ Fixed in Phase 6.
- Qwen 2.5 3B sometimes answers a follow-up wrongly rather than not at all (asked to repeat a number from an earlier answer that had none, it said "1"). The guard catches non-answers, not wrong answers.

- ~~An echoed "Reply with only the prompt:" isn't removed.~~ Fixed in Phase 6.
- Manual UI check of Review not done by clicking through; the Core pipeline was run with real models instead.
