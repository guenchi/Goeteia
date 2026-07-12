import { boot, render } from './live.js';

      const srcBox = document.getElementById('src');
      const runBtn = document.getElementById('run');
      const statusEl = document.getElementById('status');
      const liveEl = document.getElementById('live');
      const hlEl = document.getElementById('hl');

      // ---- syntax highlighting: colored <pre> mirrors the textarea ----
      const KEYWORDS = new Set([
        'define', 'define-syntax', 'define-record-type', 'define-values',
        'lambda', 'let', 'let*', 'letrec', 'letrec*', 'let-values', 'named-let',
        'if', 'cond', 'case', 'when', 'unless', 'and', 'or', 'not', 'begin',
        'quote', 'quasiquote', 'unquote', 'set!', 'do', 'else', '=>',
        'import', 'library', 'export', 'syntax-rules', 'syntax-case', 'with-syntax',
        'call/cc', 'call-with-current-continuation', 'dynamic-wind', 'guard', 'raise',
        'values', 'sx', 'sx-mount', 'sx-list', 'signal', 'signal-ref', 'signal-set!',
        'signal-update!', 'effect', 'batch', 'untracked', 'root',
      ]);
      const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      const TOK = /(;[^\n]*)|("(?:\\.|[^"\\])*"?)|(#[tf](?![-\w])|#\\.)|([()])|([^\s()";]+)|(\s+)/g;
      function highlight(code) {
        let out = '', m, head = false;   // head = next atom is a form head
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
                 : head ? `<span class="tok-h">${esc(w)}</span>`   // (div ...), (a ...), calls
                 : esc(w);
            head = false;
          }
          else out += esc(m[6]);          // whitespace preserves the head flag
        }
        return out;
      }
      function syncHL() { hlEl.innerHTML = highlight(srcBox.value) + '\n'; }
      srcBox.addEventListener('input', syncHL);
      srcBox.addEventListener('scroll', () => {
        hlEl.scrollTop = srcBox.scrollTop;
        hlEl.scrollLeft = srcBox.scrollLeft;
      });

      function setStatus(msg, err = false) {
        statusEl.textContent = msg;
        statusEl.classList.toggle('err', err);
      }

      async function go() {
        runBtn.disabled = true;
        setStatus('compiling…');
        try {
          const { compileMs, bytes } = await render(srcBox.value, liveEl);
          setStatus(`compiled ${bytes} bytes in ${compileMs.toFixed(1)} ms — rendered live`);
        } catch (e) {
          setStatus(`error: ${e.message}`, true);
        } finally {
          runBtn.disabled = false;
        }
      }

      (async () => {
        try {
          // load the compiler + libraries and the page's own source in parallel
          const [, heroSrc] = await Promise.all([
            boot(),
            fetch('hero.ss').then(r => r.text()),
          ]);
          srcBox.value = heroSrc;
          syncHL();                         // paint the highlighting
          runBtn.disabled = false;
          await go();                       // first render, from the seeded source
        } catch (e) {
          setStatus(`boot failed: ${e.message}`, true);
        }
      })();

      runBtn.addEventListener('click', go);
      srcBox.addEventListener('keydown', e => {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); go(); }
      });

      // "Try it now" lives in the live-mounted hero, so bind by delegation:
      // scroll the editor into view, then select all of the example so a
      // new visitor can start typing over it right away.
      document.addEventListener('click', e => {
        if (!e.target.closest('a[href="#editor"]')) return;
        e.preventDefault();
        document.getElementById('editor')
          .scrollIntoView({ behavior: 'smooth', block: 'start' });
        srcBox.focus({ preventScroll: true });
        srcBox.select();
      });
