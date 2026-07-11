// schwasm playground: the self-hosted compiler runs in the browser.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

const compilerBytes = fetch('goeteia.wasm').then(r => {
    if (!r.ok) throw new Error('goeteia.wasm not found — run ./build-self.sh first');
    return r.arrayBuffer();
});
const preludeText = fetch('src/prelude.ss').then(r => r.text());

function latin1(bytes) {
    let s = '';
    for (const b of bytes) s += String.fromCharCode(b);
    return s;
}

async function compileScheme(source) {
    const [bytes, prelude] = await Promise.all([compilerBytes, preludeText]);
    const input = [];
    for (const ch of prelude + '\n' + source) input.push(ch.charCodeAt(0) & 0xff);
    const out = [];
    let pos = 0;
    const { instance } = await WebAssembly.instantiate(bytes, {
        io: {
            write_byte: b => out.push(b),
            read_byte: () => (pos < input.length ? input[pos++] : -1),
        },
    });
    try {
        instance.exports.main();
    } catch (e) {
        // compile errors print through the output channel before trapping
        throw new Error(latin1(out).trim() || e.message);
    }
    return new Uint8Array(out);
}

function decode(v, ex) {
    if (typeof v === 'number') {
        return (v & 1) ? `#\\${String.fromCharCode(v >> 1)}` : String(v >> 1);
    }
    if (v === ex.false.value) return '#f';
    if (v === ex.true.value) return '#t';
    if (v === ex.null.value) return '()';
    if (v === ex.void.value) return '';
    return '#<object>';
}

async function runCompiled(bytes) {
    const out = [];
    const { instance } = await WebAssembly.instantiate(bytes, {
        io: { write_byte: b => out.push(b), read_byte: () => -1 },
    });
    try {
        const result = instance.exports.main();
        return { text: latin1(out), result: decode(result, instance.exports) };
    } catch (e) {
        return { text: latin1(out), error: e.message };
    }
}

const examples = {
    'fibonacci': `(define (fib n)
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

const srcBox = document.getElementById('src');
const outBox = document.getElementById('out');
const runBtn = document.getElementById('run');
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
srcBox.value = examples['fibonacci'];

async function go() {
    runBtn.disabled = true;
    outBox.textContent = 'compiling…';
    try {
        const t0 = performance.now();
        const wasm = await compileScheme(srcBox.value);
        const t1 = performance.now();
        const { text, result, error } = await runCompiled(wasm);
        const t2 = performance.now();
        let msg = text;
        if (error) {
            msg += (msg && !msg.endsWith('\n') ? '\n' : '') + `runtime error: ${error}`;
        } else if (result) {
            msg += (msg && !msg.endsWith('\n') ? '\n' : '') + `⇒ ${result}`;
        }
        msg += `\n\n— ${wasm.length} bytes, compiled ${(t1 - t0).toFixed(1)} ms, ran ${(t2 - t1).toFixed(1)} ms`;
        outBox.textContent = msg;
    } catch (e) {
        outBox.textContent = `compile error: ${e.message}`;
    }
    runBtn.disabled = false;
}

runBtn.addEventListener('click', go);
srcBox.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') go();
});
