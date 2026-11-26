// Talks to Helium, Google Chrome, and Safari over Apple Events (JXA).
//   <browser>                                    → JSON list of open tabs, front window first
//   <browser> focus <windowID> <tabID> [url]     → bring that tab to the front
//   <browser> close <windowID> <tabID> <url> ... → close one or more tabs (triples)
// Supported <browser> values: helium | chrome | safari
function run(argv) {
    const browser = String(argv[0] || 'helium').toLowerCase();
    const command = argv[1];

    const BUNDLES = {
        helium: 'net.imput.helium',
        chrome: 'com.google.Chrome',
        safari: 'com.apple.Safari',
    };
    const NAMES = {
        helium: 'Helium',
        chrome: 'Chrome',
        safari: 'Safari',
    };

    const bundleID = BUNDLES[browser];
    if (!bundleID) throw new Error('Unsupported browser: ' + browser);
    const appName = NAMES[browser];
    const app = Application(bundleID);

    function isTransient(error) {
        return error && (error.errorNumber === -1728 || error.errorNumber === -1719 || error.errorNumber === -1700);
    }

    function windowsByID() {
        const map = new Map();
        for (const window of app.windows()) {
            try { map.set(String(window.id()), window); } catch (error) {}
        }
        return map;
    }

    // ---------- Safari ----------
    if (browser === 'safari') {
        function safariTabIndex(window, tabID, url) {
            let urls;
            try { urls = window.tabs.url(); } catch (error) { return -1; }
            const hinted = parseInt(tabID, 10) - 1;
            if (Number.isInteger(hinted) && hinted >= 0 && hinted < urls.length) {
                const candidate = urls[hinted] ? String(urls[hinted]) : '';
                if (!url || candidate === url) return hinted;
            }
            if (url) {
                for (let i = 0; i < urls.length; i++) {
                    if (urls[i] && String(urls[i]) === url) return i;
                }
            }
            return -1;
        }

        if (command === 'focus') {
            const window = windowsByID().get(String(argv[2]));
            const index = window ? safariTabIndex(window, argv[3], argv[4] || '') : -1;
            if (index < 0) throw new Error('This Safari tab has been closed.');
            window.currentTab = window.tabs[index];
            window.index = 1;
            app.activate();
            return;
        }

        if (command === 'close') {
            const windows = windowsByID();
            const claimed = new Map(); // windowID -> Set(index)
            const targets = [];
            for (let i = 2; i + 2 < argv.length; i += 3) {
                const winID = String(argv[i]);
                const tabID = String(argv[i + 1]);
                const url = String(argv[i + 2] || '');
                const window = windows.get(winID);
                if (!window) continue;
                let urls;
                try { urls = window.tabs.url(); } catch (error) { continue; }
                if (!claimed.has(winID)) claimed.set(winID, new Set());
                const used = claimed.get(winID);
                let idx = -1;
                const hinted = parseInt(tabID, 10) - 1;
                if (Number.isInteger(hinted) && hinted >= 0 && hinted < urls.length && !used.has(hinted)) {
                    const candidate = urls[hinted] ? String(urls[hinted]) : '';
                    if (!url || candidate === url) idx = hinted;
                }
                if (idx < 0 && url) {
                    for (let j = 0; j < urls.length; j++) {
                        if (!used.has(j) && urls[j] && String(urls[j]) === url) { idx = j; break; }
                    }
                }
                if (idx >= 0) {
                    used.add(idx);
                    targets.push({ window, index: idx });
                }
            }
            // Close from the highest index down so earlier closes don't shift later ones.
            targets.sort((a, b) => b.index - a.index);
            for (const { window, index } of targets) {
                try { window.tabs[index].close(); } catch (error) {}
            }
            return;
        }

        const rows = [];
        const windows = [];
        for (const window of app.windows()) {
            try {
                // Skip non-document utility windows (Settings, Downloads, etc.).
                if (!window.tabs || window.tabs.length === 0) continue;
                windows.push({ window, order: window.index() });
            } catch (error) {}
        }
        windows.sort((a, b) => a.order - b.order);
        for (const { window, order } of windows) {
            try {
                const names = window.tabs.name();
                const urls = window.tabs.url();
                let active = -1;
                try { active = window.currentTab().index() - 1; } catch (error) {}
                const windowID = String(window.id());
                const count = Math.min(names.length, urls.length);
                for (let i = 0; i < count; i++) {
                    const address = urls[i] ? String(urls[i]) : '';
                    const title = names[i] ? String(names[i]) : '';
                    rows.push({
                        browser: 'safari',
                        id: String(i + 1),
                        windowID,
                        title,
                        address,
                        windowOrder: order,
                        tabOrder: i,
                        active: i === active,
                        loading: false,
                    });
                }
            } catch (error) {
                if (!isTransient(error)) throw error;
            }
        }
        return JSON.stringify(rows);
    }

    // ---------- Chromium (Helium & Google Chrome) ----------
    function chromiumTabIndex(window, tabID, url) {
        try {
            const ids = window.tabs.id().map(String);
            const direct = ids.indexOf(String(tabID));
            if (direct >= 0) return direct;
            if (url) {
                const urls = window.tabs.url();
                for (let i = 0; i < urls.length; i++) {
                    if (urls[i] && String(urls[i]) === url) return i;
                }
            }
        } catch (error) {}
        return -1;
    }

    if (command === 'focus') {
        const window = windowsByID().get(String(argv[2]));
        const index = window ? chromiumTabIndex(window, argv[3], argv[4] || '') : -1;
        if (index < 0) throw new Error('This ' + appName + ' tab has been closed.');
        window.activeTabIndex = index + 1;
        window.index = 1;
        app.activate();
        return;
    }

    if (command === 'close') {
        const windows = windowsByID();
        const seen = new Set();
        const targets = [];
        for (let i = 2; i + 2 < argv.length; i += 3) {
            const winID = String(argv[i]);
            const tabID = String(argv[i + 1]);
            const url = String(argv[i + 2] || '');
            const window = windows.get(winID);
            if (!window) continue;
            const index = chromiumTabIndex(window, tabID, url);
            const key = winID + ':' + index;
            if (index >= 0 && !seen.has(key)) {
                seen.add(key);
                targets.push({ window, index });
            }
        }
        targets.sort((a, b) => b.index - a.index);
        for (const { window, index } of targets) {
            try { window.tabs[index].close(); } catch (error) {}
        }
        return;
    }

    const rows = [];
    const windows = [];
    for (const window of app.windows()) {
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
                    browser,
                    id: String(ids[i]),
                    windowID,
                    title: titles[i] || '',
                    address: urls[i] || '',
                    windowOrder: order,
                    tabOrder: i,
                    active: i === active,
                    loading: !!loading[i],
                });
            }
        } catch (error) {
            // A window can close between reads.
            if (!isTransient(error)) throw error;
        }
    }
    return JSON.stringify(rows);
}
