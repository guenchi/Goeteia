;; goeteia — a Scheme to WebAssembly-GC compiler.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
;;
;; Milestone 3: strings (GC byte arrays), interned symbols,
;; characters, type predicates, and I/O through a single host import
;; (io.write_byte).  The runtime library (display, string=?, ...) is
;; written in goeteia's own Scheme (src/prelude.ss) and compiled into
;; every module.
;;
;; A program is a sequence of top-level defines and expressions; the
;; expressions run in order and the last one's value is the result,
;; exported as `main`.

;; The compiler is written in the subset of Scheme that goeteia
;; itself compiles, so it can compile itself.  Under the Chez host,
;; src/chez-driver.ss loads this file; under the self-hosted build,
;; src/wasm-driver.ss is appended and the whole thing is compiled to
;; wasm.

;;;; ------------------------------------------------------------------
;;;; portable helpers (goeteia has these in the prelude; the names
;;;; below avoid clashing with Chez builtins)

(define (nums-below n)
  (let loop ((i 0))
    (if (= i n) '() (cons i (loop (+ i 1))))))
(define (repeat-n n x)
  (if (zero? n) '() (cons x (repeat-n (- n 1) x))))
(define (first-n ls n)
  (if (zero? n) '() (cons (car ls) (first-n (cdr ls) (- n 1)))))
(define (all-true? f ls)
  (or (null? ls) (and (f (car ls)) (all-true? f (cdr ls)))))
(define (map2* f l1 l2)
  ;; explicitly sequenced left-to-right: f may carry transformer side
  ;; effects, and the hosts disagree on argument evaluation order
  (if (null? l1)
      '()
      (let* ((h (f (car l1) (car l2)))
             (t (map2* f (cdr l1) (cdr l2))))
        (cons h t))))
;; stable ascending insertion sort keyed by a numeric projection
(define (sort-by key ls)
  (if (null? ls)
      '()
      (insert-by key (car ls) (sort-by key (cdr ls)))))
(define (insert-by key x ls)
  (cond
   ((null? ls) (list x))
   ((< (key x) (key (car ls))) (cons x ls))
   (else (cons (car ls) (insert-by key x (cdr ls))))))
(define (self-id x) x)
;; R6RS map may process elements in any order; codegen effects
;; (function indices, interned literals) need source order
(define (map-in-order f ls)
  (let loop ((ls ls) (acc '()))
    (if (null? ls)
        (reverse acc)
        (loop (cdr ls) (cons (f (car ls)) acc)))))

;;;; ------------------------------------------------------------------
;;;; byte trees

(define (flatten tree)
  ;; iterative with an explicit worklist: byte trees have spines far
  ;; deeper than the wasm call stack allows
  (let walk ((stack (cons tree '())) (acc '()))
    (cond
     ((null? stack) (reverse acc))
     ((null? (car stack)) (walk (cdr stack) acc))
     ((pair? (car stack))
      (walk (cons (car (car stack))
                  (cons (cdr (car stack)) (cdr stack)))
            acc))
     (else (walk (cdr stack) (cons (car stack) acc))))))

(define (uleb n)
  (let ((lo (bitwise-and n #x7f))
        (hi (bitwise-arithmetic-shift-right n 7)))
    (if (zero? hi)
        (list lo)
        (cons (bitwise-ior lo #x80) (uleb hi)))))

(define (sleb n)
  (let ((lo (bitwise-and n #x7f))
        (hi (bitwise-arithmetic-shift-right n 7)))
    (if (if (zero? (bitwise-and lo #x40))
            (zero? hi)
            (= hi -1))
        (list lo)
        (cons (bitwise-ior lo #x80) (sleb hi)))))

(define (counted items)
  (cons (uleb (length items)) items))

(define (sized tree)
  (let ((flat (flatten tree)))
    (list (uleb (length flat)) flat)))

(define (section id tree)
  (list id (sized tree)))

;;;; ------------------------------------------------------------------
;;;; value representation
;;;;
;;;; The universal Scheme value type is eqref.  Fixnums and characters
;;;; share i31ref with a one-bit tag: fixnum n is (n << 1), character
;;;; c is (c << 1) | 1.  That keeps both unboxed and eq?-comparable
;;;; and leaves 30-bit fixnums.  Everything else is a GC struct or
;;;; array.

(define T-EQREF #x6D)
(define T-I31 #x6C)
(define T-I32 #x7F)
(define T-I8 #x78)
(define T-FUNCREF #x70)

;; fixed type-table prefix
;;
;; Every closure struct carries two entry points: a fast arity-typed
;; one (field 0, used when the argument count matches statically) and
;; a generic one taking the arguments as a list (field 1, type $fnG,
;; used by apply, by variadic procedures, and when arities differ).
;; Fixed-arity closures share one generic adapter per arity that
;; unpacks the list and forwards to the fast entry.
(define TY-PAIR 0)          ; (struct (mut eqref) (mut eqref))
(define TY-SINGLETON 1)     ; (struct i32)
(define TY-STRING 2)        ; (array (mut i8))
(define TY-SYMBOL 3)        ; (struct (ref $string))
(define TY-FNG 4)           ; (func (ref $closbase) eqref -> eqref)
(define TY-CLOSBASE 5)      ; open (struct funcref (ref $fnG))
(define TY-CLOSV 6)         ; variadic closures: base + env field
(define TY-IOFN 7)          ; (func (param i32))
(define TY-IOIN 8)          ; (func (result i32))
(define TY-KTAG 9)          ; (func (param eqref)) -- the escape tag
(define TY-VECTOR 10)       ; (array (mut eqref))
(define TY-BV 11)           ; bytevector: (struct (mut (ref $string)))
(define TY-RECBASE 12)      ; open (struct (field eqref)) -- the rtd slot
(define TY-FLONUM 13)       ; (struct (field f64))
(define TY-BIGNUM 14)       ; (struct (field i32 sign) (field (ref $vector)))
(define TY-RATIO 15)        ; (struct (field eqref num) (field eqref den))
(define TY-COMPLEX 16)      ; (struct (field eqref re) (field eqref im))
(define TY-IOIN1 17)        ; (func (param i32) (result i32))
(define TY-IOOUT2 18)       ; (func (param i32 i32))
;; the JS bridge: host references wrapped in a struct so they live in
;; the eqref world
(define TY-JSREF 19)        ; (struct (field externref))
(define TY-JEXT0 20)        ; (func (result externref))
(define TY-JEXT1 21)        ; (func (param externref) (result externref))
(define TY-JEXT2 22)        ; (func (param externref externref) (result externref))
(define TY-JSET2 23)        ; (func (param externref externref))
(define TY-JPUSH 24)        ; (func (param externref))
(define TY-JNUM 25)         ; (func (param f64) (result externref))
(define TY-JTONUM 26)       ; (func (param externref) (result f64))
(define TY-JI32 27)         ; (func (param externref) (result i32))
(define TY-JEQ 28)          ; (func (param externref externref) (result i32))
(define TY-JFN 29)          ; (func (param eqref) (result externref))
(define TY-JARG 30)         ; (func (param i32) (result externref))
(define TY-FIRST-FREE 31)

;; imported functions come first in the function index space
(define FN-WRITE-BYTE 0)
(define FN-READ-BYTE 1)
(define FN-PATH-BYTE 2)     ; push a path byte to the host
(define FN-OPEN-READ 3)     ; open accumulated path; fd or -1
(define FN-OPEN-WRITE 4)
(define FN-FREAD 5)         ; (fd) -> byte or -1
(define FN-FWRITE 6)        ; (fd byte)
(define FN-FCLOSE 7)
;; the js.* bridge
(define FN-JS-ARG-BYTE 8)   ; push a name/string byte
(define FN-JS-GLOBAL 9)
(define FN-JS-GET 10)       ; property name from pushed bytes
(define FN-JS-SET 11)
(define FN-JS-PUSH 12)      ; push a call argument
(define FN-JS-CALL 13)      ; (fn this) with pushed args
(define FN-JS-NEW 14)       ; constructor call with pushed args
(define FN-JS-STRING 15)    ; JS string from pushed bytes
(define FN-JS-STR-LEN 16)   ; stage a JS string, get its length
(define FN-JS-STR-BYTE 17)  ; read a byte of the staged string
(define FN-JS-NUMBER 18)
(define FN-JS-TO-NUMBER 19)
(define FN-JS-EQ 20)
(define FN-JS-BOOL 21)
(define FN-JS-UNDEFINED 22)
(define FN-JS-FN 23)        ; wrap a Scheme closure as a JS function
(define FN-JS-CB-ARGC 24)   ; callback arguments, host side
(define FN-JS-CB-ARG 25)
(define FN-JS-CB-RET 26)    ; callback return value, Scheme -> host
(define FN-JS-AWAIT 27)     ; suspend on a promise (JSPI); identity without it
(define N-IMPORTS 28)

;; singleton globals, in index order
(define G-FALSE 0)
(define G-TRUE 1)
(define G-NULL 2)
(define G-VOID 3)
(define G-EOF 4)
(define G-FIRST-VAR 5)

;;;; ------------------------------------------------------------------
;;;; instruction emitters

(define (global-get g) (list #x23 (uleb g)))
(define (global-set g) (list #x24 (uleb g)))
(define (local-get i) (list #x20 (uleb i)))
(define (local-set i) (list #x21 (uleb i)))
(define OP-DROP #x1A)
(define OP-REF-EQ #xD3)
(define OP-I32-EQZ #x45)

(define (gc-op . bytes) (cons #xFB bytes))
(define (i32const n) (list #x41 (sleb n)))
;; sleb of n*2 (+1 for chars) computed without forming the doubled
;; value: tagged literals near the fixnum limit would overflow it
(define (sleb-shifted n odd)
  (let ((lo (+ (* (bitwise-and n #x3f) 2) odd))
        (hi (bitwise-arithmetic-shift-right n 6)))
    (if (if (zero? (bitwise-and lo #x40)) (zero? hi) (= hi -1))
        (list lo)
        (cons (bitwise-ior lo #x80) (sleb hi)))))
(define (emit-fixnum n)
  (list #x41 (sleb-shifted n 0) (gc-op #x1C)))     ; ref.i31
(define (emit-char c)
  (list #x41 (sleb-shifted (char->integer c) 1) (gc-op #x1C)))
;; eqref -> raw tagged i32
(define (untag)
  (list (gc-op #x16 T-I31) (gc-op #x1D)))          ; ref.cast i31; i31.get_s
;; eqref fixnum -> machine integer
(define (unwrap-int)
  (list (untag) (i32const 1) #x75))                ; i32.shr_s
;; machine integer -> eqref fixnum
(define (wrap-int)
  (list (i32const 1) #x74 (gc-op #x1C)))           ; i32.shl; ref.i31
(define (ref-cast ty) (gc-op #x16 (sleb ty)))
(define (unwrap-fl)
  (list (gc-op #x16 (sleb TY-FLONUM)) (gc-op #x02 (uleb TY-FLONUM) (uleb 0))))
(define (unwrap-js)
  (list (gc-op #x16 (sleb TY-JSREF)) (gc-op #x02 (uleb TY-JSREF) (uleb 0))))
(define (ref-test ty) (gc-op #x14 (sleb ty)))
(define (struct-get ty i) (gc-op #x02 (uleb ty) (uleb i)))
(define (struct-set ty i) (gc-op #x05 (uleb ty) (uleb i)))
(define (struct-new ty) (gc-op #x00 (uleb ty)))
(define (ref-func idx) (list #xD2 (uleb idx)))

;; i32 on the stack -> Scheme boolean
(define (boolify)
  (list #x04 T-EQREF (global-get G-TRUE) #x05 (global-get G-FALSE) #x0B))

;; Scheme value on the stack -> i32 truth flag
(define (truthy)
  (list (global-get G-FALSE) OP-REF-EQ OP-I32-EQZ))

;;;; ------------------------------------------------------------------
;;;; hygiene
;;;;
;;;; Identifiers a macro template introduces are renamed to fresh
;;;; gensyms, one per identifier per expansion.  *marks* maps each
;;;; gensym back to the identifier it renamed; resolution everywhere
;;;; (keyword recognition, variable lookup, literal matching) falls
;;;; back through the table, and quote/syntax->datum strip it.
;;;; Binding forms bind the gensym itself, so introduced bindings
;;;; can't capture user code and vice versa.

(define *marks* '())      ; fresh -> original
(define *renames* '())    ; original -> fresh, per macro application
(define *macros* '())     ; name -> transformer meta-value

(define (marked-origin s)
  (let ((e (assq s *marks*)))
    (and e (cdr e))))
(define (unmark s)
  (let ((o (marked-origin s)))
    (if o (unmark o) s)))
(define (resolve-tag x)
  (if (symbol? x) (unmark x) x))
(define (strip-marks x)
  (cond
   ((symbol? x) (unmark x))
   ((pair? x) (cons (strip-marks (car x)) (strip-marks (cdr x))))
   (else x)))
(define (rename-introduced s)
  (let ((e (assq s *renames*)))
    (if e
        (cdr e)
        (let ((f (gensym (symbol->string (unmark s)))))
          (set! *marks* (cons (cons f s) *marks*))
          (set! *renames* (cons (cons s f) *renames*))
          f))))

;;;; ------------------------------------------------------------------
;;;; the expander: derived forms and user macros.  Core forms after
;;;; expansion: quote if let begin lambda set! define, plus
;;;; applications.

(define (xpand e)
  (if (pair? e)
      (let ((macro (let ((tag (resolve-tag (car e))))
                     (and (symbol? tag)
                          (not (eq? tag 'quote))
                          (not (eq? tag 'define-syntax))
                          (assq tag *macros*)))))
        (if macro
            (xpand (apply-macro (cdr macro) e))
            (xpand-core e)))
      e))

(define (xpand-core e)
  (case (resolve-tag (car e))
        ((quote define-syntax) e)
        ((lambda) `(lambda ,(cadr e) . ,(xpand* (cddr e))))
        ((and)
         (cond
          ((null? (cdr e)) #t)
          ((null? (cddr e)) (xpand (cadr e)))
          (else `(if ,(xpand (cadr e)) ,(xpand `(and . ,(cddr e))) #f))))
        ((or)
         (cond
          ((null? (cdr e)) #f)
          ((null? (cddr e)) (xpand (cadr e)))
          (else
           (let ((t (gensym "t")))
             `(let ((,t ,(xpand (cadr e))))
                (if ,t ,t ,(xpand `(or . ,(cddr e)))))))))
        ((not) `(if ,(xpand (cadr e)) #f #t))
        ((when) (xpand `(if ,(cadr e) (begin . ,(cddr e)) (begin))))
        ((unless) (xpand `(if ,(cadr e) (begin) (begin . ,(cddr e)))))
        ((cond) (xpand-cond (cdr e)))
        ((let*)
         (let ((bs (cadr e)))
           (if (null? bs)
               (xpand `(begin . ,(cddr e)))
               (xpand `(let (,(car bs)) (let* ,(cdr bs) . ,(cddr e)))))))
        ((let)
         (if (symbol? (cadr e))
             ;; a named let whose name only ever recurs as a
             ;; correct-arity tail call lowers to %loop -- a wasm
             ;; loop block, no closure, no call per iteration.
             ;; Anything else keeps the letrec spelling
             (let* ((name (cadr e)) (bs (caddr e))
                    (params (map car bs))
                    (xinits (map-in-order (lambda (b) (xpand (cadr b)))
                                          bs))
                    (xbody (xpand* (cdddr e))))
               (if (loop-ok? name (length params) params xbody)
                   `(%loop ,name ,params ,xinits . ,xbody)
                   `((let ((,name (begin)))
                       (set! ,name (lambda ,params . ,xbody))
                       ,name)
                     . ,xinits)))
             `(let ,(map (lambda (b) (list (car b) (xpand (cadr b))))
                         (cadr e))
                . ,(xpand* (cddr e)))))
        ((letrec letrec*)
         (let ((bs (cadr e)))
           (xpand `(let ,(map (lambda (b) `(,(car b) (begin))) bs)
                     ,@(map (lambda (b) `(set! ,(car b) ,(cadr b))) bs)
                     . ,(cddr e)))))
        ((do)
         (let ((bs (cadr e)) (tc (caddr e)) (cmds (cdddr e))
               (loop (gensym "loop")))
           (xpand
            `(let ,loop ,(map (lambda (b) (list (car b) (cadr b))) bs)
               (if ,(car tc)
                   (begin . ,(if (null? (cdr tc)) '((begin)) (cdr tc)))
                   (begin ,@cmds
                          (,loop . ,(map (lambda (b)
                                           (if (pair? (cddr b))
                                               (caddr b)
                                               (car b)))
                                         bs))))))))
        ((quasiquote) (xpand-qq (cadr e) 0))
        ((define-record-type) (xpand-record e))
        ((import) '(begin))            ; resolved by the driver
        ((export) e)                   ; top-level export declaration
        ((library)
         ;; (library (name ...) (export ...) (import ...) body ...)
         ;; libraries splice their definitions positionally: the
         ;; header export list is advisory (dead code elimination
         ;; prunes what goes unused), the driver has already inlined
         ;; the imports, and a mid-body (export ...) survives as a
         ;; top-level export declaration
         (cons 'begin (xpand* (cdr (cdddr e)))))
        ((case)
         ;; (case E ((d ...) body ...) ... (else body ...))
         (let ((t (gensym "t")))
           (xpand
            (list 'let (list (list t (cadr e)))
                  (build-case t (cddr e))))))
        (else (xpand* e))))
;; (define-record-type <spec> (fields <field> ...)) with
;; <spec> = name | (name constructor predicate) and
;; <field> = name | (immutable name [acc]) | (mutable name [acc [mut]]).
;; Records are structs with an identity slot: the rtd is a fresh
;; pair, the predicate is a subtype test plus rtd comparison.
(define (sym-cat parts)
  (string->symbol
   (fold-left string-append ""
              (map (lambda (x)
                     (if (symbol? x) (symbol->string (unmark x)) x))
                   parts))))
(define (xpand-record e)
  (let* ((spec (cadr e))
         (name (if (pair? spec) (car spec) spec))
         (ctor (if (pair? spec) (cadr spec) (sym-cat (list "make-" name))))
         (pred (if (pair? spec) (caddr spec) (sym-cat (list name "?"))))
         (fspecs (let find ((cs (cddr e)))
                   (cond
                    ((null? cs) '())
                    ((eq? (resolve-tag (car (car cs))) 'fields) (cdr (car cs)))
                    (else (find (cdr cs))))))
         ;; each field -> (name mutable? accessor mutator)
         (fields (map (lambda (fs) (parse-field fs name)) fspecs))
         (nf (length fields))
         (rtd (gensym "rtd"))
         (fnames (map car fields)))
    (cons 'begin
          (map xpand
               (cons `(define ,rtd (cons ',(unmark name) '()))
                     (cons `(define (,ctor . ,fnames)
                              (%record ,rtd . ,fnames))
                           (cons `(define (,pred x) (%record? x ,rtd))
                                 (let accs ((fs fields) (i 0))
                                   (if (null? fs)
                                       '()
                                       (let ((f (car fs)))
                                         (cons
                                          `(define (,(caddr f) r)
                                             (%record-ref r ,nf ,i))
                                          (append
                                           (if (cadr f)
                                               (list
                                                `(define (,(cadddr f) r v)
                                                   (%record-set! r ,nf ,i v)))
                                               '())
                                           (accs (cdr fs) (+ i 1))))))))))))))
(define (parse-field fs rec-name)
  (cond
   ((symbol? fs)
    (list fs #f (sym-cat (list rec-name "-" fs)) #f))
   ((eq? (resolve-tag (car fs)) 'immutable)
    (let ((f (cadr fs)))
      (list f #f
            (if (pair? (cddr fs))
                (caddr fs)
                (sym-cat (list rec-name "-" f)))
            #f)))
   ((eq? (resolve-tag (car fs)) 'mutable)
    (let ((f (cadr fs)))
      (list f #t
            (if (pair? (cddr fs))
                (caddr fs)
                (sym-cat (list rec-name "-" f)))
            (if (and (pair? (cddr fs)) (pair? (cdddr fs)))
                (cadddr fs)
                (sym-cat (list rec-name "-" f "-set!"))))))
   (else (errorf 'goeteia "bad field spec ~s" fs))))

;; case compiles to eq? chains; fixnums, characters, symbols and
;; booleans are all eq-comparable in goeteia
(define (build-case t clauses)
  (if (null? clauses)
      '(begin)
      (let ((c (car clauses)))
        (if (eq? (resolve-tag (car c)) 'else)
            (cons 'begin (cdr c))
            (list 'if
                  (cons 'or (map (lambda (d) (list 'eq? t (list 'quote d)))
                                 (car c)))
                  (cons 'begin (cdr c))
                  (build-case t (cdr clauses)))))))
;; quasiquote, with unquote-splicing via append
(define (xpand-qq t level)
  (cond
   ((pair? t)
    (let ((tag (resolve-tag (car t))))
      (cond
       ((and (eq? tag 'unquote) (pair? (cdr t)) (null? (cddr t)))
        (if (= level 0)
            (xpand (cadr t))
            (list 'cons ''unquote
                  (xpand-qq (cdr t) (- level 1)))))
       ((and (eq? tag 'quasiquote) (pair? (cdr t)) (null? (cddr t)))
        (list 'cons ''quasiquote
              (xpand-qq (cdr t) (+ level 1))))
       ((and (= level 0)
             (pair? (car t))
             (eq? (resolve-tag (caar t)) 'unquote-splicing)
             (pair? (cdar t)))
        (list 'append (xpand (cadr (car t)))
              (xpand-qq (cdr t) level)))
       (else
        (list 'cons (xpand-qq (car t) level)
              (xpand-qq (cdr t) level))))))
   (else (list 'quote t))))
(define (xpand* es)
  (if (pair? es)
      (cons (xpand (car es)) (xpand* (cdr es)))
      es))
(define (xpand-cond clauses)
  (if (null? clauses)
      '(begin)
      (let ((c (car clauses)))
        (cond
         ((eq? (resolve-tag (car c)) 'else) (xpand `(begin . ,(cdr c))))
         ((null? (cdr c))
          (let ((t (gensym "t")))
            `(let ((,t ,(xpand (car c))))
               (if ,t ,t ,(xpand-cond (cdr clauses))))))
         (else `(if ,(xpand (car c))
                    ,(xpand `(begin . ,(cdr c)))
                    ,(xpand-cond (cdr clauses))))))))

;;;; ------------------------------------------------------------------
;;;; macro transformers
;;;;
;;;; define-syntax accepts syntax-rules or a (lambda (x) ...) using
;;;; syntax-case.  Since the compiled program can't run at compile
;;;; time, transformers execute in a small interpreter over a Scheme
;;;; subset.  Syntax objects are plain s-expressions.

(define mv-closure (list 'mv-closure))  ; unique tag objects
(define mv-prim (list 'mv-prim))
(define mv-pvar (list 'mv-pvar))
(define (mv? tag v) (and (pair? v) (eq? (car v) tag)))
(define (make-pvar level value) (cons mv-pvar (cons level value)))
(define (pvar-level v) (cadr v))
(define (pvar-value v) (cddr v))

(define meta-prims
  '(car cdr caar cadr cdar cddr caddr cdddr cadddr cons list append
    reverse length list-ref list-tail memq member assq assoc
    pair? null? symbol? identifier? string? number? boolean? char?
    procedure? not eq? eqv? equal? zero? + - * quotient remainder
    < > <= >= = max map error gensym string->symbol symbol->string
    string-append string=? string-length substring
    free-identifier=? bound-identifier=?
    syntax->datum datum->syntax generate-temporaries void))
(define (base-meta-env)
  (map (lambda (n) (cons n (cons mv-prim n))) meta-prims))

(define (make-transformer spec)
  (let ((v (meta-eval spec (base-meta-env))))
    (unless (mv? mv-closure v)
      (errorf 'goeteia "transformer is not a procedure: ~s" spec))
    v))
(define (macro-def? f)
  (and (pair? f) (symbol? (car f)) (eq? (unmark (car f)) 'define-syntax)))
(define (add-macro! f)
  (set! *macros* (cons (cons (unmark (cadr f)) (make-transformer (caddr f)))
                       *macros*)))
(define (apply-macro tf form)
  ;; each application gets a fresh rename table; that is what keeps
  ;; separate expansions of the same macro hygienic
  (let ((saved *renames*))
    (set! *renames* '())
    (let ((out (meta-apply tf (list form))))
      (set! *renames* saved)
      out)))

(define (meta-eval e env)
  (cond
   ((symbol? e) (meta-ref e env))
   ((pair? e)
    (let ((tag (resolve-tag (car e))))
      (case tag
        ((quote) (strip-marks (cadr e)))
        ((syntax) (transcribe (cadr e) env #f))
        ((quasiquote) (meta-qq (cadr e) env 0))
        ((if)
         (if (not (eq? (meta-eval (cadr e) env) #f))
             (meta-eval (caddr e) env)
             (if (pair? (cdddr e)) (meta-eval (cadddr e) env) (void))))
        ((and) (meta-and (cdr e) env))
        ((or) (meta-or (cdr e) env))
        ((when)
         (if (not (eq? (meta-eval (cadr e) env) #f))
             (meta-seq (cddr e) env)
             (void)))
        ((unless)
         (if (eq? (meta-eval (cadr e) env) #f)
             (meta-seq (cddr e) env)
             (void)))
        ((cond) (meta-clauses (cdr e) env))
        ((let)
         (meta-seq (cddr e)
                   (append (map (lambda (b)
                                  (cons (car b) (meta-eval (cadr b) env)))
                                (cadr e))
                           env)))
        ((let*) (meta-let* (cadr e) (cddr e) env))
        ((letrec letrec*)
         (let* ((slots (map (lambda (b) (cons (car b) #f)) (cadr e)))
                (env (append slots env)))
           (let fill ((ss slots) (bs (cadr e)))
             (unless (null? ss)
               (set-cdr! (car ss) (meta-eval (cadr (car bs)) env))
               (fill (cdr ss) (cdr bs))))
           (meta-seq (cddr e) env)))
        ((lambda) (list mv-closure (cadr e) (cddr e) env))
        ((begin) (meta-seq (cdr e) env))
        ((set!)
         (let ((slot (assq (cadr e) env)))
           (unless slot
             (errorf 'goeteia "set! of unbound ~s in transformer" (cadr e)))
           (set-cdr! slot (meta-eval (caddr e) env))
           (void)))
        ((syntax-case) (meta-syntax-case e env))
        ((with-syntax) (meta-with-syntax e env))
        ((syntax-rules) (meta-eval (desugar-rules e) env))
        (else (meta-apply (meta-eval (car e) env)
                          (map (lambda (a) (meta-eval a env)) (cdr e)))))))
   (else e)))

(define (meta-ref name env)
  (let ((slot (assq name env)))
    (if slot
        (let ((v (cdr slot)))
          (if (mv? mv-pvar v)
              (if (zero? (pvar-level v))
                  (pvar-value v)
                  (errorf 'goeteia "pattern variable ~s at wrong depth" name))
              v))
        (let ((o (marked-origin name)))
          (if o
              (meta-ref o env)
              (errorf 'goeteia "unbound ~s in transformer" name))))))
(define (meta-seq es env)
  (cond
   ((null? es) (void))
   ((null? (cdr es)) (meta-eval (car es) env))
   (else (meta-eval (car es) env) (meta-seq (cdr es) env))))
(define (meta-and es env)
  (cond
   ((null? es) #t)
   ((null? (cdr es)) (meta-eval (car es) env))
   ((eq? (meta-eval (car es) env) #f) #f)
   (else (meta-and (cdr es) env))))
(define (meta-or es env)
  (if (null? es)
      #f
      (let ((v (meta-eval (car es) env)))
        (if (eq? v #f) (meta-or (cdr es) env) v))))
(define (meta-clauses clauses env)
  (if (null? clauses)
      (void)
      (let ((c (car clauses)))
        (if (eq? (resolve-tag (car c)) 'else)
            (meta-seq (cdr c) env)
            (let ((t (meta-eval (car c) env)))
              (cond
               ((eq? t #f) (meta-clauses (cdr clauses) env))
               ((null? (cdr c)) t)
               (else (meta-seq (cdr c) env))))))))
(define (meta-let* bs body env)
  (if (null? bs)
      (meta-seq body env)
      (meta-let* (cdr bs) body
                 (cons (cons (caar bs) (meta-eval (cadar bs) env)) env))))
(define (meta-qq t env level)
  (if (pair? t)
      (let ((tag (resolve-tag (car t))))
        (cond
         ((and (eq? tag 'unquote) (pair? (cdr t)) (null? (cddr t)))
          (if (zero? level)
              (meta-eval (cadr t) env)
              (list 'unquote (meta-qq (cadr t) env (- level 1)))))
         ((and (eq? tag 'quasiquote) (pair? (cdr t)) (null? (cddr t)))
          (list 'quasiquote (meta-qq (cadr t) env (+ level 1))))
         (else (cons (meta-qq (car t) env level)
                     (meta-qq (cdr t) env level)))))
      t))

(define (meta-apply f args)
  (cond
   ((mv? mv-closure f)
    (let* ((params (cadr f))
           (body (caddr f))
           (cenv (cadddr f))
           (rest (formals-rest params)))
      (let bind ((ps (formals-fixed params)) (as args) (env cenv))
        (cond
         ((pair? ps)
          (unless (pair? as)
            (errorf 'goeteia "too few arguments in transformer call"))
          (bind (cdr ps) (cdr as) (cons (cons (car ps) (car as)) env)))
         (rest (meta-seq body (cons (cons rest as) env)))
         ((null? as) (meta-seq body env))
         (else (errorf 'goeteia "too many arguments in transformer call"))))))
   ((mv? mv-prim f) (meta-prim-apply (cdr f) args))
   (else (errorf 'goeteia "transformer applied a non-procedure"))))

(define (meta-prim-apply name args)
  (define (a) (car args))
  (define (b) (cadr args))
  (case name
    ((car) (car (a))) ((cdr) (cdr (a)))
    ((caar) (caar (a))) ((cadr) (cadr (a)))
    ((cdar) (cdar (a))) ((cddr) (cddr (a)))
    ((caddr) (caddr (a))) ((cdddr) (cdddr (a))) ((cadddr) (cadddr (a)))
    ((cons) (cons (a) (b)))
    ((list) args)
    ((append) (if (null? args) '() (append (a) (if (pair? (cdr args)) (b) '()))))
    ((reverse) (reverse (a)))
    ((length) (length (a)))
    ((list-ref) (list-ref (a) (b)))
    ((list-tail) (list-tail (a) (b)))
    ((memq) (memq (a) (b))) ((member) (member (a) (b)))
    ((assq) (assq (a) (b))) ((assoc) (assoc (a) (b)))
    ((pair?) (pair? (a))) ((null?) (null? (a)))
    ((symbol?) (symbol? (a))) ((identifier?) (symbol? (a)))
    ((string?) (string? (a))) ((number?) (number? (a)))
    ((boolean?) (boolean? (a))) ((char?) (char? (a)))
    ((procedure?) (or (mv? mv-closure (a)) (mv? mv-prim (a))))
    ((not) (not (a)))
    ((eq?) (eq? (a) (b))) ((eqv?) (eqv? (a) (b))) ((equal?) (equal? (a) (b)))
    ((zero?) (zero? (a)))
    ((+) (+ (a) (b))) ((-) (- (a) (b))) ((*) (* (a) (b)))
    ((quotient) (quotient (a) (b))) ((remainder) (remainder (a) (b)))
    ((<) (< (a) (b))) ((>) (> (a) (b)))
    ((<=) (<= (a) (b))) ((>=) (>= (a) (b))) ((=) (= (a) (b)))
    ((max) (max (a) (b)))
    ;; map-in-order, not the host's map: transformers mutate through
    ;; their mapped closures (hole counters, gensyms), and the hosts
    ;; disagree on map's traversal order
    ((map) (if (pair? (cddr args))
               (map2* (lambda (x y) (meta-apply (a) (list x y)))
                      (b) (caddr args))
               (map-in-order (lambda (x) (meta-apply (a) (list x))) (b))))
    ((error) (errorf 'macro-transformer "~s" args))
    ((gensym) (gensym (if (and (pair? args) (string? (a))) (a) "g")))
    ((string->symbol) (string->symbol (a)))
    ((symbol->string) (symbol->string (unmark (a))))
    ((string-append) (fold-left string-append "" args))
    ((string=?) (string=? (a) (b)))
    ((string-length) (string-length (a)))
    ((substring) (substring (a) (b) (caddr args)))
    ((free-identifier=?) (eq? (unmark (a)) (unmark (b))))
    ((bound-identifier=?) (eq? (a) (b)))
    ((syntax->datum) (strip-marks (a)))
    ((datum->syntax) (b))
    ((generate-temporaries) (map-in-order (lambda (x) (gensym "t")) (a)))
    ((void) (void))
    (else (errorf 'goeteia "unhandled transformer primitive ~s" name))))

;;;; syntax-case pattern matching.  Match results are alists of
;;;; (pvar level . value); level is the ellipsis depth.

(define (ellipsis-id? x)
  (and (symbol? x) (eq? (unmark x) '...)))
(define (ellipsis-escape? x)
  ;; (... <form>) escapes the ellipses inside <form>
  (and (pair? x) (ellipsis-id? (car x))
       (pair? (cdr x)) (null? (cddr x))))
(define (sc-literal? x lits)
  (let ((u (unmark x)))
    (let scan ((ls lits))
      (and (pair? ls)
           (or (eq? u (unmark (car ls)))
               (scan (cdr ls)))))))
(define (improper-length ls)
  (if (pair? ls) (+ 1 (improper-length (cdr ls))) 0))

(define (sc-match pat v lits)
  (sc-match-pat pat v lits #f '()))
(define (sc-match-pat pat v lits esc acc)
  (cond
   ((symbol? pat)
    (cond
     ((eq? (unmark pat) '_) acc)
     ((sc-literal? pat lits)
      (and (symbol? v) (eq? (unmark v) (unmark pat)) acc))
     (else (cons (cons pat (cons 0 v)) acc))))
   ((pair? pat)
    (cond
     ((and (not esc) (ellipsis-escape? pat))
      (sc-match-pat (cadr pat) v lits #t acc))
     ((and (not esc) (pair? (cdr pat)) (ellipsis-id? (cadr pat)))
      (sc-match-ellipsis (car pat) (cddr pat) v lits acc))
     ((pair? v)
      (let ((acc (sc-match-pat (car pat) (car v) lits esc acc)))
        (and acc (sc-match-pat (cdr pat) (cdr v) lits esc acc))))
     (else #f)))
   ((null? pat) (and (null? v) acc))
   (else (and (equal? pat v) acc))))
(define (sc-match-ellipsis sub tailpat v lits acc)
  (let ((nrep (- (improper-length v) (improper-length tailpat))))
    (and (>= nrep 0)
         (let collect ((v v) (n nrep) (per-item '()))
           (if (zero? n)
               (let ((vars (sc-pattern-vars sub lits 0)))
                 (sc-match-pat tailpat v lits #f
                               (append (sc-zip vars (reverse per-item)) acc)))
               (let ((m (sc-match-pat sub (car v) lits #f '())))
                 (and m (collect (cdr v) (- n 1) (cons m per-item)))))))))
(define (sc-pattern-vars pat lits depth)
  ;; -> ((pvar . depth) ...)
  (cond
   ((symbol? pat)
    (cond
     ((eq? (unmark pat) '_) '())
     ((ellipsis-id? pat) '())
     ((sc-literal? pat lits) '())
     (else (list (cons pat depth)))))
   ((pair? pat)
    (cond
     ((ellipsis-escape? pat) (sc-pattern-vars (cadr pat) lits depth))
     ((and (pair? (cdr pat)) (ellipsis-id? (cadr pat)))
      (append (sc-pattern-vars (car pat) lits (+ depth 1))
              (sc-pattern-vars (cddr pat) lits depth)))
     (else (append (sc-pattern-vars (car pat) lits depth)
                   (sc-pattern-vars (cdr pat) lits depth)))))
   (else '())))
(define (sc-zip vars per-item)
  ;; rebind each pvar to the list of its per-item values, one level up
  (map (lambda (var)
         (cons (car var)
               (cons (+ (cdr var) 1)
                     (map (lambda (m)
                            (let ((e (assq (car var) m)))
                              (unless e
                                (errorf 'goeteia "missing pattern variable ~s"
                                        (car var)))
                              (cddr e)))
                          per-item))))
       vars))
(define (sc-extend bindings env)
  (append (map (lambda (bnd)
                 (cons (car bnd) (make-pvar (cadr bnd) (cddr bnd))))
               bindings)
          env))

(define (meta-syntax-case e env)
  ;; (syntax-case E (lit ...) clause ...)
  (let ((v (meta-eval (cadr e) env))
        (lits (caddr e)))
    (let try ((clauses (cdddr e)))
      (if (null? clauses)
          (errorf 'goeteia "no matching syntax-case clause for ~s" v)
          (let* ((clause (car clauses))
                 (bindings (sc-match (car clause) v lits)))
            (if bindings
                (let ((env* (sc-extend bindings env)))
                  (if (null? (cddr clause))
                      (meta-eval (cadr clause) env*)
                      ;; (pattern fender output)
                      (if (eq? (meta-eval (cadr clause) env*) #f)
                          (try (cdr clauses))
                          (meta-eval (caddr clause) env*))))
                (try (cdr clauses))))))))
(define (meta-with-syntax e env)
  ;; (with-syntax ((pat expr) ...) body ...)
  (let bind ((bs (cadr e)) (env* env))
    (if (null? bs)
        (meta-seq (cddr e) env*)
        (let ((m (sc-match (caar bs) (meta-eval (cadar bs) env) '())))
          (unless m
            (errorf 'goeteia "with-syntax pattern mismatch: ~s" (caar bs)))
          (bind (cdr bs) (sc-extend m env*))))))
(define (desugar-rules e)
  ;; (syntax-rules (lit ...) (pattern template) ...)
  (let ((x (gensym "stx")))
    `(lambda (,x)
       (syntax-case ,x ,(cadr e)
         . ,(map (lambda (rule)
                   (let ((pat (car rule)) (tmpl (cadr rule)))
                     `((_ . ,(if (pair? pat) (cdr pat) '()))
                       (syntax ,tmpl))))
                 (cddr e))))))

;;;; template transcription

(define (transcribe tmpl env esc)
  (cond
   ((symbol? tmpl)
    (let ((slot (assq tmpl env)))
      (if (and slot (mv? mv-pvar (cdr slot)))
          (let ((pv (cdr slot)))
            (if (zero? (pvar-level pv))
                (pvar-value pv)
                (errorf 'goeteia "too few ellipses after ~s" tmpl)))
          (rename-introduced tmpl))))
   ((pair? tmpl)
    (cond
     ((and (not esc) (ellipsis-escape? tmpl))
      (transcribe (cadr tmpl) env #t))
     ((and (not esc) (pair? (cdr tmpl)) (ellipsis-id? (cadr tmpl)))
      (let* ((extra (let count ((t (cddr tmpl)) (n 0))
                      (if (and (pair? t) (ellipsis-id? (car t)))
                          (count (cdr t) (+ n 1))
                          n)))
             (rest (list-tail (cddr tmpl) extra)))
        (append (transcribe-repeat (car tmpl) env (+ 1 extra))
                (transcribe rest env #f))))
     (else (cons (transcribe (car tmpl) env esc)
                 (transcribe (cdr tmpl) env esc)))))
   (else tmpl)))
(define (template-vars tmpl env acc)
  ;; pattern variables of depth > 0 occurring in tmpl
  (cond
   ((symbol? tmpl)
    (let ((slot (assq tmpl env)))
      (if (and slot
               (mv? mv-pvar (cdr slot))
               (> (pvar-level (cdr slot)) 0)
               (not (assq tmpl acc)))
          (cons (cons tmpl (cdr slot)) acc)
          acc)))
   ((pair? tmpl)
    (template-vars (cdr tmpl) env (template-vars (car tmpl) env acc)))
   (else acc)))
(define (transcribe-repeat sub env depth)
  ;; each extra ellipsis iterates a level deeper and splices
  (let ((vars (template-vars sub env '())))
    (when (null? vars)
      (errorf 'goeteia "no pattern variables under ellipsis in template"))
    (let ((n (length (pvar-value (cdar vars)))))
      (unless (all-true? (lambda (v) (= (length (pvar-value (cdr v))) n)) vars)
        (errorf 'goeteia "mismatched ellipsis counts in template"))
      (let iterate ((i 0))
        (if (= i n)
            '()
            (let ((env* (append
                         (map (lambda (v)
                                (cons (car v)
                                      (make-pvar (- (pvar-level (cdr v)) 1)
                                                 (list-ref (pvar-value (cdr v)) i))))
                              vars)
                         env)))
              (if (= depth 1)
                  (cons (transcribe sub env* #f) (iterate (+ i 1)))
                  (append (transcribe-repeat sub env* (- depth 1))
                          (iterate (+ i 1))))))))))

;;;; ------------------------------------------------------------------
;;;; lambda formals: a proper list (fixed), an improper list (fixed
;;;; plus rest), or a single symbol (all arguments as a list)

(define (formals-fixed f)
  (if (pair? f)
      (cons (car f) (formals-fixed (cdr f)))
      '()))
(define (formals-rest f)
  (cond
   ((symbol? f) f)
   ((pair? f) (formals-rest (cdr f)))
   (else #f)))
(define (formals-names f)
  (let ((r (formals-rest f)))
    (if r
        (append (formals-fixed f) (list r))
        (formals-fixed f))))

;;;; ------------------------------------------------------------------
;;;; assignment conversion: assigned lexicals are boxed in pairs

(define (assigned-vars e acc)
  (if (pair? e)
      (case (resolve-tag (car e))
        ((quote) acc)
        ((set!) (assigned-vars (caddr e)
                               (if (memq (cadr e) acc)
                                   acc
                                   (cons (cadr e) acc))))
        (else (assigned-vars (car e) (assigned-vars (cdr e) acc))))
      acc))

(define (avc e scope assigned)
  (cond
   ((symbol? e)
    (let ((s (assq e scope)))
      (if (and s (cdr s)) `(car ,e) e)))
   ((pair? e)
    (case (resolve-tag (car e))
      ((quote) e)
      ((set!)
       (let ((v (avc (caddr e) scope assigned)))
         (if (assq (cadr e) scope)
             `(set-car! ,(cadr e) ,v)
             `(set! ,(cadr e) ,v))))
      ((lambda)
       (let* ((formals (cadr e))
              (names (formals-names formals))
              (boxed (filter (lambda (p) (memq p assigned)) names))
              (scope* (append (map (lambda (p)
                                     (cons p (and (memq p assigned) #t)))
                                   names)
                              scope))
              (body (avc-body (cddr e) scope* assigned)))
         (if (null? boxed)
             `(lambda ,formals . ,body)
             `(lambda ,formals
                (let ,(map (lambda (p) `(,p (cons ,p '()))) boxed)
                  . ,body)))))
      ((let)
       (let* ((bs (cadr e))
              (scope* (append (map (lambda (b)
                                     (cons (car b)
                                           (and (memq (car b) assigned) #t)))
                                   bs)
                              scope)))
         `(let ,(map (lambda (b)
                       (let ((init (avc (cadr b) scope assigned)))
                         (if (memq (car b) assigned)
                             `(,(car b) (cons ,init '()))
                             `(,(car b) ,init))))
                     bs)
            . ,(avc-body (cddr e) scope* assigned))))
      ((%loop)
       ;; loop-ok? already rejected assigned params and names, so
       ;; the binders convert unboxed; inits in the outer scope
       (let* ((params (caddr e))
              (scope* (append (map (lambda (p) (cons p #f)) params)
                              (cons (cons (cadr e) #f) scope))))
         `(%loop ,(cadr e) ,params
                 ,(avc* (cadddr e) scope assigned)
                 . ,(avc-body (cdr (cdddr e)) scope* assigned))))
      (else (avc* e scope assigned))))
   (else e)))
(define (avc* es scope assigned)
  (if (pair? es)
      (cons (avc (car es) scope assigned) (avc* (cdr es) scope assigned))
      es))
;; a body may open with internal defines; they become boxed
;; letrec*-style bindings so mutual recursion works
(define (internal-def? f)
  (and (pair? f) (eq? (resolve-tag (car f)) 'define)))
(define (internal-def-name d)
  (if (pair? (cadr d)) (car (cadr d)) (cadr d)))
(define (internal-def-value d)
  (if (pair? (cadr d))
      (cons 'lambda (cons (cdr (cadr d)) (cddr d)))
      (caddr d)))
(define (avc-body body scope assigned)
  (if (and (pair? body) (internal-def? (car body)))
      (let* ((defs (let take ((b body))
                     (if (and (pair? b) (internal-def? (car b)))
                         (cons (car b) (take (cdr b)))
                         '())))
             (rest (let skip ((b body))
                     (if (and (pair? b) (internal-def? (car b)))
                         (skip (cdr b))
                         b)))
             (names (map (lambda (d) (internal-def-name d)) defs))
             (scope* (fold-left (lambda (sc n) (cons (cons n #t) sc))
                                scope names)))
        (list
         (cons 'let
               (cons (map (lambda (n) (list n (list 'cons '(begin) ''())))
                          names)
                     (append
                      (map (lambda (d)
                             (list 'set-car! (internal-def-name d)
                                   (avc (internal-def-value d) scope* assigned)))
                           defs)
                      (avc-body rest scope* assigned))))))
      (avc* body scope assigned)))

(define (convert-assignments form)
  (let ((assigned (assigned-vars form '())))
    (if (and (pair? form) (eq? (car form) 'define) (pair? (cadr form)))
        (let* ((formals (cdadr form))
               (names (formals-names formals))
               (boxed (filter (lambda (p) (memq p assigned)) names))
               (scope (map (lambda (p) (cons p (and (memq p assigned) #t)))
                           names))
               (body (avc-body (cddr form) scope assigned)))
          (if (null? boxed)
              `(define ,(cadr form) . ,body)
              `(define ,(cadr form)
                 (let ,(map (lambda (p) `(,p (cons ,p '()))) boxed)
                   . ,body))))
        (avc form '() assigned))))

;;;; ------------------------------------------------------------------
;;;; program state (one program per compiler run)

(define *fns* '())        ; name -> (index n-fixed variadic?)
(define *vars* '())       ; name -> global index
(define *plain-ty* '())   ; arity -> type index (top-level functions)
(define *clos-ty* '())    ; arity -> (fn-type . struct-type)
(define *rec-ty* '())     ; record field count -> struct type index
(define *lifted* '())     ; fn index -> (type-idx n-params extra f64-slots code)
;; local slots holding a raw f64 in the function being compiled;
;; reset at every function-body boundary, collected into its entry
(define *f64-slots* '())
;; active %loop labels: (name slots base-blocks) -- scoped to the
;; body compile; and the open-block counter brs measure against
(define *loops* '())
(define *blocks* 0)
(define *next-fn* 0)
(define *wrappers* '())   ; top-level fn name -> wrapper fn index
(define *adapters* '())   ; arity -> generic-entry adapter fn index
(define *interned* '())   ; (kind . datum) -> global index
(define *next-global* 0)
;; The list-of-interned-symbols function: its index is reserved up
;; front, its body is recorded after everything else has compiled and
;; the interned set is complete.  The prelude's string->symbol pulls
;; the list lazily, which keeps runtime interning eq-consistent with
;; compile-time symbol literals.
(define *reg-fn* 0)

(define (alloc-fn!)
  (let ((i *next-fn*))
    (set! *next-fn* (+ i 1))
    i))
(define (record-fn! idx entry)
  (when (assv idx *lifted*)
    (errorf 'goeteia "duplicate function index ~s" idx))
  (set! *lifted* (cons (cons idx entry) *lifted*)))

(define (clos-ty arity)
  (let ((e (assv arity *clos-ty*)))
    (unless e (errorf 'goeteia "missing closure type for arity ~s" arity))
    (cdr e)))
(define (rec-ty nfields)
  (let ((e (assv nfields *rec-ty*)))
    (unless e (errorf 'goeteia "missing record type for ~s fields" nfields))
    (cdr e)))

(define (intern! kind datum)
  (let find ((es *interned*))
    (cond
     ((null? es)
      (let ((g *next-global*))
        (set! *next-global* (+ g 1))
        (set! *interned* (cons (cons (cons kind datum) g) *interned*))
        g))
     ((and (eq? (car (caar es)) kind) (equal? (cdr (caar es)) datum))
      (cdar es))
     (else (find (cdr es))))))

;;;; ------------------------------------------------------------------
;;;; free variables (over the converted core language)

;; may (let name ...) lower to a wasm loop?  Only when every
;; occurrence of the name is the operator of a correct-arity
;; application in tail position of the loop body -- no value uses,
;; no set!, no appearance inside a nested lambda, no capture-prone
;; corner.  The body arrives expanded, so only core forms walk here.
(define (loop-mentions? v e)
  (cond
   ((eq? e v) #t)
   ((pair? e) (or (loop-mentions? v (car e)) (loop-mentions? v (cdr e))))
   (else #f)))

(define (loop-ok? name arity params xbody)
  (define (expr-ok e tail?)
    (cond
     ((eq? e name) #f)                  ; a bare value reference
     ((not (pair? e)) #t)
     (else
      (case (resolve-tag (car e))
        ((quote) #t)
        ((lambda) (not (loop-mentions? name e)))
        ((set!) (and (not (eq? (cadr e) name))
                     (expr-ok (caddr e) #f)))
        ((if) (and (expr-ok (cadr e) #f)
                   (expr-ok (caddr e) tail?)
                   (or (null? (cdddr e))
                       (expr-ok (cadddr e) tail?))))
        ((let)
         (and (not (symbol? (cadr e)))  ; named lets are gone by now
              (let ok ((binds (cadr e)))
                (or (null? binds)
                    (and (expr-ok (cadr (car binds)) #f)
                         (ok (cdr binds)))))
              (if (memq name (map car (cadr e)))
                  (not (loop-mentions? name (cddr e)))
                  (body-ok (cddr e) tail?))))
        ((begin) (body-ok (cdr e) tail?))
        ((define)                        ; internal defines, pre-avc
         (and (not (eq? (if (pair? (cadr e)) (car (cadr e)) (cadr e))
                        name))
              (expr-ok (if (pair? (cadr e))
                           (cons 'lambda (cons (cdr (cadr e)) (cddr e)))
                           (caddr e))
                       #f)))
        ((%loop)
         (if (or (eq? (cadr e) name) (memq name (caddr e)))
             (not (loop-mentions? name (cdr (cdddr e))))
             (and (let ok ((is (cadddr e)))
                    (or (null? is)
                        (and (expr-ok (car is) #f) (ok (cdr is)))))
                  (body-ok (cdr (cdddr e)) tail?))))
        (else                            ; an application
         (if (eq? (car e) name)
             (and tail?
                  (= (length (cdr e)) arity)
                  (let ok ((as (cdr e)))
                    (or (null? as)
                        (and (expr-ok (car as) #f) (ok (cdr as))))))
             (let ok ((es e))
               (or (null? es)
                   (and (expr-ok (car es) #f) (ok (cdr es)))))))))))
  (define (body-ok es tail?)
    (cond
     ((null? es) #t)
     ((null? (cdr es)) (expr-ok (car es) tail?))
     (else (and (expr-ok (car es) #f) (body-ok (cdr es) tail?)))))
  (and (not (memq name params))          ; a param shadowing the name
       ;; a set! of a loop parameter would need boxing; keep those
       ;; on the letrec path
       (let ((assigned (assigned-vars (cons 'begin xbody) '())))
         (and (not (memq name assigned))
              (let ok ((ps params))
                (or (null? ps)
                    (and (not (memq (car ps) assigned))
                         (ok (cdr ps)))))))
       (body-ok xbody #t)))

(define (free-vars e bound)
  (cond
   ((symbol? e) (if (memq e bound) '() (list e)))
   ((pair? e)
    (case (car e)
      ((quote) '())
      ((set!) (free-vars (caddr e) bound))
      ((lambda) (free-vars-body (cddr e)
                                (append (formals-names (cadr e)) bound)))
      ((let)
       (union (free-vars-body (map cadr (cadr e)) bound)
              (free-vars-body (cddr e)
                              (append (map car (cadr e)) bound))))
      ((%loop)
       (union (free-vars-body (cadddr e) bound)
              (free-vars-body (cdr (cdddr e))
                              (cons (cadr e)
                                    (append (caddr e) bound)))))
      ((begin if) (free-vars-body (cdr e) bound))
      (else (free-vars-body e bound))))
   (else '())))
(define (free-vars-body es bound)
  (fold-left (lambda (acc e) (union acc (free-vars e bound))) '() es))
(define (union a b)
  (fold-left (lambda (acc x) (if (memq x acc) acc (cons x acc))) a b))

;;;; ------------------------------------------------------------------
;;;; expression compiler

(define (fresh-local! cell)
  (let ((i (car cell)))
    (set-car! cell (+ i 1))
    i))

(define prim-arity
  '((car . 1) (cdr . 1) (cons . 2) (pair? . 1) (null? . 1) (zero? . 1)
    (+ . 2) (- . 2) (* . 2) (quotient . 2) (remainder . 2)
    (= . 2) (< . 2) (eq? . 2)
    (set-car! . 2) (set-cdr! . 2)
    (fixnum? . 1) (char? . 1) (string? . 1) (symbol? . 1)
    (flonum? . 1) (fl+ . 2) (fl- . 2) (fl* . 2) (fl/ . 2)
    (fl=? . 2) (fl<? . 2) (flsqrt . 1) (flfloor . 1) (fltruncate . 1)
    (fixnum->flonum . 1) (%fl->fx . 1)
    (%bignum? . 1) (%make-bignum . 2) (%bignum-sign . 1) (%bignum-limbs . 1)
    (boolean? . 1) (procedure? . 1)
    (char->integer . 1) (integer->char . 1)
    (string-length . 1) (string-ref . 2) (string-set! . 3)
    (symbol->string . 1) (eof-object? . 1)
    (bitwise-and . 2) (bitwise-ior . 2) (bitwise-xor . 2)
    (bitwise-arithmetic-shift-left . 2)
    (bitwise-arithmetic-shift-right . 2)
    (vector? . 1) (vector-length . 1) (vector-ref . 2) (vector-set! . 3)
    (bytevector? . 1) (bytevector-length . 1)
    (bytevector-u8-ref . 2) (bytevector-u8-set! . 3)
    (%make-vector . 2) (%make-bytevector . 2)
    (%write-byte . 1)
    (%mem-u8-ref . 1) (%mem-u8-set! . 2)
    (%mem-i32-ref . 1) (%mem-i32-set! . 2)
    (%mem-f32-ref . 1) (%mem-f32-set! . 2)
    (%mem-f64-ref . 1) (%mem-f64-set! . 2)
    (%mem-size . 0) (%mem-grow . 1)
    (%f32x4-add! . 3) (%f32x4-sub! . 3) (%f32x4-mul! . 3)
    (%f32x4-scale! . 3) (%f32x4-axpy! . 4) (%f32x4-dot . 2)
    (%js-await . 1)))

(define primitives
  '(+ - * quotient remainder = < eq? cons car cdr pair? null? zero?
    set-car! set-cdr! fixnum? char? string? symbol? boolean? procedure?
    flonum? fl+ fl- fl* fl/ fl=? fl<? flsqrt flfloor fltruncate
    fixnum->flonum %fl->fx
    %bignum? %make-bignum %bignum-sign %bignum-limbs
    %ratio? %make-ratio %ratio-num %ratio-den
    %complex? %make-complex %cx-re %cx-im
    %path-byte %open-read %open-write %fread %fwrite %fclose
    %js-ref? %js-arg-byte %js-global %js-get %js-set! %js-push
    %js-call %js-new %js-string %js-str-len %js-str-byte
    %js-number %js-to-number %js-eq %js-bool %js-undefined
    %js-fn %js-cb-argc %js-cb-arg %js-cb-ret %js-await
    char->integer integer->char string-length string-ref symbol->string
    string-set! eof-object eof-object?
    bitwise-and bitwise-ior bitwise-xor
    bitwise-arithmetic-shift-left bitwise-arithmetic-shift-right
    vector? vector-length vector-ref vector-set!
    bytevector? bytevector-length bytevector-u8-ref bytevector-u8-set!
    %make-vector %make-bytevector
    %record %record? %record-ref %record-set! %recbase? %record-rtd
    %write-byte %read-byte %make-string %make-symbol %interned-symbols
    %mem-u8-ref %mem-u8-set! %mem-i32-ref %mem-i32-set!
    %mem-f32-ref %mem-f32-set! %mem-f64-ref %mem-f64-set!
    %mem-size %mem-grow
    %f32x4-add! %f32x4-sub! %f32x4-mul! %f32x4-scale! %f32x4-axpy!
    %f32x4-dot
    %unreachable %throw-k))

(define (compile-exp e locals cell tail?)
  (cond
   ((and (integer? e) (exact? e) (fits-fixnum? e)) (emit-fixnum e))
   ((number? e) (compile-datum e))
   ((boolean? e) (global-get (if e G-TRUE G-FALSE)))
   ((char? e) (emit-char e))
   ((string? e) (global-get (intern! 'str e)))
   ((symbol? e) (compile-ref e locals cell))
   ((pair? e)
    (case (resolve-tag (car e))
      ((quote) (compile-datum (strip-marks (cadr e))))
      ((if) (compile-if e locals cell tail?))
      ((let) (compile-let e locals cell tail?))
      ((%loop) (compile-%loop e locals cell tail?))
      ((begin) (compile-body (cdr e) locals cell tail?))
      ((lambda) (compile-lambda (cadr e) (cddr e) locals cell))
      ((set!) (compile-global-set e locals cell))
      ((apply) (compile-apply e locals cell tail?))
      ((call/cc call-with-current-continuation)
       (compile-callcc e locals cell))
      (else (compile-app e locals cell tail?))))
   (else (errorf 'goeteia "cannot compile ~s" e))))

(define (compile-ref e locals cell)
  ;; lexical bindings are found by identity; unbound marked
  ;; identifiers resolve like the identifier they renamed
  (let ((slot (assq e locals)))
    (if slot
        (cond
         ((memv (cdr slot) *f64-slots*)
          ;; an f64 slot referenced generically: box it here
          (list (local-get (cdr slot)) (struct-new TY-FLONUM)))
         ((memv (- -100000 (cdr slot)) *f64-slots*)
          ;; an i32 slot: a fixnum by construction, box it
          (list (local-get (cdr slot)) (wrap-int)))
         (else (local-get (cdr slot))))
        (let* ((r (unmark e))
               (v (assq r *vars*)))
          (if v
              (global-get (cdr v))
              (let ((f (assq r *fns*)))
                (if f
                    (compile-fn-value (car f) (cdr f))
                    (let ((p (assq r prim-arity)))
                      (if p
                          ;; a primitive used as a value: synthesize
                          ;; the eta-expansion and close over nothing
                          (let ((ps (map (lambda (i) (gensym "p"))
                                         (nums-below (cdr p)))))
                            (compile-lambda ps (list (cons r ps))
                                            locals cell))
                          (errorf 'goeteia "unbound variable ~s" e))))))))))

;; walk an argument list held in local t, pushing n elements
(define (unpack-args t n)
  (map (lambda (_)
         (list (local-get t) (ref-cast TY-PAIR) (struct-get TY-PAIR 0)
               (local-get t) (ref-cast TY-PAIR) (struct-get TY-PAIR 1)
               (local-set t)))
       (nums-below n)))

;; the shared generic entry for fixed-arity closures: unpack the
;; argument list and forward to the fast entry
(define (adapter! arity)
  (let ((a (assv arity *adapters*)))
    (if a
        (cdr a)
        (let ((idx (alloc-fn!))
              (tys (clos-ty arity)))
          (set! *adapters* (cons (cons arity idx) *adapters*))
          (record-fn!
           idx
           (list TY-FNG 2 1 '()
                 (let ((t 2))
                   (list (local-get 0) (ref-cast (cdr tys))
                         (local-get 1) (local-set t)
                         (unpack-args t arity)
                         (local-get 0) (ref-cast (cdr tys))
                         (struct-get (cdr tys) 0)
                         #x15 (uleb (car tys)))))) ; return_call_ref
          idx))))

(define (compile-fn-value name entry)
  ;; a top-level function used as a value: wrap it in a closure
  (let ((idx (car entry))
        (nfixed (cadr entry))
        (variadic? (caddr entry))
        (w (assq name *wrappers*)))
    (if w
        (make-closure-code (cadr w) (cddr w) nfixed variadic?)
        (let ((widx (alloc-fn!)))
          (if variadic?
              ;; generic-only wrapper: unpack the fixed arguments,
              ;; pass the remainder as the rest list
              (let ((t 2))
                (record-fn!
                 widx
                 (list TY-FNG 2 1 '()
                       (list (local-get 1) (local-set t)
                             (unpack-args t nfixed)
                             (local-get t)
                             #x12 (uleb idx))))   ; return_call f
                (set! *wrappers* (cons (cons name (cons widx widx)) *wrappers*))
                (make-closure-code widx widx nfixed #t))
              ;; typed wrapper plus the shared per-arity adapter
              (let ((tys (clos-ty nfixed)))
                (record-fn!
                 widx
                 (list (car tys) (+ nfixed 1) 0 '()
                       (list (map (lambda (i) (local-get (+ i 1)))
                                  (nums-below nfixed))
                             #x12 (uleb idx))))
                (let ((gidx (adapter! nfixed)))
                  (set! *wrappers*
                        (cons (cons name (cons widx gidx)) *wrappers*))
                  (make-closure-code widx gidx nfixed #f))))))))

(define (make-closure-code code-idx generic-idx arity variadic?)
  (list (ref-func code-idx)
        (ref-func generic-idx)
        (global-get G-NULL)
        (struct-new (if variadic? TY-CLOSV (cdr (clos-ty arity))))))

;; f64 bits of a flonum, little-endian, using only flonum compare
;; and arithmetic so it runs identically under both hosts.
;; Normal numbers and zero; source literals don't produce the rest.
(define (ieee-bytes x)
  (if (fl=? x (fixnum->flonum 0))
      '(0 0 0 0 0 0 0 0)
      (let* ((neg (fl<? x (fixnum->flonum 0)))
             (mag (if neg (fl- (fixnum->flonum 0) x) x))
             (one (fixnum->flonum 1))
             (two (fixnum->flonum 2)))
        (let scale ((m mag) (e 0))
          (cond
           ((fl<? m one) (scale (fl* m two) (- e 1)))
           ((or (fl<? two m) (fl=? two m)) (scale (fl/ m two) (+ e 1)))
           (else
            (let bits ((frac (fl- m one)) (i 0) (acc '()))
              (if (= i 52)
                  (assemble-f64 neg (+ e 1023) (reverse acc))
                  (let ((d (fl* frac two)))
                    (if (or (fl<? one d) (fl=? one d))
                        (bits (fl- d one) (+ i 1) (cons 1 acc))
                        (bits d (+ i 1) (cons 0 acc))))))))))))
(define (assemble-f64 neg biased mant)
  ;; mant: 52 bits, most significant first -> 8 LE bytes
  (let* ((bits (append (list (if neg 1 0))
                       (exp-bits biased 11)
                       mant))
         (bytes (let byte ((bs bits) (acc '()))
                  (if (null? bs)
                      acc                       ; big-endian built, reversed
                      (byte (list-tail bs 8)
                            (cons (bits->byte (first-n bs 8)) acc))))))
    bytes))
(define (exp-bits n k)
  (if (zero? k)
      '()
      (append (exp-bits (quotient n 2) (- k 1))
              (list (remainder n 2)))))
(define (bits->byte bs)
  (fold-left (lambda (acc b) (+ (* acc 2) b)) 0 bs))

(define (fits-fixnum? n)
  (and (< n 536870912) (< -536870913 n)))
(define (compile-datum d)
  (cond
   ((and (integer? d) (exact? d) (fits-fixnum? d)) (emit-fixnum d))
   ((and (integer? d) (exact? d))
    ;; a bignum literal: decompose into 15-bit limbs with generic
    ;; arithmetic (works on host bignums under Chez and on goeteia
    ;; bignums when self-hosted) and rebuild at runtime
    (let* ((neg (< d 0))
           (mag (if neg (- 0 d) d))
           (limbs (let split ((m mag) (acc '()))
                    (if (and (fits-fixnum? m) (< m 16384))
                        (reverse (cons m acc))
                        (split (quotient m 16384)
                               (cons (remainder m 16384) acc)))))
           (codes (map-in-order emit-fixnum limbs)))
      (list (i32const (if neg 1 0))
            codes
            (gc-op #x08 (uleb TY-VECTOR) (uleb (length limbs)))
            (struct-new TY-BIGNUM))))
   ((flonum? d)
    (list #x44 (ieee-bytes d) (struct-new TY-FLONUM)))
   ((and (rational? d) (exact? d))
    ;; an exact ratio, already canonical from either host's reader
    (let* ((n (compile-datum (numerator d)))
           (dd (compile-datum (denominator d))))
      (list n dd (struct-new TY-RATIO))))
   ((and (number? d) (not (real? d)))
    (let* ((re (compile-datum (real-part d)))
           (im (compile-datum (imag-part d))))
      (list re im (struct-new TY-COMPLEX))))
   ((boolean? d) (global-get (if d G-TRUE G-FALSE)))
   ((char? d) (emit-char d))
   ((string? d) (global-get (intern! 'str d)))
   ((symbol? d) (global-get (intern! 'sym d)))
   ((null? d) (global-get G-NULL))
   ((vector? d)
    (let ((els (map-in-order compile-datum (vector->list d))))
      (list els (gc-op #x08 (uleb TY-VECTOR) (uleb (length els))))))
   ((pair? d)
    (let* ((head (compile-datum (car d)))
           (tail (compile-datum (cdr d))))
      (list head tail (struct-new TY-PAIR))))
   (else (errorf 'goeteia "unsupported datum ~s" d))))

(define (compile-if e locals cell tail?)
  ;; compile in source order: codegen effects (function indices,
  ;; interned literals) must not depend on the host's argument
  ;; evaluation order.  The arms live one block deeper -- %loop brs
  ;; measure their label distance through *blocks*
  (let ((t (compile-test (cadr e) locals cell)))
    (set! *blocks* (+ *blocks* 1))
    (let* ((c (compile-exp (caddr e) locals cell tail?))
           (a (if (null? (cdddr e))
                  (global-get G-VOID)
                  (compile-exp (cadddr e) locals cell tail?))))
      (set! *blocks* (- *blocks* 1))
      (list t #x04 T-EQREF c #x05 a #x0B))))
;; a test position wants an i32; predicates skip the boolean
;; boxing/unboxing round trip
(define (compile-test e locals cell)
  (cond
   ;; fixnum =/< over i32 expressions: compare raw, no boxing
   ((and (pair? e)
         (symbol? (car e))
         (memq (unmark (car e)) '(= <))
         (not (assq (car e) locals))
         (not (assq (unmark (car e)) *fns*))
         (= (length (cdr e)) 2)
         (i32-expr? (cadr e) locals)
         (i32-expr? (caddr e) locals))
    (let* ((a (compile-i32 (cadr e) locals cell))
           (b (compile-i32 (caddr e) locals cell)))
      (list a b (if (eq? (unmark (car e)) '=) #x46 #x48))))
   ;; flonum comparisons compare in the f64 context and land i32
   ;; directly -- no boolean box, and f64-slotted arguments never box
   ((and (pair? e)
         (symbol? (car e))
         (memq (unmark (car e)) '(fl<? fl=?))
         (not (assq (car e) locals))
         (not (assq (unmark (car e)) *fns*))
         (= (length (cdr e)) 2))
    (let* ((a (compile-f64 (cadr e) locals cell))
           (b (compile-f64 (caddr e) locals cell)))
      (list a b (if (eq? (unmark (car e)) 'fl=?) #x61 #x63))))
   ((and (pair? e)
         (symbol? (car e))
         (memq (unmark (car e)) i32-predicates)
         (let ((expect (assq (unmark (car e)) prim-arity)))
           (and expect (= (length (cdr e)) (cdr expect))))
         (not (assq (car e) locals))
         (not (assq (unmark (car e)) *fns*)))
    (pred-i32 (unmark (car e))
              (map-in-order (lambda (a) (compile-exp a locals cell #f))
                            (cdr e))
              cell))
   (else (list (compile-exp e locals cell #f) (truthy)))))

;; does a form contain a lambda? (quote subtrees don't count) -- a
;; binding captured by an inner lambda cannot live in an f64 slot,
;; since closure environments carry eqref
(define (contains-lambda? e)
  (and (pair? e)
       (let ((tag (resolve-tag (car e))))
         (cond
          ((eq? tag 'quote) #f)
          ((eq? tag 'lambda) #t)
          (else (or (contains-lambda? (car e))
                    (contains-lambda? (cdr e))))))))

;; does the symbol occur anywhere in e? identity walk, quotes and all
;; -- over-approximating occurrence keeps the capture test safe
(define (mentions? v e)
  (cond
   ((eq? e v) #t)
   ((pair? e) (or (mentions? v (car e)) (mentions? v (cdr e))))
   (else #f)))

;; could a lambda nested in e capture v?  Any lambda subtree that so
;; much as mentions the symbol counts (shadowing ignored -- that only
;; costs a boxing, never correctness).  This is the per-binding
;; refinement of contains-lambda?: a loop in the body no longer
;; denies f64 slots to bindings the loop never touches
(define (lambda-captures? v e)
  (and (pair? e)
       (let ((tag (resolve-tag (car e))))
         (cond
          ((eq? tag 'quote) #f)
          ((eq? tag 'lambda) (mentions? v e))
          (else (or (lambda-captures? v (car e))
                    (lambda-captures? v (cdr e))))))))

;; a two-armed if whose branches are both flonum expressions is one
;; itself -- min/max/clamp/abs arrive in this shape once the inliner
;; has erased the helper call
(define (fl-if? e locals)
  (and (pair? e)
       (eq? (resolve-tag (car e)) 'if)
       (= (length e) 4)
       (fl-expr? (caddr e) locals)
       (fl-expr? (cadddr e) locals)))

;; is e statically a flonum expression? (an unshadowed fl form, a
;; flonum literal, a reference to an f64-slotted local, or an if
;; with two flonum arms)
(define (fl-expr? e locals)
  (cond
   ((and (number? e) (flonum? e)) #t)
   ((symbol? e)
    (let ((slot (assq e locals)))
      (and slot (memv (cdr slot) *f64-slots*) #t)))
   ((pair? e)
    (let* ((h (car e))
           (rop (and (symbol? h) (unmark h))))
      (or (and rop (memq rop fl-direct-ops)
               (not (assq h locals))
               (not (assq rop *fns*))
               (let ((a (assq rop prim-arity)))
                 (and a (= (length (cdr e)) (cdr a)))))
          (fl-if? e locals))))
   (else #f)))

(define (compile-let e locals cell tail?)
  ;; a binding whose value is statically a flonum gets a raw f64 slot
  ;; when no lambda in the body could capture IT (other bindings may
  ;; well be captured); reads inside float expressions then use the
  ;; slot directly, others box on reference
  (let ((lambda-free (not (contains-lambda? (cddr e)))))
    (let loop ((bs (cadr e)) (code '()) (scope locals))
      (if (null? bs)
          (list (reverse code)
                (compile-body (cddr e) scope cell tail?))
          (let* ((b (car bs))
                 (slot (fresh-local! cell)))
            (cond
             ((and (fl-expr? (cadr b) locals)
                   (or lambda-free
                       (not (lambda-captures? (car b) (cddr e)))))
              (set! *f64-slots* (cons slot *f64-slots*))
              (loop (cdr bs)
                    (cons (list (compile-f64 (cadr b) locals cell)
                                (local-set slot))
                          code)
                    (cons (cons (car b) slot) scope)))
             ((and (i32-expr? (cadr b) locals)
                   (or lambda-free
                       (not (lambda-captures? (car b) (cddr e)))))
              (set! *f64-slots* (cons (- -100000 slot) *f64-slots*))
              (loop (cdr bs)
                    (cons (list (compile-i32 (cadr b) locals cell)
                                (local-set slot))
                          code)
                    (cons (cons (car b) slot) scope)))
             (else
              (loop (cdr bs)
                    (cons (list (compile-exp (cadr b) locals cell #f)
                                (local-set slot))
                          code)
                    (cons (cons (car b) slot) scope)))))))))

;; (%loop name (p ...) (init ...) body ...): the loop that never
;; calls.  Parameters are plain locals, iteration is a br back to
;; the loop header with the new values set, and the body's normal
;; fall-through is the loop's value.  Self-calls push every new
;; value on the wasm stack, then set the parameter locals in
;; reverse -- parallel binding for free
(define (compile-%loop e locals cell tail?)
  (let* ((name (cadr e))
         (params (caddr e))
         (inits (cadddr e))
         (body (cdr (cdddr e)))
         (slots (map-in-order (lambda (p) (fresh-local! cell)) params))
         (scope (append (map cons params slots) locals))
         (init-code (map-in-order
                     (lambda (i) (compile-exp i locals cell #f))
                     inits)))
    (set! *blocks* (+ *blocks* 1))      ; the loop's own label
    (set! *loops* (cons (list name slots *blocks*) *loops*))
    (let ((body-code (compile-body body scope cell tail?)))
      (set! *loops* (cdr *loops*))
      (set! *blocks* (- *blocks* 1))
      (list (map2* (lambda (code slot) (list code (local-set slot)))
                   init-code slots)
            #x03 T-EQREF                ; loop (result eqref)
            body-code
            #x0B))))

(define (compile-body es locals cell tail?)
  (cond
   ((null? es) (global-get G-VOID))
   ((null? (cdr es)) (compile-exp (car es) locals cell tail?))
   (else
    (let* ((head (compile-exp (car es) locals cell #f))
           (rest (compile-body (cdr es) locals cell tail?)))
      (list head OP-DROP rest)))))

(define (compile-global-set e locals cell)
  (let ((v (assq (unmark (cadr e)) *vars*)))
    (unless v (errorf 'goeteia "set! of unbound variable ~s" (cadr e)))
    (list (compile-exp (caddr e) locals cell #f)
          (global-set (cdr v))
          (global-get G-VOID))))

;;; closures

(define (compile-lambda formals body locals cell)
  (let* ((rest (formals-rest formals))
         (names (formals-names formals))
         (free (filter (lambda (v) (assq v locals))
                       (free-vars-body body names)))
         (idx (alloc-fn!)))
    (if rest
        (begin
          (lift-variadic! idx (formals-fixed formals) rest body free)
          (list (ref-func idx)
                (ref-func idx)
                (env-chain free locals)
                (struct-new TY-CLOSV)))
        (let ((arity (length formals))
              (gidx (adapter! (length formals))))
          (lift-fixed! idx formals body free)
          (list (ref-func idx)
                (ref-func gidx)
                (env-chain free locals)
                (struct-new (cdr (clos-ty arity))))))))

(define (env-chain free locals)
  (if (null? free)
      (global-get G-NULL)
      (list (local-get (cdr (assq (car free) locals)))
            (env-chain (cdr free) locals)
            (struct-new TY-PAIR))))

;; bind the captured environment chain (field 2) into fresh locals
(define (env-prologue free locals cell env-ty)
  (if (null? free)
      '()
      (let ((envtmp (fresh-local! cell)))
        (list (local-get 0)
              (if (eqv? env-ty TY-CLOSV) (ref-cast TY-CLOSV) '())
              (struct-get env-ty 2)
              (local-set envtmp)
              (map (lambda (v)
                     (list (local-get envtmp) (ref-cast TY-PAIR)
                           (struct-get TY-PAIR 0)
                           (local-set (cdr (assq v locals)))
                           (local-get envtmp) (ref-cast TY-PAIR)
                           (struct-get TY-PAIR 1)
                           (local-set envtmp)))
                   free)))))

(define (number-locals names first)
  (let loop ((ns names) (i first))
    (if (null? ns)
        '()
        (cons (cons (car ns) i) (loop (cdr ns) (+ i 1))))))

(define (slot-locals! names cell acc)
  (if (null? names)
      acc
      (slot-locals! (cdr names) cell
                    (cons (cons (car names) (fresh-local! cell)) acc))))

(define (lift-fixed! idx formals body free)
  (let* ((arity (length formals))
         (tys (clos-ty arity))
         (cell (list (+ arity 1)))
         (locals (slot-locals! free cell (number-locals formals 1)))
         (prologue (env-prologue free locals cell (cdr tys)))
         (saved *f64-slots*)
         (saved-loops *loops*)
         (saved-blocks *blocks*))
    (set! *f64-slots* '())
    (set! *loops* '())
    (set! *blocks* 0)
    (let* ((body-code (compile-body body locals cell #t))
           (f64s *f64-slots*))
      (set! *f64-slots* saved)
      (set! *loops* saved-loops)
      (set! *blocks* saved-blocks)
      (record-fn! idx (list (car tys) (+ arity 1)
                            (- (car cell) (+ arity 1)) f64s
                            (list prologue body-code))))))

(define (lift-variadic! idx fixed rest body free)
  ;; the body is its own generic entry: (closure args-list) -> value
  (let* ((cell (list 2))
         (t (fresh-local! cell))
         (locals (slot-locals! (cons rest fixed) cell '()))
         (locals (slot-locals! free cell locals))
         (prologue
          (list (local-get 1) (local-set t)
                (map (lambda (p)
                       (list (local-get t) (ref-cast TY-PAIR)
                             (struct-get TY-PAIR 0)
                             (local-set (cdr (assq p locals)))
                             (local-get t) (ref-cast TY-PAIR)
                             (struct-get TY-PAIR 1)
                             (local-set t)))
                     fixed)
                (local-get t) (local-set (cdr (assq rest locals)))
                (env-prologue free locals cell TY-CLOSV)))
         (saved *f64-slots*)
         (saved-loops *loops*)
         (saved-blocks *blocks*))
    (set! *f64-slots* '())
    (set! *loops* '())
    (set! *blocks* 0)
    (let* ((body-code (compile-body body locals cell #t))
           (f64s *f64-slots*))
      (set! *f64-slots* saved)
      (set! *loops* saved-loops)
      (set! *blocks* saved-blocks)
      (record-fn! idx (list TY-FNG 2 (- (car cell) 2) f64s
                            (list prologue body-code))))))

;;; applications

(define (compile-app e locals cell tail?)
  (let* ((op (car e))
         (args (cdr e))
         (rop (and (symbol? op) (unmark op))))
    (cond
     ((and (symbol? op) (assq op locals))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ;; a %loop self-call: new values on the stack, parameters set
     ;; in reverse, one br to the header.  loop-ok? proved every
     ;; such site is in tail position of the loop body
     ((and (symbol? op) (assq op *loops*))
      (let* ((entry (assq op *loops*))
             (slots (cadr entry))
             (base (caddr entry))
             (acode (map-in-order
                     (lambda (a) (compile-exp a locals cell #f))
                     args)))
        (list acode
              (map (lambda (slot) (local-set slot)) (reverse slots))
              #x0C (uleb (- *blocks* base)))))
     ((and rop (memq rop primitives) (not (assq rop *fns*)))
      (compile-prim rop args locals cell))
     ((and rop (assq rop *fns*))
      (compile-direct (cdr (assq rop *fns*)) e args locals cell tail?))
     ((and rop (assq rop *vars*))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ((pair? op)
      (compile-indirect (compile-exp op locals cell #f) args locals cell tail?))
     (else (errorf 'goeteia "cannot call ~s" op)))))

(define (compile-direct entry e args locals cell tail?)
  (let ((idx (car entry))
        (nfixed (cadr entry))
        (variadic? (caddr entry)))
    (if variadic?
        ;; extra arguments are consed into the rest list at the call
        (let ((n (length args)))
          (when (< n nfixed)
            (errorf 'goeteia "too few arguments in ~s" e))
          (let* ((fixed (map-in-order (lambda (a) (compile-exp a locals cell #f))
                                      (first-n args nfixed)))
                 (extras (arg-chain (list-tail args nfixed)
                                    (global-get G-NULL) locals cell)))
            (list fixed extras (if tail? #x12 #x10) (uleb idx))))
        (begin
          (unless (= nfixed (length args))
            (errorf 'goeteia "wrong argument count in ~s" e))
          (list (map-in-order (lambda (a) (compile-exp a locals cell #f)) args)
                (if tail? #x12 #x10)
                (uleb idx))))))

(define (arg-chain args tail-code locals cell)
  (if (null? args)
      tail-code
      (let* ((head (compile-exp (car args) locals cell #f))
             (rest (arg-chain (cdr args) tail-code locals cell)))
        (list head rest (struct-new TY-PAIR)))))

(define (compile-indirect fcode args locals cell tail?)
  (indirect-call-code
   fcode
   (map-in-order (lambda (a) (compile-exp a locals cell #f)) args)
   cell tail?))
(define (indirect-call-code fcode argc cell tail?)
  ;; dual dispatch: the fast arity-typed entry when the callee's
  ;; closure type matches this call's arity, the generic list-taking
  ;; entry otherwise (variadic callee or arity mismatch).  The
  ;; arguments compile once; both branches spill them to locals.
  (let* ((arity (length argc))
         (tys (clos-ty arity))
         (tmp (fresh-local! cell))
         (slots (map-in-order (lambda (a) (fresh-local! cell)) argc)))
    (list fcode (local-set tmp)
          (map2* (lambda (code slot) (list code (local-set slot))) argc slots)
          (local-get tmp) (ref-test (cdr tys))
          #x04 T-EQREF
          (local-get tmp) (ref-cast (cdr tys))
          (map (lambda (slot) (local-get slot)) slots)
          (local-get tmp) (ref-cast (cdr tys)) (struct-get (cdr tys) 0)
          (if tail? #x15 #x14)
          (uleb (car tys))
          #x05
          (local-get tmp) (ref-cast TY-CLOSBASE)
          (fold-right (lambda (slot rest)
                        (list (local-get slot) rest (struct-new TY-PAIR)))
                      (global-get G-NULL)
                      slots)
          (local-get tmp) (ref-cast TY-CLOSBASE) (struct-get TY-CLOSBASE 1)
          (if tail? #x15 #x14)
          (uleb TY-FNG)
          #x0B)))

(define (compile-apply e locals cell tail?)
  ;; (apply f a b ... lst): always through the generic entry, with
  ;; the leading arguments consed onto the final list
  (let ((f (cadr e))
        (args (cddr e)))
    (when (null? args)
      (errorf 'goeteia "apply needs an argument list in ~s" e))
    (let* ((leading (first-n args (- (length args) 1)))
           (final (car (list-tail args (- (length args) 1))))
           (tmp (fresh-local! cell))
           (fc (compile-exp f locals cell #f))
           (chain (let build ((as leading))
                    (if (null? as)
                        (compile-exp final locals cell #f)
                        (let* ((head (compile-exp (car as) locals cell #f))
                               (rest (build (cdr as))))
                          (list head rest (struct-new TY-PAIR)))))))
      (list fc (local-set tmp)
            (local-get tmp) (ref-cast TY-CLOSBASE)
            chain
            (local-get tmp) (ref-cast TY-CLOSBASE) (struct-get TY-CLOSBASE 1)
            (if tail? #x15 #x14)
            (uleb TY-FNG)))))

;; Escape continuations over wasm exception handling.  call/cc makes
;; a unique token; the continuation is a closure that throws the tag
;; with (token . value) as payload; call/cc catches, keeps a matching
;; token's value, and rethrows anyone else's.  The continuation is
;; one-shot and upward-only: invoking it after call/cc has returned
;; does not resume, it traps as an uncaught exception.
(define (compile-callcc e locals cell)
  (let* ((tok (fresh-local! cell))
         (wind (fresh-local! cell))
         (tokname (gensym "ktok"))
         (wname (gensym "kwind"))
         (vname (gensym "v"))
         (fcode (compile-exp (cadr e) locals cell #f))
         (kcode (compile-lambda (list vname)
                                (list (list '$escape tokname wname vname))
                                (cons (cons tokname tok)
                                      (cons (cons wname wind) locals))
                                cell))
         (tmp (fresh-local! cell)))
    (list
     ;; the token: a fresh pair, compared by identity
     (global-get G-NULL) (global-get G-NULL) (struct-new TY-PAIR)
     (local-set tok)
     ;; capture the winder stack for dynamic-wind
     (global-get (cdr (assq '$winders *vars*)))
     (local-set wind)
     #x06 T-EQREF                       ; try (result eqref)
     (indirect-call-code fcode (list kcode) cell #f)
     #x07 (uleb 0)                      ; catch $escape -> payload
     (local-set tmp)
     (local-get tmp) (ref-cast TY-PAIR) (struct-get TY-PAIR 0)
     (local-get tok) OP-REF-EQ
     #x04 T-EQREF                       ; ours?
     (local-get tmp) (ref-cast TY-PAIR) (struct-get TY-PAIR 1)
     #x05
     (local-get tmp) #x08 (uleb 0)      ; someone else's: rethrow
     #x0B                               ; end if
     #x0B)))                            ; end try

;; predicates that produce a raw i32 truth value; used directly in
;; test position (no boolean boxing) and boolified elsewhere
(define i32-predicates '(= < zero? eq? pair? null? string? symbol?
                         procedure? eof-object?))
;; call a generic arithmetic helper from the prelude by name
(define (generic-call name)
  (let ((f (assq name *fns*)))
    (unless f (errorf 'goeteia "missing generic helper ~s" name))
    (list #x10 (uleb (cadr f)))))
(define (pred-i32 op argc cell)
  (define (arg i) (list-ref argc i))
  (case op
    ((= <)
     ;; both fixnums: compare tagged; otherwise the generic helper
     (let* ((ta (fresh-local! cell)) (tb (fresh-local! cell)))
       (list (arg 0) (local-set ta) (arg 1) (local-set tb)
             (local-get ta) (gc-op #x14 T-I31)
             (local-get tb) (gc-op #x14 T-I31)
             #x71
             #x04 T-I32
             (local-get ta) (untag) (local-get tb) (untag)
             (if (eq? op '=) #x46 #x48)
             #x05
             (local-get ta) (local-get tb)
             (generic-call (if (eq? op '=) '$eq2 '$lt2))
             (truthy)
             #x0B)))
    ((zero?)
     (let ((ta (fresh-local! cell)))
       (list (arg 0) (local-set ta)
             (local-get ta) (gc-op #x14 T-I31)
             #x04 T-I32
             (local-get ta) (untag) OP-I32-EQZ
             #x05
             (local-get ta) (emit-fixnum 0) (generic-call '$eq2)
             (truthy)
             #x0B)))
    ((eq?) (list (arg 0) (arg 1) OP-REF-EQ))
    ((pair?) (list (arg 0) (ref-test TY-PAIR)))
    ((null?) (list (arg 0) (global-get G-NULL) OP-REF-EQ))
    ((string?) (list (arg 0) (ref-test TY-STRING)))
    ((symbol?) (list (arg 0) (ref-test TY-SYMBOL)))
    ((procedure?) (list (arg 0) (ref-test TY-CLOSBASE)))
    ((eof-object?) (list (arg 0) (global-get G-EOF) OP-REF-EQ))))

;; one binary arithmetic op: fixnum fast path inline, generic helper
;; otherwise.  The fast + and - work on tagged values and re-derive
;; the sum for the 30-bit overflow check instead of spending a local;
;; * checks its range in 64 bits.
(define (arith2 op acode bcode cell)
  (let* ((ta (fresh-local! cell))
         (tb (fresh-local! cell))
         (slow (list (local-get ta) (local-get tb)
                     (generic-call (case op
                                     ((+) '$add2) ((-) '$sub2) ((*) '$mul2)
                                     ((quotient) '$quot2) (else '$rem2)))))
         (tagged-op (lambda ()
                      (list (local-get ta) (untag)
                            (local-get tb) (untag)
                            (if (eq? op '+) #x6A #x6B)))))
    (list acode (local-set ta) bcode (local-set tb)
          (local-get ta) (gc-op #x14 T-I31)
          (local-get tb) (gc-op #x14 T-I31)
          #x71
          #x04 T-EQREF
          (case op
            ((+ -)
             ;; overflow iff bits 30 and 31 of the tagged result differ
             (list (tagged-op) (i32const 30) #x75
                   (tagged-op) (i32const 31) #x75
                   #x46
                   #x04 T-EQREF
                   (tagged-op) (gc-op #x1C)
                   #x05 slow #x0B))
            ((*)
             ;; p = a * (b<<1) must fit in 31 signed bits
             (let ((p64 (lambda ()
                          (list (local-get ta) (unwrap-int) #xAC
                                (local-get tb) (untag) #xAC
                                #x7E))))
               (list (p64) (p64) #xC4 #x51        ; i64.eq with extend32_s
                     #x04 T-I32
                     (p64) #xA7 (i32const 30) #x75
                     (p64) #xA7 (i32const 31) #x75
                     #x46
                     #x05 (i32const 0) #x0B
                     #x04 T-EQREF
                     (p64) #xA7 (gc-op #x1C)
                     #x05 slow #x0B)))
            ((quotient)
             (list (local-get ta) (unwrap-int)
                   (local-get tb) (unwrap-int)
                   #x6D (wrap-int)))
            (else                       ; remainder
             (list (local-get ta) (untag)
                   (local-get tb) (untag)
                   #x6F (gc-op #x1C))))
          #x05 slow #x0B)))

;; ---- unboxed float expressions ----
;; Inside a float expression tree the f64 stays on the wasm stack:
;; (fl+ (fl* a b) (fl* c d)) boxes only its final result. compile-f64
;; emits code leaving a raw f64; fl-expressions recurse directly, and
;; anything else compiles normally and unboxes at the boundary.
(define fl-direct-ops
  '(fl+ fl- fl* fl/ flsqrt flfloor fltruncate fixnum->flonum
    %mem-f64-ref %mem-f32-ref %f32x4-dot))

;; (%f32x4-dot a b): four lanes of [a]*[b] summed to one f64 -- the
;; quaternion/plane dot.  The product parks in a v128 local (encoded
;; as (- -1 slot) in *f64-slots*, see locals-decl) so each lane
;; extracts without recomputing
(define (compile-f32x4-dot args locals cell)
  (let ((v (fresh-local! cell)))
    (set! *f64-slots* (cons (- -1 v) *f64-slots*))
    (let* ((pa (compile-exp (car args) locals cell #f))
           (pb (compile-exp (cadr args) locals cell #f)))
    (list pa (unwrap-int)
          #xFD (uleb 0) (uleb 0) (uleb 0)      ; v128.load
          pb (unwrap-int)
          #xFD (uleb 0) (uleb 0) (uleb 0)
          #xFD (uleb 230)                      ; f32x4.mul
          (local-set v)
          (local-get v) #xFD (uleb 31) 0       ; f32x4.extract_lane k
          (local-get v) #xFD (uleb 31) 1
          #x92                                 ; f32.add
          (local-get v) #xFD (uleb 31) 2
          #x92
          (local-get v) #xFD (uleb 31) 3
          #x92
          #xBB))))                             ; f64.promote_f32

;; ---- the i32 context: raw machine integers in locals ----
;; The closed set: operations whose result always fits i31 given
;; fixnum inputs, so boxing at a generic reference (wrap-int) is
;; always faithful.  shift-left normalizes to 31 signed bits inside
;; the context, matching what boxing would have truncated; quotient
;; requires a positive literal divisor ((-2^30)/(-1) would escape
;; i31); remainder/quotient demand provably-fixnum arguments, since
;; their generic spelling handles bignums.  i32 slots ride
;; *f64-slots* encoded as (- -100000 slot)
(define (i32-literal? e)
  (and (integer? e) (exact? e) (fits-fixnum? e)))

(define (i32-slot? e locals)
  (let ((slot (assq e locals)))
    (and slot (memv (- -100000 (cdr slot)) *f64-slots*) #t)))

(define (i32-if? e locals)
  (and (pair? e)
       (eq? (resolve-tag (car e)) 'if)
       (= (length e) 4)
       (i32-expr? (caddr e) locals)
       (i32-expr? (cadddr e) locals)))

(define ($i32-prim-of e locals)         ; the op, when e is a direct form
  (let* ((h (car e))
         (rop (and (symbol? h) (unmark h))))
    (and rop
         (not (assq h locals))
         (not (assq rop *fns*))
         (let ((a (assq rop prim-arity)))
           (and a (= (length (cdr e)) (cdr a))))
         rop)))

(define (i32-expr? e locals)
  (cond
   ((i32-literal? e) #t)
   ((symbol? e) (i32-slot? e locals))
   ((pair? e)
    (or (i32-if? e locals)
        (case ($i32-prim-of e locals)
          ((bitwise-and bitwise-ior bitwise-xor
            bitwise-arithmetic-shift-right
            bitwise-arithmetic-shift-left
            %mem-u8-ref) #t)
          ((remainder)
           (and (i32-expr? (cadr e) locals)
                (i32-expr? (caddr e) locals)))
          ((quotient)
           (and (i32-expr? (cadr e) locals)
                (i32-literal? (caddr e))
                (> (caddr e) 0)))
          (else #f))))
   (else #f)))

(define (compile-i32 e locals cell)
  (cond
   ((i32-literal? e) (i32const e))
   ((symbol? e)
    (if (i32-slot? e locals)
        (local-get (cdr (assq e locals)))
        (list (compile-exp e locals cell #f) (unwrap-int))))
   ((and (pair? e) (i32-if? e locals))
    (let* ((t (compile-test (cadr e) locals cell))
           (c (compile-i32 (caddr e) locals cell))
           (alt (compile-i32 (cadddr e) locals cell)))
      (list t #x04 #x7F c #x05 alt #x0B)))
   ((and (pair? e) (i32-expr? e locals))
    (let ((rop ($i32-prim-of e locals)))
      (if (eq? rop '%mem-u8-ref)
          (list (compile-exp (cadr e) locals cell #f) (unwrap-int)
                #x2D (uleb 0) (uleb 0))
          ;; compile in source order: codegen effects must not
          ;; depend on the host's argument evaluation order
          (let* ((a (compile-i32 (cadr e) locals cell))
                 (b (compile-i32 (caddr e) locals cell)))
            (case rop
              ((bitwise-and) (list a b #x71))
              ((bitwise-ior) (list a b #x72))
              ((bitwise-xor) (list a b #x73))
              ((bitwise-arithmetic-shift-right) (list a b #x75))
              ((bitwise-arithmetic-shift-left)
               ;; normalize to 31 signed bits: what boxing keeps
               (list a b #x74 (i32const 1) #x74 (i32const 1) #x75))
              ((remainder) (list a b #x6F))
              ((quotient) (list a b #x6D)))))))
   (else (list (compile-exp e locals cell #f) (unwrap-int)))))

;; the prims that route through the context whatever their
;; arguments: raw in, one box out -- a chain of them keeps its
;; intermediates on the wasm stack
(define i32-context-prims
  '(bitwise-and bitwise-ior bitwise-xor
    bitwise-arithmetic-shift-left bitwise-arithmetic-shift-right))
(define (compile-i32-prim op args locals cell)
  (let ((expect (assq op prim-arity)))
    (unless (= (length args) (cdr expect))
      (errorf 'goeteia "wrong argument count for primitive ~s" op)))
  (let* ((a (compile-i32 (car args) locals cell))
         (b (compile-i32 (cadr args) locals cell)))
    (list a b
          (case op
            ((bitwise-and) #x71)
            ((bitwise-ior) #x72)
            ((bitwise-xor) #x73)
            ((bitwise-arithmetic-shift-left)
             (list #x74 (i32const 1) #x74 (i32const 1) #x75))
            (else #x75))
          (wrap-int))))

(define (compile-f64 e locals cell)
  (define (direct rop)
    (case rop
      ((fl+ fl- fl* fl/)
       (let* ((a (compile-f64 (cadr e) locals cell))
              (b (compile-f64 (caddr e) locals cell)))
         (list a b (case rop ((fl+) #xA0) ((fl-) #xA1)
                     ((fl*) #xA2) (else #xA3)))))
      ((flsqrt flfloor fltruncate)
       (list (compile-f64 (cadr e) locals cell)
             (case rop ((flsqrt) #x9F) ((flfloor) #x9C) (else #x9D))))
      ((fixnum->flonum)
       (list (compile-exp (cadr e) locals cell #f) (unwrap-int) #xB7))
      ((%mem-f64-ref)
       (list (compile-exp (cadr e) locals cell #f) (unwrap-int)
             #x2B (uleb 3) (uleb 0)))
      ((%mem-f32-ref)
       (list (compile-exp (cadr e) locals cell #f) (unwrap-int)
             #x2A (uleb 2) (uleb 0) #xBB))
      ((%f32x4-dot) (compile-f32x4-dot (cdr e) locals cell))))
  (cond
   ((and (number? e) (flonum? e)) (list #x44 (ieee-bytes e)))
   ((symbol? e)
    (let ((slot (assq e locals)))
      (if (and slot (memv (cdr slot) *f64-slots*))
          (local-get (cdr slot))               ; raw f64 slot, no unbox
          (list (compile-exp e locals cell #f) (unwrap-fl)))))
   ((pair? e)
    (let* ((h (car e))
           (rop (and (symbol? h) (unmark h))))
      ;; direct only when the head really is the primitive: not
      ;; lexically bound, not redefined at top level, arity right
      (cond
       ((and rop (memq rop fl-direct-ops)
             (not (assq h locals))
             (not (assq rop *fns*))
             (let ((a (assq rop prim-arity)))
               (and a (= (length (cdr e)) (cdr a)))))
        (direct rop))
       ;; an if with two flonum arms stays in the f64 context: the
       ;; wasm if blocks type f64 and neither branch boxes
       ((fl-if? e locals)
        (let* ((t (compile-test (cadr e) locals cell))
               (c (compile-f64 (caddr e) locals cell))
               (alt (compile-f64 (cadddr e) locals cell)))
          (list t #x04 T-F64 c #x05 alt #x0B)))
       (else (list (compile-exp e locals cell #f) (unwrap-fl))))))
   (else (list (compile-exp e locals cell #f) (unwrap-fl)))))

;; float primitives bypass the generic path so their arguments compile
;; in the f64 context (no intermediate boxing)
(define fl-context-prims
  '(fl+ fl- fl* fl/ fl=? fl<? flsqrt flfloor fltruncate
    fixnum->flonum %fl->fx %mem-f64-set! %mem-f32-set!
    %f32x4-scale! %f32x4-axpy! %f32x4-dot))
(define (compile-fl-prim op args locals cell)
  (let ((expect (assq op prim-arity)))
    (unless (= (length args) (cdr expect))
      (errorf 'goeteia "wrong argument count for primitive ~s" op)))
  (case op
    ((fl+ fl- fl* fl/)
     (let* ((a (compile-f64 (car args) locals cell))
            (b (compile-f64 (cadr args) locals cell)))
       (list a b (case op ((fl+) #xA0) ((fl-) #xA1) ((fl*) #xA2) (else #xA3))
             (struct-new TY-FLONUM))))
    ((fl=? fl<?)
     (let* ((a (compile-f64 (car args) locals cell))
            (b (compile-f64 (cadr args) locals cell)))
       (list a b (if (eq? op 'fl=?) #x61 #x63) (boolify))))
    ((flsqrt flfloor fltruncate)
     (list (compile-f64 (car args) locals cell)
           (case op ((flsqrt) #x9F) ((flfloor) #x9C) (else #x9D))
           (struct-new TY-FLONUM)))
    ((fixnum->flonum)
     (list (compile-exp (car args) locals cell #f) (unwrap-int) #xB7
           (struct-new TY-FLONUM)))
    ((%fl->fx)
     (list (compile-f64 (car args) locals cell) #xAA (wrap-int)))
    ((%f32x4-dot)
     (list (compile-f32x4-dot args locals cell)
           (struct-new TY-FLONUM)))
    ((%mem-f64-set!)
     (let* ((a (compile-exp (car args) locals cell #f))
            (v (compile-f64 (cadr args) locals cell)))
       (list a (unwrap-int) v #x39 (uleb 3) (uleb 0) (global-get G-VOID))))
    ((%mem-f32-set!)
     (let* ((a (compile-exp (car args) locals cell #f))
            (v (compile-f64 (cadr args) locals cell)))
       (list a (unwrap-int) v #xB6 #x38 (uleb 2) (uleb 0)
             (global-get G-VOID))))
    ;; ---- wasm SIMD, the scalar-mixing pair: the flonum argument
    ;; compiles in the f64 context, demotes, and splats to 4 lanes
    ((%f32x4-scale!)
     ;; (%f32x4-scale! dst a s): [dst] = [a] * splat(s)
     (let* ((d (compile-exp (car args) locals cell #f))
            (a (compile-exp (cadr args) locals cell #f))
            (s (compile-f64 (caddr args) locals cell)))
       (list d (unwrap-int)
             a (unwrap-int) #xFD (uleb 0) (uleb 0) (uleb 0)
             s #xB6 #xFD (uleb 19)                  ; f32x4.splat
             #xFD (uleb 230)                        ; f32x4.mul
             #xFD (uleb 11) (uleb 0) (uleb 0)       ; v128.store
             (global-get G-VOID))))
    ((%f32x4-axpy!)
     ;; (%f32x4-axpy! dst a b s): [dst] = [a] + [b] * splat(s) --
     ;; one column of a matrix product per call
     (let* ((d (compile-exp (car args) locals cell #f))
            (a (compile-exp (cadr args) locals cell #f))
            (b (compile-exp (caddr args) locals cell #f))
            (s (compile-f64 (cadddr args) locals cell)))
       (list d (unwrap-int)
             a (unwrap-int) #xFD (uleb 0) (uleb 0) (uleb 0)
             b (unwrap-int) #xFD (uleb 0) (uleb 0) (uleb 0)
             s #xB6 #xFD (uleb 19)
             #xFD (uleb 230)                        ; f32x4.mul
             #xFD (uleb 228)                        ; f32x4.add
             #xFD (uleb 11) (uleb 0) (uleb 0)
             (global-get G-VOID))))))

(define (compile-prim op args locals cell)
  (cond
   ((memq op fl-context-prims) (compile-fl-prim op args locals cell))
   ((memq op i32-context-prims) (compile-i32-prim op args locals cell))
   ;; provably-fixnum quotient/remainder skip the bignum dispatch
   ((and (memq op '(quotient remainder))
         (= (length args) 2)
         (i32-expr? (cons (if (eq? op 'quotient) 'quotient 'remainder)
                          args)
                    locals))
    (let* ((a (compile-i32 (car args) locals cell))
           (b (compile-i32 (cadr args) locals cell)))
      (list a b (if (eq? op 'quotient) #x6D #x6F) (wrap-int))))
   (else (compile-prim* op args locals cell))))

(define (compile-prim* op args locals cell)
  ;; arguments compile once, in source order
  (define argc (map-in-order (lambda (a) (compile-exp a locals cell #f)) args))
  (define (arg i) (list-ref argc i))
  ;; a silently dropped argument is a miscompile; check arities here
  (let ((expect (assq op prim-arity)))
    (when (and expect
               (not (memq op '(+ - *)))
               (not (= (length args) (cdr expect))))
      (errorf 'goeteia "wrong argument count for primitive ~s" op)))
  (case op
    ((+ - *)
     ;; n-ary as nested binary ops, each with a fixnum fast path and
     ;; a generic fallback (bignum promotion, flonum contagion)
     (cond
      ((and (eq? op '-) (= (length args) 1))
       (arith2 '- (emit-fixnum 0) (arg 0) cell))
      ((< (length args) 2)
       (errorf 'goeteia "primitive ~s needs two or more arguments" op))
      (else
       (let fold ((code (arg 0)) (i 1))
         (if (= i (length args))
             code
             (fold (arith2 op code (arg i) cell) (+ i 1)))))))
    ((quotient remainder)
     (arith2 op (arg 0) (arg 1) cell))
    ((= < zero? eq?) (list (pred-i32 op argc cell) (boolify)))
    ((cons) (list (arg 0) (arg 1) (struct-new TY-PAIR)))
    ((car) (list (arg 0) (ref-cast TY-PAIR) (struct-get TY-PAIR 0)))
    ((cdr) (list (arg 0) (ref-cast TY-PAIR) (struct-get TY-PAIR 1)))
    ((set-car!) (list (arg 0) (ref-cast TY-PAIR) (arg 1)
                      (struct-set TY-PAIR 0) (global-get G-VOID)))
    ((set-cdr!) (list (arg 0) (ref-cast TY-PAIR) (arg 1)
                      (struct-set TY-PAIR 1) (global-get G-VOID)))
    ((pair? null?) (list (pred-i32 op argc cell) (boolify)))
    ((fixnum? char?)
     ;; i31 with the right tag bit
     (let ((tmp (fresh-local! cell)))
       (list (arg 0) (local-set tmp)
             ;; abstract heap types are single-byte negative codes,
             ;; not sleb-encoded type indices
             (local-get tmp) (gc-op #x14 T-I31)
             #x04 T-I32
             (local-get tmp) (untag) (i32const 1) #x71 ; i32.and
             (if (eq? op 'fixnum?) OP-I32-EQZ '())
             #x05 (i32const 0) #x0B
             (boolify))))
    ((flonum?) (list (arg 0) (ref-test TY-FLONUM) (boolify)))
    ;; fl arithmetic, %fl->fx and %mem-f*-set! never reach here: they
    ;; dispatch to compile-fl-prim so arguments compile unboxed
    ((%bignum?) (list (arg 0) (ref-test TY-BIGNUM) (boolify)))
    ((%make-bignum)
     ;; (sign-fixnum limbs-vector)
     (list (arg 0) (unwrap-int) (arg 1) (ref-cast TY-VECTOR)
           (struct-new TY-BIGNUM)))
    ((%bignum-sign)
     (list (arg 0) (ref-cast TY-BIGNUM) (struct-get TY-BIGNUM 0) (wrap-int)))
    ((%bignum-limbs)
     (list (arg 0) (ref-cast TY-BIGNUM) (struct-get TY-BIGNUM 1)))
    ((%ratio?) (list (arg 0) (ref-test TY-RATIO) (boolify)))
    ((%make-ratio) (list (arg 0) (arg 1) (struct-new TY-RATIO)))
    ((%ratio-num) (list (arg 0) (ref-cast TY-RATIO) (struct-get TY-RATIO 0)))
    ((%ratio-den) (list (arg 0) (ref-cast TY-RATIO) (struct-get TY-RATIO 1)))
    ((%complex?) (list (arg 0) (ref-test TY-COMPLEX) (boolify)))
    ((%make-complex) (list (arg 0) (arg 1) (struct-new TY-COMPLEX)))
    ((%cx-re) (list (arg 0) (ref-cast TY-COMPLEX) (struct-get TY-COMPLEX 0)))
    ((%cx-im) (list (arg 0) (ref-cast TY-COMPLEX) (struct-get TY-COMPLEX 1)))
    ((%path-byte)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-PATH-BYTE) (global-get G-VOID)))
    ((%open-read) (list #x10 (uleb FN-OPEN-READ) (wrap-int)))
    ((%open-write) (list #x10 (uleb FN-OPEN-WRITE) (wrap-int)))
    ((%fread)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-FREAD) (wrap-int)))
    ((%fwrite)
     (list (arg 0) (unwrap-int) (arg 1) (unwrap-int)
           #x10 (uleb FN-FWRITE) (global-get G-VOID)))
    ((%fclose)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-FCLOSE) (global-get G-VOID)))
    ((%js-ref?) (list (arg 0) (ref-test TY-JSREF) (boolify)))
    ((%js-arg-byte)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-JS-ARG-BYTE)
           (global-get G-VOID)))
    ((%js-global)
     (list #x10 (uleb FN-JS-GLOBAL) (struct-new TY-JSREF)))
    ((%js-get)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-GET) (struct-new TY-JSREF)))
    ((%js-await)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-AWAIT) (struct-new TY-JSREF)))
    ((%js-set!)
     (list (arg 0) (unwrap-js) (arg 1) (unwrap-js)
           #x10 (uleb FN-JS-SET) (global-get G-VOID)))
    ((%js-push)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-PUSH) (global-get G-VOID)))
    ((%js-call)
     (list (arg 0) (unwrap-js) (arg 1) (unwrap-js)
           #x10 (uleb FN-JS-CALL) (struct-new TY-JSREF)))
    ((%js-new)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-NEW) (struct-new TY-JSREF)))
    ((%js-string)
     (list #x10 (uleb FN-JS-STRING) (struct-new TY-JSREF)))
    ((%js-str-len)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-STR-LEN) (wrap-int)))
    ((%js-str-byte)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-JS-STR-BYTE) (wrap-int)))
    ((%js-number)
     (list (arg 0) (unwrap-fl) #x10 (uleb FN-JS-NUMBER)
           (struct-new TY-JSREF)))
    ((%js-to-number)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-TO-NUMBER)
           (struct-new TY-FLONUM)))
    ((%js-eq)
     (list (arg 0) (unwrap-js) (arg 1) (unwrap-js)
           #x10 (uleb FN-JS-EQ) (boolify)))
    ((%js-bool)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-BOOL) (boolify)))
    ((%js-undefined)
     (list #x10 (uleb FN-JS-UNDEFINED) (struct-new TY-JSREF)))
    ((%js-fn)
     ;; the closure crosses as an opaque eqref; the host hands it
     ;; back through $jscb when the JS function is invoked
     (list (arg 0) #x10 (uleb FN-JS-FN) (struct-new TY-JSREF)))
    ((%js-cb-argc) (list #x10 (uleb FN-JS-CB-ARGC) (wrap-int)))
    ((%js-cb-arg)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-JS-CB-ARG)
           (struct-new TY-JSREF)))
    ((%js-cb-ret)
     (list (arg 0) (unwrap-js) #x10 (uleb FN-JS-CB-RET)
           (global-get G-VOID)))
    ((string? symbol? procedure?) (list (pred-i32 op argc cell) (boolify)))
    ((boolean?)
     (let ((tmp (fresh-local! cell)))
       (list (arg 0) (local-set tmp)
             (local-get tmp) (global-get G-TRUE) OP-REF-EQ
             (local-get tmp) (global-get G-FALSE) OP-REF-EQ
             #x72                       ; i32.or
             (boolify))))
    ((char->integer)
     ;; (c<<1)|1 -> c<<1: clear the tag bit
     (list (arg 0) (untag) (i32const -2) #x71 (gc-op #x1C)))
    ((integer->char)
     ;; n<<1 -> (n<<1)|1: set the tag bit
     (list (arg 0) (untag) (i32const 1) #x72 (gc-op #x1C)))
    ((string-length)
     (list (arg 0) (ref-cast TY-STRING) (gc-op #x0F) (wrap-int)))
    ((string-ref)
     (list (arg 0) (ref-cast TY-STRING)
           (arg 1) (unwrap-int)
           (gc-op #x0D (uleb TY-STRING)) ; array.get_u
           (i32const 1) #x74 (i32const 1) #x72 (gc-op #x1C)))
    ((symbol->string)
     (list (arg 0) (ref-cast TY-SYMBOL) (struct-get TY-SYMBOL 0)))
    ((string-set!)
     ;; (string-set! s i char)
     (list (arg 0) (ref-cast TY-STRING)
           (arg 1) (unwrap-int)
           (arg 2) (untag) (i32const 1) #x75          ; char code
           (gc-op #x0E (uleb TY-STRING))              ; array.set
           (global-get G-VOID)))
    ((eof-object) (global-get G-EOF))
    ((eof-object?) (list (pred-i32 op argc cell) (boolify)))
    ;; ---- the linear staging memory ----
    ;; a plain wasm memory, exported as "memory": Scheme writes bulk
    ;; numeric data here and the host reads it zero-copy as a typed
    ;; array (and vice versa). Addresses are byte offsets (fixnums);
    ;; i32 slots carry fixnum-range values.
    ((%mem-u8-ref)
     (list (arg 0) (unwrap-int) #x2D (uleb 0) (uleb 0) (wrap-int)))
    ((%mem-u8-set!)
     (list (arg 0) (unwrap-int) (arg 1) (unwrap-int)
           #x3A (uleb 0) (uleb 0) (global-get G-VOID)))
    ((%mem-i32-ref)
     (list (arg 0) (unwrap-int) #x28 (uleb 2) (uleb 0) (wrap-int)))
    ((%mem-i32-set!)
     (list (arg 0) (unwrap-int) (arg 1) (unwrap-int)
           #x36 (uleb 2) (uleb 0) (global-get G-VOID)))
    ((%mem-f32-ref)                                  ; load f32, promote, box
     (list (arg 0) (unwrap-int) #x2A (uleb 2) (uleb 0)
           #xBB (struct-new TY-FLONUM)))
    ((%mem-f64-ref)
     (list (arg 0) (unwrap-int) #x2B (uleb 3) (uleb 0)
           (struct-new TY-FLONUM)))
    ((%mem-size) (list #x3F #x00 (wrap-int)))        ; pages (64 KiB each)
    ((%mem-grow) (list (arg 0) (unwrap-int) #x40 #x00 (wrap-int)))
    ;; ---- wasm SIMD over staging memory: [dst] = [a] OP [b], four
    ;; f32 lanes per instruction.  The v128 lives only on the wasm
    ;; stack inside this one sequence, so no new types anywhere
    ((%f32x4-add! %f32x4-sub! %f32x4-mul!)
     (list (arg 0) (unwrap-int)
           (arg 1) (unwrap-int) #xFD (uleb 0) (uleb 0) (uleb 0)
           (arg 2) (unwrap-int) #xFD (uleb 0) (uleb 0) (uleb 0)
           #xFD (uleb (case op
                        ((%f32x4-add!) 228)          ; f32x4.add
                        ((%f32x4-sub!) 229)          ; f32x4.sub
                        (else 230)))                 ; f32x4.mul
           #xFD (uleb 11) (uleb 0) (uleb 0)          ; v128.store
           (global-get G-VOID)))
    ((bitwise-and bitwise-ior bitwise-xor)
     ;; the *2 fixnum tag passes through and/ior/xor unchanged
     (list (arg 0) (untag) (arg 1) (untag)
           (case op ((bitwise-and) #x71) ((bitwise-ior) #x72) (else #x73))
           (gc-op #x1C)))
    ((bitwise-arithmetic-shift-left)
     ;; (n<<1) << k = (n<<k) << 1
     (list (arg 0) (untag) (arg 1) (unwrap-int) #x74 (gc-op #x1C)))
    ((bitwise-arithmetic-shift-right)
     ;; ((n<<1) >> k) & -2 = (n>>k) << 1
     (list (arg 0) (untag) (arg 1) (unwrap-int) #x75
           (i32const -2) #x71 (gc-op #x1C)))
    ((vector?) (list (arg 0) (ref-test TY-VECTOR) (boolify)))
    ((%make-vector)
     ;; (fill n) on the stack; array.new
     (list (arg 1) (arg 0) (unwrap-int) (gc-op #x06 (uleb TY-VECTOR))))
    ((vector-length)
     (list (arg 0) (ref-cast TY-VECTOR) (gc-op #x0F) (wrap-int)))
    ((vector-ref)
     (list (arg 0) (ref-cast TY-VECTOR) (arg 1) (unwrap-int)
           (gc-op #x0B (uleb TY-VECTOR))))
    ((vector-set!)
     (list (arg 0) (ref-cast TY-VECTOR) (arg 1) (unwrap-int) (arg 2)
           (gc-op #x0E (uleb TY-VECTOR)) (global-get G-VOID)))
    ((bytevector?) (list (arg 0) (ref-test TY-BV) (boolify)))
    ((%make-bytevector)
     ;; (fill-byte n) -> fresh byte array wrapped in the bv struct
     (list (arg 1) (unwrap-int) (arg 0) (unwrap-int)
           (gc-op #x06 (uleb TY-STRING))
           (struct-new TY-BV)))
    ((bytevector-length)
     (list (arg 0) (ref-cast TY-BV) (struct-get TY-BV 0)
           (gc-op #x0F) (wrap-int)))
    ((bytevector-u8-ref)
     (list (arg 0) (ref-cast TY-BV) (struct-get TY-BV 0)
           (arg 1) (unwrap-int)
           (gc-op #x0D (uleb TY-STRING)) (wrap-int)))
    ((bytevector-u8-set!)
     (list (arg 0) (ref-cast TY-BV) (struct-get TY-BV 0)
           (arg 1) (unwrap-int) (arg 2) (unwrap-int)
           (gc-op #x0E (uleb TY-STRING)) (global-get G-VOID)))
    ((%record)
     ;; (%record rtd v ...): field count decides the struct type
     (list argc (struct-new (rec-ty (- (length args) 1)))))
    ((%recbase?) (list (arg 0) (ref-test TY-RECBASE) (boolify)))
    ((%record-rtd)
     (list (arg 0) (ref-cast TY-RECBASE) (struct-get TY-RECBASE 0)))
    ((%record?)
     ;; (%record? x rtd)
     (let ((tmp (fresh-local! cell)))
       (list (arg 0) (local-set tmp)
             (local-get tmp) (ref-test TY-RECBASE)
             #x04 T-I32
             (local-get tmp) (ref-cast TY-RECBASE) (struct-get TY-RECBASE 0)
             (arg 1) OP-REF-EQ
             #x05 (i32const 0) #x0B
             (boolify))))
    ((%record-ref)
     ;; (%record-ref x nfields index) with literal nfields/index
     (list (arg 0) (ref-cast (rec-ty (cadr args)))
           (struct-get (rec-ty (cadr args)) (+ (caddr args) 1))))
    ((%record-set!)
     ;; (%record-set! x nfields index v)
     (list (arg 0) (ref-cast (rec-ty (cadr args)))
           (arg 3)
           (struct-set (rec-ty (cadr args)) (+ (caddr args) 1))
           (global-get G-VOID)))
    ((%unreachable) (list #x00))
    ((%throw-k)
     ;; (token . value) is the exception payload; the instruction
     ;; never returns, so any result type is fine
     (list (arg 0) (arg 1) (struct-new TY-PAIR) #x08 (uleb 0)))
    ((%write-byte)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-WRITE-BYTE)
           (global-get G-VOID)))
    ((%read-byte)
     (list #x10 (uleb FN-READ-BYTE) (wrap-int)))
    ((%make-string)
     (list (arg 0) (unwrap-int) (gc-op #x07 (uleb TY-STRING)))) ; array.new_default
    ((%make-symbol)
     (list (arg 0) (ref-cast TY-STRING) (struct-new TY-SYMBOL)))
    ((%interned-symbols)
     (list #x10 (uleb *reg-fn*)))
    (else (errorf 'goeteia "unhandled primitive ~s" op))))

;;;; ------------------------------------------------------------------
;;;; top level

(define (define-form? f)
  (and (pair? f) (eq? (car f) 'define)))
(define (fn-define? f)
  (and (define-form? f) (pair? (cadr f))))
(define (var-define? f)
  (and (define-form? f) (symbol? (cadr f))))

;; every application or lambda arity might need a closure type
(define (scan-arities e acc)
  (if (pair? e)
      (case (car e)
        ((quote) acc)
        ((lambda)
         (scan-arities (cddr e)
                       (let ((a (length (formals-fixed (cadr e)))))
                         (if (memv a acc) acc (cons a acc)))))
        ((if begin set! define)
         (scan-arities (cdr e) acc))
        ((let)
         (scan-arities (map cadr (cadr e))
                       (scan-arities (cddr e) acc)))
        (else
         (let ((acc (if (list? e)
                        (let ((a (length (cdr e))))
                          (if (memv a acc) acc (cons a acc)))
                        acc)))
           (scan-arities (car e) (scan-arities (cdr e) acc)))))
      acc))

(define (scan-recs e acc)
  (let walk ((stack (cons e '())) (acc acc))
    (if (null? stack)
        acc
        (let ((e (car stack)) (stack (cdr stack)))
          (if (and (pair? e)
                   (not (eq? (resolve-tag (car e)) 'quote)))
              (walk (cons (car e) (cons (cdr e) stack))
                    (cond
                     ((and (eq? (resolve-tag (car e)) '%record) (list? e))
                      (let ((n (- (length (cdr e)) 1)))
                        (if (memv n acc) acc (cons n acc))))
                     ((and (memq (resolve-tag (car e))
                                 '(%record-ref %record-set!))
                           (list? e)
                           (integer? (caddr e)))
                      (let ((n (caddr e)))
                        (if (memv n acc) acc (cons n acc))))
                     (else acc)))
              (walk stack acc))))))

(define (compile-toplevel-fn form)
  ;; a variadic definition's rest parameter is its final wasm
  ;; parameter and receives a list
  (let* ((formals (cdadr form))
         (names (formals-names formals))
         (arity (length names))
         (cell (list arity))
         (locals (number-locals names 0))
         (saved *f64-slots*)
         (saved-loops *loops*)
         (saved-blocks *blocks*))
    (set! *f64-slots* '())
    (set! *loops* '())
    (set! *blocks* 0)
    (let* ((code (compile-body (cddr form) locals cell #t))
           (f64s *f64-slots*))
      (set! *f64-slots* saved)
      (set! *loops* saved-loops)
      (set! *blocks* saved-blocks)
      (list (cdr (assv arity *plain-ty*))
            arity
            (cons (- (car cell) arity) (cons f64s code))))))

(define T-F64 #x7C)
(define T-V128 #x7B)
(define (locals-decl n-params extra f64s)
  ;; run-length local groups from index n-params up, eqref except the
  ;; f64 slots (scanned by index, so order of collection is irrelevant)
  (if (zero? extra)
      (counted '())
      (let loop ((i n-params) (groups '()) (cur #f) (n 0))
        (define (flush)
          (if (> n 0) (cons (list (uleb n) cur) groups) groups))
        (if (= i (+ n-params extra))
            (counted (reverse (flush)))
            (let ((ty (cond ((memv i f64s) T-F64)
                            ((memv (- -1 i) f64s) T-V128)
                            ((memv (- -100000 i) f64s) #x7F)
                            (else T-EQREF))))
              (if (eqv? ty cur)
                  (loop (+ i 1) groups cur (+ n 1))
                  (loop (+ i 1) (flush) ty 1)))))))

(define (fn-code-entry n-params extra f64s code)
  (sized (list (locals-decl n-params extra f64s)
               code
               #x0B)))

;; expand each top-level form; a define-syntax produced by a macro is
;; collected, so macros can define macros
;; ---- source locations for error context ----
;; The drivers pass a loc string ("file:line") per top-level input
;; form; expansion tags every resulting form, and the per-function
;; compile wraps in $with-loc so an error names its source.  Locs
;; feed error messages only -- never the emitted bytes.

(define *form-locs* '())   ; expanded form (by identity) -> "file:line"

(define (record-loc! f loc)
  (when (and loc (pair? f))
    (set! *form-locs* (cons (cons f loc) *form-locs*))))
(define (form-loc f)
  (let ((e (assq f *form-locs*)))
    (and e (cdr e))))
(define ($with-loc loc thunk)
  (if loc
      (guard (e (#t (display "at ") (display loc) (newline) (raise e)))
        (thunk))
      (thunk)))

(define (expand-forms fs locs)
  (let loop ((fs fs) (ls locs) (acc '()))
    (if (null? fs)
        (reverse acc)
        (let ((loc (and (pair? ls) (car ls)))
              (rest (if (pair? ls) (cdr ls) '())))
          (if (macro-def? (car fs))     ; collected before this pass
              (loop (cdr fs) rest acc)
              (loop (cdr fs) rest
                    (expand-spliced
                     ($with-loc loc (lambda () (xpand (car fs))))
                     loc acc)))))))
(define (expand-spliced x loc acc)
  (cond
   ((and (pair? x) (symbol? (car x)) (eq? (unmark (car x)) 'begin))
    ;; top-level begin splices recursively (its subforms are already
    ;; expanded), so macros, define-record-type and libraries can nest
    ;; groups of defines
    (let splice ((subs (cdr x)) (acc acc))
      (if (null? subs)
          acc
          (splice (cdr subs) (expand-spliced (car subs) loc acc)))))
   ((macro-def? x) (add-macro! x) acc)
   (else
    (let ((nf (normalize-define x)))
      (record-loc! nf loc)
      (cons nf acc)))))
(define (normalize-define f)
  ;; top-level forms built by macros have marked heads
  (if (and (pair? f) (symbol? (car f)) (eq? (unmark (car f)) 'define))
      (cons 'define (cdr f))
      f))

;; ---- dead code elimination ----
;; The prelude is compiled into every module; keep only definitions
;; reachable from the program's expressions.  Any identifier occurring
;; outside quote counts as a reference (safe for macros, since this
;; runs after expansion).

(define (def-name f)
  (if (pair? (cadr f)) (car (cadr f)) (cadr f)))
(define (form-refs e acc)
  ;; worklist traversal: form spines outrun the wasm stack
  (let walk ((stack (cons e '())) (acc acc))
    (cond
     ((null? stack) acc)
     ((symbol? (car stack))
      ;; macro-introduced identifiers reference what they renamed
      (let ((u (unmark (car stack))))
        (walk (cdr stack) (if (memq u acc) acc (cons u acc)))))
     ((and (pair? (car stack))
           (not (eq? (resolve-tag (car (car stack))) 'quote)))
      (walk (cons (car (car stack))
                  (cons (cdr (car stack)) (cdr stack)))
            acc))
     (else (walk (cdr stack) acc)))))
(define (pure-init? e)
  (cond
   ((pair? e)
    (case (resolve-tag (car e))
      ((quote) #t)
      ((cons) (and (pure-init? (cadr e)) (pure-init? (caddr e))))
      (else #f)))
   ((symbol? e) #f)
   (else #t)))
(define (prune-dead forms extra-roots)
  (let ((table (fold-left (lambda (acc f)
                            (if (define-form? f)
                                (cons (cons (def-name f) f) acc)
                                acc))
                          ;; call/cc expands to code that calls the
                          ;; escape machinery behind the scenes, and
                          ;; arithmetic reaches the generic helpers
                          (list (cons 'call/cc '(begin $escape $winders))
                                (cons 'call-with-current-continuation
                                      '(begin $escape $winders))
                                (cons '+ '(begin $add2))
                                (cons '- '(begin $sub2))
                                (cons '* '(begin $mul2))
                                (cons 'quotient '(begin $quot2))
                                (cons 'remainder '(begin $rem2))
                                (cons '= '(begin $eq2))
                                (cons '< '(begin $lt2))
                                (cons 'zero? '(begin $eq2)))
                          forms)))
    (let grow ((live '())
               ;; roots: program expressions, exported names, plus the
               ;; initializers of top-level variables kept for their
               ;; side effects
               (queue (fold-left (lambda (acc f)
                                   (cond
                                    ((not (define-form? f)) (form-refs f acc))
                                    ((and (var-define? f)
                                          (pair? (cddr f))
                                          (not (pure-init? (caddr f))))
                                     (form-refs (caddr f) acc))
                                    (else acc)))
                                 extra-roots
                                 forms)))
      (cond
       ((null? queue)
        (filter (lambda (f)
                  (or (not (define-form? f))
                      (memq (def-name f) live)
                      ;; keep variables whose initializer has effects
                      (and (var-define? f)
                           (pair? (cddr f))
                           (not (pure-init? (caddr f))))))
                forms))
       ((memq (car queue) live) (grow live (cdr queue)))
       (else
        (let ((entry (assq (car queue) table)))
          (if entry
              (grow (cons (car queue) live)
                    (form-refs (cdr entry) (cdr queue)))
              (grow live (cdr queue)))))))))

;; ---- a conservative inliner ----
;; A small, once-defined, fixed-arity top-level function whose body
;; is a single binder-free expression inlines at its call sites as
;; (let ((param arg) ...) body): the let keeps arguments evaluated
;; once, in order, in the caller's scope, and codegen gives the
;; parameters plain locals -- the call disappears.  A site is left
;; alone whenever its lexical scope rebinds the callee's name or any
;; free name of the body, so nothing can be captured.  The transform
;; is a pure left-to-right tree walk: both hosts emit the same bytes.

(define $inline-cap 16)                 ; body size ceiling, in pairs

(define (fixed-formals? fs)
  (or (null? fs) (and (pair? fs) (fixed-formals? (cdr fs)))))

;; every (set! name ...) target, anywhere outside quote
(define (collect-set-names forms)
  (let walk ((stack (cons forms '())) (acc '()))
    (cond
     ((null? stack) acc)
     ((pair? (car stack))
      (let ((e (car stack)))
        (if (and (symbol? (car e)) (eq? (resolve-tag (car e)) 'quote))
            (walk (cdr stack) acc)
            (walk (cons (car e) (cons (cdr e) (cdr stack)))
                  (if (and (symbol? (car e))
                           (eq? (resolve-tag (car e)) 'set!)
                           (pair? (cdr e)) (symbol? (cadr e)))
                      (cons (cadr e) acc)
                      acc)))))
     (else (walk (cdr stack) acc)))))

;; symbols referenced by e, kept verbatim (marks and all): capture
;; is about exact identifiers, unlike DCE's unmarked liveness
(define (raw-refs e acc)
  (let walk ((stack (cons e '())) (acc acc))
    (cond
     ((null? stack) acc)
     ((symbol? (car stack))
      (walk (cdr stack)
            (if (memq (car stack) acc) acc (cons (car stack) acc))))
     ((and (pair? (car stack))
           (not (and (symbol? (car (car stack)))
                     (eq? (resolve-tag (car (car stack))) 'quote))))
      (walk (cons (car (car stack))
                  (cons (cdr (car stack)) (cdr stack)))
            acc))
     (else (walk (cdr stack) acc)))))

;; binder-free (params stay params at the new site), bounded size
(define (inlinable-body? e)
  (let walk ((stack (cons e '())) (n 0))
    (cond
     ((> n $inline-cap) #f)
     ((null? stack) #t)
     ((pair? (car stack))
      (let ((h (car (car stack))))
        (cond
         ((and (symbol? h) (eq? (resolve-tag h) 'quote))
          (walk (cdr stack) (+ n 1)))
         ((and (symbol? h)
               (memq (resolve-tag h)
                     '(lambda define set! let letrec letrec* %loop)))
          #f)
         (else (walk (cons (car (car stack))
                           (cons (cdr (car stack)) (cdr stack)))
                     (+ n 1))))))
     (else (walk (cdr stack) n)))))

;; name -> (name formals body frees)
(define (inline-candidates forms)
  (let ((set-names (collect-set-names forms))
        (counts '()))
    (for-each (lambda (f)
                (when (define-form? f)
                  (let* ((n (def-name f))
                         (e (assq n counts)))
                    (if e
                        (set-cdr! e (+ (cdr e) 1))
                        (set! counts (cons (cons n 1) counts))))))
              forms)
    (let scan ((fs forms) (acc '()))
      (if (null? fs)
          acc
          (let ((f (car fs)))
            (if (and (fn-define? f)
                     (fixed-formals? (cdadr f))
                     (pair? (cddr f)) (null? (cdddr f))
                     (= 1 (cdr (assq (def-name f) counts)))
                     (not (memq (def-name f) set-names))
                     (inlinable-body? (caddr f))
                     (not (memq (def-name f) (raw-refs (caddr f) '()))))
                (let* ((formals (cdadr f))
                       (frees (filter (lambda (n) (not (memq n formals)))
                                      (raw-refs (caddr f) '()))))
                  (scan (cdr fs)
                        (cons (list (def-name f) formals (caddr f) frees)
                              acc)))
                (scan (cdr fs) acc)))))))

;; map that returns the original list when nothing changed, so
;; untouched forms keep their identity (and their recorded locs)
(define (map-same f ls)
  (if (null? ls)
      ls
      (let* ((h (f (car ls)))
             (t (map-same f (cdr ls))))
        (if (and (eq? h (car ls)) (eq? t (cdr ls)))
            ls
            (cons h t)))))

(define ($inline-binding f scope cands)   ; one let binding (n v)
  (lambda (b)
    (let ((ni (inline-sites (cadr b) scope cands)))
      (if (eq? ni (cadr b)) b (list (car b) ni)))))

(define ($inline-app e scope cands)
  ;; rewrite the subforms, then the site itself
  (let* ((head (car e))
         (args (map-same (lambda (x) (inline-sites x scope cands)) (cdr e)))
         (nh (if (pair? head) (inline-sites head scope cands) head))
         (e2 (if (and (eq? args (cdr e)) (eq? nh head)) e (cons nh args))))
    (if (and (symbol? head) (not (memq head scope)))
        (let ((c (assq head cands)))
          (if (and c
                   (= (length args) (length (cadr c)))
                   (let overlap ((fs (cadddr c)))
                     (cond ((null? fs) #t)
                           ((memq (car fs) scope) #f)
                           (else (overlap (cdr fs))))))
              (if (null? (cadr c))
                  (caddr c)
                  (cons 'let (cons (map2* list (cadr c) (cdr e2))
                                   (list (caddr c)))))
              e2))
        e2)))

(define (inline-sites e scope cands)
  (if (not (pair? e))
      e
      (let ((h (car e)))
        (if (not (symbol? h))
            ($inline-app e scope cands)
            (case (resolve-tag h)
              ((quote) e)
              ((lambda)
               (let* ((scope2 (append (formals-names (cadr e)) scope))
                      (nb (map-same (lambda (x) (inline-sites x scope2 cands))
                                    (cddr e))))
                 (if (eq? nb (cddr e)) e (cons h (cons (cadr e) nb)))))
              ((let)
               (if (and (pair? (cdr e)) (symbol? (cadr e)))
                   (let* ((name (cadr e))          ; named let
                          (bs (caddr e))
                          (inits (map-same ($inline-binding e scope cands) bs))
                          (scope2 (cons name (append (map car bs) scope)))
                          (nb (map-same (lambda (x)
                                          (inline-sites x scope2 cands))
                                        (cdddr e))))
                     (if (and (eq? inits bs) (eq? nb (cdddr e)))
                         e
                         (cons h (cons name (cons inits nb)))))
                   (let* ((bs (cadr e))
                          (inits (map-same ($inline-binding e scope cands) bs))
                          (scope2 (append (map car bs) scope))
                          (nb (map-same (lambda (x)
                                          (inline-sites x scope2 cands))
                                        (cddr e))))
                     (if (and (eq? inits bs) (eq? nb (cddr e)))
                         e
                         (cons h (cons inits nb))))))
              ((define)
               (if (pair? (cadr e))
                   (let* ((scope2 (append (formals-names (cdadr e)) scope))
                          (nb (map-same (lambda (x)
                                          (inline-sites x scope2 cands))
                                        (cddr e))))
                     (if (eq? nb (cddr e)) e (cons h (cons (cadr e) nb))))
                   (if (pair? (cddr e))
                       (let ((ne (inline-sites (caddr e) scope cands)))
                         (if (eq? ne (caddr e)) e (list h (cadr e) ne)))
                       e)))
              ((set!)
               (let ((ne (inline-sites (caddr e) scope cands)))
                 (if (eq? ne (caddr e)) e (list h (cadr e) ne))))
              ((%loop)
               (let* ((name (cadr e))
                      (params (caddr e))
                      (inits (cadddr e))
                      (body (cdr (cdddr e)))
                      (scope2 (cons name (append params scope)))
                      (ninits (map-same (lambda (x)
                                          (inline-sites x scope cands))
                                        inits))
                      (nb (map-same (lambda (x)
                                      (inline-sites x scope2 cands))
                                    body)))
                 (if (and (eq? ninits inits) (eq? nb body))
                     e
                     (cons h (cons name (cons params (cons ninits nb)))))))
              (else ($inline-app e scope cands)))))))

(define (inline-forms forms)
  (let ((cands (inline-candidates forms)))
    (if (null? cands)
        forms
        (map-in-order
         (lambda (f)
           (let ((nf (inline-sites f '() cands)))
             (unless (eq? nf f) (record-loc! nf (form-loc f)))
             nf))
         forms))))

(define (compile-program forms locs)
  (set! *marks* '())
  (set! *renames* '())
  (set! *macros* '())
  (set! *form-locs* '())
  ;; collect explicit macro definitions first so they can be used
  ;; before their definition
  (for-each (lambda (f) (when (macro-def? f) (add-macro! f))) forms)
  (let* ((expanded (expand-forms forms locs))
         ;; top-level (export name ...): keep through DCE, expose as
         ;; wasm exports so the host can call them
         (export-names
          (fold-left (lambda (acc f)
                       (if (and (pair? f) (symbol? (car f))
                                (eq? (unmark (car f)) 'export))
                           (append acc (map (lambda (n) (unmark n)) (cdr f)))
                           acc))
                     '()
                     expanded))
         (forms (prune-dead
                 (map-in-order (lambda (f)
                                 (let ((nf (convert-assignments f)))
                                   (unless (eq? nf f)
                                     (record-loc! nf (form-loc f)))
                                   nf))
                     (filter (lambda (f)
                               (not (and (pair? f) (symbol? (car f))
                                         (eq? (unmark (car f)) 'export))))
                             (inline-forms expanded)))
                 export-names))
         (fn-defs (filter fn-define? forms))
         (var-defs (filter var-define? forms))
         (main-steps (map (lambda (f)
                            (if (var-define? f)
                                `(set! ,(cadr f) ,(caddr f))
                                f))
                          (filter (lambda (f) (not (fn-define? f))) forms))))
    (set! *fns* '())
    (set! *vars* '())
    (set! *plain-ty* '())
    (set! *clos-ty* '())
    (set! *rec-ty* '())
    (set! *lifted* '())
    (set! *wrappers* '())
    (set! *adapters* '())
    (set! *interned* '())
    ;; function index space: imports, top-level functions, main, lifted
    (set! *next-fn* (+ N-IMPORTS (length fn-defs) 1))
    (set! *reg-fn* (alloc-fn!))
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
    (set! *next-global* (+ G-FIRST-VAR (length var-defs)))
    ;; type table
    (let* ((plain-arities (sort-by self-id (fold-left
                                   (lambda (acc d)
                                     (let ((a (length (formals-names (cdadr d)))))
                                       (if (memv a acc) acc (cons a acc))))
                                   '(0)
                                   fn-defs)))
           (clos-arities (sort-by self-id (scan-arities forms '())))
           (rec-fields (sort-by self-id (scan-recs forms '())))
           (next (let number ((as plain-arities) (i TY-FIRST-FREE))
                   (if (null? as)
                       i
                       (begin
                         (set! *plain-ty* (cons (cons (car as) i) *plain-ty*))
                         (number (cdr as) (+ i 1)))))))
      (let number ((as clos-arities) (i next))
        (unless (null? as)
          (set! *clos-ty* (cons (cons (car as) (cons i (+ i 1))) *clos-ty*))
          (number (cdr as) (+ i 2))))
      (let number ((ns rec-fields)
                   (i (+ next (* 2 (length clos-arities)))))
        (unless (null? ns)
          (set! *rec-ty* (cons (cons (car ns) i) *rec-ty*))
          (number (cdr ns) (+ i 1))))
      (let* ((fn-entries (map-in-order
                          (lambda (d)
                            ;; loc plus the function's name: library
                            ;; forms splice, so their defines share
                            ;; the library's line -- the name narrows
                            ($with-loc
                             (let ((l (form-loc d)))
                               (and l (string-append
                                       l " (" (symbol->string
                                               (unmark (def-name d))) ")")))
                             (lambda () (compile-toplevel-fn d))))
                          fn-defs))
             (main-entry
              (let ((cell (list 0)))
                (set! *f64-slots* '())
                (let* ((code (compile-body
                              (if (null? main-steps) '((begin)) main-steps)
                              '() cell #t))
                       (f64s *f64-slots*))
                  (set! *f64-slots* '())
                  (list (cdr (assv 0 *plain-ty*))
                        0
                        (cons (car cell) (cons f64s code))))))
             (reg-entry
              ;; the interned-symbol list, now that interning is done
              (record-fn!
               *reg-fn*
               (list (cdr (assv 0 *plain-ty*)) 0 0 '()
                     (fold-left (lambda (acc e)
                                  (if (eq? (caar e) 'sym)
                                      (list (global-get (cdr e)) acc
                                            (struct-new TY-PAIR))
                                      acc))
                                (global-get G-NULL)
                                *interned*))))
             (lifted (sort-by car *lifted*))
             (entries (append
                       (map (lambda (e)
                              (list (car e) (cadr e)
                                    (car (caddr e))       ; extra
                                    (cadr (caddr e))      ; f64 slots
                                    (cddr (caddr e))))    ; code
                            fn-entries)
                       (list (list (car main-entry) (cadr main-entry)
                                   (car (caddr main-entry))
                                   (cadr (caddr main-entry))
                                   (cddr (caddr main-entry))))
                       (map cdr lifted)))
             (declared (map car lifted)))
        (emit-module plain-arities clos-arities rec-fields
                     (length var-defs)
                     entries declared (+ N-IMPORTS (length fn-defs))
                     export-names)))))

(define (emit-module plain-arities clos-arities rec-fields n-vars entries declared main-idx export-names)
  (flatten
   (list
    #x00 #x61 #x73 #x6D  #x01 #x00 #x00 #x00
    ;; type section
    (section 1 (counted
                (append
                 (list
                  ;; $pair
                  (list #x5F (counted (list (list T-EQREF #x01)
                                            (list T-EQREF #x01))))
                  ;; $singleton
                  (list #x5F (counted (list (list T-I32 #x00))))
                  ;; $string
                  (list #x5E T-I8 #x01)
                  ;; $symbol
                  (list #x5F (counted (list (list #x64 (sleb TY-STRING) #x00))))
                  ;; rec { $fnG : (func (ref $closbase) eqref -> eqref)
                  ;;       $closbase : open (struct funcref (ref $fnG)) }
                  (list #x4E (uleb 2)
                        (list #x60
                              (counted (list (list #x64 (sleb TY-CLOSBASE))
                                             T-EQREF))
                              (counted (list T-EQREF)))
                        (list #x50 #x00
                              #x5F (counted
                                    (list (list T-FUNCREF #x00)
                                          (list #x64 (sleb TY-FNG) #x00)))))
                  ;; $closV: variadic closures, base plus environment
                  (list #x4F (counted (list (uleb TY-CLOSBASE)))
                        #x5F (counted
                              (list (list T-FUNCREF #x00)
                                    (list #x64 (sleb TY-FNG) #x00)
                                    (list T-EQREF #x00))))
                  ;; $iofn
                  (list #x60 (counted (list T-I32)) (counted '()))
                  ;; $ioin
                  (list #x60 (counted '()) (counted (list T-I32)))
                  ;; $ktag: the escape-continuation exception tag
                  (list #x60 (counted (list T-EQREF)) (counted '()))
                  ;; $vector
                  (list #x5E T-EQREF #x01)
                  ;; $bytevector: a mutable-field wrapper, structurally
                  ;; distinct from $symbol (whose field is immutable)
                  (list #x5F (counted (list (list #x64 (sleb TY-STRING) #x01))))
                  ;; $recbase: open supertype of all record types
                  (list #x50 #x00
                        #x5F (counted (list (list T-EQREF #x00))))
                  ;; $flonum
                  (list #x5F (counted (list (list #x7C #x00))))
                  ;; $bignum: sign flag and a vector of 14-bit limbs
                  (list #x5F (counted
                              (list (list T-I32 #x00)
                                    (list #x64 (sleb TY-VECTOR) #x00))))
                  ;; $ratio and $complex: structurally identical
                  ;; shapes canonicalize to one type, so the complex
                  ;; imaginary slot is mutable purely to tell them apart
                  (list #x5F (counted (list (list T-EQREF #x00)
                                            (list T-EQREF #x00))))
                  (list #x5F (counted (list (list T-EQREF #x00)
                                            (list T-EQREF #x01))))
                  ;; io types for file ports
                  (list #x60 (counted (list T-I32)) (counted (list T-I32)))
                  (list #x60 (counted (list T-I32 T-I32)) (counted '()))
                  ;; the JS bridge
                  (list #x5F (counted (list (list #x6F #x00)))) ; $jsref
                  (list #x60 (counted '()) (counted '(#x6F)))
                  (list #x60 (counted '(#x6F)) (counted '(#x6F)))
                  (list #x60 (counted '(#x6F #x6F)) (counted '(#x6F)))
                  (list #x60 (counted '(#x6F #x6F)) (counted '()))
                  (list #x60 (counted '(#x6F)) (counted '()))
                  (list #x60 (counted '(#x7C)) (counted '(#x6F)))
                  (list #x60 (counted '(#x6F)) (counted '(#x7C)))
                  (list #x60 (counted '(#x6F)) (counted (list T-I32)))
                  (list #x60 (counted '(#x6F #x6F)) (counted (list T-I32)))
                  (list #x60 (counted (list T-EQREF)) (counted '(#x6F)))
                  (list #x60 (counted (list T-I32)) (counted '(#x6F))))
                 ;; plain function types
                 (map (lambda (a)
                        (list #x60
                              (counted (repeat-n a T-EQREF))
                              (counted (list T-EQREF))))
                      plain-arities)
                 ;; per-arity closure rec groups, each closN <: closbase
                 (map (lambda (a)
                        (let ((tys (clos-ty a)))
                          (list #x4E (uleb 2)
                                (list #x60
                                      (counted
                                       (cons (list #x64 (sleb (cdr tys)))
                                             (repeat-n a T-EQREF)))
                                      (counted (list T-EQREF)))
                                (list #x4F (counted (list (uleb TY-CLOSBASE)))
                                      #x5F
                                      (counted
                                       (list (list #x64 (sleb (car tys)) #x00)
                                             (list #x64 (sleb TY-FNG) #x00)
                                             (list T-EQREF #x00)))))))
                      clos-arities)
                 ;; per-field-count record types: rtd slot + n fields
                 (map (lambda (n)
                        (list #x4F (counted (list (uleb TY-RECBASE)))
                              #x5F
                              (counted
                               (cons (list T-EQREF #x00)
                                     (repeat-n n (list T-EQREF #x01))))))
                      rec-fields))))
    ;; import section
    (section 2 (counted
                (list (list (name-bytes "io") (name-bytes "write_byte")
                            #x00 (uleb TY-IOFN))
                      (list (name-bytes "io") (name-bytes "read_byte")
                            #x00 (uleb TY-IOIN))
                      (list (name-bytes "io") (name-bytes "path_byte")
                            #x00 (uleb TY-IOFN))
                      (list (name-bytes "io") (name-bytes "open_read")
                            #x00 (uleb TY-IOIN))
                      (list (name-bytes "io") (name-bytes "open_write")
                            #x00 (uleb TY-IOIN))
                      (list (name-bytes "io") (name-bytes "fread")
                            #x00 (uleb TY-IOIN1))
                      (list (name-bytes "io") (name-bytes "fwrite")
                            #x00 (uleb TY-IOOUT2))
                      (list (name-bytes "io") (name-bytes "fclose")
                            #x00 (uleb TY-IOFN))
                      (list (name-bytes "js") (name-bytes "arg_byte")
                            #x00 (uleb TY-IOFN))
                      (list (name-bytes "js") (name-bytes "global")
                            #x00 (uleb TY-JEXT0))
                      (list (name-bytes "js") (name-bytes "get")
                            #x00 (uleb TY-JEXT1))
                      (list (name-bytes "js") (name-bytes "set")
                            #x00 (uleb TY-JSET2))
                      (list (name-bytes "js") (name-bytes "push")
                            #x00 (uleb TY-JPUSH))
                      (list (name-bytes "js") (name-bytes "call")
                            #x00 (uleb TY-JEXT2))
                      (list (name-bytes "js") (name-bytes "new")
                            #x00 (uleb TY-JEXT1))
                      (list (name-bytes "js") (name-bytes "string")
                            #x00 (uleb TY-JEXT0))
                      (list (name-bytes "js") (name-bytes "str_len")
                            #x00 (uleb TY-JI32))
                      (list (name-bytes "js") (name-bytes "str_byte")
                            #x00 (uleb TY-IOIN1))
                      (list (name-bytes "js") (name-bytes "number")
                            #x00 (uleb TY-JNUM))
                      (list (name-bytes "js") (name-bytes "to_number")
                            #x00 (uleb TY-JTONUM))
                      (list (name-bytes "js") (name-bytes "eq")
                            #x00 (uleb TY-JEQ))
                      (list (name-bytes "js") (name-bytes "bool")
                            #x00 (uleb TY-JI32))
                      (list (name-bytes "js") (name-bytes "undefined")
                            #x00 (uleb TY-JEXT0))
                      (list (name-bytes "js") (name-bytes "fn")
                            #x00 (uleb TY-JFN))
                      (list (name-bytes "js") (name-bytes "cb_argc")
                            #x00 (uleb TY-IOIN))
                      (list (name-bytes "js") (name-bytes "cb_arg")
                            #x00 (uleb TY-JARG))
                      (list (name-bytes "js") (name-bytes "cb_ret")
                            #x00 (uleb TY-JPUSH))
                      (list (name-bytes "js") (name-bytes "await")
                            #x00 (uleb TY-JEXT1)))))
    ;; function section
    (section 3 (counted (map (lambda (e) (uleb (car e))) entries)))
    ;; memory section: one unbounded memory, the staging buffer for
    ;; bulk numeric transfer (%mem-*); exported below as "memory"
    (section 5 (counted (list (list #x00 (uleb 1)))))
    ;; tag section: the escape-continuation tag
    (section 13 (counted (list (list #x00 (uleb TY-KTAG)))))
    ;; global section: singletons, variables, interned literals
    (section 6 (counted
                (append
                 (map (lambda (tag)
                        (list #x64 (sleb TY-SINGLETON) #x00
                              (i32const tag)
                              (struct-new TY-SINGLETON)
                              #x0B))
                      '(0 1 2 3 4))
                 (map (lambda (_)
                        (list T-EQREF #x01
                              #xD0 T-EQREF ; ref.null eq
                              #x0B))
                      (nums-below n-vars))
                 (map emit-interned
                      (sort-by cdr *interned*)))))
    ;; export section
    (section 7 (counted
                (append
                 (list (export-entry "main" #x00 main-idx)
                       (export-entry "memory" #x02 0)
                       (export-entry "false" #x03 G-FALSE)
                       (export-entry "true" #x03 G-TRUE)
                       (export-entry "null" #x03 G-NULL)
                       (export-entry "void" #x03 G-VOID))
                 (map (lambda (n)
                        (let ((f (assq n *fns*)))
                          (unless f
                            (errorf 'goeteia "exported name is not a function ~s" n))
                          (export-entry (symbol->string n) #x00 (cadr f))))
                      export-names))))
    ;; element section: functions referenced by ref.func
    (if (null? declared)
        '()
        (section 9 (counted
                    (list (list #x03 #x00
                                (counted (map uleb declared)))))))
    ;; code section
    (section 10 (counted
                 (map (lambda (e)
                        (fn-code-entry (cadr e) (caddr e) (cadddr e)
                                       (list-ref e 4)))
                      entries)))
    ;; name section (custom): top-level function names + main, so
    ;; stack traces and profilers read Scheme, not wasm-function[n]
    (section 0
             (list (name-bytes "name")
                   1                    ; the function-names subsection
                   (sized (counted
                           (append
                            (map (lambda (f)
                                   (list (uleb (cadr f))
                                         (name-bytes
                                          (symbol->string (car f)))))
                                 (sort-by cadr *fns*))
                            (list (list (uleb main-idx)
                                        (name-bytes "main")))))))))))

(define (emit-interned entry)
  ;; ((kind . datum) . global-idx) -> immutable global
  (let* ((kind (caar entry))
         (datum (cdar entry))
         (str (if (eq? kind 'sym) (symbol->string datum) datum))
         (bytes (map (lambda (c) (char->integer c)) (string->list str)))
         (build-string
          (list (map i32const bytes)
                (gc-op #x08 (uleb TY-STRING) (uleb (length bytes))))))
    (if (eq? kind 'sym)
        (list #x64 (sleb TY-SYMBOL) #x00
              build-string (struct-new TY-SYMBOL) #x0B)
        (list #x64 (sleb TY-STRING) #x00
              build-string #x0B))))

(define (name-bytes s)
  (let ((chars (string->list s)))
    (list (uleb (length chars)) (map (lambda (c) (char->integer c)) chars))))

(define (export-entry name kind idx)
  (list (name-bytes name) kind (uleb idx)))
