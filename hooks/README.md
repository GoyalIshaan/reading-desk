# Reading Desk — agent bridge

A small local bridge so a script, Codex, or Claude can read your open tabs and
sort them into shelves, without clicking around the app. Everything is local
files under:

```
~/Library/Application Support/dev.readingdesk.mac/
  state.json        # the app writes this: every tab + shelf, live
  commands/         # you write here: JSON instructions the app applies (~1s)
```

The app is always the only thing that writes its own settings. You read
`state.json` and drop command files; the app applies them, deletes them, and
updates `state.json` (including a `log` of what it did).

## CLI

`hooks/reading-desk` wraps it (Python 3, no dependencies). Reading Desk must be
running for live changes; commands queued while it's closed run at next launch.

```bash
hooks/reading-desk tabs                 # every tab and its shelf
hooks/reading-desk tabs --json          # for agents
hooks/reading-desk tabs --shelf "Unsorted"
hooks/reading-desk tabs --auto-only     # tabs the app filed automatically
hooks/reading-desk shelves              # shelves with their ids and counts

hooks/reading-desk assign <url> <shelf>        # one tab → a shelf (name or id)
hooks/reading-desk assign-site <site> <shelf>  # pin a whole site to a shelf
hooks/reading-desk auto <url>                  # back to automatic filing
hooks/reading-desk ensure-shelf "Read later" --icon bookmark
hooks/reading-desk refresh                     # re-read tabs from Helium
hooks/reading-desk apply plan.json             # a batch (see below)
```

A typical "organize my tabs" run for an agent:

1. `reading-desk tabs --json` to see every tab (title, url, site, current shelf).
2. Decide a shelf per tab. Create new shelves first with `ensure-shelf` if needed.
3. Write a batch and apply it:

```bash
cat > plan.json <<'JSON'
[
  {"op": "assign", "url": "https://arxiv.org/abs/1706.03762", "category": "Papers & research"},
  {"op": "assign", "url": "https://news.ycombinator.com/item?id=1", "category": "Unsorted"}
]
JSON
reading-desk apply plan.json
```

4. `reading-desk tabs` again to confirm (or read `state.json`'s `log`).

## Raw protocol (no CLI needed)

Read `state.json`. To make a change, write a `.json` file into `commands/`
containing one command object or an array of them. Write to a temp name first
then rename into place, so the app never reads a half-written file. Supported
`op`s:

| op              | fields                        | effect                                   |
|-----------------|-------------------------------|------------------------------------------|
| `assign`        | `url`, `category`             | put that tab on a shelf                   |
| `assignSite`    | `site`, `category`            | always file that site on a shelf         |
| `auto`          | `url`                         | clear the override, file automatically   |
| `ensureCategory`| `name`, `icon?`               | create a shelf if it's missing           |
| `refresh`       | —                             | re-read tabs from Helium                 |

`category` is a shelf **id** or its **name** (case-insensitive). `url` must
match a tab's `url` from `state.json` exactly. `icon` is an SF Symbol name
(`airplane`, `flask`, `bookmark`, …).

### Shelves an agent makes

`ensureCategory` makes a shelf marked `madeByAgent` in `state.json`. It goes after the
user's own shelves, shows a small ✦ in the library index, and is **temporary**: once
none of its tabs are open any more (they were read, or closed in Helium), the app
removes it, after a 10-minute grace period so an agent can create a shelf and fill it in
separate steps. The user can choose **Keep this shelf** in the shelf editor to make it
permanent. So an agent can sort the *Unsorted* pile into topic shelves freely: the
shelves tidy themselves up afterwards and never pile up.

Assignments you make here are the same ones the app's own "Move to shelf" menu
writes, so they persist and win over the automatic rules — exactly as if you'd
set them by hand.
