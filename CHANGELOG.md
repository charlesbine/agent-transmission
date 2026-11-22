# Changelog

Agent Transmission is the provider-agnostic macOS menu-bar app and hardware control surface project.

## Unreleased

- Renamed the macOS app bundle and executable from `Codex Transmission.app` (`CodexTransmission`) to
  `Agent Transmission.app` (`AgentTransmission`).
- Added native **T3 Code** `AgentTarget` support over Orchestration V2 WebSocket RPC with scoped
  session auth (`t3 auth session issue`), dynamic provider/model/options discovery, `★ Favorites`
  sync, Fast → Smart sorting, `t3code://` deep links, and a runtime **Target** switcher
  (`T3 Code` / `Codex Desktop`).
- Replaced the closing `NSMenu` with a persistent dark obsidian SwiftUI **Menu-Bar Popover**
  (`Gearbox` + `Controls` tabs) with a visual 6+R H-gate (`● LIVE` vs `✎ EDIT` states), provider
  filters, search bar, effort picker, and native aligned switch/layer controls.
- Added a fixed-width (`44 pt`) live vector H-gate menu-bar status icon with zero width jitter.
- Added the non-activating **Floating Shift HUD**: automatic **Gear → Neutral Decision HUD** with
  configurable timeout and clickable `×` dismiss, live **`⇧ Shift` / `⌥ Option` / `(P)`** layer
  morphing, **One-Shot Tap `(P)`** Effort/Modes workflow with draining countdown bar, live 60 fps
  **`(P)` Hold Progress Guide**, and human-readable RPC error toasts.
- Added customizable **Reverse (`R`)**, **Tap `(P)`**, **Hold `(P)` (`1.2s`)**, and **Sequential
  (`S+ / S−`)** actions, including `Plan ↔ Code` toggling, `Interrupt Active Run`, `Settle Thread`,
  and T3 permission modes (`Ask` / `Edits` / `Auto` / `Full`).
- Eliminated main-thread CPU spikes on large T3 thread histories (`99.6% → 0.0%` idle CPU) with
  zero-allocation RFC3339 date parsing and batched shell chunk ingestion.
- Reconnect Codex Desktop control automatically after Codex restarts or its local IPC socket drops,
  then re-synchronize the currently focused task before applying another shift.

## 0.1.0 — 2026-08-21

- Added direct HID support for the NiTHO GS-SH Gearshifter on macOS.
- Added configurable H-pattern mappings for Codex model and reasoning effort.
- Added sequential effort and model-family stepping.
- Added a parking brake and a two-second hold gesture for Codex Fast mode.
- Added focused-task following and optional task pinning.
- Added a native menu-bar interface with persistent settings.
- Added independent `ControlSurface` and `AgentTarget` extension contracts with dependency injection.
- Isolated the first integrations as `NiTHOControlSurface` and `CodexAgentTarget`.
