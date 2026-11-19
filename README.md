# Gamdl Desk

A small native macOS app (SwiftUI) that puts a window around [gamdl](https://github.com/glomatico/gamdl), the Apple Music downloader CLI.

Paste Apple Music links, pick codecs and an output folder, and press **Download** (⌘↩). gamdl's output streams into the log pane.

## Requirements

- macOS 14 or later, Apple Silicon
- Xcode command-line tools (`swiftc`)
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

This produces `Gamdl Desk.app` next to the script. Drag it to `/Applications`.

## Sign in

gamdl needs to sign in before it can download. Do one of these:

- In the app, choose a Netscape `cookies.txt` exported from music.apple.com while signed in (it must contain the `media-user-token` cookie).
- Or run `gamdl auth` once in Terminal. It asks questions, so it can't run from inside the app.

## Options

| Section | Settings |
| --- | --- |
| Songs | codec (aac, aac-he, alac, atmos, …), lyrics file and its format |
| Music videos | codec (h264/h265), container (m4v/mp4), max height |
| Extras | save cover art (jpg/png), save playlist `.m3u`, overwrite existing files |

Settings are remembered between launches. Anything not exposed here can be set in gamdl's own config at `~/.gamdl/config.yml`.

## Credits

All downloading is done by [gamdl](https://github.com/glomatico/gamdl) by glomatico. This app only builds the command line and shows its output.

## License

[MIT](LICENSE)
