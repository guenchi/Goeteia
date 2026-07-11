// Goeteia playground: the self-hosted compiler runs in the browser,
// inside a Web Worker so runaway programs can't freeze the page.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

const compilerBytes = fetch('goeteia.wasm').then(r => {
    if (!r.ok) throw new Error('goeteia.wasm not found — run ./build-self.sh first');
    return r.arrayBuffer();
});
const preludeText = fetch('src/prelude.ss').then(r => r.text());

// ---- the worker: compile, instantiate, run, report ----

const workerSource = `
function latin1(bytes) {
    let s = '';
    for (const b of bytes) s += String.fromCharCode(b);
    return s;
}
function decode(v, ex) {
    if (typeof v === 'number') {
        return (v & 1) ? '#\\\\' + String.fromCharCode(v >> 1) : String(v >> 1);
    }
    if (v === ex.false.value) return '#f';
    if (v === ex.true.value) return '#t';
    if (v === ex.null.value) return '()';
    if (v === ex.void.value) return '';
    return '#<object>';
}
onmessage = async (e) => {
    const { compiler, prelude, source } = e.data;
    try {
        const harness = '\\n(define ($pg-write v) (write v) v)\\n(export $pg-write)\\n';
        const input = [];
        for (const ch of prelude + '\\n' + source + harness) input.push(ch.charCodeAt(0) & 0xff);
        const out = [];
        let pos = 0;
        const t0 = performance.now();
        const stubs = {
            path_byte: () => {}, open_read: () => -1, open_write: () => -1,
            fread: () => -1, fwrite: () => {}, fclose: () => {},
        };
        const { instance } = await WebAssembly.instantiate(compiler, {
            io: {
                write_byte: b => out.push(b),
                read_byte: () => (pos < input.length ? input[pos++] : -1),
                ...stubs,
            },
        });
        try {
            instance.exports.main();
        } catch (err) {
            postMessage({ compileError: latin1(out).trim() || err.message });
            return;
        }
        const wasm = new Uint8Array(out);
        const t1 = performance.now();

        const runOut = [];
        const mod = await WebAssembly.instantiate(wasm, {
            io: { write_byte: b => runOut.push(b), read_byte: () => -1, ...stubs },
        });
        let result = '', error = null;
        try {
            const ex = mod.instance.exports;
            const v = ex.main();
            if (typeof v === 'number' || v === ex.false.value ||
                v === ex.true.value || v === ex.null.value ||
                v === ex.void.value || !ex['$pg-write']) {
                result = decode(v, ex);
            } else {
                const before = runOut.length;
                ex['$pg-write'](v);
                result = latin1(runOut.slice(before));
                runOut.length = before;
            }
        } catch (err) {
            error = err.message;
        }
        const t2 = performance.now();
        postMessage({
            text: latin1(runOut), result, error,
            bytes: wasm.length,
            tCompile: t1 - t0, tRun: t2 - t1,
        });
    } catch (err) {
        postMessage({ compileError: err.message });
    }
};
`;
const workerUrl = URL.createObjectURL(
    new Blob([workerSource], { type: 'text/javascript' }));

// ---- examples ----

const examples = {
    'fib 1000 (bignums)': `;; the naive doubly-recursive fib is O(phi^n) -- fib(1000) that way
;; outlives the universe in any language.  Iterate instead, and let
;; fixnums overflow into bignums:
(define (fib n)
  (let loop ((i 0) (a 0) (b 1))
    (if (= i n) a (loop (+ i 1) b (+ a b)))))

(fib 1000)`,

    'fibonacci (naive)': `;; exponential on purpose -- try 30, not 100.
;; (the Stop button is right there if you get ambitious)
(define (fib n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(display (fib 30))
(newline)
(fib 30)`,

    'hygienic macros': `(define-syntax my-or
  (syntax-rules ()
    ((_) #f)
    ((_ e) e)
    ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))

;; the t inside my-or cannot capture this one
(let ((t 'mine))
  (my-or #f t))`,

    'records & hashtables': `(define-record-type point (fields x (mutable y)))

(define p (make-point 3 4))
(point-y-set! p 40)

(define ht (make-eq-hashtable))
(hashtable-set! ht 'x (point-x p))
(hashtable-set! ht 'y (point-y p))

(display (list 'x (hashtable-ref ht 'x #f)
               'y (hashtable-ref ht 'y #f)))
(newline)
(hashtable-size ht)`,

    'call/cc escape': `(define (product ls)
  (call/cc
   (lambda (break)
     (let loop ((ls ls) (acc 1))
       (cond
        ((null? ls) acc)
        ((zero? (car ls)) (break 'zero!))   ; bail out early
        (else (loop (cdr ls) (* acc (car ls)))))))))

(display (product '(1 2 3 4 5)))
(newline)
(product '(1 2 0 4 5))`,

    'dynamic-wind': `(define log '())
(define (note x) (set! log (cons x log)))

(call/cc
 (lambda (k)
   (dynamic-wind
     (lambda () (note 'enter))
     (lambda () (note 'inside) (k 'escaped))
     (lambda () (note 'exit)))))

(reverse log)`,
};

// ---- wiring ----

const srcBox = document.getElementById('src');
const outBox = document.getElementById('out');
const runBtn = document.getElementById('run');
const stopBtn = document.getElementById('stop');
const exSelect = document.getElementById('examples');

for (const name of Object.keys(examples)) {
    const opt = document.createElement('option');
    opt.value = name;
    opt.textContent = name;
    exSelect.appendChild(opt);
}
exSelect.addEventListener('change', () => {
    srcBox.value = examples[exSelect.value];
});
srcBox.value = examples['fib 1000 (bignums)'];

let worker = null;
let ticker = null;

function setRunning(running) {
    runBtn.disabled = running;
    stopBtn.style.display = running ? '' : 'none';
    if (!running && ticker) { clearInterval(ticker); ticker = null; }
}

async function go() {
    setRunning(true);
    const started = performance.now();
    outBox.textContent = 'running…';
    ticker = setInterval(() => {
        outBox.textContent =
            `running… ${((performance.now() - started) / 1000).toFixed(1)}s (Stop to interrupt)`;
    }, 250);
    try {
        const [compiler, prelude] = await Promise.all([compilerBytes, preludeText]);
        worker = new Worker(workerUrl);
        worker.onmessage = (e) => {
            setRunning(false);
            const m = e.data;
            if (m.compileError) {
                outBox.textContent = `compile error: ${m.compileError}`;
                return;
            }
            let msg = m.text;
            if (m.error) {
                msg += (msg && !msg.endsWith('\n') ? '\n' : '') + `runtime error: ${m.error}`;
            } else if (m.result) {
                msg += (msg && !msg.endsWith('\n') ? '\n' : '') + `⇒ ${m.result}`;
            }
            msg += `\n\n— ${m.bytes} bytes, compiled ${m.tCompile.toFixed(1)} ms, ran ${m.tRun.toFixed(1)} ms`;
            outBox.textContent = msg;
        };
        worker.postMessage({ compiler, prelude, source: srcBox.value });
    } catch (e) {
        setRunning(false);
        outBox.textContent = `error: ${e.message}`;
    }
}

function stop() {
    if (worker) { worker.terminate(); worker = null; }
    setRunning(false);
    outBox.textContent = 'stopped.';
}

runBtn.addEventListener('click', go);
stopBtn.addEventListener('click', stop);
srcBox.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') go();
});
setRunning(false);
