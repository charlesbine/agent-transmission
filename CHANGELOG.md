# Changelog

Agent Transmission is the provider-agnostic project; Codex Transmission is its first shipped app
and adapter pairing.

## Unreleased

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
