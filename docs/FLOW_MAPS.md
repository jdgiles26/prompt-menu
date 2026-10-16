# Flow maps

Diagrams of every path through Prompt Menu. They render on GitHub. Names in `code` are the real functions and types; see [ARCHITECTURE.md](ARCHITECTURE.md) for what each file owns.

1. [App launch: Services or settings](#1-app-launch-services-or-settings)
2. [Service call to dialog](#2-service-call-to-dialog)
3. [The rewrite pipeline](#3-the-rewrite-pipeline)
4. [Choosing the runner and building the command](#4-choosing-the-runner-and-building-the-command)
5. [Running a program: streaming, timeout, failure](#5-running-a-program-streaming-timeout-failure)
6. [Cleaning the output](#6-cleaning-the-output)
7. [Dialog states](#7-dialog-states)
8. [Errors and what the user sees](#8-errors-and-what-the-user-sees)
9. [Settings: load, edit, save](#9-settings-load-edit-save)
10. [App lifetime: when it quits](#10-app-lifetime-when-it-quits)
11. [Install and registration](#11-install-and-registration)
12. [Development loop](#12-development-loop)
13. [Replace Selection](#13-replace-selection)
14. [Keeping the model loaded](#14-keeping-the-model-loaded)
15. [Applying an agentic pattern](#15-applying-an-agentic-pattern)

---

## 1. App launch: Services or settings

macOS starts the app when the Services item is chosen and it isn't already running. If no service request arrives within half a second, the user opened the app directly, so it shows settings.

```mermaid
flowchart TD
    A([App starts]) --> B[applicationWillFinishLaunching<br/>main menu · servicesProvider = ServiceProvider]
    B --> C[applicationDidFinishLaunching<br/>wait 0.5 s]
    C --> D{Service request<br/>handled, or a panel open?}
    D -- yes --> E([Stay an accessory app:<br/>no Dock icon])
    D -- no --> F[showSettings<br/>activation policy → regular]
    F --> G([Settings window with Dock icon])
    H([Dock icon clicked again]) --> F
```

## 2. Service call to dialog

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant App as Any app
    participant OS as macOS Services (pbs)
    participant SP as ServiceProvider
    participant AD as AppDelegate
    participant P as ResultPanelController
    participant BG as Background queue

    U->>App: Highlight text, right-click
    U->>OS: Services → Rewrite as Agent Prompt / Bug Report / Code Review Request / Commit Message
    OS->>SP: rewriteAs…(pasteboard, userData, error)
    alt pasteboard has no text, or only whitespace
        SP-->>OS: error.pointee = "There's no text to rewrite…"
    else text
        SP->>AD: onText(text, style)
        AD->>P: ResultPanelController(source: text, style)
        AD->>P: showWindow, offset from the last dialog, orderFrontRegardless
        AD->>P: start()
        P->>P: loadConfig(), systemPrompt(for: style), spinner, 1 s timer
        P->>BG: rewrite(text, config, warm:, started:, progress:, notice:)
        BG-->>P: started(stop function) → main
        loop while the model writes
            BG-->>P: progress(cleaned text so far) → main
            P->>P: textView.string = text, scroll to end
        end
        BG-->>P: Result → main, saved as version 1 · First draft
        P->>U: Editable prompt · Check badge · Agentic Pattern… · Copy (⌘↩) · Try Again · Close
    end
```

## 3. The rewrite pipeline

`rewrite(_:config:searchDirs:timeout:started:progress:)` in `Runner.swift` is the only entry point the UI uses.

```mermaid
flowchart LR
    T[/highlighted text/] --> PI[prepareInput<br/>trim · empty → throw<br/>cut at 8,000 chars]
    PI --> INV[invocation<br/>find program · check model<br/>build arguments]
    INV --> RUN[run<br/>Process · pipes · timeout]
    RUN -- each chunk --> CO1[cleanOutput<br/>partial] --> PR[/progress callback/]
    RUN -- exit 0 --> CO2[cleanOutput<br/>final]
    CO2 --> E{empty?}
    E -- yes --> X1[[throw emptyOutput]]
    E -- no --> OUT[/agent prompt/]
    PI -. throws .-> X2[[emptyInput]]
    INV -. throws .-> X3[[executableNotFound · modelNotSet]]
    RUN -. throws .-> X4[[failed · timedOut · executableNotFound]]
```

## 4. Choosing the runner and building the command

```mermaid
flowchart TD
    S([invocation for: config]) --> P{config.executable set?}
    P -- yes --> PX{executable at that path?}
    PX -- no --> E1[[executableNotFound with that path]]
    PX -- yes --> M
    P -- no --> F[findExecutable named backend.executableName<br/>in standardSearchDirs]
    F -- not found --> E2[[executableNotFound with that name]]
    F -- found --> M{backend.needsModel<br/>and model empty?}
    M -- yes --> E3[[modelNotSet]]
    M -- no --> B{backend}
    B -- mlx --> MLX["mlx_lm.generate --model --system-prompt --prompt<br/>--max-tokens --temp --verbose True<br/>env HF_HUB_OFFLINE=1, PYTHONUNBUFFERED=1"]
    B -- llamafile --> LF["/bin/sh llamafile [-m model] --cli<br/>-p combinedPrompt -n --temp"]
    B -- llama.cpp --> LC["llama-completion -m -sys -p<br/>-cnv -st --no-display-prompt --log-disable -n --temp"]
```

Search order in `standardSearchDirs`: `/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` → `~/bin` → `~/Library/Python/*/bin` (newest first) → `$PATH`, without duplicates.

## 5. Running a program: streaming, timeout, failure

```mermaid
sequenceDiagram
    autonumber
    participant C as rewrite / caller
    participant R as run()
    participant P as Process
    participant O as stdout handler
    participant E as stderr handler

    C->>R: run(invocation, timeout, started, output)
    R->>R: executable at that path? else throw executableNotFound
    R->>P: run() (env = inherited + invocation.environment, stdin = /dev/null)
    R-->>C: started(process)
    par stdout
        loop each chunk
            P-->>O: data
            O->>O: append under lock
            O-->>C: output(all stdout so far)
        end
    and stderr
        loop each chunk
            P-->>E: data
            E->>E: append under lock
        end
    end
    alt exits before timeout
        R->>R: wait for both pipes to close (at most 2 s)
        alt status 0
            R-->>C: stdout
        else non-zero
            R-->>C: throw failed(status, last 8 lines of stderr)
        end
    else timeout
        R->>P: terminate(), then SIGKILL after 2 s
        R-->>C: throw timedOut
    end
```

The 2-second cap on waiting for the pipes covers a runner that leaves a child process holding stdout open. `testRunnerChildKeepsPipeOpen` tests it.

## 6. Cleaning the output

`cleanOutput` runs on every streamed chunk and again on the final text, so each step must also be safe on partial text.

```mermaid
flowchart TD
    A[/raw stdout/] --> B[strip ANSI escape codes]
    B --> C["remove closed &lt;think&gt;…&lt;/think&gt; blocks"]
    C --> D["remove an unclosed &lt;think&gt; to the end<br/>(still thinking mid-stream)"]
    D --> E["drop noise lines:<br/>==== · Prompt: N tokens · Generation: N tokens<br/>Peak memory: · [end of text]"]
    E --> F[trim whitespace]
    F --> P["drop a first line like 'Here is the rewritten prompt:'<br/>(only once the next line has started)"]
    P --> G{whole reply wrapped in<br/>one code fence?}
    G -- yes --> H[keep what's inside the fence]
    G -- no --> I[/clean text/]
    H --> I
```

## 7. Dialog states

```mermaid
stateDiagram-v2
    [*] --> Running: start() runs the first draft
    Running --> Running: progress → text streams in<br/>timer ticks every 1 s
    Running --> Done: success → new version, selected
    Running --> Failed: error thrown
    Running --> Closed: Close or Esc → stop the model
    Done --> Running: Try Again → repeats the last step
    Failed --> Running: Try Again
    Running --> Running: Try Again → stop, generation += 1, restart
    Done --> Done: edit text → check badge updates
    Done --> Done: pick a version → its text and check
    Done --> Running: Agentic Pattern… → Apply<br/>(edits saved as a version first)
    Failed --> Done: pick an earlier version
    Done --> Closed: Copy (⌘↩) → pasteboard
    Done --> Closed: Close or Esc
    Failed --> Closed: Close or Esc
    Closed --> [*]: onClose → AppDelegate.finish()

    state Running {
        [*] --> spinner_on
        spinner_on: spinner on · text read-only · Copy, Agentic Pattern and versions disabled
    }
    state Done {
        [*] --> editable
        editable: text editable · Copy enabled · check badge · "Done in Ns"
    }
    state Failed {
        [*] --> message
        message: error text shown · Copy disabled · earlier versions still selectable
    }
```

## 8. Errors and what the user sees

```mermaid
flowchart LR
    subgraph Thrown["RewriteError"]
        A[emptyInput]
        B["executableNotFound(name or path)"]
        C[modelNotSet]
        D["failed(status, stderr tail)"]
        E[timedOut]
        F[emptyOutput]
        G["modelError(message)"]
    end
    A --> A1["There's no text to rewrite. Highlight some text first.<br/>(also returned to macOS by ServiceProvider)"]
    B --> B1["Couldn't find X. Install it, or set its full path in settings."]
    C --> C1["No model is set. Choose one in settings."]
    D --> D1["The model runner stopped with exit code N, plus the end of stderr<br/>(e.g. the MLX model isn't downloaded)"]
    E --> E1["The model took too long and was stopped.<br/>(default 300 s)"]
    F --> F1["The model didn't return any text."]
    G --> G1["The model couldn't answer, plus the worker's message<br/>(e.g. the model isn't downloaded)"]
```

All of these appear in the dialog's text area with Copy turned off. Try Again re-reads the settings, so you can fix the setting and retry without closing the dialog.

## 9. Settings: load, edit, save

```mermaid
flowchart TD
    subgraph Load["loadConfig(from:)"]
        L1[backend: unknown or missing → mlx]
        L2[model: missing → defaultMLXModel when the runner is MLX, else empty]
        L3[executable: empty → nil, meaning search]
        L4[maxTokens: clamped to 16…8192]
        L5[temperature: clamped to 0…2]
        L6[systemPrompt: blank → agentSystemPrompt]
        L7[keepLoadedMinutes: missing → 5, clamped to 0…120]
    end
    subgraph Window["SettingsWindowController"]
        W1[pick runner] -->|backendChanged| W2[reset model if the runner type changed]
        W3[type runner path] -->|textDidChange| W4["updateHints: ✓ found or ✗ not found"]
        W5[Save] --> SV
        W6[Try It] --> SV --> T[rewrite sample text in a new dialog]
    end
    subgraph Save["saveConfig(to:)"]
        SV[write every key, and keepLoadedMinutes] --> SP{systemPrompt is the built-in one?}
        SP -- yes --> SP1[save as empty string]
        SP -- no --> SP2[save the text]
    end
    DEF[(UserDefaults local.promptmenu)] --> Load
    Save --> DEF
    CLI["defaults write local.promptmenu …"] --> DEF
```

## 10. App lifetime: when it quits

```mermaid
flowchart TD
    A([a dialog, the settings window or Replace Selection finishes]) --> B[AppDelegate.finish]
    U([the kept-loaded model unloads:<br/>idle time up, or Unload Model Now]) --> B
    B --> C{settings open, a dialog open,<br/>Replace Selection running,<br/>or a model kept loaded?}
    C -- yes --> D([keep running · menu-bar item while a model is loaded])
    C -- no --> E([NSApp.terminate<br/>model memory released])
    Q([⌘Q, logout, or SIGTERM]) --> S[SIGTERM source → NSApp.terminate]
    S --> W[applicationWillTerminate<br/>every panel.stop · warm.unload]
    W --> X([app exits, no orphaned runner or worker])
```

## 11. Install and registration

```mermaid
flowchart LR
    A[scripts/install.sh] --> B["scripts/build.sh ~/Applications<br/>swiftc · Info.plist · ad-hoc codesign"]
    B --> C["lsregister -f app<br/>Launch Services knows the bundle"]
    C --> D["pbs -update<br/>Services menu re-reads NSServices"]
    D --> E([Rewrite as Agent Prompt appears<br/>under Services → Text])
    U["scripts/install.sh --uninstall"] --> U1["lsregister -u"] --> U2["rm -rf app"] --> U3["pbs -update"]
```

## 12. Development loop

```mermaid
flowchart TD
    A([Change planned]) --> B[Read AGENTS.md and the impact map<br/>docs/AGENTIC_DEVELOPMENT.md]
    B --> C[Write or adjust tests first]
    C --> D[scripts/test.sh → watch them fail]
    D --> E[Implement in Sources/]
    E --> F[scripts/test.sh → all pass]
    F --> G{UI or plist changed?}
    G -- yes --> H[scripts/install.sh<br/>manual check: Services item, dialog, settings]
    G -- no --> I
    H --> I[Update the docs the impact map names]
    I --> J[Commit]
```

## 13. Replace Selection

**Rewrite as Agent Prompt (Replace Selection)** returns the prompt to the app that asked, in place of the highlighted text. That app waits until the answer comes back, up to `NSTimeout` (120 s); Prompt Menu gives up at `inPlaceTimeout` (110 s) so the error arrives first.

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant App as Any app
    participant OS as macOS Services
    participant SP as ServiceProvider
    participant AD as AppDelegate
    participant BG as Background queue

    U->>OS: Services → Rewrite as Agent Prompt (Replace Selection)
    OS->>SP: rewriteAsAgentPromptInPlace(pasteboard, …)
    SP->>AD: replace(text)
    AD->>AD: ProgressWindow "Rewriting with MLX…"
    AD->>BG: rewrite(text, config, warm:, timeout: 110 s)
    loop until the result arrives
        AD->>AD: RunLoop.run(0.05 s), so the progress window stays live
    end
    BG-->>AD: Result → main
    AD->>AD: close the progress window · finish()
    alt success
        SP->>OS: pasteboard = prompt
        OS->>App: replaces the highlighted text
    else error
        SP->>OS: error.pointee = message
        OS->>U: the text is left as it was
    end
```

## 14. Keeping the model loaded

```mermaid
stateDiagram-v2
    [*] --> Off: app starts
    Off --> Starting: rewrite with MLX and keepLoadedMinutes > 0
    Starting --> Loading: worker process running
    Starting --> OneShot: can't start (no Python, no script)
    Loading --> Ready: first reply done → onChange(true) → menu-bar item
    Loading --> OneShot: worker dies before replying
    Ready --> Generating: next request (no load)
    Generating --> Ready: done, or cancelled → idle timer restarts
    Generating --> Ready: error reply (e.g. model not downloaded)
    Generating --> Off: timeout → unload
    Ready --> Off: idle time up, Unload Model Now, keep-loaded set to 0, or app quits
    Off --> [*]: nothing open → app quits
    OneShot --> Off: mlx_lm.generate runs once, notice shown

    state Ready {
        [*] --> loaded
        loaded: model in memory · menu-bar item shows time left
    }
```

The worker exits when its stdin closes, so it can't outlive the app even if the app crashes.

## 15. Applying an agentic pattern

```mermaid
flowchart TD
    A([Agentic Pattern… in a finished dialog]) --> B[edited text saved as a new version]
    B --> C["shortlist(for: text)<br/>≥ 3 shared words, weighted by field and rarity<br/>+ general workflows to fill 5"]
    C --> D[picker opens: 5 candidates · search over all 203]
    D --> E{model already loaded?}
    E -- yes --> F["patternChoicePrompt → one letter<br/>parseChoice → ★ suggested, selected"]
    E -- no --> G[keyword order stands]
    F --> H
    G --> H([user picks a pattern, or searches, then Apply])
    H --> I["patternSystemPrompt(pattern, sections: style.sections)<br/>pattern as background · exact headings<br/>+ WORKFLOW PATTERN line"]
    I --> J[rewrite the current text]
    J --> K[new version: 'N · pattern title'<br/>check badge for the result]
    K --> L{good?}
    L -- no --> M[pick an earlier version, or Try Again]
    L -- yes --> N([Copy])
```
