# Reading Desk

Reading Desk is a macOS app for working through your open Helium tabs. It groups them into shelves such as **Papers & research** and **Code & engineering**. Open a card to read the page on the left and use **ChatGPT, Claude, Gemini, or your Obsidian notes** on the right. Both panes are inside Reading Desk.

## Install

### 1. Get the prerequisites

- A Mac running **macOS 14 Sonoma or later**.
- [Helium](https://helium.computer/) for importing your open tabs. You can try the app with sample tabs before connecting Helium.
- [Apple’s Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) or a working Xcode installation. If you need the tools, run this in Terminal and finish the macOS installer before continuing.

```bash
xcode-select --install
```

[Obsidian](https://obsidian.md/) is optional. The Notes pane works with an existing Obsidian vault or any local folder of Markdown files.

### 2. Clone, build, and open the app

Run these commands in Terminal from the directory where you want to keep the source.

```bash
git clone https://github.com/GoyalIshaan/reading-desk.git
cd reading-desk
./build.sh "$HOME/Applications"
open -a "$HOME/Applications/Reading Desk.app"
```

The build makes an app for the architecture of the Mac you run it on. It installs to **Applications inside your home folder** (`~/Applications`). In Finder, press **⇧⌘G** and enter `~/Applications` to find it. The standard build uses Apple’s tools and the assets already in the repo.

### 3. Import your tabs and open a page

1. Open Helium with a few tabs, then open Reading Desk.
2. If macOS asks whether Reading Desk can control Helium, choose **Allow**. Reading Desk uses this permission to import tab titles and URLs and to close tabs when you mark them done, if that option is enabled.
3. Click a shelf in the library. Click any card to start from that page, or click **Begin reading** to start with the first tab on the shelf.
4. Pick **ChatGPT**, **Claude**, **Gemini**, or **Notes** above the right pane. Drag the divider to resize the two panes.

To try the layout with sample data, quit Reading Desk first, then run:

```bash
open -a "$HOME/Applications/Reading Desk.app" --args --sample
```

Open it normally afterward to import your Helium tabs.

## Work through a shelf

- Press **⇧⌘P** to search tabs and shelves or run commands such as **Refresh Helium tabs** and **Edit shelves and filing rules**.
- Cards can show a preview image, site icon, description, and estimated reading time. Some papers and PDFs show a first-page preview. Login-gated sites can show a plain cover.
- Hover a card for actions. **Move to shelf** files that tab once. **Always file … in…** creates a rule for the site.
- Top-level shelves are checked in order. A tab goes into the first one that matches a site rule or title keyword. Move a shelf earlier to give its rules priority. Inside a shelf, its sub-shelves are checked before the shelf itself; see [Nested shelves](#nested-shelves).
- Hover near the bottom of the reading pane to show the reading controls. You can move between tabs, open the shelf’s tab list, go back or forward on the site, or copy the current link. Swipe and page back stay within the current tab’s history, so they never return you to another tab, including one you marked done.
- **Done** (**⇧⌘D**) marks the current item read and advances to the next tab. **It also closes matching Helium tabs, including duplicate tabs for that URL, by default.** If you want to keep your Helium tabs open, press **⇧⌘P** and turn off **Close Helium tabs when marked done**.

## Nested shelves

A shelf can hold sub-shelves, for example **AI research** containing **Pre-training**, **Post-training**, **Architecture**, and **Infra & systems**.

- **Create one:** press **⇧⌘P** and open **Edit shelves and filing rules**. Select a shelf and click **New sub-shelf**, or set the **Inside** menu on any existing shelf.
- **Browse:** the big names at the top show only top-level shelves, and their counts include every sub-shelf. Select a shelf that has sub-shelves to see them in a smaller row below. A parent's page shows a section for each sub-shelf, then **Unsorted in …** for tabs filed on the parent itself. Press **⌘[** or click the **↑** link to go up a level.
- **Read:** **Begin reading** or **Read shelf** on a parent queues every tab inside it, in the order the page shows them.
- **Filing:** top-level shelves are still checked in order. Within a shelf, its sub-shelves are checked first, so a tab lands on the deepest shelf that matches. **Move to shelf** and **Always file … in** can point at a shelf at any level.
- **Reorganize:** **Earlier** and **Later** move a shelf among the shelves at its own level. Deleting a shelf moves its sub-shelves up one level. **Unsorted** can't be nested or hold sub-shelves.
- **Let Claude sort a shelf:** open the shelf, press **⇧⌘P**, and run **Sort this shelf with Claude**. Claude groups the tabs filed directly on that shelf into topic sub-shelves, creating any it needs. On **Unsorted** it triages instead: it moves each tab that no rule caught to whichever shelf fits what the page is about, at any depth, and leaves the rest. It never creates shelves there, and it never moves tabs you put there yourself. This needs [Claude Code](https://claude.com/claude-code) installed and signed in. From Terminal, `hooks/reading-desk organize --shelf "AI research" --dry-run` shows the plan without changing anything.
- **Sort new tabs automatically:** in **Edit shelves**, select a shelf that has sub-shelves and turn on **Sort new tabs into sub-shelves automatically**. After each refresh, only the tabs newly landed directly on that shelf go to Claude, which files each one into a sub-shelf by what it's about. It prefers your sub-shelves and adds at most 2 new ones per run. Turn on **Move new tabs to the shelf that fits** on **Unsorted** to triage new unmatched tabs the same way, so you don't have to add a rule for every blog. Each run sends at most 25 tabs, and a tab Claude leaves where it is isn't sent again, even after a restart. If Claude Code fails on a shelf, for example because you're signed out, that shelf pauses for 10 minutes, then 20, and stops after 3 failures until you reopen the app. Sample data (`--sample`) is never auto-sorted.
- **From scripts:** `hooks/reading-desk ensure-shelf "Post-training" --parent "AI research"`. Anywhere the CLI takes a shelf, you can give a path such as `"AI research › Post-training"`. See the [bridge README](hooks/README.md).

## Sign in to websites and assistants

Reading Desk has its own persistent browser profile. Sign in inside its pane when a site asks, including the first time you open an assistant that requires an account. The app keeps site data between launches. Websites can still expire sessions or limit sign-in from an embedded browser. Use **Open in Helium** from the page controls if you need the full browser for a site.

If the password field’s macOS menu offers it, right-click the field and choose **AutoFill → Passwords…** to pick a saved login.

## Connect and edit notes

1. Open a reading tab and choose **Notes**.
2. Click **Choose folder…** and select your vault folder in Finder. Choose the folder that contains your notes. To try it with fresh notes, create and select an empty folder.
3. Search for an existing note, or click **New note for this page**. New notes go into a `Reading Desk` subfolder of the vault and start with the current page’s source link.
4. Changes autosave to the Markdown file. Press **⌘E** to switch between live preview and raw Markdown. The Notes **…** menu lets you refresh the note list, choose a different vault, or open the selected note in Obsidian.

Live preview supports frontmatter, callouts, wikilinks, embeds, tags, highlights, task lists, tables, code blocks, and KaTeX math. Full LaTeX and TikZ rendering uses a local TeX installation with `latex` and `dvisvgm`. The app checks `/Library/TeX/texbin` and other common install paths.

**Editing** works across lines in live preview: drag, ⇧-click, ⇧+arrows or ⌘A, then cut, copy, paste or type over the selection. The lines you select show as Markdown while they’re selected. The **Format** menu works in both live preview and Markdown mode. Underline is written as `<u>text</u>`, because Markdown has no syntax for it. `---` always draws a divider, even directly under a line of text, and the notes editor leaves dashes and quotes as you type them.

**Pasting an image** or a file copied in Finder saves it in your vault and embeds it. Reading Desk reads the vault’s `.obsidian/app.json`, so Obsidian’s **Settings → Files and links** choices for the attachment folder, wikilinks and link format apply here too. If you haven’t set an attachment folder, Obsidian’s default is the vault root.

If the same note changes on disk while you’re editing it, Reading Desk shows a conflict and keeps your draft available to copy before you reload the file.

## Highlights and questions

Select anything on the page (a paragraph, an equation, a code block) and a small bar appears above it. The same actions are in the right-click menu:

- **Save to note** quotes it in the page’s note as an Obsidian `[!quote]` callout. The callout carries the page title and a link straight back to the passage (a scroll-to-text link, or `#page=N` for PDFs), plus the section it sits under and, for PDFs, the page number. The Notes pane opens with the caret on the line below the quote, so you can write down what you understood. Math is saved as TeX (KaTeX, MathJax, Wikipedia and arXiv HTML all work), and code keeps its language.
- **Ask** drafts a question in ChatGPT, Claude or Gemini (the chevron picks which) with the passage and its source in the message box. Nothing is sent. If a chat’s box can’t be reached, the question goes on your clipboard instead.

Each page has one note. It’s the note you created for it, or any note whose `source:` property links to it. If there isn’t one, the first highlight creates `Reading Desk/<title>.md` with `source`, `created` and `tags` properties. arXiv abstract, PDF and HTML links all count as the same paper, and so do DOIs, OpenReview links, and addresses that differ only in `www.`, trailing slashes or tracking parameters. To send a page’s highlights to a different note, open that note and choose **Save this page’s highlights here** from the Notes `…` menu.

## Earlier notes

Reading Desk indexes the links in your vault. A card with notes about its page shows a ✎ count. When you open the page, a toast tells you, the Notes tab shows the count, and the notes list starts with **On this page**. If you have another note open, a strip above it links to the earlier ones.

## Papers

PDFs open in a native PDF reader. **Contents** (the list icon in the dock, or right-click → Sections…) jumps between the PDF’s sections, or the headings of a web page. The dock shows the page you’re on, and Reading Desk remembers it. On a paper (arXiv, OpenReview, a DOI, ACL, NeurIPS, PMLR, PDFs), **Copy BibTeX** (in the dock or the right-click menu) fetches the published entry, or builds a `@misc` entry when there isn’t one. On arXiv, the dock flips between the abstract page and the PDF.

## Bookmarks, Read later, and continuing

**Bookmarks** (**⌘D**, the bookmark icon in the dock or on a card, or right-click on the page) permanently save any page you are viewing — including PDFs or links you clicked into while reading. Unlike **Read later**, marking a tab **Done** never removes a bookmark. Open **Bookmarks** from the top of the library, press **⌥⌘B**, or search them anytime in **⇧⌘P**. Hover a bookmark card to attach an optional note or remove it.

**Read later** (**⇧⌘L**, the clock in the dock, a card’s hover button, or right-click on the page) moves a page to the *Read later* shelf and, if *Close Helium tabs when marked done* is on, closes its Helium tab. The page stays on the shelf until you mark it done. Remove it from a card’s `…` menu.

Quit while reading and Reading Desk reopens the same page at the same scroll position (or PDF page), with the same companion and note. Turn this off with ⇧⌘P → **Reopen where I left off on launch**, or jump back any time with **Continue where I left off**.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⇧⌘P | Search tabs, bookmarks, and shelves or run a command |
| ⌘D | Bookmark or remove bookmark for the page you’re viewing |
| ⌥⌘B | Open Bookmarks |
| ⇧⌘L | Save the current tab to Read later |
| ⇧⌘R | Refresh Helium tabs |
| ⌘[ | Go up one shelf level in the library (to all shelves from a top-level shelf), or go back on the current webpage while reading |
| ⌘] | Go forward on the current webpage |
| ⌘↩ | Begin reading the current shelf, or open the selected tab in Helium from the command palette |
| ⇧⌘[ | Return to the library from the reading pane |
| ⌥⌘← / ⌥⌘→ | Go to the previous or next tab on the shelf |
| ⇧⌘D | Mark the current tab done and advance |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 | Switch to ChatGPT / Claude / Gemini / Notes |
| ⇧⌘N | Toggle between Notes and the last assistant |
| ⇧⌘C | Copy the current page link |
| ⌘E | Switch the Notes editor between live preview and Markdown |
| ⌘B / ⌘I / ⌘U | Bold, italic or underline in a note |
| ⇧⌘X / ⇧⌘H / ⇧⌘E | Strikethrough, highlight or inline code in a note |
| ⌘K | Add a link in a note |

## Update

Quit Reading Desk. From the folder you cloned, run:

```bash
git pull --ff-only
./build.sh "$HOME/Applications"
open -a "$HOME/Applications/Reading Desk.app"
```

The script replaces the app at the same path. Notes are stored in the vault you chose. Browser data and app preferences are stored separately from the app bundle.

## Troubleshooting

| If you see this | Try this |
| --- | --- |
| Terminal can’t find the developer tools | Run `xcode-select --install`, finish the system installer, and rerun the build. |
| The library is empty | Open a regular Helium window with some tabs and run **Refresh Helium tabs** from **⇧⌘P**. Private windows and browser-internal pages are excluded. |
| Reading Desk says it can’t control Helium | In **System Settings → Privacy & Security → Automation**, allow Reading Desk to control Helium. Reopen Reading Desk and refresh. |
| A page needs a sign-in | Sign in inside Reading Desk, or use **Open in Helium** if the site blocks embedded sign-in. |
| The Notes pane can’t find a file | Select the vault root using **Notes → … → Choose another vault…**, then **Refresh notes**. |

## Build and development

- Run `./build.sh` without an output path to build `build/Reading Desk.app` from the local source.
- `Sources/` contains the SwiftUI app, library, embedded WebKit reader, and vault integration. `Resources/helium.js` talks to Helium using macOS Apple Events. Fonts and the bundled Markdown renderer live in `Resources/`.
- The Markdown renderer source is in [`web/renderer.js`](web/renderer.js). Rebuild the bundle with [`web/build.sh`](web/build.sh) when editing the renderer. That step uses esbuild, markdown-it, and highlight.js.
- The optional [local CLI and bridge](hooks/README.md) lets scripts list tabs and manage shelves. The CLI needs Python 3. The running app writes tab titles and URLs to its local bridge state file.
- Bundled font notices are in [`Resources/Fonts/`](Resources/Fonts). Renderer and math library licenses are in [`Resources/web/`](Resources/web).
