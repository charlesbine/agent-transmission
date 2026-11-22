# Agent Transmission

Physical control surfaces for coding-agent models and reasoning effort. The macOS menu-bar app
connects the NiTHO `GS-SH Gearshifter` to **T3 Code (Native WebSocket RPC)** and **Codex Desktop**,
giving direct H-pattern and sequential control over models, reasoning effort, and Fast mode.

Agent Transmission is an independent open-source project. It is not affiliated with or endorsed by
OpenAI or NiTHO. Codex is a product of OpenAI; NiTHO and GS-SH Gearshifter are used only to identify
compatible products.

## Demo

https://github.com/user-attachments/assets/9548d44b-e48f-4e01-b5ed-2294c923b9d5

The left side is stabilized phone footage of the physical shifter and live laptop display; the
right side is the matching screen capture. [Download the MP4](docs/assets/agent-transmission-demo.mp4).

## Requirements

- macOS 13 or later on Apple silicon
- NiTHO GS-SH Gearshifter with USB vendor ID `0x2345` and product ID `0xe00c`
- **T3 Code** (local server + `t3` CLI) and/or **Codex Desktop** / Codex CLI installed locally
- Your own model provider access configured in T3 Code or Codex

The app does not include T3 Code, Codex, provider accounts, credentials, or vendor software. It has
no telemetry and does not send prompts or task contents anywhere.

## Install

Download the release ZIP, move **Agent Transmission.app** to Applications, open it, and plug in the
shifter. The app has no Dock icon; its current gear and preset appear in the menu bar.

Use the menu bar's **Target** submenu to switch between **T3 Code** and **Codex Desktop** at
runtime (persisted in `UserDefaults`). On first launch, the app defaults to **T3 Code** when
`~/.t3/userdata/server-runtime.json` exists, and **Codex Desktop** otherwise.

To start it automatically after signing in, open the menu-bar item and enable **Launch at Login**.
If macOS requires approval, the item opens **System Settings → General → Login Items**.

Release `0.1.0` is ad-hoc signed when built without an Apple Developer ID. macOS may require you to
right-click the app and choose **Open** the first time. A Developer-ID-signed and notarized release
can be built with the workflow below.

## Controls

- Direct H-pattern gears select configurable presets after a stable 25 ms engagement.
- Neutral is electrically invisible and preserves the last applied preset.
- Sequential throws adjust effort within the current model family.
- Hold `(P)` during a sequential throw to step across model families (in T3 Code, across all
  connected providers and models; in Codex Desktop, through Luna, Terra, and Sol) while preserving
  the closest supported effort.
- Pull and release `(P)` to toggle the software parking brake.
- Hold `(P)` uninterrupted for two seconds to toggle Fast mode (`fastMode` / `serviceTier` on models
  that expose it).
- Automatic targeting follows the thread actually focused in T3 Code (`lastVisitedAt` /
  `opens.openedAt`) or Codex Desktop; any task can also be pinned from the **Task** submenu.

Using `(P)` as a modifier or holding it long enough for Fast consumes the press, so release cannot
also toggle parking. Neutral, task focus changes, remapping, and releasing the parking brake never
replay a preset. Target settings change only after a fresh physical input.

## Targets

### T3 Code (Native WebSocket RPC)

`T3CodeAgentTarget` connects directly to the local T3 Code server over its native Orchestration V2
WebSocket RPC protocol with zero external Swift dependencies:

- **Server discovery:** reads `$T3CODE_HOME/userdata/server-runtime.json` (default
  `~/.t3/userdata/server-runtime.json`) for the live server `origin` / `port`.
- **Scoped auth:** stores a bearer session in `~/.config/agent-transmission/session.json` with
  `0600` permissions. When missing or rejected (`401`/`403`), it invokes `$T3CODE_CLI_PATH` (default
  `~/.t3/bin/t3`) to mint a scoped session:

  ```sh
  t3 auth session issue \
    --scope orchestration:read \
    --scope orchestration:operate \
    --label "Agent Transmission" \
    --ttl 365d \
    --json
  ```

  and exchanges the bearer token at `POST /api/auth/websocket-ticket` for a short-lived WebSocket
  ticket (`ws://<host>:<port>/ws?orchestrationProtocol=2&wsTicket=<ticket>`).
- **Live catalog & transmission map:** subscribes to `subscribeServerConfig` and
  `orchestration.subscribeShell` to discover ready providers, live models, favorites, and per-model
  option descriptors (`effort`, `reasoningEffort`, `thought_level`, `fastMode`, `serviceTier`).
  Gears 1–6 and R automatically map across your live favorites/models and stay customizable under
  **Transmission · configure**.
- **Deep links:** **Open target task** opens `t3code://threads/<environmentId>/<threadId>`.

### Codex Desktop

Task discovery uses the documented local Codex app-server protocol and the installed Codex CLI.
Focused-task detection and settings writes currently use Codex Desktop's versioned, user-owned Unix
IPC router at `~/.codex/ipc/ipc.sock` because the documented app-server API does not expose a stable
way to change the settings of an already-open Desktop-owned task.

| Position | Preset | Codex model | Effort |
| --- | --- | --- | --- |
| 1 | Luna Max | `gpt-5.6-luna` | `max` |
| 2 | Sol Medium | `gpt-5.6-sol` | `medium` |
| 3 | Sol High | `gpt-5.6-sol` | `high` |
| 4 | Sol XHigh | `gpt-5.6-sol` | `xhigh` |
| 5 | Sol Max | `gpt-5.6-sol` | `max` |
| 6 | Sol Ultra | `gpt-5.6-sol` | `ultra` |
| R | Review | `gpt-5.6-sol` | `max` |

Each direct position can be changed under **Transmission · configure** (persisted independently per
target). Changes do not apply until the lever moves again.

That Codex Desktop bridge is experimental. A future Codex Desktop release may change it. Agent
Transmission fails closed with a visible menu-bar error and never falls back to UI automation or a
sibling app-server. If T3 Code or Codex restarts, Transmission reconnects automatically with bounded
backoff and re-synchronizes the currently focused task; the menu's **Reconnect** action retries
immediately. Settings affect subsequent turns only; an answer already in progress is not changed.

## Adapter architecture

The application core has no direct dependency on NiTHO, IOKit, T3 Code, Codex app-server, or Codex
Desktop IPC. Hardware and agent integrations meet through two public contracts in
`Sources/AgentTransmissionCore/IntegrationContracts.swift`:

```text
ControlSurface → ControlSurfaceEvent → AppModel → AgentSettingsUpdate → AgentTarget
     NiTHO                                                       T3 Code | Codex Desktop
```

A `ControlSurface` owns device discovery, connection lifecycle, raw reports, and debouncing. It
emits semantic position, effort-step, model-family-step, modifier, parking, and Fast-mode events;
it never imports or calls an agent integration.

An `AgentTarget` owns task discovery, focus tracking, supported presets, default mappings,
model-family and effort stepping rules, task URLs, and settings writes. It receives generic
model/effort/Fast updates; it never imports or calls a controller implementation.

Both `T3CodeAgentTarget` and `CodexAgentTarget` conform to `AgentTarget` and plug into the same
`AppModel` and `NiTHOControlSurface`. `AppModel` accepts targets via initializer injection or a
runtime target factory, so additional controllers or agents can be added independently. Adapter
callbacks are delivered on the main thread because they update menu-bar state.

## Build and test

```sh
swift test
swift run AgentTransmission
```

Build an ad-hoc-signed app and versioned release ZIP:

```sh
./scripts/package-app.sh
```

For Developer ID distribution, set the exact signing identity before packaging:

```sh
AGENT_TRANSMISSION_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/package-app.sh
```

After creating a `notarytool` keychain profile, notarize, staple, and recreate the release ZIP:

```sh
AGENT_TRANSMISSION_NOTARY_PROFILE="agent-transmission" \
  ./scripts/notarize-app.sh
```

Local builds use ad-hoc signing by default. Notarized distribution requires a Developer ID
Application identity and a `notarytool` keychain profile supplied by the maintainer.

## Current NiTHO adapter

- Buttons 1–6: forward gears
- Button 7: reverse
- Buttons 8–9: sequential up/down
- Button 10: momentary `(P)` control
- X/Y descriptor fields do not change; lateral neutral movement is not observable

## License

Copyright 2026 Meta Ember. Licensed under the [Apache License 2.0](LICENSE).

Apache-2.0 permits commercial redistribution, including selling compiled copies, as long as its
terms are followed. It does not grant rights to project or third-party trademarks.
