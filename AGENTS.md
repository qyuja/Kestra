# Kestra

## Development validation

- Keep `/Applications/Kestra.app` and its production preferences untouched during development. Use `BUILD_CONFIGURATION=debug ./script/build_and_run.sh --verify` for the isolated `dist/KestraDev.app` (`com.kiannest.kestra.dev`).
- Test with `swift test`. Build/test success is not evidence of real mouse-hover behavior or an end-to-end signed update/relaunch.

## Compact log

- 2026-09-18: Continuing v0.1.12 hover follow-up. Explicit AppKit tracking selectors need regression coverage. Updating the popover header update entry and persistent automatic-check preference; keep Sparkle signature verification and production/dev isolation intact.
