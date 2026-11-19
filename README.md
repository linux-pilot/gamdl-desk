<p align="center">
  <img src="Assets/logo.png" width="128" alt="Gamdl Desk icon">
</p>

# Gamdl Desk

A small native macOS app (SwiftUI) that puts a window around [gamdl](https://github.com/glomatico/gamdl), the Apple Music downloader CLI.

Paste Apple Music links, pick codecs and an output folder, and press **Download** (⌘↩). Each finished song or video shows up in the Activity list, and gamdl's full output is in the Log.

## Features

- **Link checking as you paste**: Apple Music links (album, song, playlist, artist, music video) and ISRC codes are counted. Duplicates are ignored, and anything else is flagged and never passed to gamdl.
- **Activity list**: shows what was saved, skipped or failed, with Show in Finder for each file. The status bar shows elapsed time and totals.
- **Fast log**: copy it, save it, or search it with ⌘F. It stays responsive with tens of thousands of lines.
- **Sign-in help**: if gamdl can't sign in, a banner offers to run `gamdl auth` in Terminal. You can also point the app at a `cookies.txt`.
- **Artist links**: choose what an artist link downloads (all albums, singles, top songs, music videos, …) instead of hitting gamdl's interactive menu.
- **Safe stopping**: Stop (⌘.) escalates from interrupt to terminate to kill if gamdl doesn't exit. Quitting during a download asks first and stops gamdl, so it isn't left running.
- **Adapts to window size**: works from a compact 520 pt window up to full screen. The Options inspector can be hidden (⌥⌘I), and it follows light and dark mode.
- The Dock icon bounces and gets a badge when a download finishes in the background.

## Requirements

- macOS 14 or later, Apple Silicon
- Xcode or the Xcode command-line tools (Swift 6)
- gamdl 4.x:
  ```bash
  uv tool install "gamdl[widevine]"
  ```
  The app looks for `gamdl` in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
- An Apple Music subscription

## Build

```bash
./build.sh
```

This produces `Gamdl Desk.app` next to the script. Drag it to `/Applications`. The app icon is generated from `Assets/logo.png` by `scripts/make-icon.swift`.

## Test

```bash
swift test
```

Covers link parsing, command-line building, settings persistence, gamdl output parsing, and the process runner (streaming, ordering, stdin closed, stop escalation, hung pipes) using real child processes.

## Sign in

gamdl needs to sign in before it can download. Do one of these:

- Click **Sign In with Terminal…** (in Options, or the banner that appears after a sign-in error). It runs `gamdl auth` in Terminal, which asks a few questions.
- Or choose a Netscape `cookies.txt` exported from music.apple.com while signed in (it must contain the `media-user-token` cookie).

## Options

| Section | Settings |
| --- | --- |
| Output | output folder |
| Account | cookies file (optional), sign in with Terminal |
| Songs | codec (aac, aac-he, alac, atmos, …), lyrics file and its format |
| Music videos | codec (h264/h265), container (m4v/mp4), max height |
| Artist links | what to download from an artist page |
| Files | save cover art (jpg/png), save playlist `.m3u`, overwrite existing files |
| Performance | parallel downloads (1–8) |

Settings are remembered between launches. Anything not exposed here can be set in gamdl's own config at `~/.gamdl/config.yml`.

## Project layout

| Path | What |
| --- | --- |
| `Sources/GamdlCore` | Testable logic: options → command line, link parsing, output parsing, process runner |
| `Sources/GamdlDesk` | The SwiftUI app |
| `Tests/GamdlCoreTests` | Swift Testing suite |
| `scripts/make-icon.swift` | Builds `AppIcon.icns` from the logo |

## Credits

All downloading is done by [gamdl](https://github.com/glomatico/gamdl) by glomatico. This app only builds the command line and shows its output.

## License

[MIT](LICENSE)
