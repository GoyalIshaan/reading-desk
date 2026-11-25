function run(argv) {
    const helium = Application('net.imput.helium');
    if (argv[0] === 'focus') {
        const window = helium.windows.byId(argv[1]);
        const index = window.tabs.id().map(String).indexOf(argv[2]);
        if (index < 0) throw new Error('This Helium tab has been closed.');
        window.activeTabIndex = index + 1;
        window.index = 1;
        helium.activate();
        return;
    }
    const rows = [];
    for (const window of helium.windows()) {
        try {
            const ids = window.tabs.id();
            const titles = window.tabs.title();
            const urls = window.tabs.url();
            const windowID = String(window.id());
            for (let i = 0; i < ids.length; i++) {
                rows.push({ id: String(ids[i]), windowID, title: titles[i] || '', address: urls[i] || '' });
            }
        } catch (error) {
            // A window may disappear during the batch reads.
            if (error.errorNumber !== -1728 && error.errorNumber !== -1719) throw error;
        }
    }
    return JSON.stringify(rows);
}
