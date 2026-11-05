# Decisions

## 2026-10-30: The Explain style is an original built-in prompt

- **Chosen:** a built-in `explainPrompt` in `Style.swift` written for readers who lose focus in long paragraphs: TL;DR first, fixed sections, short bullets, bold key terms, jargon defined in place, guesses marked "(probably)".
- **Alternatives:** loading an "ADHD explain" Claude skill at run time; adapting a skill's text.
- **Why:** no such skill is installed on this Mac, the app has no network code, and a 3B local model follows a fixed outline far better than a long skill file. The user chose an original prompt.

## 2026-10-30: The follow-up chat re-sends the conversation each turn

- **Chosen:** `chatContext` packs the highlighted text, the current result and the turns so far into the **system prompt** (≤ `maxChatCharacters`, 12,000, in fixed shares: newest turns ≤ 3,000, result ≤ 3,000, the text in the rest); the question alone is the prompt. `answerFollowUp` runs it through the existing `rewrite` pipeline, and if `isNonAnswer` sees a refusal or an echo of the context, asks once more without the context.
- **Alternatives:** everything in one user message (tried first); dropping every turn before cutting the text (the first version: with an 8,000-character text and a long result, no turn fit, so the chat forgot everything); a chat session in the MLX worker; stronger prompt wording only.
- **Why:** the runners answer one prompt and exit, and a worker session would be MLX-only with state that outlives the dialog. With everything in one message, Qwen 2.5 3B echoed the context back on off-topic questions. Wording changes helped only some of the time (temperature 0.3); the fallback made 5 of 5 test questions get an answer. 12,000 characters stays within a small model's context on an 8 GB Mac.

## 2026-10-30: Explain This for Me accepts Finder files

- **Chosen:** `NSSendFileTypes` for plain text, source code, JSON and XML; `explainInput(files:)` reads only the chosen files, up to 8,000 characters, and rejects non-UTF-8 or NUL-containing data.
- **Alternatives:** highlighted text only.
- **Why:** the user asked for files too. Open question: whether macOS shows a privacy prompt for files in protected folders (see PLAN.md).

## 2026-10-30: What counts as no answer

- **Chosen:** precision over recall. `isNonAnswer` counts only clear cases: an apology, "can't answer", "unsure how to answer", "has no information/instructions/details", or "doesn't cover the question" in the first sentence (typographic apostrophes normalized); a context heading alone on its line; or the result returned unchanged. `answerFollowUp` also counts an earlier answer of 40+ characters repeated word for word for a different question. The chat prompt says to answer only what was asked and not to repeat or redo the result unless asked.
- **Alternatives:** any "the text/code doesn't contain/include/mention…" sentence, a 200-character copy of the context, any repeated answer (the earlier versions); a looser detector for the model redoing the explanation.
- **Why:** a false alarm throws away a right answer and asks again without the text, which gives a guess. The earlier rules did that to "The code doesn't include any error handling…", to an edited result in a rewrite dialog (it starts like the result), and to "No." given twice. Vague replies are rarer and visible. Redoing the explanation on an off-topic question was fixed in the prompt instead: with Qwen 2.5 3B, 3 of 3 "How do I make pancakes?" runs then got a recipe.

## 2026-11-05: A file macOS blocks is chosen by the user, with no new permission

- **Chosen:** detect `EPERM` or `EACCES` from `open()`, show a window that says so, and offer **Choose File…** (an `NSOpenPanel`). If that fails too, say how to use highlighted text, or that adding Full Disk Access is the user's call.
- **Alternatives:** asking for Full Disk Access (a permission, which AGENTS.md rule 3 rules out); going through another process or Apple Events to get around the block (Apple Events are ruled out, and it would defeat a protection the user is relying on); a stable signing identity (keeps grants across rebuilds, but `macl` already survived a rebuild here, and the ad-hoc signature is a project rule).
- **Why:** tccd logged `kTCCServiceSystemPolicyAppDataDetailed does not allow prompting; recording denied`, so macOS never asks and the app can't request it. Before the Open panel: `deny(1)`. After: the read works, the file has a `com.apple.macl` attribute, and it still works after a rebuild. Inferred from the logs and the attribute: Apple's documentation of this wasn't checked.

## 2026-11-05: A non-modal window for failures, not an alert

- **Chosen:** `FailurePanelController`, an ordinary window.
- **Alternatives:** `NSAlert.runModal` (the first version); only `error.pointee`.
- **Why:** with the alert up, SIGTERM didn't quit the app and another Services request failed with "didn't return pasteboard data in time". `error.pointee` isn't shown by Finder, which was the original bug.

## 2026-11-05: Code owns the agentic workflow; the model adds task details

- **Chosen:** `Workflow.swift` writes phases, gates, the work loop and shared rules, and keeps the draft's other sections. The model's reply is used only for each phase's details. Hand-written blueprints for 8 patterns, and one per catalog category for the other 195.
- **Alternatives:** stronger prompt wording; a repair pass with the model; parsing phases out of each pattern's catalog text; a hand-written blueprint for each of the 203 patterns.
- **Why:** with Qwen 2.5 3B, applying a pattern copied the draft's steps word for word and added one line, and scored 85. Catalog text often describes building such a system ("fine-tune that judge on its own traces") rather than applying it to a task, and only 76 of 203 have numbered steps. The cost: patterns in one category share phases, with only the `WORKFLOW PATTERN:` line, the model's details and the shared rules around them differing, so a fallback pattern is less distinct than a hand-written one. Add a blueprint when one matters.

## 2026-11-05: Explain is offered on text files only, including ones macOS doesn't know

- **Chosen:** `NSSendFileTypes` with the text types plus `public.text`, and `UTImportedTypeDeclarations` declaring `.toml`, `.sql`, `.env`, `.ini`, `.conf` and `.cfg` as plain text.
- **Alternatives:** `public.data`, tried first, which shows the item on every file, and only says "not text" after the click; the user asked not to have it on PDFs and PNGs. Listing `dyn.*` types, which are undocumented.
- **Why:** those extensions have only dynamic types, so without a declaration Finder wouldn't offer the item. The cost: files with no extension, and a file named exactly `.env`, have no extension to match, so they don't offer it; highlighted text still works for those.

## 2026-11-05: Explain This for Me takes anything, and describes what it can't quote

- **Chosen:** `public.item`, `public.data`, `public.content`, `public.folder` and `public.directory` in `NSSendFileTypes`, and `ItemDescription.swift`, which decides what an item is from its contents: folder layout and telling files, SQLite schema and samples (`immutable=1`, so nothing is written or locked), document text, decoded plist, archive listing, or a profile of type, details and fragments. Replaces the "text files only" entry above, at the user's request ("folders, non file extension saved files, .db files and any file and any folder").
- **Alternatives:** per-type declarations, which can't match a file with no extension; refusing after the click, which is what made `public.data` unwanted before; shelling out to `sqlite3`, when the system library can guarantee read-only and a time limit; OCR for images, left out for now because `file` gives the type and size, and it would be a new framework and a slower path.
- **Why:** a small text model can't use raw bytes, but can explain structure and names well. The checks are time and size limits rather than file-type rules, because these run while Finder waits. Files read automatically from a folder skip secret-looking names and private-key contents, and secret-looking database columns are hidden: the user chose the folder, not each file in it. A file chosen directly is read as chosen. The cost: the item is now on every Finder right-click, including PDFs and images, which reverses the earlier preference.

## 2026-11-05: Code repairs what a 3B model gets wrong in every built-in prompt

- **Chosen:** every built-in prompt was run on Qwen 2.5 3B (llama.cpp) and its replies read against what each item is for. What the model got wrong repeatably is repaired in code (`Finishing.swift`, `Workflow.swift`): limits the user stated ("dont touch the db schema") are added to CONSTRAINTS in the user's words; a "do not" line about nothing the user mentioned ("Do not modify any existing code") is dropped; CONSTRAINTS and DONE WHEN are one bullet per item; files, folders and numbers of two digits or more that the text never gave (`test/auth`, `charge_test.go`, "1800") get a `[CONFIRM: …]`; a RED phase's details can't expect success; a commit message loses "Subject:"/"Body:" labels and "Fix:", gets brackets on a bare CONFIRM, and a "Verified:" line from the notes; lines copied from the instructions go. The Commit Message prompt has an example, Code Review asks for specific checks, and Explain asks for real edge cases instead of generic advice.
- **Alternatives:** prompt wording only; a bigger default model; leaving the checker to flag problems.
- **Why:** wording alone was tried first. The commit message kept its labels until the example, and numbers were still invented with it. Code makes each repair certain and testable, and keeps the first draft as fast as it was. A bigger model doesn't fit 8 GB Macs. Measured after: Commit Message 3 of 3 runs right with check 100; Code Review lists specific checks and questions the test file it made up.
- **Not fixed, and why:** Qwen 2.5 3B still answers "what happens if `times` is 0?" wrongly (the force unwrap crashes) and Explain misses that crash, even with the new rules. That's the model's reasoning, not the prompt's shape; a larger model from the Model menu does better.

## 2026-11-05: The pattern suggestion stays MLX-only

- **Chosen:** the ★ suggestion still runs only with a kept-loaded MLX model; on llama.cpp the keyword and task-type order stands.
- **Alternatives:** a one-shot model run while the pattern list is open.
- **Why:** measured twice on this note ("fix the 500 on /signin, need a regression test"), Qwen 2.5 3B answered "C", Workflow Evals with Mocked Tools, over the shortlist's first pick, Spec-As-Test. A slower, worse pick isn't worth a second model in memory beside the one about to run.

## 2026-11-05: Reading Finder items happens off the main thread, with an overall limit

- **Chosen:** `readItems` reads on a background queue behind a small "Reading …" window, and gives up after 45 s with a message (`slowRead`). The app doesn't quit while it reads.
- **Alternatives:** time limits inside PDFKit and every read (PDFKit has none to set).
- **Why:** a hung read can't be cancelled, but it no longer freezes the app; its late result is ignored.

## 2026-11-05: Images are explained by their text, read on the Mac

- **Chosen:** Vision's text recognition (`VNRecognizeTextRequest`), which runs on the device, plus the image's size in pixels.
- **Alternatives:** type and size only (before); a vision model.
- **Why:** the text model can't see pictures, and a screenshot's text (an error, a scanned page) is what most people want explained. Vision needs no permission or entitlement and no network.

## 2026-11-05: Send To hands the prompt over by the clipboard, not a file

- **Chosen:** **Open in …** puts the prompt on the clipboard and opens a `.command` script in Terminal that holds only `cd` to the folder and the CLI's command, with `"$(pbpaste)"` as the prompt argument, and deletes itself first thing. **Copy Command** single-quotes the prompt as one word. CLIs are data (`Harness`: program, arguments, one `{prompt}`); four defaults, each checked against that CLI's docs on this date (`claude [prompt]` from `claude --help` 2.1.318, `codex [PROMPT]`, `gemini -i`, `aider --message`); users add or override them in `harnesses.json`, which the app reads and never writes.
- **Alternatives:** the FEATURE_FUTURE design (prompt in a temp file read with `cat {prompt_file}`); scripting Terminal with Apple Events; running the CLI as a child process.
- **Why:** guardrail 2.1 says the user's text isn't written to disk, which a temp file would break, even briefly. Apple Events need a permission (rule 3). An agent CLI is interactive and needs a terminal, and running one headless would let it act where the user can't watch. The clipboard is overwritten, as Copy already does; the script reads it within a second of opening. Codex's own `--help` crashed on this Mac (a broken install), so its flags come from its source and docs.

