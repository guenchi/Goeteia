// View-source overlay: fetch the page's Scheme source (from the badge's
// data-src) and show it, syntax-highlighted, in an on-page modal.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

const KEYWORDS = new Set([
  'define', 'define-syntax', 'define-record-type', 'define-values',
  'lambda', 'let', 'let*', 'letrec', 'letrec*', 'let-values',
  'if', 'cond', 'case', 'when', 'unless', 'and', 'or', 'not', 'begin',
  'quote', 'quasiquote', 'unquote', 'set!', 'do', 'else', '=>',
  'import', 'library', 'export', 'syntax-rules', 'syntax-case', 'with-syntax',
  'call/cc', 'dynamic-wind', 'guard', 'raise', 'values',
  'sx', 'sx-mount', 'sx-list', 'signal', 'signal-ref', 'signal-set!',
  'signal-update!', 'effect', 'batch', 'untracked', 'root',
  'render-page', 'read-file', 'write-file', 'html->document', 'sxml->html', 'raw',
]);
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const TOK = /(;[^\n]*)|("(?:\\.|[^"\\])*"?)|(#[tf](?![-\w])|#\\.)|([()])|([^\s()";]+)|(\s+)/g;
function highlight(code) {
  let out = '', m, head = false;
  TOK.lastIndex = 0;
  while ((m = TOK.exec(code))) {
    if (m[1]) out += `<span class="tok-c">${esc(m[1])}</span>`;
    else if (m[2]) { out += `<span class="tok-s">${esc(m[2])}</span>`; head = false; }
    else if (m[3]) { out += `<span class="tok-l">${esc(m[3])}</span>`; head = false; }
    else if (m[4]) { out += `<span class="tok-p">${esc(m[4])}</span>`; head = (m[4] === '('); }
    else if (m[5]) {
      const w = m[5];
      out += KEYWORDS.has(w) ? `<span class="tok-k">${esc(w)}</span>`
           : /^[+-]?[0-9]/.test(w) ? `<span class="tok-n">${esc(w)}</span>`
           : head ? `<span class="tok-h">${esc(w)}</span>`
           : esc(w);
      head = false;
    }
    else out += esc(m[6]);
  }
  return out;
}

document.addEventListener('DOMContentLoaded', () => {
  const badge = document.querySelector('.src-badge');
  const overlay = document.getElementById('src-overlay');
  if (!badge || !overlay) return;
  const codeEl = document.getElementById('src-code');
  const titleEl = document.getElementById('src-title');
  const closeBtn = document.getElementById('src-close');
  const hide = () => { overlay.hidden = true; };

  badge.addEventListener('click', async () => {
    const src = badge.dataset.src;
    titleEl.textContent = src;
    codeEl.innerHTML = 'loading…';
    overlay.hidden = false;
    try {
      const text = await fetch(src).then(r => {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      });
      codeEl.innerHTML = highlight(text);
    } catch (e) {
      codeEl.textContent = `could not load ${src} — ${e.message}`;
    }
  });
  closeBtn.addEventListener('click', hide);
  overlay.addEventListener('click', e => { if (e.target === overlay) hide(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !overlay.hidden) hide(); });
});
