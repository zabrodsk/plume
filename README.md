# Plume

A minimalist Markdown editor for macOS where every letter blooms onto the page.

The point of Plume is the *feel* of typing. Each character enters with a 90 ms
opacity rise; the rest of the app gets out of the way. Dark, focused, small.

→ **[Live demo](https://zabrodsk.github.io/plume/)**
→ **[Download for macOS](https://github.com/zabrodsk/plume/releases/latest)**

## Build from source

```bash
git clone https://github.com/zabrodsk/plume.git
cd plume/src
./build.sh
open Plume.app
```

Requires macOS 12+ and the Swift toolchain (`xcode-select --install`).

## What's inside

```
src/
  main.swift      Cocoa shell — window, menu, file I/O, JS bridge
  index.html      The editor (dark mode, runs inside WKWebView)
  icon.swift      Generates AppIcon.icns
  Info.plist      Bundle metadata
  build.sh        swiftc → lipo → iconutil → bundle → sign
demo/
  index.html      The marketing landing page (also the editor demo)
```

## License

MIT. See [LICENSE](LICENSE).
