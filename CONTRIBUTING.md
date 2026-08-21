# Contributing

Bug reports and focused pull requests are welcome. Please describe the macOS version, agent target
and version, controller identity, exact physical input, expected result, and observed result.

## Adding an adapter

- Add a controller by conforming to `ControlSurface`. Keep device discovery, raw input parsing, and
  debouncing inside the adapter and emit only `ControlSurfaceEvent` values.
- Add an agent integration by conforming to `AgentTarget`. Keep task discovery, focus tracking,
  supported models, default mappings, stepping rules, provider protocols, and settings translation
  inside the adapter.
- Do not make a controller import an agent adapter or make an agent adapter import controller code.
- Supply the implementation through `AppModel` initializer injection and add a fake-adapter test
  covering the event or settings path.
- Deliver adapter callbacks on the main thread.

Before opening a pull request, run:

```sh
swift test
swift build -c release
./scripts/package-app.sh
```

Keep changes narrow and include regression coverage for behavior changes when the state-machine or
adapter-contract test seams apply. Contributions intentionally submitted to this project are licensed
under Apache-2.0, as described in section 5 of the license.
