# Burrow

A native macOS app for cleaning, uninstalling and maintaining your Mac. Every scan and every change runs through [Mole](https://github.com/tw93/Mole), the open-source cleanup CLI by tw93. Burrow ships a pinned copy of Mole inside the app and adds a SwiftUI interface on top. It never deletes files itself; Mole's protection rules, Trash routing and operation log stay in charge.

## What it does

Burrow draws your disk as a cross-section of dots: free space is the air on top, and the layers below are what fills it, from macOS at the bottom to your home folder at the top.

| Screen | Mole command | Notes |
|---|---|---|
| Dig | `mo clean --dry-run`, `mo installer --dry-run`, `mo purge --dry-run`, then `mo clean`, `mo installer`, `mo purge` | One scan for caches, installers and build leftovers. What it finds glows as veins in the top layer. Caches clear together; Keep adds a path to Mole's protected list. Installers and build leftovers are picked one by one. System caches are optional and ask for your password |
| Tune up | `mo optimize --dry-run`, `mo optimize` | Opens from Dig. Tasks that need admin access are skipped if you decline |
| Vitals | `mo status --watch` | Processor, memory and battery on Dig; click for the health score, busiest apps and network |
| Apps | `mo uninstall --list`, `--dry-run`, `mo uninstall`, `mo slim --dry-run` | Pick apps or drop them on the panel. Mole's plan is measured into app, data, caches and settings before anything moves to the Trash. Slimming opens Mole's own picker in Terminal |
| Space | `mo analyze --json` | Folders as layers; double-click to open one. Move to Trash is limited to your home folder |
| Log | `mo history --json` | Everything Mole removed or changed, with the files of each run |
| Settings (⌘,) | `~/.config/mole/whitelist`, `purge_paths`, `mo touchid` | Shared with the Mole CLI |

## How Burrow drives Mole

- Read-only data comes from Mole's JSON output (`status`, `analyze`, `history`, `uninstall --list`).
- Burrow builds its previews from the same text Mole prints for `--dry-run`, so they match what Mole will do.
- Mole only lets you choose installers and project artifacts through its terminal menus. Burrow runs those menus in a hidden terminal and steps through them row by row, so exactly what you selected is marked. It then reads Mole's own confirmation list and presses Enter only when that list matches your selection. On any difference it backs out and nothing changes.
- Uninstall works the same way: Burrow confirms only when Mole's plan names the exact app bundles you picked. If another installed app answers to the same name, Burrow refuses and points you to `mo uninstall` in Terminal.
- App Slimming is the exception. Mole's slim picker redraws only the rows that change, which Burrow cannot follow reliably, so that choice happens in Terminal.
- **Administrator access.** Each run gets its own pseudo-terminal, so a single password covers the whole run. When sudo asks, Burrow shows a native password sheet and passes the password straight to sudo; it never stores it. If you turn on Touch ID for administrator tasks in Settings, macOS shows its own Touch ID prompt instead.

## Build

Requires macOS 14 or later, Swift 6 (Command Line Tools are enough) and Go. On macOS 26 and later the panels use Liquid Glass; earlier versions get a material with the same layout.

```bash
./scripts/build-app.sh
```

The script clones the Mole tag pinned in `MOLE_VERSION`, builds Mole's Go tools for both architectures, and writes `dist/Burrow.app`. Point it at a local Mole checkout with `MOLE_SOURCE=/path/to/Mole`. The app is signed ad hoc unless you set `SIGN_IDENTITY`. Distributing it outside your own Mac needs a Developer ID signature and notarization.

## Test

```bash
./scripts/test.sh
```

With `MOLE_SOURCE` set, it also runs the live tests against that checkout. They only use previews and dry runs, so nothing on the Mac changes.

## Updating Mole

1. Change `MOLE_VERSION` to the new tag.
2. Run `MOLE_SOURCE=/path/to/Mole ./scripts/test.sh` against a checkout of that tag. The live tests drive the new Mole's real menus and previews.
3. Refresh the fixtures under `Tests/BurrowCoreTests/Fixtures` from the new version's output.

A format change then fails a test instead of breaking a screen.

## License

GPL-3.0, the same as Mole. Burrow is an independent project and is not affiliated with Mole or Mole for Mac.
