# Agent Transmission

Physical control surfaces for coding-agent models and reasoning effort. The first shipped pairing
is the **Codex Transmission** macOS menu-bar app, connecting the NiTHO `GS-SH Gearshifter` to Codex
model, reasoning-effort, and Fast-mode controls.

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
- Codex Desktop or the Codex CLI installed locally
- Your own Codex access through an eligible OpenAI account

The app does not include Codex, an OpenAI account, credentials, or vendor software. It has no
telemetry and does not send prompts or task contents anywhere.

## Install

Download the release ZIP, move **Codex Transmission.app** to Applications, open it, and plug in the
shifter. The app has no Dock icon; its current gear and preset appear in the menu bar.

Release `0.1.0` is ad-hoc signed when built without an Apple Developer ID. macOS may require you to
right-click the app and choose **Open** the first time. A Developer-ID-signed and notarized release
can be built with the workflow below.

## Controls

- Direct H-pattern gears select configurable presets after a stable 25 ms engagement.
- Neutral is electrically invisible and preserves the last applied preset.
- Sequential throws adjust effort within the current model family.
- Hold `(P)` during a sequential throw to move through Luna, Terra, and Sol while preserving the
  closest supported effort.
- Pull and release `(P)` to toggle the software parking brake.
- Hold `(P)` uninterrupted for two seconds to toggle Codex Fast mode.
- Automatic targeting follows the task actually focused in Codex Desktop; a task can also be pinned
  from the menu.

Using `(P)` as a modifier or holding it long enough for Fast consumes the press, so release cannot
also toggle parking. Neutral, task focus changes, remapping, and releasing the parking brake never
replay a preset. Codex settings change only after a fresh physical input.

## Default transmission

| Position | Preset | Codex model | Effort |
| --- | --- | --- | --- |
| 1 | Luna Max | `gpt-5.6-luna` | `max` |
| 2 | Sol Medium | `gpt-5.6-sol` | `medium` |
| 3 | Sol High | `gpt-5.6-sol` | `high` |
| 4 | Sol XHigh | `gpt-5.6-sol` | `xhigh` |
| 5 | Sol Max | `gpt-5.6-sol` | `max` |
| 6 | Sol Ultra | `gpt-5.6-sol` | `ultra` |
| R | Review | `gpt-5.6-sol` | `max` |

Each direct position can be changed under **Transmission · configure**. Changes persist across
launches and do not apply until the lever moves again.

## Compatibility boundary

Task discovery uses the documented local Codex app-server protocol and the installed Codex CLI.
Focused-task detection and settings writes currently use Codex Desktop's versioned, user-owned Unix
IPC router at `~/.codex/ipc/ipc.sock` because the documented app-server API does not expose a stable
way to change the settings of an already-open Desktop-owned task.

That Desktop bridge is experimental. A future Codex Desktop release may change it. Codex
Transmission fails closed with a visible menu-bar error and never falls back to UI automation or a
sibling app-server. Settings affect subsequent turns only; an answer already in progress is not
changed.

## Adapter architecture

The application core has no direct dependency on NiTHO, IOKit, Codex app-server, or Codex Desktop
IPC. Hardware and agent integrations meet through two public contracts in
`Sources/AgentTransmissionCore/IntegrationContracts.swift`:

```text
ControlSurface → ControlSurfaceEvent → AppModel → AgentSettingsUpdate → AgentTarget
     NiTHO                                                      Codex
```

A `ControlSurface` owns device discovery, connection lifecycle, raw reports, and debouncing. It
emits semantic position, effort-step, model-family-step, modifier, parking, and Fast-mode events;
it never imports or calls an agent integration.

An `AgentTarget` owns task discovery, focus tracking, supported presets, default mappings,
model-family and effort stepping rules, task URLs, and settings writes. It receives generic
model/effort/Fast updates; it never imports or calls a controller implementation.

The shipped pair is `NiTHOControlSurface` and `CodexAgentTarget`. `AppModel` accepts both through
initializer injection, so another controller or agent can be added independently. Adapter
callbacks are delivered on the main thread because they update menu-bar state.

## Build and test

```sh
swift test
swift run CodexTransmission
```

Build an ad-hoc-signed app and versioned release ZIP:

```sh
./scripts/package-app.sh
```

For Developer ID distribution, set the exact signing identity before packaging:

```sh
CODEX_TRANSMISSION_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/package-app.sh
```

After creating a `notarytool` keychain profile, notarize, staple, and recreate the release ZIP:

```sh
CODEX_TRANSMISSION_NOTARY_PROFILE="codex-transmission" \
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
