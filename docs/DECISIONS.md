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

- **Chosen:** `isNonAnswer` looks only at the first sentence for refusals ("I'm sorry", "can't answer", "the text doesn't contain/mention/cover…"), treats a context heading alone on its line or a 200-character verbatim copy as an echo, and `answerFollowUp` also counts an earlier answer repeated word for word for a different question.
- **Alternatives:** any line copied from the context (the first version), any heading at a line start.
- **Why:** each was seen with Qwen 2.5 3B. The first version flagged a correct answer that quoted one line of the code, and "The result: 3" is an answer. Quoting the text is what an explanation does, so only long copies count.
