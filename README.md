# Burrow

A Mac cleaner that shows you your disk instead of a list. Burrow draws the startup disk as a cross-section of dots, with free space as the air on top, and lets you dig through it for caches, old installers and build leftovers.

Every scan and every deletion is done by [Mole](https://github.com/tw93/Mole), the open-source cleanup CLI by tw93. Burrow bundles a pinned copy of Mole and puts a native SwiftUI interface on top. It never deletes a file itself.

![Burrow after a dig](docs/dig.png)

## What's inside

**Dig.** One scan runs Mole's previews for caches, installers and build leftovers while a worm searches your home folder's layer. Each finding lights up as a thread along its trail. Uncheck what you want to keep, press Clear, and the marked dots drop away as the ground settles into the space you got back. Tune up (Mole's maintenance tasks) and live CPU, memory and battery sit in the toolbar.

**Apps.** Pick an app, or drop one on the panel, to see everything that leaves with it: the app, its data, caches and settings, and your personal data if you choose. Apps that still carry Intel code can be slimmed instead.

**Space.** Folders as layers. Double-click one to go deeper. Folders Mole thinks are worth a look are marked.

**Log.** Everything Mole removed or changed, with the files of each run.

**Settings** (⌘,) picks the color palette (Moonlight, Ember, Lagoon or Iris) and edits the same files as the Mole command line: protected paths, project folders, and Touch ID for administrator tasks.

## Safety

- Every preview is a Mole dry run. Nothing changes until you press Clear or Uninstall.
- Mole can't clean some cache categories and skip others, so caches clear together. Keep adds a path to Mole's protected list. If the cache preview didn't finish, Clear leaves caches alone.
- Installers and uninstalled apps go to the Trash. Build leftovers are deleted. Mole only offers ones untouched for 7 days, and they start unchecked.
- Installers, build leftovers and uninstalls go through Mole's own menus. Burrow selects your picks row by row and confirms only when Mole's confirmation lists exactly those items. On any difference it backs out and nothing changes.
- If another installed app answers to the same name, Burrow won't uninstall and points you to `mo uninstall`.
- Your password goes straight to sudo for one run and is never stored. With Touch ID turned on, macOS asks instead.
- Slimming happens in Mole's own picker in Terminal, because Burrow can't follow that menu reliably.
- Space moves things to the Trash only inside your home folder, and never the folders macOS depends on.

## Build

Requires macOS 14 or later, Swift 6 (Command Line Tools are enough) and Go. On macOS 26 and later the panels use Liquid Glass.

```bash
./scripts/build-app.sh
```

The script fetches the Mole tag pinned in `MOLE_VERSION`, builds Mole's Go tools for both architectures, and writes `dist/Burrow.app`. To use a local Mole checkout instead, set `MOLE_SOURCE=/path/to/Mole`. Without Xcode, Burrow itself is built for Apple Silicon only. The app is signed ad hoc unless you set `SIGN_IDENTITY`; distributing it needs a Developer ID signature and notarization.

To run a debug build against the Mole that `build-app.sh` prepared:

```bash
swift build
BURROW_MOLE=.build/app/mole/mole BURROW_SESSION_HELPER=.build/debug/burrow-session .build/debug/Burrow
```

## Test

```bash
./scripts/test.sh
```

With `MOLE_SOURCE` set, it also runs live tests against that checkout. They only use previews and dry runs, so nothing on the Mac changes.

## Updating Mole

1. Change `MOLE_VERSION` to the new tag.
2. Run `MOLE_SOURCE=/path/to/Mole ./scripts/test.sh` against a checkout of that tag. The live tests drive the new Mole's real menus and previews.
3. Refresh the fixtures in `Tests/BurrowCoreTests/Fixtures` from the new version's output.

A change in Mole's output then fails a test instead of breaking a screen.

## License

GPL-3.0, the same as Mole. Burrow is an independent project and is not affiliated with Mole or Mole for Mac.
