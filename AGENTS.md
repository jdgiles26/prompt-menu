# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, Copilot and others) working in this repository. Humans are welcome to read it too.

**Read [docs/AGENTIC_DEVELOPMENT.md](docs/AGENTIC_DEVELOPMENT.md) before changing anything.** It has the full guardrails, the touch and don't-touch map, and the "if you change X, also update Y" table. This file is the short version.

## What this is

A macOS app that adds **Services → Rewrite as Agent Prompt**. It sends highlighted text to a **local** model runner (MLX `mlx_lm.generate`, Mozilla.ai `llamafile`, or llama.cpp `llama-completion`) started as a program, and shows the streamed result in an editable dialog. It's Swift 5 and AppKit, built with plain `swiftc`. It has no dependencies, no Xcode project and no network code.

- `Sources/Core/`: the logic, with no UI. Fully tested.
- `Sources/PromptMenu/`: the AppKit shell. Checked by hand.
- `Tests/`: a home-made test runner plus tests, run with `scripts/test.sh`.
- `docs/`: [ARCHITECTURE](docs/ARCHITECTURE.md) · [FLOW_MAPS](docs/FLOW_MAPS.md) · [DEVELOPMENT](docs/DEVELOPMENT.md) · [AGENTIC_DEVELOPMENT](docs/AGENTIC_DEVELOPMENT.md)

## Commands

```sh
scripts/test.sh            # must pass before you say you're done
scripts/build.sh build     # must build with no errors
scripts/install.sh         # only when checking UI or Services by hand (writes to ~/Applications)
```

## Hard rules: never break these

1. **No network code.** No `URLSession`, sockets, `Network.framework`, web views, HTTP servers, or `http(s)://` in `Sources/`. No localhost servers either. Runners are started as programs. `testNoNetworkCode` enforces this, and you must not weaken that test to get past it.
2. **No downloads.** Never make the app fetch models or anything else. MLX runs with `HF_HUB_OFFLINE=1`.
3. **No entitlements, permissions or `*UsageDescription` keys.** No accessibility, screen recording or Apple Events.
4. **No third-party dependencies.** Build with `swiftc` and the Command Line Tools only. Don't add a Package.swift, CocoaPods or an Xcode project.
5. **Tests first.** Write or update the test, watch it fail, then implement. Never delete or loosen an assertion just to make a change pass. If an assertion is wrong, say why in the commit.
6. **Tests never need a real model, the user's `PATH`, the user's settings, or the network.** Use `makeScript` fake runners and a throwaway `UserDefaults` suite.
7. **Don't run a shell with user text.** Pass the text as one `Process` argument. Never build a shell command string from it. (llamafile goes through `/bin/sh` with the path as `$0` and the arguments as separate argv entries, never with `-c`.)
8. **Keep the Services wiring in sync.** `NSMessage` in `Resources/App-Info.plist` = `serviceMessage` = the method name in `Service.swift`, with the signature `(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>)`.
9. **Don't touch user-facing behavior you weren't asked about.** This covers the menu item title, the bundle id `local.promptmenu`, the settings keys, and the built-in prompt's section names.
10. **Don't commit or push unless asked.** Never force-push. Never commit `build/`.

## Before you finish

- [ ] `scripts/test.sh` prints `All tests passed.`
- [ ] `scripts/build.sh build` succeeds with no new warnings
- [ ] You updated every doc that the [change-impact map](docs/AGENTIC_DEVELOPMENT.md#change-impact-map) names for your change
- [ ] If you changed the UI or the plist, you did the manual checks in [DEVELOPMENT.md](docs/DEVELOPMENT.md#manual-checks), or you clearly said you couldn't
- [ ] Your summary says what you verified and what you didn't
