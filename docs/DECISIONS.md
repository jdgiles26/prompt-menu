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
