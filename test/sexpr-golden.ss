;; expect: #t
;; (web sexpr) against the SAME golden fixture that pins rt/sexpr.mjs:
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
;; Split in two (see test/sexpr-golden-read.ss): parsing the fixture's
;; 65536-digit number token builds a bignum big enough that doing it
;; AFTER the write sweep exhausts the runtime's stack, while either
;; half alone is comfortable.  Splitting is not the whole story: three
;; write entries are still passed over here as too large for this
;; runtime, each printed by name as it happens with the count pinned,
;; and test/sexpr-mjs.mjs exercises all of them against the same
;; fixture.
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

;; ---- 1. every golden wire string parses, and rewrites identically --
;; This is a FIXED-POINT check: parse the authority's bytes, write them
;; back, compare.  It catches a mistake on one side, and it is blind to
;; a matching pair of them -- decode a flonum big-endian AND encode it
;; big-endian and every byte here still agrees while every value in
;; between is wrong.  What the parsed value actually IS gets asked in
;; test/sexpr-anchors.ss, where the value is built from a spec that
;; never touches this codec and both directions are asserted against
;; the authority's bytes.  That file covers the value model as a cross
;; product of type x spelling branch, with the branch names pinned, so
;; the question this file cannot ask is answered by construction rather
;; than by whoever last thought of a case.  test/sexpr-limits.ss holds a
;; second, smaller leg of the same property whose expected bytes are
;; literals in its own source, so it still stands if the fixture itself
;; is wrong.

(define write-ok
  (and loaded
       (let loop ((i 0) (ok #t))
         (if (= i (sx-len "write"))
             ok
             (if (> (sx-size "write" i) oversized-limit)
                 (begin (note-oversized (sx-name "write" i)) (loop (+ i 1) ok))
             (let* ((name (sx-name "write" i))
                    (wire (sx-str "__sxWire" i))
                    (r (guard (e ((refusal? e) 'raised))
                         (sexpr->string (string->sexpr wire)))))
               (loop (+ i 1)
                     (and ok
                          (or (and (string? r) (string=? r wire))
                              (begin
                                (display "  golden mismatch: ")
                                (display name)
                                (when (string? r)
                                  (display " -> ") (display r))
                                (newline)
                                #f))))))))))

;; ---- 3. the writer's refusal set ----------------------------------
;; The writer's refusal set, name for name against the authority's.
;; The generator also measures whether the authority writes anything
;; its own reader refuses -- it did, for five names, before the fix
;; this fixture was regenerated against -- and marks those; the branch
;; below still honours the marking so an upstream regression arrives
;; as data rather than as a mismatch.

(define reject-ok
  (and loaded
       (let loop ((i 0) (ok #t))
         (if (= i (sx-len "write_reject"))
             ok
             (let* ((name (sx-name "write_reject" i))
                    (text (sx-str "__sxSym" i))
                    (rejected (sx-flag "__sxRejected" i))
                    (divergent? (lambda (_) (sx-flag "__sxDivergent" i)))
                    ;; measured, and currently always false: the
                    ;; authority no longer writes a name its own reader
                    ;; refuses.  Kept because the generator still
                    ;; measures it, so a regression upstream arrives as
                    ;; data instead of as a mismatch here.
                    (r (guard (e ((refusal? e) 'raised))
                         (sexpr->string (string->symbol text))))
                    (good (cond ((divergent? text) (eq? r 'raised))
                                (rejected (eq? r 'raised))
                                (else (and (string? r) (string=? r text))))))
               (loop (+ i 1)
                     (and ok
                          (or good
                              (begin (display "  symbol verdict differs: ")
                                     (display name) (display " ")
                                     (display text) (newline)
                                     #f)))))))))

;; ---- the writer refusal boundary this batch brought into line ------

(define unsafe-symbol-ok
  (and (eq? 'raised (guard (e ((refusal? e) 'raised))
                      (sexpr->string (string->symbol "12"))))
       (eq? 'raised (guard (e ((refusal? e) 'raised))
                      (sexpr->string (string->symbol "+1"))))
       (eq? 'raised (guard (e ((refusal? e) 'raised))
                      (sexpr->string (string->symbol "."))))
       (string=? "ok" (sexpr->string (string->symbol "ok")))))

;; ---- verdict -------------------------------------------------------

;; The fatal decoder is only evidence if something would notice it being
;; reverted, and the fixture is valid UTF-8 so every entry passes either
;; way.  This feeds malformed bytes to THE DECODER THIS FILE USES -- an
;; earlier version built a fresh fatal decoder here and proved only that
;; TextDecoder can be fatal, which it can whatever this file does.
(define (decoder-refuses? b64)
  (= 1 (js->number (call-js "__sxDecodeProbe" (string->js b64)))))
(define decoder-is-fatal
  (and (decoder-refuses? "Iv8i")          ; 22 ff 22 -- a lone #xff
       (not (decoder-refuses? "IuS4rSI=")))) ; 22 e4 b8 ad 22 -- valid CJK

(check "fixture present" fixture-present?)
(check "the fixture decoder refuses malformed UTF-8" decoder-is-fatal)
(when fixture-present?
  (check "golden write vectors" write-ok)
  ;; pinned: a new oversized vector must be a decision, not a drift
  ;; membership, not just the count: an equal-sized substitution would
  ;; silently change WHICH cases this file stops holding anyone to
  (check "oversized set is the known one"
         (and (= oversized 3)
              (let loop ((want (list "string-64k" "symbol-token-cap" "bytevector-64k")) (ok #t))
                (if (null? want)
                    ok
                    (loop (cdr want)
                          (and ok (if (member (car want) oversized-names)
                                      #t
                                      (begin (display "  unexpected oversized set, missing: ")
                                             (display (car want)) (newline)
                                             #f))))))))
  (check "writer refusal set" reject-ok)
  (check "unsafe symbol names refused" unsafe-symbol-ok))

(= fails 0)
