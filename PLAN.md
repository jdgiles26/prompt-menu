# Plan

Source: the request to fix rewrites failing on a deleted model (offer the models already on this Mac) and to build the unfinished items in [docs/FEATURE_FUTURE.md](docs/FEATURE_FUTURE.md).

## Phase 1: models and FEATURE_FUTURE

- [x] Round 1: model menu, deleted-model recovery, `localModels` discovery (MLX + GGUF, labeled by format)
- [x] Round 2: §1 Fill Gaps, §2 Compare Models, §5 Add Project
- [x] Round 3: §3 Review (jury, harden, Review Log), checked end to end with Qwen 2.5 3B and LFM2.5 1.2B through `llama-completion`
- [ ] Round 4: §4 Send to a coding agent's CLI. **Blocked:** see Open Questions.
- [ ] §6 smaller items: not started (keeping llama.cpp loaded needs per-version testing; mlx-swift needs Xcode, which the build rules exclude)
- [x] Committed (778afdc)

## Phase 2: Explain This for Me and the follow-up chat

Source: the request for a right-click "Explain this for me" item in an ADHD-friendly style (text, code and Finder files), and a small chat under every dialog's result that answers any follow-up with the dialog's context.

- [x] Round 1: `Style.explain`, original built-in explain prompt, `explainInput(files:)`, plist entry with `NSSendFileTypes`, `explainThisForMe` in Service.swift, checker skips dropped facts for explain
- [x] Round 2: `Chat.swift` (`ChatTurn`, `chatSystemPrompt`, `chatContext`, `maxChatCharacters`, `isNonAnswer`, `answerFollowUp`). Checked with Qwen 2.5 3B through `llama-completion`: explain check 100 in 21–25 s; 5 of 5 follow-ups answered in 6–12 s, including off-topic ones via the fallback
- [x] Round 3: chat area and `askQuestion` in ResultPanel (one model run per dialog kept), Explain hides the rewrite tools, docs
- [x] Review (torvalds-doctrine) and fixes, each with a failing test first: fixed context shares so a long text can't wipe the conversation; a `Stopper` so Close stops the fallback run too; `isNonAnswer` no longer flags "The result: 3"; `explainInput` trims bytes only where the read stopped and stops reading once full; an earlier answer repeated for a new question counts as no answer. Real-model check: an 8,000-character file explained in 22 s (check 100), three follow-ups in 7–8 s each, "Canberra" answered, and a fact from two turns back recalled
- [x] /code-review findings fixed, failing test first where Core: non-answers counted precisely (right answers like "The code doesn't include any error handling", an edited result and a repeated "No." are kept; curly-apostrophe refusals are caught); the chat prompt says not to redo the result; llamafile labels follow-ups "Question" and explanations "Text to explain" (rewrites unchanged); `explainInput` reads with the throwing `read(upToCount:)`; after a failed run the chat uses the last working version and Copy stays off; Review… and the check score are hidden for explanations. Real model: an on-topic "No, …" kept 3 of 3, pancakes answered 3 of 3, an edit request applied, Canberra answered
- [ ] Manual checks 13 and 14 in DEVELOPMENT.md: the UI isn't clicked through yet (the real-model runs above went through the Core pipeline, not the dialog)
- [x] Committed as phase2-round1 to round3

## Phase 3: Finder Explain fix and real agentic workflows

Source: the request to review the service, permanently fix Explain This for Me from a right-click on a file in a Finder folder, and harden agentic rewrites, which "lacked true agentic workflow rewrites".

Evidence (2026-11-05): three right-clicks on `~/Library/Group Containers/group.com.docker/unleash-v2-docker-desktop.json` each logged `System Policy: PromptMenu deny(1) file-read-data`, and tccd logged `kTCCServiceSystemPolicyAppDataDetailed does not allow prompting; recording denied`. The read failed, the service only set `error.pointee`, which Finder never shows, and the 0.5 s launch timer opened Settings. Baseline with Qwen 2.5 3B: applying a pattern copied the draft's STEPS word for word, added one `WORKFLOW PATTERN:` line, and scored 85.

- [x] Round 1: Every Explain failure opens a dialog; protected files get a macOS-mediated Choose File path; a Services launch never opens Settings; empty and UTF-16 files; item offered on more text files (not PDFs or images, at the user's request)
- [x] Round 2: `install.sh` stops the old process and unregisters the build copy, so Services can't run stale code
- [x] Round 3: `Workflow.swift`: code-owned phases and gates for all 203 patterns, the model fills in task details; drafts get a work loop and every section; no fact dropped; the check scores workflow gaps; task-type shortlist
- [x] Round 4: Docs, real-model before and after, install, cold-launch check
- [x] Committed, at the user's request
- [ ] Finder right-click on a blocked file, start to finish, confirmed by the user. Choose File's grant was seen in the logs from one click during testing; the whole flow hasn't been watched

## Open Questions

- ~~Does macOS show a privacy prompt for Explain on a Finder file?~~ Answered 2026-11-05 for another app's folder: no prompt, a silent denial; see Phase 3 and docs/DECISIONS.md. ~/Documents, ~/Desktop and ~/Downloads weren't tested; the same window and Choose File handle a denial there.

- §4 writes a prompt file, a `.command` script and `harnesses.json` outside the repo and `local.promptmenu`. AGENTIC_DEVELOPMENT §6 says to ask first, and guardrail 2.1 says user text isn't written to disk. Allowed?
- ~~Model folders~~ Decided 2026-10-26: added to the user's own settings (`modelFolders`), not as code defaults. The app was set to MLX Gemma 12B, which doesn't fit in 8 GB and was the cause of failed rewrites; it now uses llama.cpp + `~/.kimi_openclaw/models/qwen2.5-3b-instruct-q4_k_m.gguf` (rewrite done in 8 s, check 81). Both Gemma 12B copies were deleted at the user's request.

## Found Along the Way

- Files with no extension (`Makefile`, a file named exactly `.env`) don't offer Explain in Finder: there's no extension to declare as text and `public.data` would bring PDFs and images back. Highlighted text works for them.
- AGENTS.md says "five Services items"; there are six since Explain. Not changed in Phase 3.
- `Prompt Menu.dmg` in the repo root (untracked, Oct 30) holds code from before this phase. Mounting or installing from it brings the old behavior back. No script builds it.
- The app was installed at 13:05 on Oct 30, before the phase2-round4 commit (13:53), so those fixes never reached Services until this phase's install.
- `suggestPattern` (the ★) only runs with a kept-loaded MLX model, so on llama.cpp, the current backend here, the keyword and task-type order is all there is.
- With a qwen2.5 3B reply, a phase's details can contradict its gate ("run the new test to ensure it passes" under RED, whose gate says it fails). The gate is still there; the checker doesn't compare them.
- The model can still invent a limit such as "Do not modify any existing code". The original request now takes priority over it in the prompt's own words, but the line stays.

- FLOW_MAPS' table of contents was missing flow 16 (Review); added with 17 and 18.
- Asked to change one line in a rewrite dialog, Qwen 2.5 3B returns only the changed section, not the whole result the chat prompt asks for. It's an answer, so it's kept; the user copies the section by hand.
- The transcript is rebuilt whole on every streamed chunk, and the "You:/Assistant:" format is written in Chat.swift and ResultPanel.swift. Unmeasured; only matters for long chats.
- A Metal out-of-memory failure during a run (seen once, transient, at 74% free memory afterwards) shows as "The model runner stopped with exit code 1" plus the log tail. A plainer message for out-of-memory would help on 8 GB Macs.
- In Explain dialogs the spinner keeps its place after the hidden Add Project button, so it sits a little to the right. Cosmetic.
- Qwen 2.5 3B sometimes answers a follow-up wrongly rather than not at all (asked to repeat a number from an earlier answer that had none, it said "1"). The guard catches non-answers, not wrong answers.

- An LFM2.5 1.2B first draft ended with "Reply with only the prompt:" (an echoed instruction). `cleanOutput` doesn't remove it.
- Manual UI check of Review not done by clicking through; the Core pipeline was run with real models instead.
