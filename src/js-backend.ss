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
;; Known divergences from the wasm target, all confined to corners
;; the test suite pins down as unobservable: argument evaluation
;; order inside a few primitives follows JS left-to-right; deep
;; non-self tail calls consume JS stack (wasm has return_call); a
;; top-level function referenced as a value is one stable JS
;; function, not a fresh closure per reference.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

;;;; ------------------------------------------------------------------
;;;; deterministic text state

(define *jn* 0)                 ; fresh locals v<n> / labels B<n>
(define *jconsts* '())          ; ((kind . datum) . index), newest first
(define *jconst-n* 0)
(define *jhelpers* '())         ; glue helpers actually used, by JS name

(define (jfresh!)
  (set! *jn* (+ *jn* 1))
  (string-append "v" (number->string *jn*)))
(define (jlabel!)
  (set! *jn* (+ *jn* 1))
  (string-append "B" (number->string *jn*)))

(define (jconst! kind datum)
  (let find ((es *jconsts*))
    (cond
     ((null? es)
      (let ((i *jconst-n*))
        (set! *jconst-n* (+ i 1))
        (set! *jconsts* (cons (cons (cons kind datum) i) *jconsts*))
        (string-append "C" (number->string i))))
     ((and (eq? (car (caar es)) kind) (equal? (cdr (caar es)) datum))
      (string-append "C" (number->string (cdar es))))
     (else (find (cdr es))))))

;; a prelude generic helper (e.g. $add2) reached from a primitive's
;; slow path: resolve its emitted name, mirroring generic-call's
;; missing-helper compile error
(define (jgeneric name)
  (let ((f (assq name *fns*)))
    (unless f (errorf 'goeteia "missing generic helper ~s" name))
    (jfn-name name (cadr f))))

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

;; deterministic mangling: keep ASCII alphanumerics, everything else
;; becomes '_'; the numeric index disambiguates collisions
(define (jmangle s)
  (let* ((n (string-length s))
         (out (make-string n)))
    (let loop ((i 0))
      (if (= i n)
          out
          (let ((c (char->integer (string-ref s i))))
            (string-set! out i
                         (if (or (and (<= 48 c) (<= c 57))
                                 (and (<= 65 c) (<= c 90))
                                 (and (<= 97 c) (<= c 122)))
                             (integer->char c)
                             (integer->char 95)))
            (loop (+ i 1)))))))

(define (jfn-name sym idx)
  (string-append "F" (number->string idx) "_"
                 (jmangle (symbol->string sym))))
(define (jvar-name g)
  (string-append "V" (number->string g)))

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
    (reverse acc)))

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
    ;; bignum literal: same 14-bit limb split as the wasm backend
    (let* ((neg (< d 0))
           (mag (if neg (- 0 d) d))
           (limbs (let split ((m mag) (acc '()))
                    (if (and (fits-fixnum? m) (< m 16384))
                        (reverse (cons m acc))
                        (split (quotient m 16384)
                               (cons (remainder m 16384) acc))))))
      (list "(new Bignum(" (if neg "1" "0") ",["
            (jsep "," (map-in-order jtag-int limbs))
            "]))")))
   ((flonum? d) (list "(new Fl(FB(\"" (jflonum-hex d) "\")))"))
   ((and (rational? d) (exact? d))
    (list "(new Ratio(" (jd (numerator d)) "," (jd (denominator d)) "))"))
   ((and (number? d) (not (real? d)))
    (list "(new Cx(" (jd (real-part d)) "," (jd (imag-part d)) "))"))
   ((boolean? d) (if d "TRUE" "FALSE"))
   ((char? d) (jtag-char d))
   ((string? d) (jconst! 'str d))
   ((symbol? d) (jconst! 'sym d))
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
       (list "(()=>{" (without-jself (lambda () (jt e env '()))) "})()"))
      ((begin)
       (if (null? (cdr e))
           "VOID"
           (list "(" (jsep "," (map-in-order
                                (lambda (s) (list "(" (jx s env lctx) ")"))
                                (cdr e)))
                 ")")))
      ((lambda) (jx-lambda (cadr e) (cddr e) env))
      ((set!) (jx-set e env lctx))
      ((apply) (jx-apply e env lctx))
      ((call/cc call-with-current-continuation) (jx-callcc e env lctx))
      (else (jx-app e env lctx))))
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
                          (errorf 'goeteia "unbound variable ~s" e))))))))))

(define (jx-let e env lctx)
  ;; parallel let in expression position: an arrow IIFE; inits
  ;; compile in the outer scope
  (let* ((bs (cadr e))
         (names (map-in-order (lambda (b) (jfresh!)) bs))
         (inits (map-in-order (lambda (b) (jx (cadr b) env lctx)) bs))
         (env2 (append (map2* (lambda (b n) (cons (car b) n)) bs names) env)))
    (list "((" (jsep "," names) ")=>{"
          (without-jself (lambda () (jt-body (cddr e) env2 '())))
          "})(" (jsep "," (map (lambda (i) (list "(" i ")")) inits)) ")")))

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
  (let ((v (assq (unmark (cadr e)) *vars*)))
    (unless v (errorf 'goeteia "set! of unbound variable ~s" (cadr e)))
    (list "((" (jvar-name (cdr v)) "=(" (jx (caddr e) env lctx) ")),VOID)")))

(define (jx-apply e env lctx)
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
      (list "A2((" fc "),[" (jsep "," lead) "],(" fin "))"))))

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
          ";try{return IC((" (jx (cadr e) env lctx) "),[(" x ")=>"
          (jfn-name '$escape (cadr esc)) "(" t "," w "," x ")]);}catch("
          ex "){if(" ex " instanceof Esc&&" ex ".p.a===" t ")return "
          ex ".p.d;throw " ex ";}})()")))

(define (jcall fcode args env lctx)
  (list fcode "("
        (jsep "," (map-in-order (lambda (a) (list "(" (jx a env lctx) ")"))
                                args))
        ")"))

;; Indirect calls carry no compile-time arity proof.  Native JS fills
;; missing parameters with undefined, while the Wasm adapter traps.
(define (jicall fcode args env lctx)
  (list "IC(" fcode ",["
        (jsep "," (map-in-order (lambda (a) (list "(" (jx a env lctx) ")"))
                                 args))
        "])"))

(define (jx-app e env lctx)
  (let* ((op (car e))
         (args (cdr e))
         (rop (and (symbol? op) (unmark op))))
    (cond
     ((and (symbol? op) (assq op env))
      (jicall (list "(" (cdr (assq op env)) ")") args env lctx))
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
        (jcall (jfn-name rop (car entry)) args env lctx)))
     ((and rop (assq rop *vars*))
      (jicall (list "(" (jvar-name (cdr (assq rop *vars*))) ")") args env lctx))
     ((pair? op)
      (jicall (list "(" (jx op env lctx) ")") args env lctx))
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
          ((fl=?) (list "((" (a 0) ".v)===(" (a 1) ".v))"))
          ((fl<?) (list "((" (a 0) ".v)<(" (a 1) ".v))"))
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
        ((quote lambda set! apply call/cc call-with-current-continuation)
         (list "return " (jx e env lctx) ";"))
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
          (else (list "return " (jx e env lctx) ";")))))
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
(define (jp op args trees)
  (define (a i) (list "(" (list-ref trees i) ")"))
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
    ((car) (list "(" (a 0) ".a)"))
    ((cdr) (list "(" (a 0) ".d)"))
    ((set-car!) (list "((" (a 0) ".a=" (a 1) "),VOID)"))
    ((set-cdr!) (list "((" (a 0) ".d=" (a 1) "),VOID)"))
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
    ((fl+) (list "(new Fl(" (a 0) ".v+" (a 1) ".v))"))
    ((fl-) (list "(new Fl(" (a 0) ".v-" (a 1) ".v))"))
    ((fl*) (list "(new Fl(" (a 0) ".v*" (a 1) ".v))"))
    ((fl/) (list "(new Fl(" (a 0) ".v/" (a 1) ".v))"))
    ((fl=?) (list "((" (a 0) ".v===" (a 1) ".v)?TRUE:FALSE)"))
    ((fl<?) (list "((" (a 0) ".v<" (a 1) ".v)?TRUE:FALSE)"))
    ((flsqrt) (list "(new Fl(Math.sqrt(" (a 0) ".v)))"))
    ((flfloor) (list "(new Fl(Math.floor(" (a 0) ".v)))"))
    ((fltruncate) (list "(new Fl(Math.trunc(" (a 0) ".v)))"))
    ((fixnum->flonum) (list "(new Fl(" (a 0) ">>1))"))
    ((%fl->fx) (list "(W(Math.trunc(" (a 0) ".v)|0))"))
    ;; the numeric tower's building blocks
    ((%bignum?) (list "((" (a 0) " instanceof Bignum)?TRUE:FALSE)"))
    ((%make-bignum) (list "(new Bignum(" (a 0) ">>1," (a 1) "))"))
    ((%bignum-sign) (list "(W(" (a 0) ".sg))"))
    ((%bignum-limbs) (list "(" (a 0) ".l)"))
    ((%ratio?) (list "((" (a 0) " instanceof Ratio)?TRUE:FALSE)"))
    ((%make-ratio) (list "(new Ratio(" (a 0) "," (a 1) "))"))
    ((%ratio-num) (list "(" (a 0) ".n)"))
    ((%ratio-den) (list "(" (a 0) ".dd)"))
    ((%complex?) (list "((" (a 0) " instanceof Cx)?TRUE:FALSE)"))
    ((%make-complex) (list "(new Cx(" (a 0) "," (a 1) "))"))
    ((%cx-re) (list "(" (a 0) ".re)"))
    ((%cx-im) (list "(" (a 0) ".im)"))
    ;; chars and strings
    ((char->integer) (list "(" (a 0) "&-2)"))
    ((integer->char) (list "(" (a 0) "|1)"))
    ((string-length) (list "(" (a 0) ".length<<1)"))
    ((string-ref) (list "((AR(" (a 0) "," (a 1) ")<<1)|1)"))
    ((string-set!) (list "AW(" (a 0) "," (a 1) "," (a 2) ">>1)"))
    ((symbol->string) (list "(" (a 0) ".s)"))
    ((%make-string) (list "(new Uint8Array(" (a 0) ">>1))"))
    ((%make-symbol) (list "(new Sym(" (a 0) "))"))
    ((%interned-symbols) "(RSYMS())")
    ;; vectors and bytevectors
    ((vector?) (list "(Array.isArray(" (a 0) ")?TRUE:FALSE)"))
    ((%make-vector)
     (list "(new Array(" (a 0) ">>1).fill(" (a 1) "))"))
    ((vector-length) (list "(" (a 0) ".length<<1)"))
    ((vector-ref) (list "AR(" (a 0) "," (a 1) ")"))
    ((vector-set!) (list "AW(" (a 0) "," (a 1) "," (a 2) ")"))
    ((bytevector?) (list "((" (a 0) " instanceof BV)?TRUE:FALSE)"))
    ((%make-bytevector)
     (list "(new BV(new Uint8Array(" (a 0) ">>1).fill(" (a 1) ">>1)))"))
    ((bytevector-length) (list "(" (a 0) ".u.length<<1)"))
    ((bytevector-u8-ref) (list "(AR(" (a 0) ".u," (a 1) ")<<1)"))
    ((bytevector-u8-set!)
     (list "AW(" (a 0) ".u," (a 1) "," (a 2) ">>1)"))
    ;; fixnum bitwise, straight on the tagged representation
    ((bitwise-and) (list "(" (a 0) "&" (a 1) ")"))
    ((bitwise-ior) (list "(" (a 0) "|" (a 1) ")"))
    ((bitwise-xor) (list "(" (a 0) "^" (a 1) ")"))
    ((bitwise-arithmetic-shift-left)
     ;; (n<<1) << k, renormalized to i31 like ref.i31 does
     (list "(((" (a 0) "<<(" (a 1) ">>1))<<1)>>1)"))
    ((bitwise-arithmetic-shift-right)
     (list "((" (a 0) ">>(" (a 1) ">>1))&-2)"))
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
    ((%write-byte) (list "((IO.write_byte(" (a 0) ">>1)),VOID)"))
    ((%read-byte) "(W(IO.read_byte()))")
    ((%path-byte) (list "((IO.path_byte(" (a 0) ">>1)),VOID)"))
    ((%open-read) "(W(IO.open_read()))")
    ((%open-write) "(W(IO.open_write()))")
    ((%fread) (list "(W(IO.fread(" (a 0) ">>1)))"))
    ((%fwrite) (list "((IO.fwrite(" (a 0) ">>1," (a 1) ">>1)),VOID)"))
    ((%fclose) (list "((IO.fclose(" (a 0) ">>1)),VOID)"))
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
    ((%mem-grow) (list "(W(MGROW(" (a 0) ">>1)))"))
    ;; SIMD as scalar loops; single-rounded per lane, like f32x4
    ((%f32x4-add!)
     (list "(F4('+'," (a 0) ">>1," (a 1) ">>1," (a 2) ">>1),VOID)"))
    ((%f32x4-sub!)
     (list "(F4('-'," (a 0) ">>1," (a 1) ">>1," (a 2) ">>1),VOID)"))
    ((%f32x4-mul!)
     (list "(F4('*'," (a 0) ">>1," (a 1) ">>1," (a 2) ">>1),VOID)"))
    ((%f32x4-scale!)
     (list "(F4SC(" (a 0) ">>1," (a 1) ">>1," (a 2) ".v),VOID)"))
    ((%f32x4-axpy!)
     (list "(F4AX(" (a 0) ">>1," (a 1) ">>1," (a 2) ">>1," (a 3) ".v),VOID)"))
    ((%f32x4-dot)
     (list "(new Fl(F4D(" (a 0) ">>1," (a 1) ">>1)))"))
    ;; JS FFI: the wasm bridge protocol, implemented natively
    ((%js-ref?) (list "((" (a 0) " instanceof JSRef)?TRUE:FALSE)"))
    ((%js-arg-byte) (list "((NB.push(" (a 0) ">>1)),VOID)"))
    ((%js-global) "(new JSRef(GPROX))")
    ((%js-get) (list "(new JSRef(JGET(" (a 0) ".v)))"))
    ((%js-set!) (list "((JSET(" (a 0) ".v," (a 1) ".v)),VOID)"))
    ((%js-push) (list "((AS.push(" (a 0) ".v)),VOID)"))
    ((%js-call) (list "(new JSRef(JCALL(" (a 0) ".v," (a 1) ".v)))"))
    ((%js-new) (list "(new JSRef(JNEW(" (a 0) ".v)))"))
    ((%js-string) "(new JSRef(TDX()))")
    ((%js-str-len) (list "(W(JSL(" (a 0) ".v)))"))
    ((%js-str-byte) (list "(W(STG[" (a 0) ">>1]))"))
    ((%js-number) (list "(new JSRef(" (a 0) ".v))"))
    ((%js-to-number) (list "(new Fl(Number(" (a 0) ".v)))"))
    ((%js-eq) (list "((" (a 0) ".v===" (a 1) ".v)?TRUE:FALSE)"))
    ((%js-bool) (list "((" (a 0) ".v)?TRUE:FALSE)"))
    ((%js-undefined) "(new JSRef(void 0))")
    ((%js-fn) (list "(new JSRef(" (jhelper! "JFN") "(" (a 0) ")))"))
    ((%js-cb-argc) "(W(CBS[CBS.length-1].args.length))")
    ((%js-cb-arg)
     (list "(new JSRef(CBS[CBS.length-1].args[" (a 0) ">>1]))"))
    ((%js-cb-ret)
     (list "((CBS[CBS.length-1].ret=" (a 0) ".v),VOID)"))
    ;; no JSPI on this target: the promise comes back unawaited,
    ;; mirroring the wasm host's no-engine-support fallback
    ((%js-await) (a 0))
    (else (errorf 'goeteia "unhandled primitive ~s" op))))

;;;; ------------------------------------------------------------------
;;;; the runtime kernel

(define $js-kernel
  '("\"use strict\";"
    "const FALSE={s:0},TRUE={s:1},NIL={s:2},VOID={s:3},EOFV={s:4};"
    ;; a pair is the tagged object literal {t:"pair",a,d}: single
    ;; inline-slot allocation (a bare array is JSArray + a separate
    ;; elements store, far slower at heap scale), monomorphic walks,
    ;; and .t===\"pair\" answers pair? on any value; vectors stay
    ;; bare JS arrays, so Array.isArray answers vector?
    "class Fl{constructor(v){this.v=v;}}"
    "class Sym{constructor(s){this.s=s;}}"
    "class BV{constructor(u){this.u=u;}}"
    "class Bignum{constructor(sg,l){this.sg=sg;this.l=l;}}"
    "class Ratio{constructor(n,dd){this.n=n;this.dd=dd;}}"
    "class Cx{constructor(re,im){this.re=re;this.im=im;}}"
    "class Rec{constructor(f){this.f=f;}}"
    "class JSRef{constructor(v){this.v=v;}}"
    "class Esc{constructor(p){this.p=p;}}"
    "let IO={write_byte:()=>{},read_byte:()=>-1,path_byte:()=>{},"
    "open_read:()=>-1,open_write:()=>-1,fread:()=>-1,fwrite:()=>{},"
    "fclose:()=>{}};"
    ;; raw int -> tagged i31 (the ref.i31 31-bit wrap)
    "const W=(r)=>(((r|0)<<1)<<1)>>1;"
    ;; byte string literal -> Uint8Array
    "const S=(s)=>{const n=s.length,u=new Uint8Array(n);"
    "for(let i=0;i<n;i++)u[i]=s.charCodeAt(i);return u;};"
    ;; 16 hex chars (little-endian ieee bytes) -> f64
    "const FB=(h)=>{const dv=new DataView(new ArrayBuffer(8));"
    "for(let i=0;i<8;i++)dv.setUint8(i,parseInt(h.substr(i*2,2),16));"
    "return dv.getFloat64(0,true);};"
    ;; JS rest array -> Scheme list
    "const L2=(xs)=>{let l=NIL;"
    "for(let i=xs.length-1;i>=0;i--)l={t:\"pair\",a:xs[i],d:l};return l;};"
    "const LD=(xs,tl)=>{let l=tl;"
    "for(let i=xs.length-1;i>=0;i--)l={t:\"pair\",a:xs[i],d:l};return l;};"
    ;; checked indirect call / (apply f pre lst).  Function.length is
    ;; exactly the fixed prefix for fixed and rest-argument arrows.
    "const IC=(f,xs)=>{if(xs.length<f.length)"
    "throw new TypeError('wrong argument count');return f(...xs);};"
    "const A2=(f,pre,l)=>{const xs=pre;"
    "for(;l!==NIL;l=l.d)xs.push(l.a);return IC(f,xs);};"
    "const UNR=()=>{throw new Error('unreachable');};"
    "const THR=(tk,v)=>{throw new Esc({t:\"pair\",a:tk,d:v});};"
    "const KFIX=(x)=>(typeof x==='number'&&!(x&1))?TRUE:FALSE;"
    "const KCHR=(x)=>(typeof x==='number'&&(x&1)===1)?TRUE:FALSE;"
    "const KBOOL=(x)=>(x===TRUE||x===FALSE)?TRUE:FALSE;"
    "const KREC=(x,r)=>(x instanceof Rec&&x.f[0]===r)?TRUE:FALSE;"
    ;; JS arrays and typed arrays otherwise return undefined or silently
    ;; ignore an out-of-range write instead of trapping like Wasm.
    "const OOB=()=>{throw new RangeError('array element access out of bounds');};"
    "const IX=(a,i)=>{i>>=1;if(i<0||i>=a.length)OOB();return i;};"
    "const AR=(a,i)=>a[IX(a,i)];"
    "const AW=(a,i,v)=>{a[IX(a,i)]=v;return VOID;};"
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
    "new Uint8Array(nb).set(new Uint8Array(b));b=nb;return old;}};})();"
    "let MEMB=MEMOBJ.buffer,MEMV=new DataView(MEMB),MEMU=new Uint8Array(MEMB);"
    "const MREF=()=>{const b=MEMOBJ.buffer;if(b!==MEMB){MEMB=b;"
    "MEMV=new DataView(b);MEMU=new Uint8Array(b);}};"
    "const M8R=(p)=>{MREF();return MEMU[p>>1]<<1;};"
    "const M8W=(p,v)=>{MREF();MEMU[p>>1]=v>>1;return VOID;};"
    "const M32R=(p)=>{MREF();return W(MEMV.getInt32(p>>1,true));};"
    "const M32W=(p,v)=>{MREF();MEMV.setInt32(p>>1,v>>1,true);return VOID;};"
    "const MF32R=(p)=>{MREF();return new Fl(MEMV.getFloat32(p>>1,true));};"
    "const MF32W=(p,v)=>{MREF();MEMV.setFloat32(p>>1,v.v,true);return VOID;};"
    "const MF64R=(p)=>{MREF();return new Fl(MEMV.getFloat64(p>>1,true));};"
    "const MF64W=(p,v)=>{MREF();MEMV.setFloat64(p>>1,v.v,true);return VOID;};"
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
    "return r;};"
    ;; JS FFI: nameBuf/argStack protocol, implemented natively.  The
    ;; instance global mirrors the wasm host bridge: __goeteia_*
    ;; resolve per-instance, __goeteia_mem is the staging memory,
    ;; eval sees this instance's globalThis
    "const NB=[],CBS=[];let AS=[],STG=[];"
    "const TD=new TextDecoder(),TE=new TextEncoder();"
    "const TDX=()=>{const s=TD.decode(new Uint8Array(NB));NB.length=0;"
    "return s;};"
    "const LG=new Map();"
    "const SEV=(c)=>Function('globalThis','c','return eval(c);')(GPROX,String(c));"
    "const GPROX=new Proxy(globalThis,{"
    "get(t,k){if(k==='eval')return SEV;"
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
    "const JSL=(s)=>{STG=TE.encode(String(s));return STG.length;};"))

;; glue helpers: emitted only when used, resolving prelude generics
;; by their compiled names
(define (jglue name)
  (cond
   ((string=? name "JADD")
    (list "const JADD=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const s=a+b;if(((s<<1)>>1)===s)return s;}return "
          (jgeneric '$add2) "(a,b);};"))
   ((string=? name "JSUB")
    (list "const JSUB=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const s=a-b;if(((s<<1)>>1)===s)return s;}return "
          (jgeneric '$sub2) "(a,b);};"))
   ((string=? name "JMUL")
    (list "const JMUL=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const p=(a>>1)*b;if(((p<<1)>>1)===p)return p;}return "
          (jgeneric '$mul2) "(a,b);};"))
   ((string=? name "JQUO")
    (list "const JQUO=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{const d=b>>1;if(d===0)throw new RangeError('divide by zero');"
          "return W(Math.trunc((a>>1)/d));}return "
          (jgeneric '$quot2) "(a,b);};"))
   ((string=? name "JREM")
    ;; operands stay tagged (2a % 2b = 2(a%b)); renormalize to i31
    ;; like ref.i31, with no extra shift
    (list "const JREM=(a,b)=>{if(typeof a==='number'&&typeof b==='number')"
          "{if(b===0)throw new RangeError('divide by zero');"
          "return ((a%b)<<1)>>1;}return " (jgeneric '$rem2) "(a,b);};"))
   ((string=? name "JEQN")
    (list "const JEQN=(a,b)=>(typeof a==='number'&&typeof b==='number')"
          "?a===b:(" (jgeneric '$eq2) "(a,b)!==FALSE);"))
   ((string=? name "JLTN")
    (list "const JLTN=(a,b)=>(typeof a==='number'&&typeof b==='number')"
          "?a<b:(" (jgeneric '$lt2) "(a,b)!==FALSE);"))
   ((string=? name "JZ")
    (list "const JZ=(a)=>typeof a==='number'?a===0:("
          (jgeneric '$eq2) "(a,(0))!==FALSE);"))
   ((string=? name "JFN")
    (list "const JFN=(clo)=>(...args)=>{const fr={args,ret:void 0};"
          "CBS.push(fr);try{" (jgeneric '$jscb) "(clo);}finally{CBS.pop();}"
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
                 (list "const C" (number->string i) "="
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
                                         (number->string (cdr e)) ",d:"
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
                 (list (jstring-lit (symbol->string n)) ":"
                       (jfn-name n (cadr f)))))
             export-names)))
      (jbytes
       (list
        (map (lambda (l) (list l "\n")) $js-kernel)
        var-decl
        fn-texts
        const-texts
        glue-texts
        rsyms-text
        "export const rt={\"false\":FALSE,\"true\":TRUE,\"null\":NIL,"
        "\"void\":VOID,mem:MEMOBJ};\n"
        "export const xports={" (jsep "," export-name-texts) "};\n"
        "export function main(io){if(io)IO=io;" main-text "}\n")))))
