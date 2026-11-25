// Talks to Helium over Apple Events (JXA).
//   (no args)                     → JSON list of every tab in every window, front window first
//   focus <windowID> <tabID>      → bring that tab to the front
//   close <windowID> <tabID> ...  → close one or more tabs (pairs)
function run(argv) {
    const helium = Application('net.imput.helium');
    const command = argv[0];

    function windowsByID() {
        const map = new Map();
        for (const window of helium.windows()) {
            try { map.set(String(window.id()), window); } catch (error) {}
        }
        return map;
    }

    function tabIndex(window, tabID) {
        return window.tabs.id().map(String).indexOf(String(tabID));
    }

    if (command === 'focus') {
        const window = windowsByID().get(String(argv[1]));
        const index = window ? tabIndex(window, argv[2]) : -1;
        if (index < 0) throw new Error('This Helium tab has been closed.');
        window.activeTabIndex = index + 1;
        window.index = 1;
        helium.activate();
        return;
    }

    if (command === 'close') {
        const windows = windowsByID();
        // Close from the highest index down so earlier closes don't shift later ones.
        const targets = [];
        for (let i = 1; i + 1 < argv.length; i += 2) {
            const window = windows.get(String(argv[i]));
            if (!window) continue;
            const index = tabIndex(window, argv[i + 1]);
            if (index >= 0) targets.push({ window, index });
        }
        targets.sort((a, b) => b.index - a.index);
        for (const { window, index } of targets) {
            try { window.tabs[index].close(); } catch (error) {}
        }
        return;
    }

    const rows = [];
    const windows = [];
    for (const window of helium.windows()) {
        try {
            if (window.mode && window.mode() === 'incognito') continue;
            windows.push({ window, order: window.index() });
        } catch (error) {}
    }
    windows.sort((a, b) => a.order - b.order);
    for (const { window, order } of windows) {
        try {
            // Batch reads: one Apple Event per property instead of one per tab.
            const ids = window.tabs.id();
            const titles = window.tabs.title();
            const urls = window.tabs.url();
            const loading = window.tabs.loading();
            let active = -1;
            try { active = window.activeTabIndex() - 1; } catch (error) {}
            const windowID = String(window.id());
            for (let i = 0; i < ids.length; i++) {
                rows.push({
                    id: String(ids[i]), windowID, title: titles[i] || '', address: urls[i] || '',
                    windowOrder: order, tabOrder: i, active: i === active, loading: !!loading[i],
                });
            }
        } catch (error) {
            // A window can close between reads.
            if (error.errorNumber !== -1728 && error.errorNumber !== -1719) throw error;
        }
    }
    return JSON.stringify(rows);
}
