// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Render docs/api.md into #doc with marked; fall back to raw text.
// The same renderer manual.js and changelog.js use -- one kind of page,
// one script shape.
const doc = document.getElementById('doc');
const SRC = 'docs/api.md';

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
  .catch(() => fail('The API index isn’t available yet.'));
