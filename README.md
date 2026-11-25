# Reading Desk

Reading Desk is a standalone macOS app for reading Helium tabs beside ChatGPT, Claude, or an Obsidian note. It uses system WebKit and builds with the macOS Swift toolchain. It has no runtime dependencies to install.

1. Open **Reading Desk** with Helium running. If macOS prompts for Automation access, allow Reading Desk to control Helium so it can import open tab titles and URLs.
2. Choose a topic card, then pick a tab or click **Start reading**. The arrows and source menu move through the topic. Drag the center divider to resize the panes.
3. Select **ChatGPT**, **Claude**, or **Notes**. Websites have a separate sign-in session in Reading Desk. Use the arrow in a web pane to reopen its current URL in Helium.
4. In **Notes**, select **Use Dev vault** or **Choose folder…**. Edit any Markdown file in the selected vault. New notes go into its `Reading Desk` folder and start with the current source link. Edits autosave, with a conflict prompt if they would overwrite an outside change.

Tabs are categorized on-device. The row menu assigns a category to a URL or restores automatic categorization. Notes stay in the vault. **⌘ K** searches tabs, **⌘ ⇧ N** toggles between Notes and chat, and **⌘ ⌥ ←/→** moves between sources.

## Build

Run `./build.sh` to write the app bundle to `build/Reading Desk.app`. Pass an output directory to place the bundle elsewhere. The app targets macOS 14 or later and builds for the current Mac’s architecture.

For sample tabs, run `open -n -a "$PWD/build/Reading Desk.app" --args --sample` from this directory.
