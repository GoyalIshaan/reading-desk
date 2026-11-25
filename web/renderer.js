// Obsidian-flavoured Markdown renderer for Reading Desk's notes pane.
// Bundled with esbuild into Resources/web/renderer.js (see web/build.sh).
// KaTeX is loaded separately as a global (window.katex).
import MarkdownIt from 'markdown-it';
import hljs from 'highlight.js/lib/common';

const post = (message) => window.webkit?.messageHandlers?.desk?.postMessage(message);
window.addEventListener('error', (e) => post({ type: 'log', message: `${e.message} @ ${e.filename}:${e.lineno}` }));
const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const slug = (s) => String(s).trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '');

let attachments = [];
let notePath = '';
let seq = 0;
const latexCache = new Map();
const IMAGE = /\.(png|jpe?g|gif|webp|svg|avif|bmp|tiff?)$/i;
const AUDIO = /\.(mp3|wav|m4a|ogg|flac|webm)$/i;
const VIDEO = /\.(mp4|mov|mkv|ogv)$/i;

// ---------- paths -------------------------------------------------------------

function vaultURL(path) {
    return 'desk://vault/' + path.split('/').map(encodeURIComponent).join('/');
}

function resolveAttachment(name) {
    const clean = name.replace(/^\.?\//, '');
    const lower = clean.toLowerCase();
    const exact = attachments.find((p) => p.toLowerCase() === lower);
    if (exact) return vaultURL(exact);
    const base = lower.split('/').pop();
    const byName = attachments.find((p) => p.toLowerCase().split('/').pop() === base);
    if (byName) return vaultURL(byName);
    const folder = notePath.includes('/') ? notePath.slice(0, notePath.lastIndexOf('/') + 1) : '';
    return vaultURL(folder + clean);
}

function resolveRelative(src) {
    if (/^[a-z][a-z0-9+.-]*:/i.test(src)) return src;
    let decoded = src;
    try { decoded = decodeURI(src); } catch {}
    return resolveAttachment(decoded);
}

// ---------- math --------------------------------------------------------------

function renderMath(tex, display) {
    const key = (display ? 'D:' : 'I:') + tex;
    if (latexCache.has(key)) return wrapSVG(latexCache.get(key), display);
    try {
        return window.katex.renderToString(tex, {
            displayMode: display, throwOnError: true, strict: 'ignore', output: 'htmlAndMathml', trust: false,
        });
    } catch (error) {
        // KaTeX can't do it: hand it to the real TeX installation.
        return latexPlaceholder(tex, display ? 'display' : 'inline', error.message);
    }
}

function latexPlaceholder(source, mode, reason) {
    const id = 'tex' + ++seq;
    post({ type: 'latex', id, source, mode });
    const block = mode !== 'inline';
    return `<${block ? 'div' : 'span'} class="latex-pending ${block ? 'is-block' : ''}" id="${id}" title="${escapeHtml(reason || 'Rendering with LaTeX…')}">`
        + `<span class="latex-spinner"></span>${block ? '<span class="latex-label">Compiling with LaTeX…</span>' : ''}</${block ? 'div' : 'span'}>`;
}

function wrapSVG(svg, mode) {
    const block = mode === true || mode === 'display' || mode === 'tikz';
    return `<${block ? 'div' : 'span'} class="latex-svg ${mode === 'tikz' ? 'is-tikz' : ''} ${block ? 'is-block' : ''}">${svg}</${block ? 'div' : 'span'}>`;
}

window.deskFillLatex = (id, source, mode, svg, error) => {
    const node = document.getElementById(id);
    if (svg) latexCache.set((mode === 'inline' ? 'I:' : mode === 'tikz' ? 'T:' : 'D:') + source, svg);
    if (!node) return;
    if (svg) {
        node.outerHTML = wrapSVG(svg, mode);
    } else {
        node.outerHTML = `<${mode === 'inline' ? 'span' : 'div'} class="math-error" title="${escapeHtml(error || '')}">${escapeHtml(source)}</${mode === 'inline' ? 'span' : 'div'}>`;
    }
};

function mathInline(state, silent) {
    const src = state.src;
    const start = state.pos;
    if (src.charCodeAt(start) !== 0x24) return false;
    if (src.charCodeAt(start + 1) === 0x24) {
        const end = src.indexOf('$$', start + 2);
        if (end < 0 || end > state.posMax) return false;
        if (!silent) state.push('math_block_inline', '', 0).content = src.slice(start + 2, end);
        state.pos = end + 2;
        return true;
    }
    const next = src[start + 1];
    if (!next || /\s/.test(next)) return false;
    let end = start + 1;
    for (;;) {
        end = src.indexOf('$', end);
        if (end < 0 || end >= state.posMax) return false;
        if (src[end - 1] === '\\' || /\s/.test(src[end - 1]) || /\d/.test(src[end + 1] || '')) { end++; continue; }
        break;
    }
    if (!silent) state.push('math_inline', '', 0).content = src.slice(start + 1, end);
    state.pos = end + 1;
    return true;
}

function mathBlock(state, startLine, endLine, silent) {
    const start = state.bMarks[startLine] + state.tShift[startLine];
    const max = state.eMarks[startLine];
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    if (state.src.slice(start, start + 2) !== '$$') return false;
    const first = state.src.slice(start + 2, max);
    let content = '';
    let line = startLine;
    let found = false;
    if (first.trim().length >= 2 && first.trim().endsWith('$$')) {
        content = first.trim().slice(0, -2);
        found = true;
    } else {
        content = first.trim() ? first + '\n' : '';
        for (line = startLine + 1; line < endLine; line++) {
            const text = state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
            if (state.sCount[line] < state.blkIndent && text.trim()) break;
            if (text.trim().endsWith('$$')) {
                content += text.trim().slice(0, -2);
                found = true;
                break;
            }
            content += text + '\n';
        }
    }
    if (!found) return false;
    if (silent) return true;
    const token = state.push('math_block', 'div', 0);
    token.block = true;
    token.content = content;
    token.map = [startLine, line + 1];
    state.line = line + 1;
    return true;
}

// ---------- obsidian inline syntax --------------------------------------------

function wikilink(state, silent) {
    const src = state.src;
    let start = state.pos;
    let embed = false;
    if (src[start] === '!' && src.startsWith('[[', start + 1)) { embed = true; start += 1; }
    else if (!src.startsWith('[[', start)) return false;
    const end = src.indexOf(']]', start + 2);
    if (end < 0 || end > state.posMax) return false;
    const inner = src.slice(start + 2, end);
    if (!inner.trim() || inner.includes('\n')) return false;
    if (!silent) {
        const bar = inner.indexOf('|');
        const token = state.push(embed ? 'wiki_embed' : 'wikilink', '', 0);
        token.meta = { target: (bar < 0 ? inner : inner.slice(0, bar)).trim(), alias: bar < 0 ? null : inner.slice(bar + 1).trim() };
    }
    state.pos = end + 2;
    return true;
}

function highlightMark(state, silent) {
    const src = state.src;
    const start = state.pos;
    if (src.charCodeAt(start) !== 0x3d || src.charCodeAt(start + 1) !== 0x3d) return false;
    const end = src.indexOf('==', start + 2);
    if (end < 0 || end + 2 > state.posMax || end === start + 2 || /\s/.test(src[start + 2])) return false;
    if (!silent) {
        const oldMax = state.posMax;
        state.push('mark_open', 'mark', 1);
        state.pos = start + 2;
        state.posMax = end;
        state.md.inline.tokenize(state);
        state.posMax = oldMax;
        state.push('mark_close', 'mark', -1);
    }
    state.pos = end + 2;
    return true;
}

function tag(state, silent) {
    const src = state.src;
    const pos = state.pos;
    if (src[pos] !== '#') return false;
    if (pos > 0 && !/[\s(]/.test(src[pos - 1])) return false;
    const match = /^#([\p{L}\p{N}_\-/]+)/u.exec(src.slice(pos, state.posMax));
    if (!match || /^\d+$/.test(match[1])) return false;
    if (!silent) state.push('tag', '', 0).content = match[1];
    state.pos += match[0].length;
    return true;
}

// ---------- callouts ----------------------------------------------------------

const CALLOUTS = {
    note: ['8, 109, 221', 'pencil'], info: ['8, 109, 221', 'info'], todo: ['8, 109, 221', 'check-circle'],
    abstract: ['0, 191, 188', 'clipboard'], summary: ['0, 191, 188', 'clipboard'], tldr: ['0, 191, 188', 'clipboard'],
    tip: ['0, 191, 188', 'flame'], hint: ['0, 191, 188', 'flame'], important: ['0, 191, 188', 'flame'],
    success: ['8, 185, 78', 'check'], check: ['8, 185, 78', 'check'], done: ['8, 185, 78', 'check'],
    question: ['236, 117, 0', 'help'], help: ['236, 117, 0', 'help'], faq: ['236, 117, 0', 'help'],
    warning: ['236, 117, 0', 'alert'], caution: ['236, 117, 0', 'alert'], attention: ['236, 117, 0', 'alert'],
    failure: ['233, 49, 71', 'x'], fail: ['233, 49, 71', 'x'], missing: ['233, 49, 71', 'x'],
    danger: ['233, 49, 71', 'zap'], error: ['233, 49, 71', 'zap'], bug: ['233, 49, 71', 'bug'],
    example: ['120, 82, 238', 'list'], quote: ['158, 158, 158', 'quote'], cite: ['158, 158, 158', 'quote'],
};

const ICONS = {
    pencil: '<path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/>',
    info: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
    'check-circle': '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
    clipboard: '<rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2M12 11h4M12 16h4M8 11h.01M8 16h.01"/>',
    flame: '<path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.07-2.14-.22-4.05 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.15.43-2.29 1-3a2.5 2.5 0 0 0 2.5 2.5z"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    help: '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3M12 17h.01"/>',
    alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3ZM12 9v4M12 17h.01"/>',
    x: '<path d="M18 6 6 18M6 6l12 12"/>',
    zap: '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>',
    bug: '<path d="m8 2 1.88 1.88M14.12 3.88 16 2M9 7.13v-1a3.003 3.003 0 1 1 6 0v1"/><path d="M12 20c-3.3 0-6-2.7-6-6v-3a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v3c0 3.3-2.7 6-6 6M12 20v-9M6.53 9C4.6 8.8 3 7.1 3 5M6 13H2M3 21c0-2.1 1.7-3.9 3.8-4M20.97 5c0 2.1-1.6 3.8-3.5 4M22 13h-4M17.2 17c2.1.1 3.8 1.9 3.8 4"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
    quote: '<path d="M3 21c3 0 7-1 7-8V5c0-1.25-.76-2.02-2-2H4c-1.25 0-2 .75-2 1.97V11c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 .01-1 1.03V20c0 1 0 1 1 1z"/><path d="M15 21c3 0 7-1 7-8V5c0-1.25-.76-2.02-2-2h-4c-1.25 0-2 .75-2 1.97V11c0 1.25.75 2 2 2h.75c0 2.25.25 4-2.75 4v3c0 1 0 1 1 1z"/>',
    chevron: '<path d="m9 18 6-6-6-6"/>',
    link: '<path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
    tags: '<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>',
    text: '<path d="M17 6.1H3M21 12.1H3M15.1 18H3"/>',
    calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
    copy: '<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ICONS.pencil}</svg>`;

function callouts(state) {
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
        const open = tokens[i];
        if (open.type !== 'blockquote_open') continue;
        const paragraph = tokens[i + 1];
        const inline = tokens[i + 2];
        if (paragraph?.type !== 'paragraph_open' || inline?.type !== 'inline') continue;
        const lines = inline.content.split('\n');
        const match = /^\[!([\w-]+)\]([+-]?)[ \t]*(.*)$/.exec(lines[0]);
        if (!match) continue;
        const type = match[1].toLowerCase();
        const meta = { callout: type, fold: match[2], title: match[3] || type[0].toUpperCase() + type.slice(1) };
        open.meta = meta;
        inline.content = lines.slice(1).join('\n');
        if (!inline.content.trim()) {
            paragraph.hidden = true;
            if (tokens[i + 3]?.type === 'paragraph_close') tokens[i + 3].hidden = true;
        }
        let depth = 0;
        for (let j = i; j < tokens.length; j++) {
            if (tokens[j].type === 'blockquote_open') depth++;
            else if (tokens[j].type === 'blockquote_close' && --depth === 0) { tokens[j].meta = meta; break; }
        }
    }
}

// ---------- tasks & source lines ----------------------------------------------

function sourceLines(state) {
    const offset = state.env.offset || 0;
    for (const token of state.tokens) {
        if (token.map && token.nesting === 1) token.attrSet('data-line', String(token.map[0] + offset));
    }
}

function tasks(state) {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i++) {
        const inline = tokens[i];
        if (inline.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue;
        const match = /^\[([ xX/\-><!?*])\](?:[ \t]|$)/.exec(inline.content);
        if (!match) continue;
        const item = tokens[i - 2];
        const mark = match[1];
        const checked = mark !== ' ';
        item.attrJoin('class', 'task-list-item' + (checked ? ' is-checked' : ''));
        item.attrSet('data-task', mark);
        const first = inline.children[0];
        if (first?.type === 'text') first.content = first.content.slice(match[0].length);
        const box = new state.Token('html_inline', '', 0);
        box.content = `<input type="checkbox" class="task-list-item-checkbox" ${checked ? 'checked' : ''} data-line="${item.attrGet('data-line')}">`;
        inline.children.unshift(box);
        let list = i - 3;
        while (list >= 0 && tokens[list].type !== 'bullet_list_open' && tokens[list].type !== 'ordered_list_open') list--;
        if (list >= 0) tokens[list].attrJoin('class', 'contains-task-list');
    }
}

// ---------- markdown-it setup -------------------------------------------------

const md = new MarkdownIt({ html: true, linkify: true, breaks: true, typographer: false });
md.block.ruler.before('fence', 'math_block', mathBlock, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
md.inline.ruler.after('escape', 'math_inline', mathInline);
md.inline.ruler.before('link', 'wikilink', wikilink);
md.inline.ruler.before('emphasis', 'mark', highlightMark);
md.inline.ruler.push('tag', tag);
md.core.ruler.after('block', 'source_lines', sourceLines);
md.core.ruler.before('inline', 'callouts', callouts);
md.core.ruler.after('inline', 'tasks', tasks);

const rules = md.renderer.rules;
rules.math_inline = (t, i) => renderMath(t[i].content, false);
rules.math_block_inline = (t, i) => renderMath(t[i].content, true);
rules.math_block = (t, i) => `<div class="math-block" data-line="${t[i].attrGet('data-line') ?? ''}">${renderMath(t[i].content, true)}</div>\n`;
rules.tag = (t, i) => `<a class="tag" href="#" data-tag="${escapeHtml(t[i].content)}">#${escapeHtml(t[i].content)}</a>`;

rules.wikilink = (t, i) => {
    const { target, alias } = t[i].meta;
    const [page, heading] = target.split('#');
    const label = alias || (heading ? (page ? `${page} > ${heading}` : heading) : page).replace(/\.md$/i, '');
    return `<a class="internal-link" href="#" data-href="${escapeHtml(target)}">${escapeHtml(label)}</a>`;
};

rules.wiki_embed = (t, i, options, env) => {
    const { target, alias } = t[i].meta;
    const file = target.split('#')[0];
    if (IMAGE.test(file)) {
        const size = /^(\d+)(?:x(\d+))?$/.exec(alias || '');
        const style = size ? ` width="${size[1]}"${size[2] ? ` height="${size[2]}"` : ''}` : '';
        return `<span class="image-embed"><img src="${resolveAttachment(file)}" alt="${escapeHtml(size ? file : alias || file)}"${style} loading="lazy"></span>`;
    }
    if (AUDIO.test(file)) return `<audio controls src="${resolveAttachment(file)}"></audio>`;
    if (VIDEO.test(file)) return `<video controls src="${resolveAttachment(file)}"></video>`;
    if (/\.pdf$/i.test(file)) return `<a class="internal-link" href="${resolveAttachment(file)}" data-external="1">${escapeHtml(file)}</a>`;
    if ((env.depth || 0) > 0) return `<a class="internal-link" href="#" data-href="${escapeHtml(target)}">${escapeHtml(alias || target)}</a>`;
    const id = 'embed' + ++seq;
    post({ type: 'embed', id, target });
    return `<div class="internal-embed" id="${id}"><div class="embed-title"><a class="internal-link" href="#" data-href="${escapeHtml(target)}">${escapeHtml(target.replace(/\.md$/i, ''))}</a></div><div class="embed-body"><span class="muted">Loading…</span></div></div>`;
};

rules.blockquote_open = (t, i) => {
    const meta = t[i].meta;
    if (!meta) return `<blockquote${md.renderer.renderAttrs(t[i])}>\n`;
    const [color, iconName] = CALLOUTS[meta.callout] || CALLOUTS.note;
    const title = `<div class="callout-title"><span class="callout-icon">${icon(iconName)}</span><span class="callout-title-inner">${md.renderInline(meta.title)}</span>${meta.fold ? `<span class="callout-fold">${icon('chevron')}</span>` : ''}</div>`;
    const attrs = `class="callout" data-callout="${escapeHtml(meta.callout)}" style="--callout-color: ${color}"`;
    if (meta.fold) return `<details ${attrs}${meta.fold === '+' ? ' open' : ''}><summary>${title}</summary><div class="callout-content">\n`;
    return `<div ${attrs}>${title}<div class="callout-content">\n`;
};
rules.blockquote_close = (t, i) => {
    const meta = t[i].meta;
    if (!meta) return '</blockquote>\n';
    return meta.fold ? '</div></details>\n' : '</div></div>\n';
};

rules.fence = (t, i) => {
    const token = t[i];
    const lang = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
    const code = token.content;
    if (lang === 'math') return `<div class="math-block">${renderMath(code, true)}</div>`;
    if (lang === 'tikz') {
        const key = 'T:' + code;
        if (latexCache.has(key)) return wrapSVG(latexCache.get(key), 'tikz');
        return latexPlaceholder(code, 'tikz');
    }
    let html = escapeHtml(code);
    if (lang && hljs.getLanguage(lang)) {
        try { html = hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch {}
    }
    return `<div class="code-block" data-line="${token.attrGet('data-line') ?? ''}">`
        + `<div class="code-toolbar">${lang ? `<span class="code-lang">${escapeHtml(lang)}</span>` : '<span></span>'}<button class="copy-code" title="Copy">${icon('copy')}</button></div>`
        + `<pre><code class="hljs${lang ? ' language-' + escapeHtml(lang) : ''}">${html}</code></pre></div>\n`;
};

const defaultImage = rules.image;
rules.image = (t, i, options, env, self) => {
    const src = t[i].attrGet('src') || '';
    t[i].attrSet('src', resolveRelative(src));
    t[i].attrSet('loading', 'lazy');
    return defaultImage(t, i, options, env, self);
};

rules.link_open = (t, i, options, env, self) => {
    const href = t[i].attrGet('href') || '';
    if (/^https?:/i.test(href)) t[i].attrJoin('class', 'external-link');
    else if (!href.startsWith('#')) {
        t[i].attrJoin('class', 'internal-link');
        t[i].attrSet('data-href', decodeURIComponentSafe(href));
        t[i].attrSet('href', '#');
    }
    return self.renderToken(t, i, options);
};
function decodeURIComponentSafe(s) { try { return decodeURIComponent(s); } catch { return s; } }

rules.heading_open = (t, i, options, env, self) => {
    const inline = t[i + 1];
    if (inline?.content) t[i].attrSet('id', slug(inline.content));
    return self.renderToken(t, i, options);
};

// ---------- frontmatter ---------------------------------------------------------

function splitFrontmatter(src) {
    const match = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(src);
    if (!match) return { body: src, props: null, offset: 0 };
    return { body: src.slice(match[0].length), props: parseYAML(match[1]), offset: (match[0].match(/\n/g) || []).length };
}

function parseYAML(text) {
    const props = [];
    let current = null;
    for (const raw of text.split(/\r?\n/)) {
        if (!raw.trim() || raw.trim().startsWith('#')) continue;
        const item = /^\s+-\s*(.*)$/.exec(raw);
        if (item && current) {
            if (!Array.isArray(current[1])) current[1] = current[1] ? [current[1]] : [];
            current[1].push(unquote(item[1]));
            continue;
        }
        const pair = /^([^:\s][^:]*):\s*(.*)$/.exec(raw);
        if (!pair) continue;
        let value = pair[2].trim();
        if (/^\[.*\]$/.test(value)) value = value.slice(1, -1).split(',').map((v) => unquote(v.trim())).filter(Boolean);
        else value = unquote(value);
        current = [pair[1].trim(), value];
        props.push(current);
    }
    return props;
}
const unquote = (v) => v.replace(/^(['"])(.*)\1$/, '$2');

function renderProps(props) {
    if (!props.length) return '';
    const rows = props.map(([key, value]) => {
        const lower = key.toLowerCase();
        const kind = ['tags', 'tag', 'aliases'].includes(lower) ? 'tags' : /date|created|updated|modified/.test(lower) ? 'calendar' : Array.isArray(value) ? 'list' : /^https?:/.test(value) ? 'link' : 'text';
        const values = Array.isArray(value) ? value : value ? [value] : [];
        let html;
        if (lower === 'tags' || lower === 'tag') html = values.map((v) => `<a class="tag" href="#">#${escapeHtml(v.replace(/^#/, ''))}</a>`).join(' ');
        else if (Array.isArray(value)) html = values.map((v) => `<span class="multi-select-pill">${md.renderInline(v)}</span>`).join('');
        else if (/^https?:/.test(value)) html = `<a class="external-link" href="${escapeHtml(value)}">${escapeHtml(value)}</a>`;
        else html = value ? md.renderInline(value) : '<span class="muted">Empty</span>';
        return `<div class="metadata-property"><div class="metadata-property-key"><span class="metadata-icon">${icon(kind)}</span>${escapeHtml(key)}</div><div class="metadata-property-value">${html}</div></div>`;
    }).join('');
    return `<div class="metadata-container"><div class="metadata-heading">Properties</div>${rows}</div>`;
}

// ---------- live preview editor -----------------------------------------------
//
// The note is split into blocks (each paragraph line, list item, heading,
// callout, math/code block…). Every block is rendered except the one holding
// the cursor, which is a raw-Markdown textarea. Leaving a line renders it;
// after IDLE_MS without typing the current block shows rendered too, while the
// (now invisible) textarea keeps focus so the next keystroke carries on.

const IDLE_MS = 5000;
const live = {
    source: '', lines: [], offsets: [0], blocks: [], active: null,
    wrapper: null, textarea: null, preview: null, tail: null,
    idleTimer: null, editTimer: null, checkTimer: null,
    relayouting: false, pendingClick: false, lastLineCount: 0,
};
const keyOf = new WeakMap();

function renderNote(markdown, depth) {
    const { body, props, offset } = splitFrontmatter(markdown);
    return (props && depth === 0 ? renderProps(props) : '') + md.render(body, { offset, depth });
}

function setSource(source) {
    live.source = source;
    live.lines = source.split('\n');
    live.offsets = [0];
    for (let i = 0; i < live.lines.length; i++) live.offsets.push(live.offsets[i] + live.lines[i].length + 1);
    live.blocks = computeBlocks(live.lines, source);
}

function lineOf(offset) {
    let line = 0;
    while (line + 1 < live.offsets.length - 1 && live.offsets[line + 1] <= offset) line++;
    return line;
}

function computeBlocks(lines, source) {
    const blocks = [];
    const fm = /^---[ \t]*\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/.exec(source);
    let fmEnd = 0;
    if (fm) {
        fmEnd = (fm[0].match(/\n/g) || []).length + (fm[0].endsWith('\n') ? 0 : 1);
        blocks.push({ start: 0, end: fmEnd, kind: 'fm' });
    }
    let tokens = [];
    try { tokens = md.parse(lines.slice(fmEnd).join('\n'), { offset: 0, depth: 0 }); } catch {}
    const push = (start, end, kind) => {
        start += fmEnd; end += fmEnd;
        while (end > start && !lines[end - 1].trim()) end--;
        if (end > start) blocks.push({ start, end, kind });
    };
    for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (t.level !== 0 || !t.map || t.nesting === -1) continue;
        if (t.type === 'bullet_list_open' || t.type === 'ordered_list_open') {
            const close = t.type.replace('_open', '_close');
            for (let j = i + 1; j < tokens.length; j++) {
                const u = tokens[j];
                if (u.type === close && u.level === 0) { i = j; break; }
                if (u.type === 'list_item_open' && u.level === 1 && u.map) push(u.map[0], u.map[1], 'item');
            }
            continue;
        }
        if (t.type === 'paragraph_open') {
            for (let l = t.map[0]; l < t.map[1]; l++) push(l, l + 1, 'pline');
            continue;
        }
        push(t.map[0], t.map[1], t.type.replace('_open', ''));
    }
    return blocks;
}

function rangeForLine(line) {
    const block = live.blocks.find((b) => b.start <= line && line < b.end);
    return block ? { start: block.start, end: block.end } : { start: line, end: line + 1 };
}

function renderBlock(block) {
    const text = live.lines.slice(block.start, block.end).join('\n');
    if (block.kind === 'fm') {
        const inner = text.replace(/^---[^\n]*\n?/, '').replace(/\n?---[ \t]*$/, '');
        const props = parseYAML(inner);
        return props.length ? renderProps(props) : '<div class="metadata-container"><div class="metadata-heading">Properties</div></div>';
    }
    if (block.kind === 'pline') return `<p>${md.renderInline(text, { offset: block.start, depth: 0 })}</p>`;
    return md.render(text, { offset: block.start, depth: 0 });
}

function blockElement(block, reuse) {
    const key = block.kind + '\u0000' + live.lines.slice(block.start, block.end).join('\n');
    let el = reuse.get(key)?.pop();
    if (el) {
        const delta = block.start - Number(el.dataset.start);
        if (delta) el.querySelectorAll('[data-line]').forEach((n) => { n.dataset.line = String(Number(n.dataset.line) + delta); });
    } else {
        el = document.createElement('div');
        el.className = 'lblock lblock-' + block.kind;
        el.innerHTML = renderBlock(block);
        keyOf.set(el, key);
    }
    el.dataset.start = block.start;
    el.dataset.end = block.end;
    const next = live.lines[block.end];
    el.classList.toggle('gend', next === undefined || !next.trim());
    return el;
}

function ensureChrome() {
    if (live.wrapper) return;
    live.wrapper = document.createElement('div');
    live.wrapper.className = 'live-active';
    live.textarea = document.createElement('textarea');
    live.textarea.spellcheck = true;
    live.textarea.rows = 1;
    live.preview = document.createElement('div');
    live.preview.className = 'live-preview';
    live.wrapper.append(live.textarea, live.preview);
    live.tail = document.createElement('div');
    live.tail.className = 'live-tail';
    wireTextarea(live.textarea);
}

function autosize() {
    const ta = live.textarea;
    ta.style.height = '0px';
    ta.style.height = ta.scrollHeight + 'px';
}

function styleTextarea() {
    const first = live.textarea.value.split('\n')[0];
    const heading = /^(#{1,6})\s/.exec(first);
    live.textarea.className = heading ? 'ta-h' + heading[1].length
        : /^(```|~~~|\$\$|\||---\s*$)/.test(first.trim()) ? 'ta-code' : '';
}

/// Rebuilds the document, keeping rendered blocks that didn't change (so math
/// and embeds don't re-render) and putting the textarea over `active`.
function layout(active, caret) {
    ensureChrome();
    const container = document.getElementById('live');
    const reuse = new Map();
    for (const el of container.querySelectorAll(':scope > .lblock')) {
        const key = keyOf.get(el);
        if (!reuse.has(key)) reuse.set(key, []);
        reuse.get(key).push(el);
    }
    if (active) {
        active = { ...active };
        for (const b of live.blocks) {
            if (b.start < active.end && active.start < b.end) {
                active.start = Math.min(active.start, b.start);
                active.end = Math.max(active.end, b.end);
            }
        }
        active.end = Math.min(Math.max(active.end, active.start + 1), Math.max(live.lines.length, active.start + 1));
    }
    live.active = active;
    const children = [];
    let placed = false;
    for (const b of live.blocks) {
        if (active && b.start < active.end && active.start < b.end) continue;
        if (active && !placed && b.start >= active.end) { children.push(live.wrapper); placed = true; }
        children.push(blockElement(b, reuse));
    }
    if (active && !placed) children.push(live.wrapper);
    children.push(live.tail);

    live.relayouting = true;
    const scroll = window.scrollY;
    syncChildren(container, children);
    if (active) {
        const ta = live.textarea;
        const value = live.lines.slice(active.start, active.end).join('\n');
        if (ta.value !== value) ta.value = value;
        live.lastLineCount = active.end - active.start;
        live.wrapper.classList.remove('idle');
        styleTextarea();
        autosize();
        ta.focus({ preventScroll: true });
        if (caret != null) {
            const pos = Math.max(0, Math.min(value.length, caret - live.offsets[active.start]));
            ta.setSelectionRange(pos, pos);
        }
        window.scrollTo(0, scroll);
        const rect = ta.getBoundingClientRect();
        if (rect.bottom > window.innerHeight - 40 || rect.top < 20) ta.scrollIntoView({ block: 'nearest' });
        armIdle();
    } else {
        window.scrollTo(0, scroll);
    }
    live.relayouting = false;
}

/// Bring the container's children in line with `wanted` without moving nodes
/// that are already in place, so a text selection in an untouched block survives
/// (moving a node clears any selection inside it, which broke ⌘C).
function syncChildren(container, wanted) {
    const keep = new Set(wanted);
    for (const node of [...container.childNodes]) if (!keep.has(node)) node.remove();
    wanted.forEach((node, i) => {
        const current = container.childNodes[i];
        if (current !== node) container.insertBefore(node, current || null);
    });
}

// ---------- undo / redo ----------
// The editor rewrites the textarea whenever the cursor crosses into another
// block, which wipes WebKit's own undo stack, so the editor keeps its own:
// snapshots of the whole note, with bursts of typing coalesced into one step.

const history = { undo: [], redo: [], last: 0, kind: '' };

function snapshot() {
    return { source: live.source, caret: live.active ? caretOffset() : null };
}

function remember(kind) {
    const now = Date.now();
    if (kind && kind === history.kind && now - history.last < 1200) { history.last = now; return; }
    history.undo.push(snapshot());
    if (history.undo.length > 400) history.undo.shift();
    history.redo = [];
    history.last = now;
    history.kind = kind || '';
}

function restore(entry) {
    setSource(entry.source);
    scheduleEdit();
    flushEdit();
    if (entry.caret != null) layout(rangeForLine(lineOf(entry.caret)), entry.caret);
    else layout(null, null);
}

function undo() {
    if (!history.undo.length) return;
    history.redo.push(snapshot());
    restore(history.undo.pop());
    history.kind = '';
}

function redo() {
    if (!history.redo.length) return;
    history.undo.push(snapshot());
    restore(history.redo.pop());
    history.kind = '';
}

document.addEventListener('keydown', (event) => {
    if (!event.metaKey || event.altKey || event.ctrlKey) return;
    const key = event.key.toLowerCase();
    if (key === 'z') {
        event.preventDefault();
        event.stopPropagation();
        if (event.shiftKey) redo(); else undo();
    } else if (key === 'y' && !event.shiftKey) {
        event.preventDefault();
        redo();
    }
}, true);

function commit() {
    clearTimeout(live.idleTimer);
    flushEdit();
    if (live.active) layout(null, null);
}

function caretOffset() {
    return live.active ? live.offsets[live.active.start] + live.textarea.selectionStart : 0;
}

/// The textarea's text changed: splice it into the source.
function absorbTextarea() {
    const a = live.active;
    if (!a) return;
    const edited = live.textarea.value.split('\n');
    const lines = [...live.lines.slice(0, a.start), ...edited, ...live.lines.slice(a.end)];
    a.end = a.start + edited.length;
    setSource(lines.join('\n'));
    scheduleEdit();
}

/// Re-check which block the caret is in; re-layout if it left the current one.
function checkCaret(force) {
    if (!live.active) return;
    const caret = caretOffset();
    const line = lineOf(caret);
    const want = rangeForLine(line);
    const lineCount = live.active.end - live.active.start;
    if (force || want.start !== live.active.start || want.end !== live.active.end || lineCount !== live.lastLineCount) {
        layout(want, caret);
    }
}

function scheduleEdit() {
    clearTimeout(live.editTimer);
    live.editTimer = setTimeout(flushEdit, 300);
}

function flushEdit() {
    if (live.editTimer == null) return;
    clearTimeout(live.editTimer);
    live.editTimer = null;
    post({ type: 'edit', text: live.source });
}

function armIdle() {
    clearTimeout(live.idleTimer);
    live.wrapper.classList.remove('idle');
    live.idleTimer = setTimeout(goIdle, IDLE_MS);
}

function goIdle() {
    const a = live.active;
    if (!a || document.activeElement !== live.textarea) return;
    const text = live.lines.slice(a.start, a.end).join('\n');
    if (!text.trim()) return;
    live.preview.innerHTML = a.end - a.start === 1 && !/^\s*([#>|$`~-]|\d+[.)]|[*+]\s)/.test(text)
        ? `<p>${md.renderInline(text, { offset: a.start, depth: 0 })}</p>`
        : md.render(text, { offset: a.start, depth: 0 });
    live.wrapper.classList.add('idle');
}

function moveTo(line, column) {
    flushEditLater();
    const target = Math.max(0, Math.min(live.lines.length - 1, line));
    const caret = live.offsets[target] + Math.min(column, live.lines[target].length);
    layout(rangeForLine(target), caret);
}
function flushEditLater() { if (live.editTimer != null) scheduleEdit(); }

function wireTextarea(ta) {
    ta.addEventListener('beforeinput', (event) => {
        // Edit ▸ Undo / Redo from the menu arrive here.
        if (event.inputType === 'historyUndo') { event.preventDefault(); undo(); return; }
        if (event.inputType === 'historyRedo') { event.preventDefault(); redo(); return; }
        const type = event.inputType || '';
        remember(type === 'insertText' ? 'type' : type.startsWith('delete') ? 'delete' : type);
    });
    ta.addEventListener('input', () => {
        armIdle();
        absorbTextarea();
        styleTextarea();
        autosize();
        clearTimeout(live.checkTimer);
        live.checkTimer = setTimeout(() => checkCaret(false), 120);
    });
    ta.addEventListener('keydown', (event) => {
        armIdle();
        const value = ta.value;
        const start = ta.selectionStart, end = ta.selectionEnd;
        const before = value.slice(0, start);
        const onFirstLine = !before.includes('\n');
        const onLastLine = !value.slice(end).includes('\n');
        const column = start - (before.lastIndexOf('\n') + 1);
        const a = live.active;
        if (event.key === 'Escape') { event.preventDefault(); ta.blur(); return; }
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        if (event.key === 'ArrowUp' && onFirstLine && !event.shiftKey && a.start > 0) {
            event.preventDefault();
            moveTo(a.start - 1, column);
            return;
        }
        if (event.key === 'ArrowDown' && onLastLine && !event.shiftKey && a.end < live.lines.length) {
            event.preventDefault();
            moveTo(a.end, column);
            return;
        }
        if (event.key === 'Backspace' && start === 0 && end === 0 && a.start > 0) {
            // Join with the line above, like any editor.
            event.preventDefault();
            remember('');
            const at = live.offsets[a.start] - 1;
            setSource(live.source.slice(0, at) + live.source.slice(at + 1));
            scheduleEdit();
            layout(rangeForLine(lineOf(at)), at);
            return;
        }
        if (event.key === 'Enter' && !event.shiftKey && start === end) {
            // Continue lists and tasks; an empty item ends the list.
            const lineStart = before.lastIndexOf('\n') + 1;
            const current = value.slice(lineStart, value.indexOf('\n', start) < 0 ? value.length : value.indexOf('\n', start));
            const item = /^(\s*)([-*+]|(\d+)([.)]))(\s+\[.\])?\s+/.exec(current);
            // Enter at or before the marker just pushes the item down.
            if (item && start - lineStart > item[0].length - 1) {
                event.preventDefault();
                remember('');
                if (current.trim() === item[0].trim()) {
                    // Empty item ends the list, leaving a blank line so what
                    // follows isn't swallowed into the last item.
                    ta.setRangeText('\n', lineStart, lineStart + current.length, 'end');
                } else {
                    const marker = item[3] ? `${Number(item[3]) + 1}${item[4]}` : item[2];
                    ta.setRangeText(`\n${item[1]}${marker}${item[5] ? ' [ ]' : ''} `, start, end, 'end');
                }
                ta.dispatchEvent(new Event('input'));
                return;
            }
            // Plain Enter: let the newline in, then render what we just left.
            requestAnimationFrame(() => checkCaret(false));
        }
        if (event.key === 'Tab') {
            event.preventDefault();
            remember('');
            const lineStart = before.lastIndexOf('\n') + 1;
            if (event.shiftKey) {
                const indent = /^(\t| {1,4})/.exec(value.slice(lineStart));
                if (indent) ta.setRangeText('', lineStart, lineStart + indent[0].length, 'end');
            } else if (/^\s*([-*+]|\d+[.)])\s/.test(value.slice(lineStart))) {
                ta.setRangeText('\t', lineStart, lineStart, 'end');
            } else {
                ta.setRangeText('\t', start, end, 'end');
            }
            ta.dispatchEvent(new Event('input'));
        }
    });
    ta.addEventListener('keyup', (event) => {
        if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'].includes(event.key)) checkCaret(false);
    });
    ta.addEventListener('mouseup', () => checkCaret(false));
    ta.addEventListener('blur', () => {
        setTimeout(() => {
            if (live.relayouting || live.pendingClick) return;
            if (document.activeElement !== live.textarea) commit();
        }, 0);
    });
}

/// Where in the source did the click land? Match the rendered text before the
/// click point, character by character, against the block's Markdown.
function sourceColumn(el, text, x, y) {
    const range = document.caretRangeFromPoint?.(x, y);
    if (!range || !el.contains(range.startContainer)) return text.length;
    const prefix = document.createRange();
    prefix.setStart(el, 0);
    prefix.setEnd(range.startContainer, range.startOffset);
    // Skip rendered characters with no source counterpart (layout whitespace,
    // KaTeX glyphs); a miss is not a reason to stop matching.
    let j = 0;
    for (const ch of prefix.toString().replace(/^\s+/, '')) {
        if (/\s/.test(ch) && text[j] !== ch) continue;
        const k = text.indexOf(ch, j);
        if (k < 0 || k - j > 40) continue;
        j = k + 1;
    }
    return j;
}

function activate(el, x, y) {
    const block = { start: Number(el.dataset.start), end: Number(el.dataset.end) };
    const text = live.lines.slice(block.start, block.end).join('\n');
    layout(block, live.offsets[block.start] + sourceColumn(el, text, x, y));
}

function activateEnd() {
    const last = live.lines.length - 1;
    if (live.lines[last].trim()) {
        setSource(live.source + '\n');
        scheduleEdit();
    }
    const line = live.lines.length - 1;
    layout({ start: line, end: line + 1 }, live.offsets[line]);
}

const interactive = 'a, input, summary, .copy-code, textarea, audio, video, .callout-fold';

document.addEventListener('mousedown', (event) => {
    if (event.target.closest(interactive)) return;
    if (event.target.closest('#live > .lblock, .live-tail') && live.active) live.pendingClick = true;
});

document.addEventListener('click', (event) => {
    const box = event.target.closest('.task-list-item-checkbox');
    if (box) {
        event.preventDefault();
        toggleTask(Number(box.dataset.line));
        return;
    }
    const copy = event.target.closest('.copy-code');
    if (copy) {
        post({ type: 'copy', text: copy.closest('.code-block').querySelector('code').innerText });
        copy.classList.add('copied');
        setTimeout(() => copy.classList.remove('copied'), 1200);
        return;
    }
    const link = event.target.closest('a');
    if (link) {
        event.preventDefault();
        live.pendingClick = false;
        if (link.classList.contains('tag')) return;
        if (link.dataset.external) { post({ type: 'external', url: link.href }); return; }
        const target = link.dataset.href;
        if (target != null) {
            if (target.startsWith('#')) document.getElementById(slug(target.slice(1)))?.scrollIntoView({ behavior: 'smooth' });
            else { flushEdit(); post({ type: 'open', target }); }
            return;
        }
        const href = link.getAttribute('href') || '';
        if (href.startsWith('#')) document.getElementById(href.slice(1))?.scrollIntoView({ behavior: 'smooth' });
        else if (href) post({ type: 'external', url: link.href });
        return;
    }
    if (event.target.closest(interactive)) return;
    const selected = String(window.getSelection() || '');
    const el = event.target.closest('#live > .lblock');
    if (el && !selected) { live.pendingClick = false; activate(el, event.clientX, event.clientY); return; }
    if (event.target.closest('.live-tail') && !selected) { live.pendingClick = false; activateEnd(); return; }
    if (live.pendingClick) { live.pendingClick = false; if (document.activeElement !== live.textarea) commit(); }
});

function toggleTask(line) {
    const text = live.lines[line];
    if (text == null) return;
    const match = /^(\s*(?:[-*+]|\d+[.)])\s+)\[(.)\]/.exec(text);
    if (!match) return;
    const lines = [...live.lines];
    lines[line] = match[1] + (match[2] === ' ' ? '[x]' : '[ ]') + text.slice(match[0].length);
    const caret = live.active ? caretOffset() : null;
    remember('');
    setSource(lines.join('\n'));
    scheduleEdit();
    flushEdit();
    layout(live.active, caret);
}

window.deskRender = (payload) => {
    attachments = payload.attachments || [];
    const sameNote = notePath === (payload.path || '');
    notePath = payload.path || '';
    const content = document.getElementById('content');
    if (!document.getElementById('live')) {
        content.innerHTML = '<div class="inline-title"></div><div id="live"></div>';
    }
    content.querySelector('.inline-title').textContent = notePath.split('/').pop().replace(/\.md$/i, '');
    const y = window.scrollY;
    clearTimeout(live.editTimer);
    live.editTimer = null;
    if (!sameNote) {
        document.getElementById('live').replaceChildren();
        history.undo = [];
        history.redo = [];
    }
    live.active = null;
    setSource(payload.markdown);
    layout(null, null);
    window.scrollTo(0, payload.keepScroll && sameNote ? y : 0);
};

window.deskStartEditing = () => activateEnd();
window.__deskLive = { live, sourceColumn };

window.deskFillEmbed = (id, markdown) => {
    const node = document.getElementById(id);
    if (!node) return;
    const body = node.querySelector('.embed-body');
    body.innerHTML = markdown == null ? '<span class="muted">Note not found.</span>' : renderNote(markdown, 1);
};

post({ type: 'ready' });
