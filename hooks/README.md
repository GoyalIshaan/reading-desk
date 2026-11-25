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
hooks/reading-desk tabs --shelf "Everything else"
hooks/reading-desk tabs --shelf "AI research"   # includes tabs on its sub-shelves
hooks/reading-desk tabs --auto-only     # tabs the app filed automatically
hooks/reading-desk shelves              # the shelf tree, indented, with ids and counts

hooks/reading-desk assign <url> <shelf>        # one tab → a shelf (id, name, or path)
hooks/reading-desk assign-site <site> <shelf>  # pin a whole site to a shelf
hooks/reading-desk auto <url>                  # back to automatic filing
hooks/reading-desk ensure-shelf "Read later" --icon bookmark
hooks/reading-desk ensure-shelf "Post-training" --parent "AI research"
hooks/reading-desk organize --shelf "AI research" --dry-run  # Claude proposes sub-shelves
hooks/reading-desk organize --shelf "AI research"            # ...and files the tabs
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
  {"op": "assign", "url": "https://news.ycombinator.com/item?id=1", "category": "Everything else"}
]
JSON
reading-desk apply plan.json
```

4. `reading-desk tabs` again to confirm (or read `state.json`'s `log`).

## Sorting a shelf with Claude

`organize` sorts one shelf's tabs into sub-shelves by topic. It needs
[Claude Code](https://claude.com/claude-code) installed and signed in. The app
runs the same command from ⇧⌘P → **Sort this shelf into sub-shelves with
Claude**, on the shelf you're viewing or reading.

What it does, in order:

1. Reads `state.json` and takes the tabs filed directly on the shelf (with
   `--all`, every tab anywhere inside it).
2. Sends their titles, sites and addresses, plus the shelf's existing
   sub-shelves, to `claude -p`. Claude runs with no tools and no MCP servers,
   so it can only return a plan. It can't read files or run commands, whatever
   a page title says.
3. Checks the plan:
   - It drops unknown tabs and cleans names.
   - It reuses existing sub-shelves at any depth, and allows at most two levels
     for new ones.
   - It creates at most `--max-new` new sub-shelves (default 6), counting new
     parents too.
   - Tabs Claude can't place keep their current shelf.
4. Prints the plan. With `--dry-run` it stops here.
5. Queues one batch: `ensureCategory` for each new sub-shelf, then `assign`
   for each tab. Existing shelves are referred to by id.
6. Waits for the app to apply the batch, then checks `state.json` and reports
   how many tabs actually moved.

`--max-new 0` makes it use only sub-shelves you already created. Their title
words are shown to Claude as hints of what each one covers.

Options:

- `--all`: re-sort tabs already on sub-shelves too.
- `--url ADDRESS`: sort only this tab; repeat it for several.
- `--dry-run`: show the plan without changing anything.
- `--max-new N`: the most new sub-shelves to create.
- `--model M`: a Claude model alias, such as `sonnet` or `opus`.

Tabs are filed with per-tab assignments, so they stay put. New tabs land on the
shelf itself until you sort again, unless the shelf has **Sort new tabs into
sub-shelves automatically** turned on in the app's shelf editor. Then the app
runs `organize --max-new 2 --url <each new tab>` for it after each refresh that
brings new tabs.
`state.json` shows the setting as `autoSort` on each shelf.

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
| `ensureCategory`| `name`, `icon?`, `parent?`    | create a shelf if it's missing           |
| `refresh`       | —                             | re-read tabs from Helium                 |

`category` and `parent` each name one shelf in any of these forms:

- **id:** the shelf's `id` from `state.json`.
- **name:** case-insensitive. If several shelves share a name, a top-level
  shelf with that name wins; otherwise the first one in `state.json` order
  does. Use a path to reach a specific nested one.
- **path:** each level's name, separated by `›`, `>` or `/`, for example
  `AI research › Post-training` or `AI research/Post-training`.

`url` must match a tab's `url` from `state.json` exactly. `icon` is an SF
Symbol name (`airplane`, `flask`, `bookmark`, …).

`ensureCategory` with `parent` looks only among that shelf's direct children
and creates the new shelf inside it. A `name` written as a path with `›` or `>`
(such as `AI research › Post-training`) does the same, using the leading levels
as the parent. `/` doesn't split a name, so `CI/CD` stays one shelf. Without
either, any shelf with that name counts, and a new one is created at the top
level. It fails, and records an error in `log`, if the parent doesn't match a
shelf, is `Everything else`, or is given both ways.

## Nested shelves in `state.json`

Shelves can sit inside other shelves. `categories` lists every shelf with its
parent before its children, with siblings in filing order. The nesting fields are:

- `parent`: the id of the shelf it sits inside, or `null` at the top level.
- `path`: the readable path, for example `AI research › Post-training`.

Each tab in `tabs` also has `categoryPath`, the readable path of its shelf.
`category` and `categoryName` still give only the shelf's own id and name.

Assignments you make here are the same ones the app's own "Move to shelf" menu
writes, so they persist and win over the automatic rules — exactly as if you'd
set them by hand.
