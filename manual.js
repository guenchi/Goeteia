// Render docs/manual.md into #doc with marked; fall back to raw text.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.
const doc = document.getElementById('doc');
const lang = new URLSearchParams(location.search).get('lang') === 'zh-cn'
  ? 'zh-cn' : 'en';
const SRC = lang === 'zh-cn' ? 'docs/manual.zh-cn.md' : 'docs/manual.md';
// highlight the active language in the switcher
document.querySelectorAll('.langtoggle a').forEach(a => {
  if ((a.dataset.lang || 'en') === lang) a.classList.add('active');
});

function fail(msg) {
  doc.innerHTML =
    '<div class="status">' + msg +
    '<br><br>You can read it directly at <code>' + SRC + '</code>.</div>';
}

fetch(SRC)
  .then(r => {
    if (!r.ok) throw new Error('http ' + r.status);
    return r.text();
  })
  .then(md => {
    if (typeof marked === 'undefined') {
      // renderer failed to load (offline / blocked): show the raw text
      const pre = document.createElement('pre');
      pre.textContent = md;
      doc.replaceChildren(pre);
      return;
    }
    marked.setOptions({ gfm: true, breaks: false });
    doc.innerHTML = marked.parse(md);
    // marked v12 drops automatic heading IDs; assign GitHub-style slugs
    // so the table of contents and #hash links resolve
    const seen = {};
    doc.querySelectorAll('h1, h2, h3, h4').forEach(h => {
      let slug = h.textContent.toLowerCase().trim()
        .replace(/[^\w一-鿿\- ]+/g, '')  // keep letters, digits, _, -, space, CJK
        .replace(/\s+/g, '-');
      if (seen[slug] != null) slug += '-' + (++seen[slug]);
      else seen[slug] = 0;
      h.id = slug;
    });
    // jump to an in-page anchor if the URL carries one
    if (location.hash) {
      const el = document.getElementById(location.hash.slice(1));
      if (el) el.scrollIntoView();
    }
  })
  .catch(() => fail('The manual isn’t available yet.'));
