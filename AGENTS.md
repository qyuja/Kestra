# AgentDeputy

## Development validation

- Keep installed `/Applications/Kestra.app`, `/Applications/AgentDeputy.app`, and their production preferences untouched during development. Use `BUILD_CONFIGURATION=debug ./script/build_and_run.sh --verify` for the isolated `dist/AgentDeputyDev.app` (`com.kiannest.agentdeputy.dev`).
- Test with `swift test`. Build/test success is not evidence of real mouse-hover behavior or an end-to-end signed update/relaunch.

## Compact log

- 2026-09-28: Continue the AgentDeputy menubar logo motion: change only the outer stroke's visible travel to clockwise, retain the original idle SVG, inner artwork, and 2.4-second lap. Verify the rendered path and use the isolated Dev app; leave installed apps untouched.

- 2026-09-28: Rename Kestra source/test modules, app bundle and local project directory to AgentDeputy. Preserve the published GitHub repository URL until it exists under the new name; copy old app state into the new bundle namespace without removing installed or persisted old-state data. Claude Code Hook paths require a manual reconnect after rename.

- 2026-09-28: Continuing AgentDeputy SVG menubar orientation/centering repair. The latest request supersedes the earlier 180-degree flip: preserve the SVG's original orientation, account explicitly for the status button's coordinate system, and center the visible artwork without moving the inner panel during animation. Keep the outer-stroke lap and isolated Dev validation; do not touch the installed app.

- 2026-09-28: Continuing AgentDeputy dark-theme logo work. Preserve the approved geometry and light assets, add an adaptive dark variant, and keep existing rebranding/client changes intact. Validate with isolated KestraDev; the installed app remains untouched.

- 2026-09-21: Continuing CPU optimization after v0.1.16. Use isolated KestraDev measurements; baseline is mostly 1–3% but has double-digit spikes. Inspect SwiftUI animation/layout and hidden hosting lifetime; do not claim sustained single-digit CPU from a short sample or touch the installed app.

- 2026-09-18: Continuing v0.1.12 hover follow-up. Explicit AppKit tracking selectors need regression coverage. Updating the popover header update entry and persistent automatic-check preference; keep Sparkle signature verification and production/dev isolation intact.
