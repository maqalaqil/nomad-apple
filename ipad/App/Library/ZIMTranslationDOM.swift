import Foundation

/// Runs only in a named, isolated WebKit content world. No page-message handler is
/// installed, and translated strings are assigned to text nodes, never innerHTML.
enum ZIMTranslationDOM {
    static let capture = #"""
    const old = globalThis.__nomadArticleTranslation;
    if (old && old.applied) throw new Error("Restore the original article before translating it again.");
    const root = document.querySelector('main, article, .mw-parser-output, #content') || document.body;
    if (!root) throw new Error("The article has no readable body.");
    const skipped = 'script,style,noscript,code,pre,svg,math,textarea,input,select,button,[translate="no"],[hidden],[aria-hidden="true"]';
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [], originals = [], texts = [];
    let total = 0, scanned = 0, node;
    while ((node = walker.nextNode())) {
        if (++scanned > 20000) throw new Error("This article is too large for in-place translation. Translate a smaller excerpt in Text Translation.");
        const parent = node.parentElement;
        if (!parent || parent.closest(skipped)) continue;
        const text = node.nodeValue.trim();
        if (!text || !/[\p{L}\p{N}]/u.test(text)) continue;
        if (!parent.getClientRects().length) continue;
        total += text.length;
        if (text.length > 4000 || total > 60000 || nodes.length >= 512)
            throw new Error("This article exceeds the in-place limit (512 text runs or 60,000 characters). Use Text Translation for smaller excerpts.");
        nodes.push(node); originals.push(node.nodeValue); texts.push(text);
    }
    if (!nodes.length) throw new Error("No visible article text was found.");
    globalThis.__nomadArticleTranslation = {token, nodes, originals, applied:false,
        lang:document.documentElement.getAttribute('lang'), dir:document.documentElement.getAttribute('dir')};
    return texts;
    """#

    static let apply = #"""
    const state = globalThis.__nomadArticleTranslation;
    if (!state || state.token !== token || state.applied || values.length !== state.nodes.length)
        throw new Error("The article changed before translation finished. Try again.");
    for (let i = 0; i < state.nodes.length; i++) {
        if (!state.nodes[i].isConnected || state.nodes[i].nodeValue !== state.originals[i] || typeof values[i] !== 'string')
            throw new Error("The article changed before translation finished. Try again.");
    }
    state.translated = [];
    for (let i = 0; i < state.nodes.length; i++) {
        const original = state.originals[i];
        const value = (original.match(/^\s*/u)?.[0] || '') + values[i] + (original.match(/\s*$/u)?.[0] || '');
        state.nodes[i].nodeValue = value;
        state.translated.push(value);
    }
    document.documentElement.setAttribute('lang', target);
    document.documentElement.setAttribute('dir', rtl ? 'rtl' : 'ltr');
    state.applied = true;
    return true;
    """#

    static let restore = #"""
    const state = globalThis.__nomadArticleTranslation;
    if (!state) return true;
    for (let i = 0; i < state.nodes.length; i++) {
        const node = state.nodes[i];
        if (node.isConnected && (!state.applied || node.nodeValue === state.translated[i])) node.nodeValue = state.originals[i];
    }
    if (state.applied) {
        if (state.lang === null) document.documentElement.removeAttribute('lang'); else document.documentElement.setAttribute('lang', state.lang);
        if (state.dir === null) document.documentElement.removeAttribute('dir'); else document.documentElement.setAttribute('dir', state.dir);
    }
    delete globalThis.__nomadArticleTranslation;
    return true;
    """#
}
