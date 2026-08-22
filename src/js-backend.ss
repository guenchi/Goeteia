;; JavaScript backend: emit an ES module functionally equivalent to
;; the wasm module, for hosts without WasmGC support (see
;; docs/js-backend.md).  The pipeline is shared through
;; prepare-program; this file walks the same core language the wasm
;; emitter walks and prints JS text instead of wasm bytes.
;;
;; Value representation mirrors the wasm backend: fixnums and chars
;; are JS numbers carrying the same low-bit i31 tag (n<<1 / c<<1|1),
;; every heap value is a small class, strings are Uint8Arrays, and
;; JS-FFI values stay wrapped in JSRef so they never collide with
;; tagged numbers.  All optimization contexts (unboxed f64/i32) are
;; skipped: the generic path is always emitted -- this target is a
;; compatibility fallback, not the fast path.
;;
;; Known divergences from the wasm target.  This list used to end
;; with "all confined to corners the test suite pins down as
;; unobservable", and both halves of that were false: `(eq? f f)` on
;; a top-level f answers #f here and #t on wasm, which is an ordinary
;; expression rather than a corner, and no test asserted it -- the one
;; place that cared, test/trig.ss, worked AROUND it with a textual
;; check and said so.  A note that claims coverage stops the next
;; person from looking, so it is worth more than the divergence it
;; was describing.
;;
;;   argument evaluation order inside a few primitives follows JS
;;   left-to-right;
;;
;;   a top-level function referenced as a value is one stable JS
;;   function, not a fresh closure per reference.  `eq?` sees this,
;;   and so does anything keyed by it -- an eq-hashtable finds a
;;   top-level procedure again here and does not on wasm.  Both
;;   answers are pinned, per target, in
;;   test/js-backend-procedure-identity.mjs; a .ss fixture cannot
;;   express them, because run-tests.sh holds every target to one
;;   `;; expect:` line.
;;
;; The %-prefixed accessors (%ratio-num, %ratio-den, %cx-re, %cx-im
;; and their kin) do NOT check the type of their argument, on either
;; target -- callers are the prelude and are expected to have decided
;; already.  Adding a check here would be a real cost on the hottest
;; path, while on wasm the equivalent check is free: ref.cast is what
;; reading the field compiles to anyway.  So the contract is "caller
;; guarantees", and what differs is the FAILURE SHAPE:
;;
;;   wasm stops at the boundary -- an illegal cast, at the call.
;;   here the field read yields `undefined`, which is not a Scheme
;;   value and is not stopped: it goes into pairs (`pair?` answers
;;   #t), compares with eq?, answers #f to number?, and travels until
;;   something reads its tag -- at which point the error is a JS
;;   TypeError naming a property, in a place unrelated to the call
;;   that made it.
;;
;; Practical consequence, and the reason this paragraph is here: a
;; crash on the JS target that cannot be located should be reproduced
;; on the wasm target first.  It stops nearer the mistake.  Non-self tail calls
;; run in constant stack via the TC/TR trampoline (wasm:
;; return_call); js-await still cannot suspend, and the kernel shims
;; the JSPI probes to say so honestly.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

;;;; ------------------------------------------------------------------
;;;; deterministic text state

(define *jn* 0)                 ; fresh locals v<n> / labels B<n>
(define *jconsts* '())          ; ((kind . datum) . index), newest first
(define *jconst-n* 0)
(define *jhelpers* '())         ; glue helpers actually used, by JS name

;; compact counter names: base-28 digits with no vowels, no 'l', no 'x',
;; so no suffix can spell a JS keyword after the prefix ('void') or a
;; kernel name ('Fl', 'Cx'), and tokens stay unambiguous at a glance
(define $jdigits "0123456789bcdfghjkmnpqrstvwz")
(define (jb28 n)
  (let loop ((n n) (acc '()))
    (let ((d (string (string-ref $jdigits (remainder n 28))))
          (q (quotient n 28)))
      (if (= q 0)
          (apply string-append d acc)
          (loop q (cons d acc))))))

(define (jfresh!)
  (set! *jn* (+ *jn* 1))
  (string-append "v" (jb28 *jn*)))
(define (jlabel!)
  (set! *jn* (+ *jn* 1))
  (string-append "B" (jb28 *jn*)))

(define (jconst! kind datum)
  (let find ((es *jconsts*))
    (cond
     ((null? es)
      (let ((i *jconst-n*))
        (set! *jconst-n* (+ i 1))
        (set! *jconsts* (cons (cons (cons kind datum) i) *jconsts*))
        (string-append "C" (jb28 i))))
     ((and (eq? (car (caar es)) kind) (equal? (cdr (caar es)) datum))
      (string-append "C" (jb28 (cdar es))))
     (else (find (cdr es))))))

;; a prelude generic helper (e.g. $add2) reached from a primitive's
;; slow path: resolve its emitted name, mirroring generic-call's
;; missing-helper compile error
(define (jgeneric name)
  (let ((f (assq name *fns*)))
    (unless f (errorf 'goeteia "missing generic helper ~s" name))
    (jfn-name name (cadr f))))

;; a glue call into a prelude generic: TR only when it may bounce
(define (jgeneric-tr name argstr)
  (let ((call (list (jgeneric name) "(" argstr ")")))
    (if (jbouncy? name) (list "TR(" call ")") call)))

(define (jhelper! name) ; record a used glue helper (emitted at the end)
  (unless (member name *jhelpers*)
    (set! *jhelpers* (cons name *jhelpers*)))
  name)

;; the enclosing top-level function, for direct self tail calls:
;; (name label pnames) or #f.  Cleared inside any nested arrow body
;; (a continue cannot cross a function boundary), like the wasm
;; backend's per-function loop state.
(define *jself* #f)
(define (without-jself thunk)
  (let ((saved *jself*))
    (set! *jself* #f)
    (let ((r (thunk)))
      (set! *jself* saved)
      r)))

;;;; ------------------------------------------------------------------
;;;; names

;; the numeric index alone names a function -- readable output is a
;; non-goal, and the Scheme name is recoverable through xports/the
;; compiler's *fns* table when debugging
(define (jfn-name sym idx)
  (string-append "F" (jb28 idx)))
(define (jvar-name g)
  (string-append "V" (jb28 g)))

;;;; ------------------------------------------------------------------
;;;; text assembly: trees of strings flatten to output bytes

(define (jsep sep trees)
  (if (null? trees)
      '()
      (let loop ((ts (cdr trees)) (acc (list (car trees))))
        (if (null? ts)
            (reverse acc)
            (loop (cdr ts) (cons (car ts) (cons sep acc)))))))

(define (jbytes tree)
  ;; tree: string | list of trees -> byte list
  (let ((acc '()))
    (let walk ((t tree))
      (cond
       ((null? t) #f)
       ((pair? t) (walk (car t)) (walk (cdr t)))
       ((string? t)
        (let ((n (string-length t)))
          (let loop ((i 0))
            (when (< i n)
              (set! acc (cons (char->integer (string-ref t i)) acc))
              (loop (+ i 1))))))
       (else #f)))
    (jsquash (reverse acc))))

;; The emitters parenthesize defensively, so `((x))` is systematic.
;; One text pass deletes a paren pair whose matching pair sits
;; DIRECTLY inside it -- always a no-op to the JS parser, since the
;; inner pair already delimits one primary expression.  Cascades
;; bottom-up: `(((x)))` collapses through the same last-closed check.
;; String literals (both quote kinds, backslash escapes) are opaque.
(define (jsquash bytes)
  (let* ((v (list->vector bytes))
         (n (vector-length v))
         (del (make-vector n #f)))
    ;; stack entries are (open-pos . top-level-comma-seen); the last
    ;; closed pair carries its comma flag so an argument-list outer
    ;; pair still collapses around a comma-free inner expression
    (let scan ((i 0) (q 0) (stack '()) (lo -2) (lc -2) (lcm #f))
      (if (< i n)
          (let ((c (vector-ref v i)))
            (cond
             ((> q 0)                     ; inside a string literal
              (cond
               ((= c 92) (scan (+ i 2) q stack lo lc lcm))
               ((= c q) (scan (+ i 1) 0 stack lo lc lcm))
               (else (scan (+ i 1) q stack lo lc lcm))))
             ((or (= c 34) (= c 39)) (scan (+ i 1) c stack lo lc lcm))
             ((= c 40) (scan (+ i 1) 0 (cons (cons i #f) stack) lo lc lcm))
             ((= c 44)
              (unless (null? stack) (set-cdr! (car stack) #t))
              (scan (+ i 1) 0 stack lo lc lcm))
             ((= c 41)
              ;; a '(' preceded by a name, ')' or ']' opens a call's
              ;; argument list: collapsing it around a comma-carrying
              ;; inner pair would split one argument into several, so
              ;; those collapse only when the inner pair is comma-free
              (let* ((p (car (car stack)))
                     (b (if (> p 0) (vector-ref v (- p 1)) 32))
                     (callee? (or (and (<= 48 b) (<= b 57))
                                  (and (<= 65 b) (<= b 90))
                                  (and (<= 97 b) (<= b 122))
                                  (= b 95) (= b 36) (= b 41) (= b 93))))
                (when (and (= lo (+ p 1)) (= lc (- i 1))
                           (not (and callee? lcm)))
                  (vector-set! del p #t)
                  (vector-set! del i #t))
                (scan (+ i 1) 0 (cdr stack) p i (cdr (car stack)))))
             (else (scan (+ i 1) 0 stack lo lc lcm))))
          #f))
    ;; second pass: parens around one identifier atom drop unless
    ;; they are an argument list (callee-ish byte before).  Digit-only
    ;; atoms keep theirs -- `(0).t` must not become `0.t` -- and an
    ;; identifier atom is safe bare in every emitted context
    ;; (operand, object value, single arrow parameter, argument).
    (let ((ident? (lambda (b)
                    (or (and (<= 48 b) (<= b 57))
                        (and (<= 65 b) (<= b 90))
                        (and (<= 97 b) (<= b 122))
                        (= b 95) (= b 36))))
          (at (lambda (i) (if (and (>= i 0) (< i n)) (vector-ref v i) 32))))
      (let scan2 ((i 0) (q 0))
        (when (< i n)
          (let ((c (vector-ref v i)))
            (cond
             ((> q 0)
              (cond
               ((= c 92) (scan2 (+ i 2) q))
               ((= c q) (scan2 (+ i 1) 0))
               (else (scan2 (+ i 1) q))))
             ((or (= c 34) (= c 39)) (scan2 (+ i 1) c))
             ((and (= c 40) (not (vector-ref del i))
                   ;; the effective neighbor skips bytes pass one
                   ;; deleted, or a collapsed argument list's callee
                   ;; would touch the atom directly
                   (let prev ((k (- i 1)))
                     (if (and (>= k 0) (vector-ref del k))
                         (prev (- k 1))
                         (let ((b (at k)))
                           (not (or (ident? b) (= b 41) (= b 93)))))))
              ;; scan the atom: letters/digits after a non-digit start
              (let atom ((j (+ i 1)) (nondigit #f))
                (cond
                 ((and (< j n) (ident? (at j)))
                  (atom (+ j 1) (or nondigit
                                    (let ((b (at j)))
                                      (not (and (<= 48 b) (<= b 57)))))))
                 ((and nondigit (> j (+ i 1)) (= (at j) 41)
                       (not (vector-ref del j)))
                  (vector-set! del i #t)
                  (vector-set! del j #t)
                  (scan2 (+ j 1) 0))
                 (else (scan2 (+ i 1) 0)))))
             (else (scan2 (+ i 1) 0)))))))
    (let collect ((i (- n 1)) (acc '()))
      (if (< i 0)
          acc
          (collect (- i 1)
                   (if (vector-ref del i) acc (cons (vector-ref v i) acc)))))))

;; JS string literal from a byte string: printable ASCII verbatim,
;; everything else (and quote/backslash) as \xHH -- deterministic
;; across hosts, decoded byte-per-char by the kernel's S().  `<`
;; escapes too, so no string literal can form the `</script`
;; sequence when the module text is inlined into an HTML page.
(define $jhex "0123456789abcdef")
(define (jstring-lit s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '("\"")))
      (if (= i n)
          (reverse (cons "\"" acc))
          (let ((b (char->integer (string-ref s i))))
            (loop (+ i 1)
                  (cons (if (and (<= 32 b) (<= b 126)
                                 (not (= b 34)) (not (= b 92))
                                 (not (= b 60)))
                            (let ((c (make-string 1)))
                              (string-set! c 0 (integer->char b))
                              c)
                            (let ((h (make-string 4)))
                              (string-set! h 0 (integer->char 92))  ; backslash
                              (string-set! h 1 (integer->char 120)) ; x
                              (string-set! h 2 (string-ref $jhex (quotient b 16)))
                              (string-set! h 3 (string-ref $jhex (remainder b 16)))
                              h))
                        acc)))))))

;; f64 as 16 hex chars (ieee-bytes order), decoded by the kernel's FB
;; -- both hosts print the same text where decimal formatting could
;; not be trusted to agree
(define (jflonum-hex d)
  (let ((bs (flatten (list (ieee-bytes d))))
        (out (make-string 16)))
    (let loop ((bs bs) (i 0))
      (if (null? bs)
          out
          (begin
            (string-set! out i (string-ref $jhex (quotient (car bs) 16)))
            (string-set! out (+ i 1)
                         (string-ref $jhex (remainder (car bs) 16)))
            (loop (cdr bs) (+ i 2)))))))

;;;; ------------------------------------------------------------------
;;;; datum

(define (jtag-int n)
  (string-append "(" (number->string (* 2 n)) ")"))
(define (jtag-char c)
  (string-append "(" (number->string (+ (* 2 (char->integer c)) 1)) ")"))

(define (jd d)
  (cond
   ((and (integer? d) (exact? d) (fits-fixnum? d)) (jtag-int d))
   ((and (integer? d) (exact? d))
    ;; bignum literal: the host's own arbitrary-precision integers
    (list "(" (number->string d) "n)"))
   ((flonum? d)
    (jkernel! 'fl)
    (list "(new Fl(FB(\"" (jflonum-hex d) "\")))"))
   ((and (rational? d) (exact? d))
    (jkernel! 'num)
    (list "(new Ratio(" (jd (numerator d)) "," (jd (denominator d)) "))"))
   ((and (number? d) (not (real? d)))
    (jkernel! 'num)
    (list "(new Cx(" (jd (real-part d)) "," (jd (imag-part d)) "))"))
   ((boolean? d) (if d "TRUE" "FALSE"))
   ((char? d) (jtag-char d))
   ((string? d) (jconst! 'str d))
   ((symbol? d) (jkernel! 'sym) (jconst! 'sym d))
   ((null? d) "NIL")
   ((vector? d)
    (list "([" (jsep "," (map-in-order jd (vector->list d))) "])"))
   ((pair? d)
    ;; flatten the spine into one array literal: nested `new Pair`
    ;; text thousands deep blows the JS parser's recursion
    (let spine ((x d) (acc '()))
      (cond
       ((pair? x) (spine (cdr x) (cons (jd (car x)) acc)))
       ((null? x)
        (list "L2([" (jsep "," (reverse acc)) "])"))
       (else
        (list "LD([" (jsep "," (reverse acc)) "]," (jd x) ")")))))
   (else (errorf 'goeteia "unsupported datum ~s" d))))

;;;; ------------------------------------------------------------------
;;;; expressions

;; env: scheme identifier (by identity) -> JS name.  lctx: %loop name
;; -> (label pnames), live only through statement-position tails.

(define (jx e env lctx)
  (cond
   ((and (integer? e) (exact? e) (fits-fixnum? e)) (jtag-int e))
   ((number? e) (jd e))
   ((boolean? e) (if e "TRUE" "FALSE"))
   ((char? e) (jtag-char e))
   ((string? e) (jconst! 'str e))
   ((symbol? e) (jref e env))
   ((pair? e)
    (case (resolve-tag (car e))
      ((quote) (jd (strip-marks (cadr e))))
      ((if)
       (let* ((t (jb (cadr e) env lctx))
              (c (jx (caddr e) env lctx))
              (a (if (null? (cdddr e))
                     "VOID"
                     (jx (cadddr e) env lctx))))
         (list "((" t ")?(" c "):(" a "))")))
      ((let) (jx-let e env lctx))
      ((%loop)
       (list "TR((()=>{" (without-jself (lambda () (jt e env '()))) "})())"))
      ((begin)
       (if (null? (cdr e))
           "VOID"
           (list "(" (jsep "," (map-in-order
                                (lambda (s) (list "(" (jx s env lctx) ")"))
                                (cdr e)))
                 ")")))
      ((lambda) (jx-lambda (cadr e) (cddr e) env))
      ((set!) (jx-set e env lctx))
      ((apply) (jx-apply e env lctx #f))
      ((call/cc call-with-current-continuation) (jx-callcc e env lctx))
      (else (jx-app e env lctx #f))))
   (else (errorf 'goeteia "cannot compile ~s" e))))

(define (jref e env)
  (let ((slot (assq e env)))
    (if slot
        (cdr slot)
        (let* ((r (unmark e))
               (v (assq r *vars*)))
          (if v
              (jvar-name (cdr v))
              (let ((f (assq r *fns*)))
                (if f
                    (jfn-name r (cadr f))
                    (let ((p (assq r prim-arity)))
                      (if p
                          ;; a primitive as a value: eta-expand
                          (let ((ps (map-in-order (lambda (i) (jfresh!))
                                                  (nums-below (cdr p)))))
                            (list "((" (jsep "," ps) ")=>"
                                  (jp r (map (lambda (x) 'eta) ps) ps)
                                  ")"))
                          (errorf 'goeteia
                                  (string-append "unbound variable ~s"
                                                 (unbound-hint r))
                                  e))))))))))

(define (jx-let e env lctx)
  ;; parallel let in expression position: an arrow IIFE; inits
  ;; compile in the outer scope
  (let* ((bs (cadr e))
         (names (map-in-order (lambda (b) (jfresh!)) bs))
         (inits (map-in-order (lambda (b) (jx (cadr b) env lctx)) bs))
         (env2 (append (map2* (lambda (b n) (cons (car b) n)) bs names) env)))
    (list "TR(((" (jsep "," names) ")=>{"
          (without-jself (lambda () (jt-body (cddr e) env2 '())))
          "})(" (jsep "," (map (lambda (i) (list "(" i ")")) inits)) "))")))

(define (jx-lambda formals body env)
  (let* ((rest (formals-rest formals))
         (fixed (formals-fixed formals))
         (fnames (map-in-order (lambda (p) (jfresh!)) fixed)))
    (if rest
        (let* ((rr (jfresh!))
               (rn (jfresh!))
               (env2 (append (map2* cons fixed fnames)
                             (cons (cons rest rn) env))))
          (list "((" (jsep "," (append fnames (list (string-append "..." rr))))
                ")=>{const " rn "=L2(" rr ");"
                (without-jself (lambda () (jt-body body env2 '())))
                "})"))
        (let ((env2 (append (map2* cons fixed fnames) env)))
          (list "((" (jsep "," fnames) ")=>{"
                (without-jself (lambda () (jt-body body env2 '())))
                "})")))))

(define (jx-set e env lctx)
  (let* ((r (unmark (cadr e)))
         (v (assq r *vars*)))
    (unless v
      (errorf 'goeteia
              (string-append "set! of unbound variable ~s" (unbound-hint r))
              (cadr e)))
    (list "((" (jvar-name (cdr v)) "=(" (jx (caddr e) env lctx) ")),VOID)")))

(define (jx-apply e env lctx tail?)
  (let ((f (cadr e))
        (args (cddr e)))
    (when (null? args)
      (errorf 'goeteia "apply needs an argument list in ~s" e))
    (let* ((leading (first-n args (- (length args) 1)))
           (final (car (list-tail args (- (length args) 1))))
           (fc (jx f env lctx))
           (lead (map-in-order (lambda (a) (list "(" (jx a env lctx) ")"))
                               leading))
           (fin (jx final env lctx)))
      (if tail?
          (list "A2T((" fc "),[" (jsep "," lead) "],(" fin "))")
          (list "TR(A2((" fc "),[" (jsep "," lead) "],(" fin ")))")))))

(define (jx-callcc e env lctx)
  (let* ((t (jfresh!))
         (w (jfresh!))
         (x (jfresh!))
         (ex (jfresh!))
         (wv (assq '$winders *vars*))
         (esc (assq '$escape *fns*)))
    (unless (and wv esc)
      (errorf 'goeteia "call/cc needs the $escape/$winders runtime"))
    (list "(()=>{const " t "={t:\"pair\",a:NIL,d:NIL}," w "="
          (jvar-name (cdr wv))
          ";try{return TR(IC((" (jx (cadr e) env lctx) "),[(" x ")=>TR("
          (jfn-name '$escape (cadr esc)) "(" t "," w "," x "))]));}catch("
          ex "){if(" ex " instanceof Esc&&" ex ".p.a===" t ")return "
          ex ".p.d;throw " ex ";}})()")))


;;;; ------------------------------------------------------------------
;;;; trampoline elision
;;
;; A tail call must stay a TC thunk only when the callee's tail
;; chain can reach a cycle (mutual recursion, or a variadic
;; function's self call, which has no rebind loop): an acyclic chain
;; of direct tail calls is bounded by the static function count, so
;; calling straight through costs constant stack.  A non-tail call
;; needs its TR unwind only when the callee may actually return a
;; thunk.  Closures always ride the indirect protocol (TCI builds
;; the thunk, IC sites keep TR), so only the top-level graph is
;; analyzed.

(define *jdanger* (make-eq-hashtable)) ; tail calls to it stay thunks
(define *jbouncy* (make-eq-hashtable)) ; calls to it keep the TR unwind

(define (jdanger? n) (hashtable-contains? *jdanger* n))
(define (jbouncy? n) (hashtable-contains? *jbouncy* n))

(define (jscan-trampolines! fn-defs)
  (set! *jdanger* (make-eq-hashtable))
  (set! *jbouncy* (make-eq-hashtable))
  (let ((out (make-eq-hashtable))     ; name -> distinct tail targets
        (rev (make-eq-hashtable))     ; target -> callers
        (base (make-eq-hashtable))    ; has an indirect/apply tail
        (names '()))
    (define (edge! f g)
      (let ((ts (hashtable-ref out f '())))
        (unless (memq g ts)
          (hashtable-set! out f (cons g ts))
          (hashtable-set! rev g (cons f (hashtable-ref rev g '()))))))
    ;; mirror jt's tail skeleton; lambda bodies are separate frames
    (define (scan-tail f e bound lnames self)
      (when (pair? e)
        (case (resolve-tag (car e))
          ((quote lambda set! call/cc call-with-current-continuation) #f)
          ((if)
           (scan-tail f (caddr e) bound lnames self)
           (unless (null? (cdddr e))
             (scan-tail f (cadddr e) bound lnames self)))
          ((begin) (scan-last f (cdr e) bound lnames self))
          ((let)
           (scan-last f (cddr e)
                      (append (map-in-order car (cadr e)) bound)
                      lnames self))
          ((%loop)
           (scan-last f (cdr (cdddr e))
                      (append (caddr e) bound)
                      (cons (cadr e) lnames) self))
          ((apply) (hashtable-set! base f #t))
          (else
           (let ((op (car e)))
             (cond
              ((not (symbol? op)) (hashtable-set! base f #t))
              ((memq op bound) (hashtable-set! base f #t))
              ((memq op lnames) #f)          ; loop rebind, no thunk
              (else
               (let ((r (unmark op)))
                 (cond
                  ((and self (eq? r (car self))
                        (= (length (cdr e)) (cdr self)))
                   #f)                       ; label rebind, no thunk
                  ((assq r *fns*) (edge! f r))
                  ((memq r primitives) #f)
                  (else (hashtable-set! base f #t)))))))))))
    (define (scan-last f xs bound lnames self)
      (cond ((null? xs) #f)
            ((null? (cdr xs)) (scan-tail f (car xs) bound lnames self))
            (else (scan-last f (cdr xs) bound lnames self))))
    (let loop ((ds fn-defs) (i N-IMPORTS))
      (unless (null? ds)
        (let* ((d (car ds))
               (name (unmark (def-name d)))
               (formals (cdadr d))
               (rest (formals-rest formals))
               (fixed (formals-fixed formals))
               (entry (assq name *fns*))
               ;; the rebind label exists only in the definition call
               ;; sites resolve to, and never in a variadic body
               (self (and (not rest) entry (= (cadr entry) i)
                          (cons name (length fixed)))))
          (unless (memq name names) (set! names (cons name names)))
          (scan-last name (cddr d) '() '() self))
        (loop (cdr ds) (+ i 1))))
    ;; safe fixpoint: safe iff every tail edge target is safe (a
    ;; Kahn drain over pending target counts); cycles never qualify,
    ;; the rest is danger
    (let ((safe (make-eq-hashtable))
          (pending (make-eq-hashtable)))
      (for-each (lambda (n)
                  (hashtable-set! pending n
                                  (length (hashtable-ref out n '()))))
                names)
      (let drain ((q (filter (lambda (n)
                               (= 0 (hashtable-ref pending n 1)))
                             names)))
        (unless (null? q)
          (let ((g (car q)))
            (hashtable-set! safe g #t)
            (drain
             (fold-left
              (lambda (acc f)
                (let ((c (- (hashtable-ref pending f 1) 1)))
                  (hashtable-set! pending f c)
                  (if (= c 0) (cons f acc) acc)))
              (cdr q)
              (hashtable-ref rev g '()))))))
      (for-each (lambda (n)
                  (unless (hashtable-contains? safe n)
                    (hashtable-set! *jdanger* n #t)))
                names))
    ;; bouncy fixpoint: seeded by indirect/apply tails and by kept
    ;; thunk edges (a tail call to a danger node); a straight tail
    ;; call passes the callee's thunk through, so it propagates up
    ;; the reverse edges
    (let ((q '()))
      (define (mark! f)
        (unless (hashtable-contains? *jbouncy* f)
          (hashtable-set! *jbouncy* f #t)
          (set! q (cons f q))))
      (for-each
       (lambda (n)
         (when (or (hashtable-contains? base n)
                   (let some ((ts (hashtable-ref out n '())))
                     (and (pair? ts)
                          (or (jdanger? (car ts)) (some (cdr ts))))))
           (mark! n)))
       names)
      (let drain ()
        (unless (null? q)
          (let ((g (car q)))
            (set! q (cdr q))
            (for-each mark! (hashtable-ref rev g '()))
            (drain)))))))

;; A non-tail call unwinds any trampoline the callee returns (TR); a
;; tail call BUILDS the trampoline thunk instead of calling (TC/TCI),
;; so non-self tail chains run in constant JS stack -- the wasm
;; backend's return_call.  Direct calls are arity-checked at compile
;; time (bare TC); indirect ones check at bounce time (TCI).
(define (jcall gname fcode args env lctx tail?)
  (let ((acode (jsep "," (map-in-order
                          (lambda (a) (list "(" (jx a env lctx) ")"))
                          args))))
    (if tail?
        (if (jdanger? gname)
            (list "(new TC(" fcode ",[" acode "]))")
            (list fcode "(" acode ")"))
        (if (jbouncy? gname)
            (list "TR(" fcode "(" acode "))")
            (list fcode "(" acode ")")))))

;; Indirect calls carry no compile-time arity proof.  Native JS fills
;; missing parameters with undefined, while the Wasm adapter traps.
(define (jicall fcode args env lctx tail?)
  (let ((acode (jsep "," (map-in-order
                          (lambda (a) (list "(" (jx a env lctx) ")"))
                          args))))
    (if tail?
        (list "TCI(" fcode ",[" acode "])")
        (list "TR(IC(" fcode ",[" acode "]))"))))

(define (jx-app e env lctx tail?)
  (let* ((op (car e))
         (args (cdr e))
         (rop (and (symbol? op) (unmark op))))
    (cond
     ((and (symbol? op) (assq op env))
      (jicall (list "(" (cdr (assq op env)) ")") args env lctx tail?))
     ((and rop (memq rop primitives) (not (assq rop *fns*)))
      (jp rop args (map-in-order (lambda (a) (jx a env lctx)) args)))
     ((and rop (assq rop *fns*))
      (let* ((entry (cdr (assq rop *fns*)))
             (nfixed (cadr entry))
             (variadic? (caddr entry)))
        (if variadic?
            (when (< (length args) nfixed)
              (errorf 'goeteia "too few arguments in ~s" e))
            (unless (= nfixed (length args))
              (errorf 'goeteia "wrong argument count in ~s" e)))
        (jcall rop (jfn-name rop (car entry)) args env lctx tail?)))
     ((and rop (assq rop *vars*))
      (jicall (list "(" (jvar-name (cdr (assq rop *vars*))) ")")
              args env lctx tail?))
     ((pair? op)
      (jicall (list "(" (jx op env lctx) ")") args env lctx tail?))
     (else (errorf 'goeteia "cannot call ~s" op)))))

;; test position: a raw JS boolean; the predicate set the wasm
;; backend fast-paths lands here too, everything else is !==FALSE
(define (jb e env lctx)
  (if (and (pair? e)
           (symbol? (car e))
           (not (assq (car e) env))
           (not (assq (unmark (car e)) *fns*))
           (let ((expect (assq (unmark (car e)) prim-arity)))
             (and expect (= (length (cdr e)) (cdr expect)))))
      (let ((rop (unmark (car e)))
            (a (lambda (i) (list "(" (jx (list-ref (cdr e) i) env lctx) ")"))))
        (jkernel-for-op! rop)
        (case rop
          ((=) (list (jhelper! "JEQN") "(" (a 0) "," (a 1) ")"))
          ((<) (list (jhelper! "JLTN") "(" (a 0) "," (a 1) ")"))
          ((zero?) (list (jhelper! "JZ") "(" (a 0) ")"))
          ((eq?) (list "(" (a 0) "===" (a 1) ")"))
          ((pair?) (list "((" (a 0) ".t)===\"pair\")"))
          ((null?) (list "(" (a 0) "===NIL)"))
          ((string?) (list "(" (a 0) " instanceof Uint8Array)"))
          ((symbol?) (list "(" (a 0) " instanceof Sym)"))
          ((procedure?) (list "(typeof " (a 0) "==='function')"))
          ((eof-object?) (list "(" (a 0) "===EOFV)"))
          ((fl=?) (list "(FLV(" (a 0) ")===FLV(" (a 1) "))"))
          ((fl<?) (list "(FLV(" (a 0) ")<FLV(" (a 1) "))"))
          (else (list "((" (jx e env lctx) ")!==FALSE)"))))
      (list "((" (jx e env lctx) ")!==FALSE)")))

;;;; ------------------------------------------------------------------
;;;; statements (function-body tails)

(define (jt-body es env lctx)
  (cond
   ((null? es) "return VOID;")
   ((null? (cdr es)) (jt (car es) env lctx))
   (else
    (let* ((head (jx (car es) env lctx))
           (rest (jt-body (cdr es) env lctx)))
      (list "(" head ");" rest)))))

(define (jt e env lctx)
  (if (pair? e)
      (case (resolve-tag (car e))
        ((if)
         (let* ((t (jb (cadr e) env lctx))
                (c (jt (caddr e) env lctx))
                (a (if (null? (cdddr e))
                       "return VOID;"
                       (jt (cadddr e) env lctx))))
           (list "if(" t "){" c "}else{" a "}")))
        ((begin) (jt-body (cdr e) env lctx))
        ((let)
         ;; statement position: an inline block, so an enclosing
         ;; loop's continue stays reachable through the tail
         (let* ((bs (cadr e))
                (names (map-in-order (lambda (b) (jfresh!)) bs))
                (inits (map-in-order (lambda (b) (jx (cadr b) env lctx)) bs))
                (env2 (append (map2* (lambda (b n) (cons (car b) n)) bs names)
                              env)))
           (list "{"
                 (if (null? bs)
                     '()
                     (list "let "
                           (jsep "," (map2* (lambda (n i)
                                              (list n "=(" i ")"))
                                            names inits))
                           ";"))
                 (jt-body (cddr e) env2 lctx) "}")))
        ((%loop)
         (let* ((name (cadr e))
                (params (caddr e))
                (inits (cadddr e))
                (body (cdr (cdddr e)))
                (pnames (map-in-order (lambda (p) (jfresh!)) params))
                (label (jlabel!))
                (icode (map-in-order (lambda (i) (jx i env lctx)) inits))
                (env2 (append (map2* cons params pnames) env))
                (lctx2 (cons (list name label pnames) lctx)))
           (list "{"
                 (if (null? pnames)
                     '()
                     (list "let " (jsep "," (map2* (lambda (n i)
                                                     (list n "=(" i ")"))
                                                   pnames icode))
                           ";"))
                 label ":for(;;){" (jt-body body env2 lctx2) "}}")))
        ((quote lambda set! call/cc call-with-current-continuation)
         (list "return " (jx e env lctx) ";"))
        ((apply)
         ;; tail apply builds the trampoline thunk (A2T)
         (list "return " (jx-apply e env lctx #t) ";"))
        (else
         (cond
          ((and (symbol? (car e))
                (not (assq (car e) env))
                (assq (car e) lctx))
           ;; loop self-call: new values into temps, assign, continue
           (jt-rebind (assq (car e) lctx) (cdr e) env lctx))
          ((and (symbol? (car e))
                (not (assq (car e) env))
                *jself*
                (eq? (unmark (car e)) (car *jself*))
                (= (length (cdr e)) (length (caddr *jself*))))
           ;; direct self tail call: the wasm backend's return_call,
           ;; spelled as a continue on the function's own loop
           (jt-rebind *jself* (cdr e) env lctx))
          (else
           ;; any other tail application returns a trampoline thunk
           (list "return " (jx-app e env lctx #t) ";")))))
      (list "return " (jx e env lctx) ";")))

(define (jt-rebind entry args env lctx)
  (let* ((label (cadr entry))
         (pnames (caddr entry))
         (tmps (map-in-order (lambda (a) (jfresh!)) args))
         (acode (map-in-order (lambda (a) (jx a env lctx)) args)))
    (list "{"
          (if (null? tmps)
              '()
              (list "const "
                    (jsep "," (map2* (lambda (t a)
                                       (list t "=(" a ")"))
                                     tmps acode))
                    ";"))
          (map2* (lambda (p t) (list p "=" t ";")) pnames tmps)
          "continue " label ";}")))

;;;; ------------------------------------------------------------------
;;;; primitives

;; trees are the argument expressions, already compiled in source
;; order.  args (the raw forms) are consulted only where the wasm
;; backend also needs literals (%record-ref field indices).
;; which kernel groups a primitive reaches; consulted at emission so
;; DCE-pruned primitives never register anything
(define $jp-kernel-groups
  '((fl fl+ fl- fl* fl/ fl=? fl<? flsqrt flfloor fltruncate
        fixnum->flonum %fl->fx flonum? %js-to-number %big->fl)
    (num %ratio? %make-ratio %ratio-num %ratio-den
         %complex? %make-complex %cx-re %cx-im)
    (sym symbol? symbol->string %make-symbol %interned-symbols)
    (bv bytevector? %make-bytevector bytevector-length
        bytevector-u8-ref bytevector-u8-set!)
    (rec %record %record? %record-ref %record-set! %recbase? %record-rtd)
    (mem %mem-u8-ref %mem-u8-set! %mem-i32-ref %mem-i32-set!
         %mem-f32-ref %mem-f32-set! %mem-f64-ref %mem-f64-set!
         %mem-size %mem-grow
         %f32x4-add! %f32x4-sub! %f32x4-mul! %f32x4-scale!
         %f32x4-axpy! %f32x4-dot)
    (ffi %js-ref? %js-arg-byte %js-global %js-get %js-set! %js-push
         %js-call %js-new %js-string %js-str-len %js-str-byte
         %js-number %js-to-number %js-eq %js-bool %js-undefined
         %js-fn %js-cb-argc %js-cb-arg %js-cb-ret)))

(define (jkernel-for-op! op)
  (for-each (lambda (e)
              (when (memq op (cdr e)) (jkernel! (car e))))
            $jp-kernel-groups))

(define (jp op args trees)
  (define (a i) (list "(" (list-ref trees i) ")"))
  (jkernel-for-op! op)
  (let ((expect (assq op prim-arity)))
    (when (and expect
               (not (memq op '(+ - *)))
               (not (= (length trees) (cdr expect))))
      (errorf 'goeteia "wrong argument count for primitive ~s" op)))
  (case op
    ((+ - *)
     (cond
      ((and (eq? op '-) (= (length trees) 1))
       (list (jhelper! "JSUB") "((0)," (a 0) ")"))
      ((< (length trees) 2)
       (errorf 'goeteia "primitive ~s needs two or more arguments" op))
      (else
       (let ((h (jhelper! (case op ((+) "JADD") ((-) "JSUB") (else "JMUL")))))
         (let fold ((code (a 0)) (i 1))
           (if (= i (length trees))
               code
               (fold (list h "(" code "," (a i) ")") (+ i 1))))))))
    ((quotient) (list (jhelper! "JQUO") "(" (a 0) "," (a 1) ")"))
    ((remainder) (list (jhelper! "JREM") "(" (a 0) "," (a 1) ")"))
    ((=) (list "(" (jhelper! "JEQN") "(" (a 0) "," (a 1) ")?TRUE:FALSE)"))
    ((<) (list "(" (jhelper! "JLTN") "(" (a 0) "," (a 1) ")?TRUE:FALSE)"))
    ((zero?) (list "(" (jhelper! "JZ") "(" (a 0) ")?TRUE:FALSE)"))
    ((eq?) (list "((" (a 0) "===" (a 1) ")?TRUE:FALSE)"))
    ((cons) (list "({t:\"pair\",a:" (a 0) ",d:" (a 1) "})"))
    ((car) (list "(PV(" (a 0) ").a)"))
    ((cdr) (list "(PV(" (a 0) ").d)"))
    ((set-car!) (list "((PV(" (a 0) ").a=" (a 1) "),VOID)"))
    ((set-cdr!) (list "((PV(" (a 0) ").d=" (a 1) "),VOID)"))
    ((pair?) (list "(((" (a 0) ".t)===\"pair\")?TRUE:FALSE)"))
    ((null?) (list "((" (a 0) "===NIL)?TRUE:FALSE)"))
    ((fixnum?) (list "(KFIX(" (a 0) "))"))
    ((char?) (list "(KCHR(" (a 0) "))"))
    ((boolean?) (list "(KBOOL(" (a 0) "))"))
    ((flonum?) (list "((" (a 0) " instanceof Fl)?TRUE:FALSE)"))
    ((string?) (list "((" (a 0) " instanceof Uint8Array)?TRUE:FALSE)"))
    ((symbol?) (list "((" (a 0) " instanceof Sym)?TRUE:FALSE)"))
    ((procedure?) (list "((typeof " (a 0) "==='function')?TRUE:FALSE)"))
    ((eof-object) "EOFV")
    ((eof-object?) (list "((" (a 0) "===EOFV)?TRUE:FALSE)"))
    ;; flonum arithmetic, generic (boxed) spelling only
    ((fl+) (list "(new Fl(FLV(" (a 0) ")+FLV(" (a 1) ")))"))
    ((fl-) (list "(new Fl(FLV(" (a 0) ")-FLV(" (a 1) ")))"))
    ((fl*) (list "(new Fl(FLV(" (a 0) ")*FLV(" (a 1) ")))"))
    ((fl/) (list "(new Fl(FLV(" (a 0) ")/FLV(" (a 1) ")))"))
    ((fl=?) (list "((FLV(" (a 0) ")===FLV(" (a 1) "))?TRUE:FALSE)"))
    ((fl<?) (list "((FLV(" (a 0) ")<FLV(" (a 1) "))?TRUE:FALSE)"))
    ((flsqrt) (list "(new Fl(Math.sqrt(FLV(" (a 0) "))))"))
    ((flfloor) (list "(new Fl(Math.floor(FLV(" (a 0) "))))"))
    ((fltruncate) (list "(new Fl(Math.trunc(FLV(" (a 0) "))))"))
    ((fixnum->flonum) (list "(new Fl(IU(" (a 0) ")))"))
    ((%fl->fx) (list "F2I(" (a 0) ".v)"))
    ;; the numeric tower's building blocks
    ((%bignum?) (list "((typeof " (a 0) "==='bigint')?TRUE:FALSE)"))
    ((%big-add) (list "(" (a 0) "+" (a 1) ")"))
    ((%big-neg) (list "(-" (a 0) ")"))
    ((%big-mul) (list "(" (a 0) "*" (a 1) ")"))
    ((%big-quot) (list "(" (a 0) "/" (a 1) ")"))
    ((%big-rem) (list "(" (a 0) "%" (a 1) ")"))
    ((%big-lt) (list "((" (a 0) "<" (a 1) ")?TRUE:FALSE)"))
    ((%big-eq) (list "((" (a 0) "===" (a 1) ")?TRUE:FALSE)"))
    ;; back to a tagged fixnum when the value fits i31
    ((%big-norm)
     (list "(" (jhelper! "BNRM") "(" (a 0) "))"))
    ((%fx->big) (list "(BigInt(IU(" (a 0) ")))"))
    ((%big->fl) (list "(new Fl(Number(" (a 0) ")))"))
    ((%big->str) (list "(S(String(" (a 0) ")))"))
    ((%ratio?) (list "((" (a 0) " instanceof Ratio)?TRUE:FALSE)"))
    ((%make-ratio) (list "(new Ratio(" (a 0) "," (a 1) "))"))
    ((%ratio-num) (list "(" (a 0) ".n)"))
    ((%ratio-den) (list "(" (a 0) ".dd)"))
    ((%complex?) (list "((" (a 0) " instanceof Cx)?TRUE:FALSE)"))
    ((%make-complex) (list "(new Cx(" (a 0) "," (a 1) "))"))
    ((%cx-re) (list "(" (a 0) ".re)"))
    ((%cx-im) (list "(" (a 0) ".im)"))
    ;; chars and strings
    ((char->integer) (list "(I31(" (a 0) ")&-2)"))
    ((integer->char) (list "(I31(" (a 0) ")|1)"))
    ((string-length) (list "(STR(" (a 0) ").length<<1)"))
    ((string-ref) (list "((AR(STR(" (a 0) ")," (a 1) ")<<1)|1)"))
    ((string-set!) (list "AW(STR(" (a 0) ")," (a 1) ",IU(" (a 2) "))"))
    ((symbol->string) (list "(SYMV(" (a 0) ").s)"))
    ((%make-string) (list "(new Uint8Array(IU(" (a 0) ")))"))
    ((%make-symbol) (list "(new Sym(STR(" (a 0) ")))"))
    ((%interned-symbols) "(RSYMS())")
    ;; vectors and bytevectors
    ((vector?) (list "(Array.isArray(" (a 0) ")?TRUE:FALSE)"))
    ((%make-vector)
     (list "(new Array(IU(" (a 0) ")).fill(" (a 1) "))"))
    ((vector-length) (list "(VEC(" (a 0) ").length<<1)"))
    ((vector-ref) (list "AR(VEC(" (a 0) ")," (a 1) ")"))
    ((vector-set!) (list "AW(VEC(" (a 0) ")," (a 1) "," (a 2) ")"))
    ((bytevector?) (list "((" (a 0) " instanceof BV)?TRUE:FALSE)"))
    ((%make-bytevector)
     (list "(new BV(new Uint8Array(IU(" (a 0) ")).fill(IU(" (a 1) "))))"))
    ((bytevector-length) (list "(BVU(" (a 0) ").length<<1)"))
    ((bytevector-u8-ref) (list "(AR(BVU(" (a 0) ")," (a 1) ")<<1)"))
    ((bytevector-u8-set!)
     (list "AW(BVU(" (a 0) ")," (a 1) ",IU(" (a 2) "))"))
    ;; fixnum bitwise, straight on the tagged representation
    ((bitwise-and) (list "(I31(" (a 0) ")&I31(" (a 1) "))"))
    ((bitwise-ior) (list "(I31(" (a 0) ")|I31(" (a 1) "))"))
    ((bitwise-xor) (list "(I31(" (a 0) ")^I31(" (a 1) "))"))
    ((bitwise-arithmetic-shift-left)
     ;; (n<<1) << k, renormalized to i31 like ref.i31 does
     (list "(((I31(" (a 0) ")<<IU(" (a 1) "))<<1)>>1)"))
    ((bitwise-arithmetic-shift-right)
     (list "((I31(" (a 0) ")>>IU(" (a 1) "))&-2)"))
    ;; records
    ((%record) (list "(new Rec([" (jsep "," trees) "]))"))
    ((%recbase?) (list "((" (a 0) " instanceof Rec)?TRUE:FALSE)"))
    ((%record-rtd) (list "(" (a 0) ".f[0])"))
    ((%record?) (list "(KREC(" (a 0) "," (a 1) "))"))
    ((%record-ref)
     (list "(" (a 0) ".f[" (number->string (+ (caddr args) 1)) "])"))
    ((%record-set!)
     (list "((" (a 0) ".f[" (number->string (+ (caddr args) 1)) "]="
           (a 3) "),VOID)"))
    ;; control
    ((%unreachable) "(UNR())")
    ((%throw-k) (list "(THR(" (a 0) "," (a 1) "))"))
    ;; IO
    ((%write-byte) (list "((IO.write_byte(IU(" (a 0) "))),VOID)"))
    ((%read-byte) "(W(IO.read_byte()))")
    ((%path-byte) (list "((IO.path_byte(IU(" (a 0) "))),VOID)"))
    ((%open-read) "(W(IO.open_read()))")
    ((%open-write) "(W(IO.open_write()))")
    ((%fread) (list "(W(IO.fread(IU(" (a 0) "))))"))
    ((%fwrite) (list "((IO.fwrite(IU(" (a 0) "),IU(" (a 1) "))),VOID)"))
    ((%fclose) (list "((IO.fclose(IU(" (a 0) "))),VOID)"))
    ;; the linear staging memory
    ((%mem-u8-ref) (list "M8R(" (a 0) ")"))
    ((%mem-u8-set!) (list "M8W(" (a 0) "," (a 1) ")"))
    ((%mem-i32-ref) (list "M32R(" (a 0) ")"))
    ((%mem-i32-set!) (list "M32W(" (a 0) "," (a 1) ")"))
    ((%mem-f32-ref) (list "MF32R(" (a 0) ")"))
    ((%mem-f32-set!) (list "MF32W(" (a 0) "," (a 1) ")"))
    ((%mem-f64-ref) (list "MF64R(" (a 0) ")"))
    ((%mem-f64-set!) (list "MF64W(" (a 0) "," (a 1) ")"))
    ((%mem-size) "(MSIZE())")
    ((%mem-grow) (list "(W(MGROW(IU(" (a 0) "))))"))
    ;; SIMD as scalar loops; single-rounded per lane, like f32x4
    ((%f32x4-add!)
     (list "(F4('+',IU(" (a 0) "),IU(" (a 1) "),IU(" (a 2) ")),VOID)"))
    ((%f32x4-sub!)
     (list "(F4('-',IU(" (a 0) "),IU(" (a 1) "),IU(" (a 2) ")),VOID)"))
    ((%f32x4-mul!)
     (list "(F4('*',IU(" (a 0) "),IU(" (a 1) "),IU(" (a 2) ")),VOID)"))
    ((%f32x4-scale!)
     (list "(F4SC(IU(" (a 0) "),IU(" (a 1) "),FLV(" (a 2) ")),VOID)"))
    ((%f32x4-axpy!)
     (list "(F4AX(IU(" (a 0) "),IU(" (a 1) "),IU(" (a 2) "),FLV(" (a 3) ")),VOID)"))
    ((%f32x4-dot)
     (list "(new Fl(F4D(IU(" (a 0) "),IU(" (a 1) "))))"))
    ;; JS FFI: the wasm bridge protocol, implemented natively
    ((%js-ref?) (list "((" (a 0) " instanceof JSRef)?TRUE:FALSE)"))
    ((%js-arg-byte) (list "((NB.push(IU(" (a 0) "))),VOID)"))
    ((%js-global) "(new JSRef(GPROX))")
    ((%js-get) (list "(new JSRef(JGET(" (a 0) ".v)))"))
    ((%js-set!) (list "((JSET(" (a 0) ".v," (a 1) ".v)),VOID)"))
    ((%js-push) (list "((AS.push(" (a 0) ".v)),VOID)"))
    ((%js-call) (list "(new JSRef(JCALL(" (a 0) ".v," (a 1) ".v)))"))
    ((%js-new) (list "(new JSRef(JNEW(" (a 0) ".v)))"))
    ((%js-string) "(new JSRef(TDX()))")
    ((%js-str-len) (list "(W(JSL(" (a 0) ".v)))"))
    ((%js-str-byte) (list "(W(STG[IU(" (a 0) ")]))"))
    ((%js-number) (list "(new JSRef(" (a 0) ".v))"))
    ((%js-to-number) (list "(new Fl(Number(" (a 0) ".v)))"))
    ((%js-eq) (list "((" (a 0) ".v===" (a 1) ".v)?TRUE:FALSE)"))
    ((%js-bool) (list "((" (a 0) ".v)?TRUE:FALSE)"))
    ((%js-undefined) "(new JSRef(void 0))")
    ((%js-fn) (list "(new JSRef(" (jhelper! "JFN") "(" (a 0) ")))"))
    ((%js-cb-argc) "(W(CBS[CBS.length-1].args.length))")
    ((%js-cb-arg)
     (list "(new JSRef(CBS[CBS.length-1].args[IU(" (a 0) ")]))"))
    ((%js-cb-ret)
     (list "((CBS[CBS.length-1].ret=" (a 0) ".v),VOID)"))
    ;; no JSPI on this target: the promise comes back unawaited,
    ;; mirroring the wasm host's no-engine-support fallback
    ((%js-await) (a 0))
    (else (errorf 'goeteia "unhandled primitive ~s" op))))

;;;; ------------------------------------------------------------------
;;;; the runtime kernel

(define *jkernels* '())        ; kernel groups the program reaches
(define (jkernel! g)
  (unless (memq g *jkernels*)
    (set! *jkernels* (cons g *jkernels*)))
  g)

;; The runtime kernel, grouped so a program only carries what it
;; reaches: a page section that never touches the FFI or the staging
;; memory ships without them.  Groups list their dependencies; core
;; is always emitted.  Registration happens at emission, so anything
;; DCE pruned from the prelude never drags its group in.
(define $js-kernel-groups
  '((core ()
    "\"use strict\";"
    "const FALSE={s:0},TRUE={s:1},NIL={s:2},VOID={s:3},EOFV={s:4};"
    ;; a pair is the tagged object literal {t:"pair",a,d}: single
    ;; inline-slot allocation (a bare array is JSArray + a separate
    ;; elements store, far slower at heap scale), monomorphic walks,
    ;; and .t===\"pair\" answers pair? on any value; vectors stay
    ;; bare JS arrays, so Array.isArray answers vector?
    "class Esc{constructor(p){this.p=p;}}"
    "const PV=(x)=>{if(x?.t!=='pair')throw new TypeError('expected pair');"
    "return x;};"
    "let IO={write_byte:()=>{},read_byte:()=>-1,path_byte:()=>{},"
    "open_read:()=>-1,open_write:()=>-1,fread:()=>-1,fwrite:()=>{},"
    "fclose:()=>{}};"
    ;; raw int -> tagged i31 (the ref.i31 31-bit wrap)
    "const W=(r)=>(((r|0)<<1)<<1)>>1;"
    "const I31=(x)=>{if(typeof x!=='number'||(x|0)!==x)"
    "throw new TypeError('expected i31');return x;};"
    "const IU=(x)=>I31(x)>>1;"
    ;; byte string literal -> Uint8Array
    "const S=(s)=>{const n=s.length,u=new Uint8Array(n);"
    "for(let i=0;i<n;i++)u[i]=s.charCodeAt(i);return u;};"
    "const TD=new TextDecoder(),TE=new TextEncoder();"
    "const U=(s)=>TD.decode(S(s));"
    ;; JS rest array -> Scheme list
    "const L2=(xs)=>{let l=NIL;"
    "for(let i=xs.length-1;i>=0;i--)l={t:\"pair\",a:xs[i],d:l};return l;};"
    "const LD=(xs,tl)=>{let l=tl;"
    "for(let i=xs.length-1;i>=0;i--)l={t:\"pair\",a:xs[i],d:l};return l;};"
    "const IC=(f,xs)=>{if(xs.length<f.length)"
    "throw new TypeError('wrong argument count');return f(...xs);};"
    ;; the trampoline: a non-self tail call returns a TC thunk instead
    ;; of calling (wasm: return_call), and every non-tail call site
    ;; unwinds through TR, so tail chains run in constant JS stack
    "class TC{constructor(f,xs){this.f=f;this.xs=xs;}}"
    "const TCI=(f,xs)=>{if(xs.length<f.length)"
    "throw new TypeError('wrong argument count');return new TC(f,xs);};"
    "const TR=(r)=>{while(r instanceof TC)r=r.f(...r.xs);return r;};"
    "const A2=(f,pre,l)=>{const xs=pre;"
    "for(;l!==NIL;l=l.d)xs.push(l.a);return IC(f,xs);};"
    "const A2T=(f,pre,l)=>{const xs=pre;"
    "for(;l!==NIL;l=l.d)xs.push(l.a);return TCI(f,xs);};"
    "const UNR=()=>{throw new Error('unreachable');};"
    "const THR=(tk,v)=>{throw new Esc({t:\"pair\",a:tk,d:v});};"
    "const KFIX=(x)=>(typeof x==='number'&&!(x&1))?TRUE:FALSE;"
    "const KCHR=(x)=>(typeof x==='number'&&(x&1)===1)?TRUE:FALSE;"
    "const KBOOL=(x)=>(x===TRUE||x===FALSE)?TRUE:FALSE;"
    ;; JS arrays and typed arrays otherwise return undefined or silently
    ;; ignore an out-of-range write instead of trapping like Wasm.
    "const OOB=()=>{throw new RangeError('array element access out of bounds');};"
    "const IX=(a,i)=>{i=IU(i);if(i<0||i>=a.length)OOB();return i;};"
    "const AR=(a,i)=>a[IX(a,i)];"
    "const AW=(a,i,v)=>{a[IX(a,i)]=v;return VOID;};"
    "const STR=(x)=>{if(!(x instanceof Uint8Array))"
    "throw new TypeError('expected string');return x;};"
    "const VEC=(x)=>{if(!Array.isArray(x))"
    "throw new TypeError('expected vector');return x;};")
    (fl (core)
    "class Fl{constructor(v){this.v=v;}}"
    "const FLV=(x)=>{if(!(x instanceof Fl))"
    "throw new TypeError('expected flonum');return x.v;};"
    ;; 16 hex chars (little-endian ieee bytes) -> f64
    "const FB=(h)=>{const dv=new DataView(new ArrayBuffer(8));"
    "for(let i=0;i<8;i++)dv.setUint8(i,parseInt(h.substr(i*2,2),16));"
    "return dv.getFloat64(0,true);};"
    ;; f64 -> i32.trunc_s -> tagged i31.  JavaScript's bitwise coercion
    ;; silently maps NaN/infinity/out-of-range values instead of trapping.
    "const F2I=(x)=>{x=Math.trunc(x);if(!Number.isFinite(x)||"
    "x<-2147483648||x>2147483647)throw new RangeError('integer overflow');"
    "return W(x);};")
    (sym (core)
    "class Sym{constructor(s){this.s=s;}}"
    "const SYMV=(x)=>{if(!(x instanceof Sym))"
    "throw new TypeError('expected symbol');return x;};")
    (bv (core)
    "class BV{constructor(u){this.u=u;}}"
    "const BVU=(x)=>{if(!(x instanceof BV))"
    "throw new TypeError('expected bytevector');return x.u;};")
    (num (core)
    "class Ratio{constructor(n,dd){this.n=n;this.dd=dd;}}"
    "class Cx{constructor(re,im){this.re=re;this.im=im;}}")
    (rec (core)
    "class Rec{constructor(f){this.f=f;}}"
    "const KREC=(x,r)=>(x instanceof Rec&&x.f[0]===r)?TRUE:FALSE;")
    (membuf (core)
    ;; Basic WebAssembly.Memory gives grow its real failure and old-view
    ;; detachment semantics even on hosts without WasmGC.  Hosts with
    ;; no WebAssembly at all (restricted embedded JS environments) get
    ;; a plain-ArrayBuffer stand-in: same buffer/grow surface, growth
    ;; failure still lands as -1 through MGROW's catch; only the
    ;; detachment of old views is beyond a polyfill's reach.
    "const MEMOBJ=(typeof WebAssembly!=='undefined'&&WebAssembly.Memory)"
    "?new WebAssembly.Memory({initial:1})"
    ":(()=>{let b=new ArrayBuffer(65536);return{get buffer(){return b;},"
    "grow(n){const old=b.byteLength/65536;"
    "const nb=new ArrayBuffer((old+(n>>>0))*65536);"
    "new Uint8Array(nb).set(new Uint8Array(b));b=nb;return old;}};})();")
    (mem (membuf fl)
    "let MEMB=MEMOBJ.buffer,MEMV=new DataView(MEMB),MEMU=new Uint8Array(MEMB);"
    "const MREF=()=>{const b=MEMOBJ.buffer;if(b!==MEMB){MEMB=b;"
    "MEMV=new DataView(b);MEMU=new Uint8Array(b);}};"
    ;; typed-array byte access is otherwise silent out of bounds,
    ;; unlike wasm memory loads/stores; the DataView widths already trap
    "const M8P=(p)=>{p=IU(p);if(p<0||p>=MEMB.byteLength)"
    "throw new RangeError('memory access out of bounds');return p;};"
    "const M8R=(p)=>{MREF();return MEMU[M8P(p)]<<1;};"
    "const M8W=(p,v)=>{MREF();MEMU[M8P(p)]=IU(v);return VOID;};"
    "const M32R=(p)=>{MREF();return W(MEMV.getInt32(IU(p),true));};"
    "const M32W=(p,v)=>{MREF();MEMV.setInt32(IU(p),IU(v),true);return VOID;};"
    "const MF32R=(p)=>{MREF();return new Fl(MEMV.getFloat32(IU(p),true));};"
    "const MF32W=(p,v)=>{MREF();MEMV.setFloat32(IU(p),FLV(v),true);return VOID;};"
    "const MF64R=(p)=>{MREF();return new Fl(MEMV.getFloat64(IU(p),true));};"
    "const MF64W=(p,v)=>{MREF();MEMV.setFloat64(IU(p),FLV(v),true);return VOID;};"
    "const MSIZE=()=>W(MEMOBJ.buffer.byteLength/65536);"
    "const MGROW=(n)=>{try{const old=MEMOBJ.grow(n>>>0);MREF();return old;}"
    "catch(_){return -1;}};"
    ;; f32x4 kernels: refresh the views, then snapshot all source
    ;; lanes before the first store, matching v128.load when dst
    ;; partially overlaps a source.
    "const FV=(p)=>[MEMV.getFloat32(p,true),MEMV.getFloat32(p+4,true),"
    "MEMV.getFloat32(p+8,true),MEMV.getFloat32(p+12,true)];"
    "const F4=(op,d,p,q)=>{MREF();const x=FV(p),y=FV(q);"
    "for(let i=0;i<4;i++)MEMV.setFloat32(d+i*4,"
    "op==='+'?x[i]+y[i]:op==='-'?x[i]-y[i]:x[i]*y[i],true);};"
    "const F4SC=(d,p,s)=>{MREF();const sf=Math.fround(s),x=FV(p);"
    "for(let i=0;i<4;i++)MEMV.setFloat32(d+i*4,x[i]*sf,true);};"
    "const F4AX=(d,p,q,s)=>{MREF();const sf=Math.fround(s),x=FV(p),y=FV(q);"
    "for(let i=0;i<4;i++)MEMV.setFloat32(d+i*4,"
    "x[i]+Math.fround(y[i]*sf),true);};"
    "const F4D=(p,q)=>{MREF();const fr=Math.fround;let r=fr(fr(MEMV.getFloat32(p,true)*MEMV.getFloat32(q,true))+fr(MEMV.getFloat32(p+4,true)*MEMV.getFloat32(q+4,true)));"
    "r=fr(r+fr(MEMV.getFloat32(p+8,true)*MEMV.getFloat32(q+8,true)));"
    "r=fr(r+fr(MEMV.getFloat32(p+12,true)*MEMV.getFloat32(q+12,true)));"
    "return r;};")
    (ffi (membuf)
    "class JSRef{constructor(v){this.v=v;}}"
    ;; JS FFI: nameBuf/argStack protocol, implemented natively.  The
    ;; instance global mirrors the wasm host bridge: __goeteia_*
    ;; resolve per-instance, __goeteia_mem is the staging memory,
    ;; eval sees this instance's globalThis
    "const NB=[],CBS=[];let AS=[],STG=[];"
    "const TDX=()=>{const s=TD.decode(new Uint8Array(NB));NB.length=0;"
    "return s;};"
    "const LG=new Map();"
    ;; this target cannot suspend (js-await is the identity), so the
    ;; JSPI probes must answer no: eval'd and js-get'd WebAssembly is
    ;; shimmed with Suspending/promising erased
    "const WASM_SHIM=(typeof WebAssembly!=='undefined')"
    "?new Proxy(WebAssembly,{get:(t,k)=>"
    "(k==='Suspending'||k==='promising')?void 0:Reflect.get(t,k,t)})"
    ":void 0;"
    "const SEV=(c)=>Function('globalThis','WebAssembly','c','return eval(c);')(GPROX,WASM_SHIM,String(c));"
    "const GPROX=new Proxy(globalThis,{"
    "get(t,k){if(k==='eval')return SEV;"
    "if(k==='WebAssembly')return WASM_SHIM;"
    "if(k==='__goeteia_mem')return MEMOBJ;"
    "if(LG.has(k))return LG.get(k);"
    "return Reflect.get(t,k,t);},"
    "set(t,k,v){if(typeof k==='string'&&k.startsWith('__goeteia_'))"
    "{LG.set(k,v);return true;}"
    "return Reflect.set(t,k,v,t);}});"
    "const JGET=(o)=>o[TDX()];"
    "const JSET=(o,v)=>{o[TDX()]=v;};"
    "const JCALL=(f,t)=>{const g=AS;AS=[];"
    "return f.apply(t===GPROX?globalThis:t,g);};"
    "const JNEW=(c)=>{const g=AS;AS=[];return new c(...g);};"
    "const JSL=(s)=>{STG=TE.encode(String(s));return STG.length;};")))

;; the reached groups, dependency-closed, in table order
(define (jkernel-lines)
  (let closure ((gs *jkernels*))
    (let ((more (fold-left
                 (lambda (acc g)
                   (fold-left (lambda (a d) (if (memq d a) a (cons d a)))
                              acc
                              (cadr (assq g $js-kernel-groups))))
                 gs gs)))
      (if (= (length more) (length gs))
          (let emit ((table $js-kernel-groups) (acc '()))
            (if (null? table)
                (reverse acc)
                (emit (cdr table)
                      (if (memq (car (car table)) gs)
                          (cons (cddr (car table)) acc)
                          acc))))
          (closure more)))))

;; glue helpers: emitted only when used, resolving prelude generics
;; by their compiled names
(define (jglue name)
  (cond
   ((string=? name "BNRM")
    (list "const BNRM=(b)=>"
          "(b>=-536870912n&&b<=536870911n)?(Number(b)<<1):b;"))
   ((string=? name "JADD")
    (list "const JADD=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const s=a+b;if(((s<<1)>>1)===s)return s;}return "
          (jgeneric-tr '$add2 "a,b") ";};"))
   ((string=? name "JSUB")
    (list "const JSUB=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const s=a-b;if(((s<<1)>>1)===s)return s;}return "
          (jgeneric-tr '$sub2 "a,b") ";};"))
   ((string=? name "JMUL")
    (list "const JMUL=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const p=(a>>1)*b;if(((p<<1)>>1)===p)return p;}return "
          (jgeneric-tr '$mul2 "a,b") ";};"))
   ((string=? name "JQUO")
    (list "const JQUO=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const d=b>>1;if(d===0)throw new RangeError('divide by zero');"
          "return W(Math.trunc((a>>1)/d));}return "
          (jgeneric-tr '$quot2 "a,b") ";};"))
   ((string=? name "JREM")
    ;; operands stay tagged (2a % 2b = 2(a%b)); renormalize to i31
    ;; like ref.i31, with no extra shift
    (list "const JREM=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{if(b===0)throw new RangeError('divide by zero');"
          "return ((a%b)<<1)>>1;}return " (jgeneric-tr '$rem2 "a,b") ";};"))
   ((string=? name "JEQN")
    (list "const JEQN=(a,b)=>(typeof a==='number'&&typeof b==='number')"
          "?a===b:((" (jgeneric-tr '$eq2 "a,b") ")!==FALSE);"))
   ((string=? name "JLTN")
    (list "const JLTN=(a,b)=>(typeof a==='number'&&typeof b==='number')"
          "?a<b:((" (jgeneric-tr '$lt2 "a,b") ")!==FALSE);"))
   ((string=? name "JZ")
    (list "const JZ=(a)=>typeof a==='number'?a===0:(("
          (jgeneric-tr '$eq2 "a,(0)") ")!==FALSE);"))
   ((string=? name "JFN")
    (list "const JFN=(clo)=>(...args)=>{const fr={args,ret:void 0};"
          "CBS.push(fr);try{" (jgeneric-tr '$jscb "clo") ";}finally{CBS.pop();}"
          "return fr.ret;};"))
   (else (errorf 'goeteia "unknown glue helper ~s" name))))

;;;; ------------------------------------------------------------------
;;;; program assembly

(define (jt-toplevel-fn d idx)
  ;; idx is positional: a redefined name gets a distinct function,
  ;; and call sites assq *fns* where the later entry shadows
  (let* ((name (unmark (def-name d)))
         (formals (cdadr d))
         (rest (formals-rest formals))
         (fixed (formals-fixed formals))
         (fnames (map-in-order (lambda (p) (jfresh!)) fixed)))
    (if rest
        (let* ((rr (jfresh!))
               (rn (jfresh!))
               (env (append (map2* cons fixed fnames)
                            (list (cons rest rn)))))
          (set! *jself* #f)
          (list "const " (jfn-name name idx) "=("
                (jsep "," (append fnames (list (string-append "..." rr))))
                ")=>{const " rn "=L2(" rr ");"
                (jt-body (cddr d) env '()) "};\n"))
        ;; fixed arity: the body rides a labeled loop so a direct
        ;; self tail call rebinds and continues (wasm: return_call)
        (let ((env (map2* cons fixed fnames))
              (label (jlabel!)))
          ;; self tail calls rebind only when this define is the one
          ;; call sites resolve to (a shadowed earlier define is not)
          (set! *jself* (let ((f (assq name *fns*)))
                          (and f (= (cadr f) idx)
                               (list name label fnames))))
          (let ((body (jt-body (cddr d) env '())))
            (set! *jself* #f)
            (list "const " (jfn-name name idx) "=("
                  (jsep "," fnames) ")=>{" label ":for(;;){"
                  body "}};\n"))))))

(define (compile-program-js forms locs)
  (let* ((prep (prepare-program forms locs))
         (export-names (car prep))
         (fn-defs (caddr prep))
         (var-defs (cadddr prep))
         (main-steps (cadr (cdddr prep))))
    (set! *fns* '())
    (set! *vars* '())
    (set! *fn-specs* '())
    (set! *jn* 0)
    (set! *jconsts* '())
    (set! *jconst-n* 0)
    (set! *jhelpers* '())
    (set! *jkernels* '(core))
    ;; the same deterministic numbering the wasm backend uses
    (let number ((ds fn-defs) (i N-IMPORTS))
      (unless (null? ds)
        (let ((formals (cdadr (car ds))))
          (set! *fns* (cons (list (car (cadr (car ds)))
                                  i
                                  (length (formals-fixed formals))
                                  (and (formals-rest formals) #t))
                            *fns*)))
        (number (cdr ds) (+ i 1))))
    (let number ((ds var-defs) (g G-FIRST-VAR))
      (unless (null? ds)
        (set! *vars* (cons (cons (cadr (car ds)) g) *vars*))
        (number (cdr ds) (+ g 1))))
    (jscan-trampolines! fn-defs)
    (let* ((fn-texts (let go ((ds fn-defs) (i N-IMPORTS) (acc '()))
                       (if (null? ds)
                           (reverse acc)
                           (go (cdr ds) (+ i 1)
                               (cons
                                ($with-loc
                                 (let ((l (form-loc (car ds))))
                                   (and l (string-append
                                           l " (" (symbol->string
                                                   (unmark (def-name (car ds))))
                                           ")")))
                                 (lambda () (jt-toplevel-fn (car ds) i)))
                                acc)))))
           (main-text (jt-body (if (null? main-steps) '((begin)) main-steps)
                               '() '()))
           ;; interned constants, in interning order
           (const-texts
            (map-in-order
             (lambda (e)
               ;; e = ((kind . datum) . index)
               (let ((kind (caar e))
                     (datum (cdar e))
                     (i (cdr e)))
                 (when (eq? kind 'sym) (jkernel! 'sym))
                 (list "const C" (jb28 i) "="
                       (if (eq? kind 'str)
                           (list "S(" (jstring-lit datum) ")")
                           (list "new Sym(S("
                                 (jstring-lit (symbol->string datum)) "))"))
                       ";\n")))
             (reverse *jconsts*)))
           ;; the interned-symbol registry: a fresh list per call, in
           ;; interning order, mirroring the wasm registry function
           (rsyms-text
            (list "const RSYMS=()=>("
                  (fold-left (lambda (acc e)
                               (if (eq? (caar e) 'sym)
                                   (list "{t:\"pair\",a:C"
                                         (jb28 (cdr e)) ",d:"
                                         acc "}")
                                   acc))
                             "NIL"
                             *jconsts*)
                  ");\n"))
           (var-decl
            (if (null? *vars*)
                '()
                (list "let "
                      (jsep "," (map-in-order
                                 (lambda (v) (jvar-name (cdr v)))
                                 (reverse *vars*)))
                      ";\n")))
           (glue-texts (map-in-order jglue (reverse *jhelpers*)))
           (export-name-texts
            (map-in-order
             (lambda (n)
               (let ((f (assq n *fns*)))
                 (unless f
                   (errorf 'goeteia "exported name is not a function ~s" n))
                 ;; nothing outside the module unwinds a thunk, so an
                 ;; export that may return one goes out through TR --
                 ;; the rest are handed over directly, keeping their
                 ;; arity visible to the host
                 (list "[U(" (jstring-lit (symbol->string n)) ")]:"
                       (if (jbouncy? n)
                           (list "(...xs)=>TR(" (jfn-name n (cadr f))
                                 "(...xs))")
                           (jfn-name n (cadr f))))))
             export-names)))
      (jbytes
       (list
        (map (lambda (grp)
               (map (lambda (l) (list l "\n")) grp))
             (jkernel-lines))
        var-decl
        fn-texts
        const-texts
        glue-texts
        rsyms-text
        "export const rt={\"false\":FALSE,\"true\":TRUE,\"null\":NIL,"
        "\"void\":VOID,mem:(typeof MEMOBJ!=='undefined'?MEMOBJ:void 0)};\n"
        "export const xports={" (jsep "," export-name-texts) "};\n"
        "export function main(io){if(io)IO=io;"
        "return TR((()=>{" main-text "})());}\n")))))
