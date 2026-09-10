;; A recording Web Audio mock, for tests that judge the SHAPE of an
;; audio graph rather than its samples.
;;
;; It lives here, in one file, because the mock that was inline in
;; test/audio.ss was about to be copied into a second audio test.  A
;; copied instrument is two instruments that drift, and the drift shows
;; up as one test believing a graph the other test cannot see.
;;
;; Four decisions in it are not conveniences, and each one exists
;; because the version it replaces could not tell two situations apart:
;;
;;   NODE IDENTITY.  Every node gets a unique id (GAIN#3, SRC#7).  The
;;     old mock gave every gain the id 'GAIN', so `gain.connect:DEST`
;;     named no particular gain -- and a panned voice has three of them.
;;     Any assertion about which node reached the destination was
;;     unwritable, and the ones that were written were true of a graph
;;     wired several different wrong ways.
;;
;;   RAW TIMES.  Every entry carries currentTime as a NUMBER.  The old
;;     mock recorded t.toFixed(2), and a fade is exactly a question
;;     about small differences in time: two ramps 4 ms apart printed
;;     identically, so a cell comparing them compared two equal strings
;;     and passed whatever the library did.  Nothing here may round.
;;
;;   ABSENT IS NOT ZERO.  connect records outputIndex and inputIndex as
;;     they arrived, and an argument that was not passed is recorded as
;;     the symbol 'absent -- not as 0.  A mock that defaulted them to 0
;;     would make "connected explicitly to input 1" and "connected with
;;     the default" the same reading, and the reason those indices are
;;     written explicitly in the first place is that the default is
;;     wrong for a merger.  The instrument must be able to see the
;;     distinction the code exists to make.
;;
;;   THE CLOCK IS DRIVEN.  currentTime advances only when a test says
;;     so.  A mock whose clock runs by itself makes "scheduled 0.5 s
;;     from now" and "scheduled at 2.5" indistinguishable, and makes
;;     reruns differ.  And `ended` is delivered by the test, never by
;;     stop(): on the platform it arrives later and separately, so a
;;     mock that fires it inside stop() cannot tell a library that waits
;;     for it from one that assumes it.
;;
;; What this cannot judge: whether any of it SOUNDS right, and
;; whether the platform's real nodes behave as assumed.  A graph is not
;; a signal.  That boundary is written down in
;; archive/goeteia-audio-design.md and is not narrowed by anything here.
(library (audmock)
  (export audio-mock-install! audio-mock-reset!
          audio-now audio-advance!
          audio-log-length audio-op audio-time-at audio-arg audio-arg-num audio-arg-count
          audio-find audio-find-from audio-fire-ended!
          audio-node-field
          audio-target-of audio-path-from audio-node-kind audio-path-kinds
          audio-newest-of-kind audio-nodes-created)
  (import (rnrs) (web js))

  (define (audio-mock-install!)
    (js-eval "
globalThis.__audio = { log: [], now: 0, ids: 0, nodes: {}, edges: {} };
(function () {
  const A = globalThis.__audio;
  // 'absent' is a distinct reading from 0: see the file header.
  const arg = v => (v === undefined ? 'absent' : v);
  const rec = (op, args) => A.log.push({ op: op, t: A.now, args: args });
  const param = (nodeId, name) => {
    let v = 0;
    return {
      // a plain assignment is a parameter write and is recorded as one
      get value() { return v },
      set value(x) { v = x; rec('param.value', [nodeId, name, x]) },
      setValueAtTime(x, t) { v = x; rec('param.setValueAtTime', [nodeId, name, x, t]); return this },
      linearRampToValueAtTime(x, t) { v = x; rec('param.linearRamp', [nodeId, name, x, t]); return this },
      exponentialRampToValueAtTime(x, t) { v = x; rec('param.expRamp', [nodeId, name, x, t]); return this },
      cancelScheduledValues(t) { rec('param.cancel', [nodeId, name, t]); return this },
    };
  };
  const node = (kind, extra) => {
    const id = kind + '#' + (++A.ids);
    const n = {
      id: id, kind: kind,
      started: 'absent', stopped: 'absent', onended: null,
      connect(dst, out, inp) {
        const to = (dst && dst.id) || String(dst);
        rec('connect', [id, to, arg(out), arg(inp)]);
        // The edge is ALSO kept outside the log, and survives a
        // reset.  The log is what happened in this section; the graph
        // is a structure that persists, and reading one out of the
        // other made every path assertion depend on where the section
        // breaks fell.  Measured: inserting one harmless
        // audio-mock-reset! between two sections turned a cell about
        // the library red, because the bus's edge to the destination is
        // recorded once, when the bus is born.
        (A.edges[id] = A.edges[id] || []).push(to);
        return dst;
      },
      disconnect(dst, out, inp) {
        const to = (dst && dst.id) || (dst === undefined ? 'absent' : String(dst));
        rec('disconnect', [id, to, arg(out), arg(inp)]);
        if (A.edges[id]) {
          A.edges[id] = (dst === undefined) ? [] : A.edges[id].filter(d => d !== to);
        }
      },
      start(t) { n.started = arg(t); rec('start', [id, arg(t)]) },
      stop(t) { n.stopped = arg(t); rec('stop', [id, arg(t)]) },
    };
    Object.assign(n, extra || {});
    A.nodes[id] = n;
    return n;
  };
  A.node = node;
  // Reading is done through these rather than by taking values apart in
  // Scheme: (web js) exports no type predicates, so a Scheme-side
  // reader would have to guess what a recorded argument is, and guess
  // wrong exactly where an argument is 'absent'.
  // The node a given node currently feeds: the last edge added and not
  // removed.  A node with several live outputs (the pan branch feeds
  // two gains) answers with the last of them -- the same answer the
  // log-scanning version gave, kept deliberately so that this change
  // fixes the reset dependence without also changing what any existing
  // cell means.  A cell that needs every output needs a new reader.
  A.targetOf = (id) => {
    const es = A.edges[id];
    return (es && es.length) ? es[es.length - 1] : '';
  };
  A.argStr = (i, k) => { const v = A.log[i].args[k]; return v === undefined ? 'absent' : String(v) };
  A.argNum = (i, k) => { const v = A.log[i].args[k]; return typeof v === 'number' ? v : NaN };
  A.field = (id, name) => {
    const n = A.nodes[id];
    if (!n) return 'no-such-node';
    const v = n[name];
    return v === undefined ? 'absent' : String(v);
  };
  A.fireEnded = id => {
    const n = A.nodes[id];
    rec('ended', [id]);
    if (n && n.onended) n.onended({ target: n });
  };
  globalThis.__syncThen = v => ({ then(f) { const r = f(v); return (r && r.then) ? r : globalThis.__syncThen(r) } });
  globalThis.AudioContext = function () {
    Object.defineProperty(this, 'currentTime', { get: () => A.now });
    this.destination = { id: 'DEST' };
    this.resume = () => rec('resume', []);
    this.createOscillator = () => {
      const n = node('OSC');
      n.type = ''; n.frequency = param(n.id, 'frequency');
      return n;
    };
    this.createGain = () => {
      const n = node('GAIN');
      n.gain = param(n.id, 'gain');
      return n;
    };
    this.createStereoPanner = () => {
      const n = node('PANNER');
      n.pan = param(n.id, 'pan');
      return n;
    };
    this.createChannelMerger = c => { const n = node('MERGER'); n.inputs = arg(c); return n };
    this.createBufferSource = () => {
      const n = node('SRC');
      n.buffer = null; n.loop = false; n.playbackRate = param(n.id, 'playbackRate');
      return n;
    };
    this.createDynamicsCompressor = () => {
      const n = node('COMP');
      for (const k of ['threshold', 'knee', 'ratio', 'attack', 'release']) n[k] = param(n.id, k);
      return n;
    };
    this.decodeAudioData = ab => { rec('decode', [(ab && ab.id) || String(ab)]); return globalThis.__syncThen({ id: 'BUF' }) };
  };
  globalThis.fetch = url => {
    rec('fetch', [url]);
    return globalThis.__syncThen({ arrayBuffer: () => globalThis.__syncThen({ id: 'AB' }) });
  };
})();
"))

  (define (A) (js-get (js-global) "__audio"))
  (define (entry i) (js-index (js-get (A) "log") i))
  (define (call2 name a b)
    (js-call (js-get (A) name) (A) a b))

  ;; How many nodes the mock has made, ever.  This deliberately
  ;; SURVIVES audio-mock-reset!, and that is the whole reason it exists:
  ;; counting nodes out of the log counts only the ones whose connect is
  ;; still in the log, so a node made before a reset stops existing as
  ;; far as that count is concerned.  A cell asserting "this many nodes
  ;; were made" over a reset then answers about a smaller world than the
  ;; one it means, and it answers it confidently.
  ;;
  ;; Measured, not argued: a cell counting connect-sources could not
  ;; see a mutant that built the bus during audio-init! -- the bus's
  ;; connect was cleared by the reset, so the count came out at exactly
  ;; the number the cell expected.  Counting creations sees it (5, not
  ;; 4).  Take a mark and subtract; do not reset.
  (define (audio-nodes-created) (js->number (js-get (A) "ids")))

  ;; Empties the log AND the clock.  In this instrument the log IS
  ;; the graph -- audio-target-of reads edges out of it -- so an edge
  ;; made before a reset is not merely unlisted, it is gone, and a path
  ;; that crosses it stops early with no sign that anything was lost.
  ;; A section that wants a fresh count and a whole graph must take a
  ;; mark (audio-log-length) and count from it, not reset.
  (define (audio-mock-reset!)
    (js-eval "globalThis.__audio.log.length = 0; globalThis.__audio.now = 0;"))

  (define (audio-now) (js->number (js-get (A) "now")))
  ;; Advancing is additive rather than absolute: a test that set the
  ;; clock backwards would produce a log whose times do not increase,
  ;; which no reader would think to check for.
  (define (audio-advance! dt)
    (unless (and (real? dt) (>= dt 0))
      (error 'audio-advance! "time moves forward only" dt))
    (js-set! (A) "now" (number->js (+ (audio-now) dt))))

  (define (audio-log-length) (js->number (js-get (js-get (A) "log") "length")))
  (define (audio-op i) (js->string (js-get (entry i) "op")))
  ;; The time is read as a NUMBER and never through a string: the whole
  ;; reason it is recorded raw is that fades differ by milliseconds.
  (define (audio-time-at i) (js->number (js-get (entry i) "t")))
  (define (audio-arg-count i) (js->number (js-get (js-get (entry i) "args") "length")))
  ;; An argument that was not passed reads as the string "absent".  It
  ;; is not 0, and a cell that wants 0 must say 0.
  (define (audio-arg i k)
    (js->string (call2 "argStr" (number->js i) (number->js k))))
  (define (audio-arg-num i k)
    (js->number (call2 "argNum" (number->js i) (number->js k))))

  (define (audio-find op) (audio-find-from op 0))
  (define (audio-find-from op from)
    (let ((n (audio-log-length)))
      (let loop ((i from))
        (cond ((>= i n) #f)
              ((string=? (audio-op i) op) i)
              (else (loop (+ i 1)))))))

  (define (audio-fire-ended! id)
    (js-call (js-get (A) "fireEnded") (A) (string->js id)))

  ;; Read a field off a recorded node -- 'started / 'stopped state --
  ;; without scanning the log for it.  Answers "absent" for a field that
  ;; was never set and "no-such-node" for an id that was never made:
  ;; two different facts, and a mock that returned the same thing for
  ;; both would let a cell about a node that does not exist read as a
  ;; cell about a node that was never started.
  (define (audio-node-field id name)
    (js->string (call2 "field" (string->js id) (string->js name))))

  ;; ---- reading the graph, not just the log ----
  ;; These live here rather than in each test because two files need
  ;; them, and a copied instrument is two instruments that drift.
  ;;
  ;; A node's current target is the destination of its LAST connect that
  ;; no later disconnect has undone.  A graph that is rewired -- a
  ;; bus switched between two downstreams, say -- legitimately has more
  ;; than one connect per node over its life, and only the last one is
  ;; the graph as it now stands.  Reading the FIRST would make every
  ;; assertion after a rewire describe the graph before it, and it would
  ;; do so quietly: the answer is a real node id either way.
  ;; #f rather than "" for a node that feeds nothing: the empty string
  ;; would be a node id as far as every caller here is concerned, and
  ;; audio-path-from would follow it.
  (define (audio-target-of id)
    (let ((v (js->string (js-call (js-get (A) "targetOf") (A) (string->js id)))))
      (if (string=? v "") #f v)))

  ;; The chain of node ids from one node onwards.  Bounded, and a run
  ;; that hits the bound answers "runaway" rather than looping: a cycle
  ;; is something these tests should report, not hang on.
  (define (audio-path-from id)
    (let loop ((id id) (n 0) (out '()))
      (cond ((> n 12) (reverse (cons "runaway" out)))
            ((not id) (reverse out))
            (else (loop (audio-target-of id) (+ n 1) (cons id out))))))

  (define (audio-node-kind id)          ; "GAIN#7" -> "GAIN"
    (let loop ((i 0))
      (cond ((= i (string-length id)) id)
            ((char=? (string-ref id i) #\#) (substring id 0 i))
            (else (loop (+ i 1))))))

  (define (audio-path-kinds id) (map audio-node-kind (audio-path-from id)))

  ;; The most recently created node of a kind that has been connected to
  ;; something.  Tests ask this because the library, not the test, makes
  ;; the nodes: there is no other way to name "the source play! just
  ;; started".  Answers "no-such-node" rather than #f so that a cell
  ;; asking about a node that was never made fails with a readable
  ;; comparison instead of a type error.
  (define (audio-newest-of-kind kindname)
    (let loop ((i 0) (found "no-such-node"))
      (cond ((>= i (audio-log-length)) found)
            ((and (string=? (audio-op i) "connect")
                  (string=? (audio-node-kind (audio-arg i 0)) kindname))
             (loop (+ i 1) (audio-arg i 0)))
            (else (loop (+ i 1) found))))))
