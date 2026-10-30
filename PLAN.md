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
- [ ] Manual checks 13 and 14 in DEVELOPMENT.md: the UI isn't clicked through yet (the real-model runs above went through the Core pipeline, not the dialog)
- [x] Committed as phase2-round1 to round3

## Open Questions

- Explain This for Me on a Finder file in ~/Documents, ~/Desktop or ~/Downloads: does macOS show a privacy prompt for this unsandboxed app? Unverified. If it does, AGENTIC_DEVELOPMENT §6 says stop and ask; the fallback is text only.

- §4 writes a prompt file, a `.command` script and `harnesses.json` outside the repo and `local.promptmenu`. AGENTIC_DEVELOPMENT §6 says to ask first, and guardrail 2.1 says user text isn't written to disk. Allowed?
- ~~Model folders~~ Decided 2026-10-26: added to the user's own settings (`modelFolders`), not as code defaults. The app was set to MLX Gemma 12B, which doesn't fit in 8 GB and was the cause of failed rewrites; it now uses llama.cpp + `~/.kimi_openclaw/models/qwen2.5-3b-instruct-q4_k_m.gguf` (rewrite done in 8 s, check 81). Both Gemma 12B copies were deleted at the user's request.

## Found Along the Way

- FLOW_MAPS' table of contents was missing flow 16 (Review); added with 17 and 18.
- With llamafile, `combinedPrompt` labels the user's part "Text to rewrite:", so a follow-up question goes in under that label too. Not changed (it's shared with every style); worth a neutral label later.
- A Metal out-of-memory failure during a run (seen once, transient, at 74% free memory afterwards) shows as "The model runner stopped with exit code 1" plus the log tail. A plainer message for out-of-memory would help on 8 GB Macs.
- In Explain dialogs the spinner keeps its place after the hidden Add Project button, so it sits a little to the right. Cosmetic.
- Qwen 2.5 3B sometimes answers a follow-up wrongly rather than not at all (asked to repeat a number from an earlier answer that had none, it said "1"). The guard catches non-answers, not wrong answers.

- An LFM2.5 1.2B first draft ended with "Reply with only the prompt:" (an echoed instruction). `cleanOutput` doesn't remove it.
- Manual UI check of Review not done by clicking through; the Core pipeline was run with real models instead.
