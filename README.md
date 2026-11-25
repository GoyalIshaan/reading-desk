# Reading Desk

A dark, distraction-free macOS app for working through your open Helium tabs. Tabs are filed onto shelves automatically. Open a shelf and you get a split view: the page fills the left side, edge to edge, and ChatGPT, Claude, Gemini or your Obsidian notes sit on the right. Hit **Done** and the tab closes in Helium and the next one on the shelf opens.

## Using it

1. Open **Reading Desk** with Helium running. If macOS asks, allow it to control Helium. It needs that to read your tabs and to close the ones you finish.
2. Pick a shelf from the index at the top, then click **Begin reading**, or click any card to start from that tab.
3. On the right, switch between **ChatGPT · Claude · Gemini · Notes**. Each one keeps its own sign-in, and you stay logged in between launches.
4. The page has no toolbar. Hover the small pill in its bottom-right corner to get back, forward, reload and "open in Helium". Click the link icon to copy the URL.
5. Click **Done** (⇧⌘D) when you've finished a tab. To keep tabs open in Helium, turn that off under the sliders menu.

## Library

Each tab gets a card with its page's preview image, favicon, site, an estimated reading time, the title and the page's own description. Papers on arXiv and OpenReview, and PDFs, show their first page. Pages with no useful image get a snapshot, taken in a private off-screen browser. Pages that need a sign-in (Gmail, ChatGPT, Notion…) get a plain cover. Previews are cached in `~/Library/Caches/dev.readingdesk.mac`.

Hover a card to mark it done or move it to another shelf without opening it.

## Notes

The Notes pane renders Markdown the way Obsidian does: Properties, callouts (including folding ones), `[[wikilinks]]`, embedded notes and images (`![[…]]`), `#tags`, `==highlights==`, checkboxes you can click, tables and highlighted code. Math goes through KaTeX. Anything KaTeX can't handle, and every ` ```tikz ` block, is compiled by your TeX installation (`latex` + `dvisvgm`, found in `/Library/TeX/texbin`). Editing is live preview, as in Obsidian: click anywhere to edit, and only the line or block you're in shows raw Markdown. Leave the line and it renders. After 5 seconds without typing, the current line renders too, and you can keep typing straight away. Lists and tasks continue on Enter. **⌘E** switches to full source mode.

## Shelves and auto-filing

Click the books icon in the library to edit shelves. You can add, rename, reorder and delete them. Each shelf has:

- **Sites**: `arxiv.org` matches that site and its subdomains, `docs.` matches hosts that start with it, and `/blog/` matches anywhere in the URL.
- **Title keywords**: words that show up in the tab title.

A tab goes onto the first shelf (top to bottom) that matches it. Use *Earlier* to move a shelf up. Each card's `…` menu (on hover) also has **Move to shelf** for a one-off change, and **Always file *site* in…** to pin a whole site to a shelf.

## Shortcuts

| | |
|---|---|
| ⇧⌘P | Search every tab by title, site, shelf or description |
| ⌘[ | Library: back to all shelves |
| ⌘↩ | Start reading the open shelf |
| ⇧⌘D | Done, then next tab |
| ⌥⌘← / ⌥⌘→ | Previous / next tab on the shelf |
| ⌘[ / ⌘] | Page back / forward |
| ⌥⌘1–4 | ChatGPT / Claude / Gemini / Notes |
| ⇧⌘N | Toggle notes ↔ last chat |
| ⇧⌘C | Copy page link |
| ⇧⌘[ | Back to library |
| ⌘E | Notes: live preview ↔ source mode |

## Build

```bash
./build.sh
```

This writes `build/Reading Desk.app`. Fonts (EB Garamond, Geist, Monaspace Argon; all SIL OFL) and the notes renderer are bundled from `Resources/`. To change the renderer, edit `web/renderer.js` and run `web/build.sh` (it needs esbuild, markdown-it and highlight.js; see the script). To install it, copy it to `~/Applications`. To try it with sample tabs, run `open -n -a "$PWD/build/Reading Desk.app" --args --sample`. Needs macOS 14 or later.
