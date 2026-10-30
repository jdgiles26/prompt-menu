# Plan

Source: the request to fix rewrites failing on a deleted model (offer the models already on this Mac) and to build the unfinished items in [docs/FEATURE_FUTURE.md](docs/FEATURE_FUTURE.md).

## Phase 1: models and FEATURE_FUTURE

- [x] Round 1: model menu, deleted-model recovery, `localModels` discovery (MLX + GGUF, labeled by format)
- [x] Round 2: §1 Fill Gaps, §2 Compare Models, §5 Add Project
- [x] Round 3: §3 Review (jury, harden, Review Log), checked end to end with Qwen 2.5 3B and LFM2.5 1.2B through `llama-completion`
- [ ] Round 4: §4 Send to a coding agent's CLI. **Blocked:** see Open Questions.
- [ ] §6 smaller items: not started (keeping llama.cpp loaded needs per-version testing; mlx-swift needs Xcode, which the build rules exclude)
- [ ] Not committed yet (AGENTS.md rule 10: commit only when asked)

## Open Questions

- §4 writes a prompt file, a `.command` script and `harnesses.json` outside the repo and `local.promptmenu`. AGENTIC_DEVELOPMENT §6 says to ask first, and guardrail 2.1 says user text isn't written to disk. Allowed?
- ~~Model folders~~ Decided 2026-10-26: added to the user's own settings (`modelFolders`), not as code defaults. The app was set to MLX Gemma 12B, which doesn't fit in 8 GB and was the cause of failed rewrites; it now uses llama.cpp + `~/.kimi_openclaw/models/qwen2.5-3b-instruct-q4_k_m.gguf` (rewrite done in 8 s, check 81). Both Gemma 12B copies were deleted at the user's request.

## Found Along the Way

- An LFM2.5 1.2B first draft ended with "Reply with only the prompt:" (an echoed instruction). `cleanOutput` doesn't remove it.
- Manual UI check of Review not done by clicking through; the Core pipeline was run with real models instead.
