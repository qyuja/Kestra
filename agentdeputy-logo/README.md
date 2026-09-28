# AgentDeputy logo

Light appearance: indigo `#5B5CE2`, navy `#172033`.
Dark appearance: light indigo `#8B8CFF`, off-white `#F1F5F9`.

The layered panels represent multiple accounts and coding tasks. The terminal chevron identifies coding work; the separate status dot represents task activity and alerts.

- `logo.svg`: horizontal mark and exact AgentDeputy wordmark; scalable and self-contained.
- `logo.png`: transparent rendering of the horizontal logo, 1600 × 520 px.
- `logo-icon.svg`: square symbol without text.
- `logo-icon.png`: transparent square symbol, 1024 × 1024 px.
- `logo-template.svg`: monochrome symbol for potential macOS menu bar template use.
- `preview.png`: the same logo rendered on white for review.
- `size-check.png`: actual 18, 24, 32 and 64 px symbol renders for visual inspection.
- `logo-dark.svg` / `logo-dark.png`: horizontal logo for dark surfaces; PNG is transparent, 1600 × 520 px.
- `logo-icon-dark.svg` / `logo-icon-dark.png`: square symbol for dark surfaces; PNG is transparent, 1024 × 1024 px.
- `preview-dark.png`: the dark logo rendered on `#171923` for review.
- `size-check-dark.png`: actual 18, 24, 32 and 64 px dark symbol renders, from left to right.
- `bar-icon-animation.gif`: enlarged monochrome menu bar animation preview, rendered from the application's layer paths and keyframe timing.
- `bar-icon-poses.png`: rest, diagonal hold, mid-turn and near-rest poses.

SVGs use a generic Helvetica Neue / Arial / sans-serif font stack. Letter appearance can vary with the local fonts. No external fonts, linked images, gradients or scripts are used.

The dark variant keeps the approved geometry and transparency; only its two colors change. Use the light assets on light surfaces and the dark assets on dark surfaces.

The application popover's `AppBrandIcon` selects the matching PNG from the effective SwiftUI color scheme, including automatic system appearance. Its image cache keeps the two variants separate. The menu bar continues to use macOS template tinting.

Selecting `AgentDeputy Logo` in menu bar icon settings uses native Core Animation layers. With an active task, the outer outline rotates clockwise and the inner outline counterclockwise to 45° over 300 ms, both hold for 200 ms, then continue in the same direction to 360° over 1500 ms. Each outline rotates around its own panel center. The chevron and signal stay fixed. The two-second cycle repeats while tasks run and returns to the original pose when idle; theme/quota updates preserve playback phase. Custom animated layers use the menu bar's actual black/white foreground appearance.

The actual view's dark/light/dark rendering is covered by a regression test. Asset previews are SVG renders; they do not substitute for visual inspection of the running application.
