# OPEN_UP

A Spotlight-style "open with…" picker in a black-and-white terminal style.

- **Docker** (`server/`): file-type rules, learning from your picks, and the UI (picker + settings). State is kept in `./data/state.json`.
- **Mac helper** (`helper/`, installs to `~/Applications/OPEN_UP.app`): receives files from macOS, shows the picker in a floating window, and launches the app you pick. It also indexes your installed apps and asks macOS which apps can open each file.

## Install

```bash
./install.sh
```

## Use

| | |
|---|---|
| `open ~/Applications/OPEN_UP.app` | settings: rank apps per extension |
| `./bin/openup file.pdf` | show the picker for a file |
| `./bin/openup --default md pdf txt` | make OPEN_UP the double-click app for those types |

Picker keys: `↑↓` move · `⏎` open · `⇧⏎` open and always use this app · `⇥` show other apps · type to search everything · `esc` quit.

**How the guess is ranked:** your ranked apps for the extension come first, then `*` (any-type) rules, then apps you've picked before (by how often, with a bonus for recent picks), then macOS's suggestions.

If the container is down, the helper falls back to a native alert listing macOS's top 3 suggestions.

To undo a default: Finder → Get Info → Open with → choose an app → Change All.
