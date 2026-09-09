# Menu bar icon plugins

Kestra can load resource-only icon plugins from:

```text
~/Library/Application Support/com.kiannest.kestra/icon-plugins
```

Create one subdirectory per plugin and put a `manifest.json` in it. A plugin
uses either PNG frames or a macOS system symbol:

```json
{
  "schemaVersion": 1,
  "id": "circle-example",
  "name": "Circle Example",
  "systemSymbol": "circle"
}
```

The supported fields are `schemaVersion`, `id`, `name`, optional `frames`
(relative PNG paths), optional `systemSymbol`, optional `idleFrame`, and
optional `cycleDuration` in seconds. `frames` and `systemSymbol` are mutually
exclusive. The built-in IDs `barbell-squat` and `sparkles` cannot be replaced.

Installation and refresh

1. Copy the whole plugin subdirectory into the directory above. Do not put
   executable files there or expect them to run.
2. Use the app's plugin refresh action after adding or replacing a plugin.
   Opening the plugin directory creates it when necessary.
3. Select the plugin in the app. A missing saved selection falls back to the
   built-in squat icon and is reported to the app.

Safety limits

The loader only parses JSON and reads PNG/SF Symbol resources. It does not
load Swift, scripts, bundles, or dynamic libraries. Manifest and resource
paths must stay inside the plugin directory after symlink resolution. Invalid
packages are reported and skipped. PNG frames are limited to 32 frames, 1 MiB
per frame, and 512×512 pixels; manifest files are limited to 64 KiB.

Licensing

Plugin authors are responsible for the licenses of their own PNG assets. This
example contains no image asset and uses the macOS `circle` SF Symbol, which
is subject to Apple's SF Symbols license and the platform's usage terms. The
built-in barbell-squat artwork remains covered by the Apache-2.0 notice in
`Sources/Kestra/Resources/RunnerGallery-LICENSE.txt`.
