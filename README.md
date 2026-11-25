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
- Shelves are checked in order. A tab goes into the first shelf that matches a site rule or title keyword. Move a shelf earlier to give its rules priority.
- Hover near the bottom of the reading pane to show the reading controls. You can move between tabs, open the shelf’s tab list, go back or forward on the site, or copy the current link.
- **Done** (**⇧⌘D**) marks the current item read and advances to the next tab. **It also closes matching Helium tabs, including duplicate tabs for that URL, by default.** If you want to keep your Helium tabs open, press **⇧⌘P** and turn off **Close Helium tabs when marked done**.

## Sign in to websites and assistants

Reading Desk has its own persistent browser profile. Sign in inside its pane when a site asks, including the first time you open an assistant that requires an account. The app keeps site data between launches. Websites can still expire sessions or limit sign-in from an embedded browser. Use **Open in Helium** from the page controls if you need the full browser for a site.

If the password field’s macOS menu offers it, right-click the field and choose **AutoFill → Passwords…** to pick a saved login.

## Connect and edit notes

1. Open a reading tab and choose **Notes**.
2. Click **Choose folder…** and select your vault folder in Finder. Choose the folder that contains your notes. To try it with fresh notes, create and select an empty folder.
3. Search for an existing note, or click **New note for this page**. New notes go into a `Reading Desk` subfolder of the vault and start with the current page’s source link.
4. Changes autosave to the Markdown file. Press **⌘E** to switch between live preview and raw Markdown. The Notes **…** menu lets you refresh the note list, choose a different vault, or open the selected note in Obsidian.

Live preview supports frontmatter, callouts, wikilinks, embeds, tags, highlights, task lists, tables, code blocks, and KaTeX math. Full LaTeX and TikZ rendering uses a local TeX installation with `latex` and `dvisvgm`. The app checks `/Library/TeX/texbin` and other common install paths.

If the same note changes on disk while you’re editing it, Reading Desk shows a conflict and keeps your draft available to copy before you reload the file.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⇧⌘P | Search tabs and shelves or run a command |
| ⇧⌘R | Refresh Helium tabs |
| ⌘[ | Return to all shelves from the library, or go back on the current webpage while reading |
| ⌘] | Go forward on the current webpage |
| ⌘↩ | Begin reading the current shelf, or open the selected tab in Helium from the command palette |
| ⇧⌘[ | Return to the library from the reading pane |
| ⌥⌘← / ⌥⌘→ | Go to the previous or next tab on the shelf |
| ⇧⌘D | Mark the current tab done and advance |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 | Switch to ChatGPT / Claude / Gemini / Notes |
| ⇧⌘N | Toggle between Notes and the last assistant |
| ⇧⌘C | Copy the current page link |
| ⌘E | Switch the Notes editor between live preview and Markdown |

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
