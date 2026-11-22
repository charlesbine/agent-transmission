# Changelog

Agent Transmission is the provider-agnostic macOS menu-bar app and hardware control surface project.

## Unreleased

- Renamed the macOS app bundle and executable from `Codex Transmission.app` (`CodexTransmission`) to
  `Agent Transmission.app` (`AgentTransmission`).
- Added native **T3 Code** `AgentTarget` support over Orchestration V2 WebSocket RPC with scoped
  session auth (`t3 auth session issue`), dynamic provider/model/options discovery, `t3code://` deep
  links, and a runtime menu-bar **Target** switcher (`T3 Code` / `Codex Desktop`).
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
