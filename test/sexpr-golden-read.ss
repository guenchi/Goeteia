;; expect: #t
;; (web sexpr) read side, against the SAME golden fixture:
;; test/sexpr-vectors.json, written by (igropyr sexpr).
;;
;; Three implementations of one wire format is a twin-drift risk, and
;; the way it is usually discovered is that two of them agree with each
;; other and both are wrong.  So neither of ours is ever checked against
;; the other: this file and test/sexpr-mjs.mjs each hold their own
;; implementation to the Scheme original's bytes, and the triangle
;; closes through the fixture rather than between the twins.
;;
;; The fixture carries wire text as base64 of its UTF-8 bytes, and this
;; file decodes only the entries it needs -- there is no JSON reader in
;; the browser half, so it scans the fixture for the fields it wants.
;;
;; The read half of test/sexpr-golden.ss, in its own file: parsing the
;; 65536-digit number token after that file's write sweep exhausts the
;; runtime's stack.  Splitting is not the whole story: five read
;; entries are still passed over here as too large, each printed by
;; name with the count pinned, and test/sexpr-mjs.mjs covers them.
(import (rnrs) (web js) (web fs) (web sexpr) (notrun))

;; Named skips go to STDERR, not stdout.  run-tests.sh compares the
;; WHOLE of stdout against the ";; expect:" line, so anything a passing
;; run prints there is a failure -- while "a skip must be named out
;; loud" is a rule about the log, not about the oracle's channel.  The
;; two live on different channels and both get what they need.
(define _note-chan (js-eval "globalThis.__note=(s)=>{console.error(s);}"))
(define __note (js-get (js-global) "__note"))
(define (note s) (js-call __note (js-undefined) (string->js s)))


;; "It raised" is not "it refused": a crash raises too, and a probe that
;; counts any exception as a refusal cannot tell a guard doing its job
;; from the implementation falling over.  Every guard below asks for
;; this codec's own refusal shape.
(define (refusal? e)
  (and (list? e) (= 3 (length e)) (eq? (car e) 'sexpr-error)))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))

;; ---- reading the fixture ------------------------------------------
;; The file is JSON; rather than write a parser for it here, the host's
;; own JSON.parse does the structural work and the values come back
;; through the JS bridge one field at a time.

(define FIXTURE-PATH "test/sexpr-vectors.json")
(define fixture-present? (fs-exists? FIXTURE-PATH))

;; An entry carries its wire either as base64 of the UTF-8 bytes or,
;; when it runs to tens of kilobytes, as the rule that builds it (the
;; generator checked the rule against the oracle's actual output).  The
;; fourth column of a reject row says whether the authority writes a
;; name that its own reader then refuses -- those are the names both of
;; our implementations deliberately refuse.
(define parse-fixture
  (js-eval "globalThis.__sxFixture=(text)=>{const d=JSON.parse(text);
    const dec=(b64)=>{const bin=atob(b64);
      const bytes=new Uint8Array(bin.length);
      for(let i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
      // fatal: a replacement-mode decoder would turn malformed fixture
      // bytes into U+FFFD before anything compared them
      return new TextDecoder('utf-8',{fatal:true}).decode(bytes);};
    const wire=(e,bf,rf)=>e[rf]?e[rf].prefix+e[rf].repeat.repeat(e[rf].count)+e[rf].suffix
                               :dec(e[bf]);
    // Accessors, not materialized arrays: several entries are tens of
    // kilobytes and holding all of them decoded at once exhausts the
    // runtime.  Each call rebuilds just the field being asked for.
    // the probe below runs THIS closure, not a fresh decoder: a
    // hard-coded one would stay fatal while this one was reverted
    globalThis.__sxDecodeProbe=(b64)=>{try{dec(b64);return 0;}catch(e){return 1;}};
    globalThis.__sxLen=(g)=>d[g].length;
    globalThis.__sxSize=(g,i)=>{const e=d[g][i];
      const r=e.wire_rule||e.input_rule;
      return r?r.prefix.length+r.count+r.suffix.length
              :(e.wire_b64||e.input_b64||'').length;};
    globalThis.__sxName=(g,i)=>d[g][i].name;
    globalThis.__sxWire=(i)=>wire(d.write[i],'wire_b64','wire_rule');
    globalThis.__sxInput=(i)=>wire(d.read[i],'input_b64','input_rule');
    globalThis.__sxAccepted=(i)=>d.read[i].accepted?1:0;
    globalThis.__sxErrPos=(i)=>d.read[i].accepted?-1:d.read[i].error_pos;
    globalThis.__sxCanonical=(i)=>d.read[i].accepted&&d.read[i].rewritable
      ?wire(d.read[i],'canonical_b64','canonical_rule'):'';
    globalThis.__sxSym=(i)=>d.write_reject[i].sym;
    globalThis.__sxRejected=(i)=>d.write_reject[i].rejected?1:0;
    globalThis.__sxDivergent=(i)=>d.write_reject[i].divergence?1:0;
    return d.write.length;}"))

(define (call-js name . args)
  (apply js-call (js-get (js-global) name) (js-undefined) args))
(define (sx-len group) (js->number (call-js "__sxLen" (string->js group))))
(define (sx-name group i) (js->string (call-js "__sxName" (string->js group) i)))
(define (sx-str name i) (js->string (call-js name i)))
(define (sx-flag name i) (= 1 (js->number (call-js name i))))
(define (sx-num name i) (js->number (call-js name i)))
(define raised-marker (list 'raised))

(define (ascii-only? s)
  (let loop ((i 0))
    (or (= i (string-length s))
        (and (< (char->integer (string-ref s i)) 128) (loop (+ i 1))))))

;; Only a position AFTER a non-ASCII character can differ from the
;; authority's -- read-astral-then-error fails at 1, before the emoji
;; shifts anything, and matches it exactly.  For the ones that do
;; differ, "any number will do" is not the alternative: a regression
;; reporting 0, or 5 instead of 6, would sail through that.  So this
;; file names THIS runtime's expected byte position for each such
;; probe.  The list is short on purpose -- if it grows, the entry
;; below fails until someone measures the new one and writes it down.
(define byte-positions
  '(("read-astral-then-error" . 1)
    ("read-astral-trailing" . 6)))

(define byte-position-notes 0)
(define (byte-position-ok? name pos)
  (set! byte-position-notes (+ byte-position-notes 1))
  (let ((want (assoc name byte-positions)))
    (cond
     ((not want)
      (display "  NO EXPECTED BYTE POSITION RECORDED for ")
      (display name) (display " (got ") (display pos) (display ")")
      (newline)
      #f)
     ((= pos (cdr want))
      ;; a NOTE, not a failure -- and so it belongs on the same channel
      ;; as the other named exemptions, off the oracle's stdout
      (note (string-append
             "  position compared in BYTES (this runtime indexes UTF-8 "
             "bytes, the authority counts code points): " name))
      #t)
     (else
      (display "  byte position differs: ") (display name)
      (display " pos=") (display pos)
      (display " want=") (display (cdr want)) (newline)
      #f))))
(define (sx-size group i)
  (js->number (call-js "__sxSize" (string->js group) i)))

;; This runtime holds the whole sweep in one heap, and the fixture's
;; oversized entries (a 65-kilobyte token, a 70-kilobyte bytevector)
;; exhaust it when parsed alongside everything else -- each is fine
;; alone.  They are NOT quietly dropped: each one is named below as it
;; is passed over, and the count is pinned, so a new oversized vector
;; cannot join them unnoticed.  test/sexpr-mjs.mjs exercises all of
;; them against the same fixture.
(define oversized-limit 16384)
(define oversized 0)
(define oversized-names '())
(define (note-oversized name)
  (set! oversized (+ oversized 1))
  (set! oversized-names (cons name oversized-names))
  (not-exercised! "too large for this runtime" name))

(define loaded
  (and fixture-present?
       (let ((text (fs-slurp-string FIXTURE-PATH)))
         (js->number (js-call (js-get (js-global) "__sxFixture")
                              (js-undefined) (string->js text))))))

;; ---- 2. the oracle's accept/reject verdicts ------------------------

(define read-ok
  (and loaded
       (let loop ((i 0) (ok #t))
         (if (= i (sx-len "read"))
             ok
             (if (> (sx-size "read" i) oversized-limit)
                 (begin (note-oversized (sx-name "read" i)) (loop (+ i 1) ok))
             (let* ((name (sx-name "read" i))
                    (input (sx-str "__sxInput" i))
                    (accepted (sx-flag "__sxAccepted" i))
                    (canonical (sx-str "__sxCanonical" i))
                    ;; a UNIQUE marker, not a tagged pair: a successful
                    ;; parse can itself be a pair -- "(. a)" comes back
                    ;; as a two-element list -- so a pair? test would
                    ;; call that a failure
                    ;; the codec's OWN refusal shape, tag included: any
                    ;; three-element list passed before, so a crash that
                    ;; happened to be one read as a guard doing its job
                    (r (guard (e (#t (vector raised-marker
                                             (if (refusal? e) (caddr e) -1))))
                         (string->sexpr input)))
                    (raised? (and (vector? r) (= 2 (vector-length r))
                                  (eq? (vector-ref r 0) raised-marker)))
                    (good
                     (cond
                      ;; The authority refuses it: so must we, AND at
                      ;; the same position.  Collapsing every failure to
                      ;; "it raised" would pass a reversion that reported
                      ;; 0 everywhere -- including for the astral probes,
                      ;; which exist precisely to pin a position.
                      ;; The authority refuses it: so must we, AND at
                      ;; the same position.  Collapsing every failure to
                      ;; "it raised" would pass a reversion that reported
                      ;; 0 everywhere.
                      ;;
                      ;; The one exception is a position AFTER a
                      ;; non-ASCII character.  This runtime's strings are
                      ;; UTF-8 BYTES (js->string hands back 8 units for
                      ;; the 5 code points of `"<emoji>" x`), while the
                      ;; authority counts code points, so the two cannot
                      ;; agree on such a position without a UTF-8 decode
                      ;; on the parser's hot path.  The refusal itself is
                      ;; still required here; only the number is let go,
                      ;; and only for probes whose input is not ASCII.
                      ((not accepted)
                       (and raised?
                            (or (= (vector-ref r 1) (sx-num "__sxErrPos" i))
                                (and (not (ascii-only? input))
                                     (byte-position-ok? name (vector-ref r 1))))))
                      ;; it parses and rewrites: same canonical bytes
                      ((not (string=? canonical ""))
                       (and (not raised?)
                            (let ((w (guard (e ((refusal? e) 'raised))
                                       (sexpr->string r))))
                              (and (string? w) (string=? w canonical)))))
                      ;; it parses but the authority will not write it
                      ;; back (a symbol named "+1"): both halves must
                      ;; agree, or this side would emit a datum the
                      ;; authority refuses to produce
                      (else
                       (and (not raised?)
                            (eq? 'raised
                                 (guard (e ((refusal? e) 'raised)) (sexpr->string r))))))))
               (loop (+ i 1)
                     (and ok
                          (or good
                              (begin (display "  read verdict differs: ")
                                     (display name)
                                     (when (and raised? (not accepted))
                                       (display " pos=") (display (vector-ref r 1))
                                       (display " want=")
                                       (display (sx-num "__sxErrPos" i)))
                                     (newline)
                                     #f))))))))))

;; ---- 4. the two boundaries this batch brought into line ------------
;; Spelled out rather than left to the fixture sweep, because these are
;; the behaviours (web sexpr) did not have before this batch: a base64
;; tail with bits left over is an error, not a silently short read, and
;; a symbol whose name would read back as a number does not go out.

(define bad-b64-ok
  (and (eq? 'raised (guard (e ((refusal? e) 'raised)) (string->sexpr "#vu8\"AB\"")))
       (eq? 'raised (guard (e ((refusal? e) 'raised)) (string->sexpr "#vu8\"AR==\"")))
       ;; and the accepting side of the same boundary still accepts
       (let ((v (guard (e ((refusal? e) 'raised)) (string->sexpr "#vu8\"A\""))))
         (and (bytevector? v) (= 0 (bytevector-length v))))))

;; (the symbol-refusal boundary lives in test/sexpr-golden.ss, with the
;; write sweep it belongs to.  A copy here would be a definition nobody
;; checks -- which is what it was until this line replaced it.)

;; ---- verdict -------------------------------------------------------

(check "fixture present" fixture-present?)
(when fixture-present?
  (check "oracle read verdicts" read-ok)
  ;; this file has its own decoder closure, so it needs its own probe:
  ;; the one in test/sexpr-golden.ss says nothing about this one
  (check "the fixture decoder refuses malformed UTF-8"
         (and (= 1 (js->number (call-js "__sxDecodeProbe" (string->js "Iv8i"))))
              (= 0 (js->number (call-js "__sxDecodeProbe" (string->js "IuS4rSI="))))))
  ;; pinned: exactly the non-ASCII probes may skip the position check
  (check "byte-position exemptions are the known ones" (= byte-position-notes 1))
  ;; membership, not just the count: an equal-sized substitution would
  ;; silently change WHICH cases this file stops holding anyone to
  (check "oversized set is the known one"
         (and (= oversized 5)
              (let loop ((want (list "read-long-token" "read-token-65536" "read-token-65537" "read-number-token-65536" "read-number-token-65537")) (ok #t))
                (if (null? want)
                    ok
                    (loop (cdr want)
                          (and ok (if (member (car want) oversized-names)
                                      #t
                                      (begin (display "  unexpected oversized set, missing: ")
                                             (display (car want)) (newline)
                                             #f))))))))
  (check "base64 tail is checked" bad-b64-ok)
  ;; Named membership, not just the count.  A probe could be deleted and
  ;; the recorded count decremented with it, and every sweep here would
  ;; simply run over one fewer entry -- the JS suite names its required
  ;; probes and caught exactly that; this side did not.  Every asymmetry
  ;; between the two has turned out to be a hole in whichever asserted
  ;; less.  The names below are the boundaries and the shapes a
  ;; reasonable edit might drop.
  ;; The depth boundary moves with WHAT SITS INNERMOST: at the same
  ;; parenthesis count a nest ending in `()` is accepted where one
  ;; ending in an atom is refused, because the empty list is recognised
  ;; while an atom costs one more descent.  Asserted here as well as in
  ;; the JS suite -- it was asserted only there, and one suite knowing a
  ;; fact the other does not is how the last several holes looked.
  (check "the depth boundary depends on the innermost datum"
         (let ((opens (lambda (name)
                        (let find ((i 0))
                          (cond ((= i (sx-len "read")) -1)
                                ((string=? name (sx-name "read" i))
                                 (let ((s (sx-str "__sxInput" i)))
                                   (let count ((j 0) (n 0))
                                     (if (= j (string-length s))
                                         n
                                         (count (+ j 1)
                                                ;; 40 is the open paren;
                                                ;; a #\( literal here
                                                ;; confuses the reader
                                                (if (= 40 (char->integer
                                                           (string-ref s j)))
                                                    (+ n 1) n))))))
                                (else (find (+ i 1)))))))
               (innermost (lambda (name)
                            (let find ((i 0))
                              (cond ((= i (sx-len "read")) "?")
                                    ((string=? name (sx-name "read" i))
                                     (let* ((s (sx-str "__sxInput" i))
                                            (m (string-length s))
                                            (o (let back ((j (- m 1)))
                                                 (cond ((< j 0) 0)
                                                       ((= 40 (char->integer
                                                               (string-ref s j)))
                                                        j)
                                                       (else (back (- j 1))))))
                                            (c (let fwd ((j o))
                                                 (cond ((= j m) m)
                                                       ((= 41 (char->integer
                                                               (string-ref s j)))
                                                        (+ j 1))
                                                       (else (fwd (+ j 1)))))))
                                       (substring s o c)))
                                    (else (find (+ i 1)))))))
               (accepted (lambda (name)
                           (let find ((i 0))
                             (cond ((= i (sx-len "read")) 'missing)
                                   ((string=? name (sx-name "read" i))
                                    (sx-flag "__sxAccepted" i))
                                   (else (find (+ i 1))))))))
           ;; depth AND what sits innermost, both asserted: relying on
           ;; the name to say which is which is relying on the thing the
           ;; pair exists to check
           (and (= 63 (opens "read-deep-63-empty"))
                (= 65 (opens "read-deep-65-empty"))
                (= 64 (opens "read-deep-64-atom"))
                (= 65 (opens "read-deep-65-atom"))
                (string=? "()" (innermost "read-deep-63-empty"))
                (string=? "()" (innermost "read-deep-65-empty"))
                (string=? "(1)" (innermost "read-deep-64-atom"))
                (string=? "(1)" (innermost "read-deep-65-atom"))
                (eq? #t (accepted "read-deep-63-empty"))
                (eq? #t (accepted "read-deep-65-empty"))
                (eq? #t (accepted "read-deep-64-atom"))
                (eq? #f (accepted "read-deep-65-atom")))))
  (check "the fixture still carries the probes that pin the boundaries"
         (let loop ((want '(
                             "read-int" "read-ratio-reduces"
                             "read-plus-five" "read-trailing-datum"
                             "read-deep-63-empty" "read-deep-65-empty"
                             "read-deep-64-atom" "read-deep-65-atom"
                             "read-token-65536" "read-token-65537"
                             "read-number-token-65536"
                             "read-number-token-65537"
                             "read-bv-bad-padding"
                             "read-bv-noncanonical-tail"
                             "read-bv-all-padding"
                             "read-bv-padding-midway"
                             "read-f8-wrong-length" "read-f8-noncanonical"
                             "read-astral-then-error"
                             "read-astral-trailing" "read-ratio-zero-den"
                             "read-double-slash"))
                    (ok #t))
           (if (null? want)
               ok
               (let find ((i 0))
                 (cond ((= i (sx-len "read"))
                        (display "  the fixture lost the probe: ")
                        (display (car want)) (newline)
                        (loop (cdr want) #f))
                       ((string=? (car want) (sx-name "read" i))
                        (loop (cdr want) ok))
                       (else (find (+ i 1)))))))))

(= fails 0)
