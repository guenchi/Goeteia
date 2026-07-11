;; schwasm — a Scheme to WebAssembly-GC compiler.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
;;
;; Milestone 3: strings (GC byte arrays), interned symbols,
;; characters, type predicates, and I/O through a single host import
;; (io.write_byte).  The runtime library (display, string=?, ...) is
;; written in schwasm's own Scheme (src/prelude.ss) and compiled into
;; every module.
;;
;; A program is a sequence of top-level defines and expressions; the
;; expressions run in order and the last one's value is the result,
;; exported as `main`.

;; The compiler is written in the subset of Scheme that schwasm
;; itself compiles, so it can compile itself.  Under the Chez host,
;; src/chez-driver.ss loads this file; under the self-hosted build,
;; src/wasm-driver.ss is appended and the whole thing is compiled to
;; wasm.

;;;; ------------------------------------------------------------------
;;;; portable helpers (schwasm has these in the prelude; the names
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
  (if (null? l1)
      '()
      (cons (f (car l1) (car l2)) (map2* f (cdr l1) (cdr l2)))))
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
(define TY-FIRST-FREE 19)

;; imported functions come first in the function index space
(define FN-WRITE-BYTE 0)
(define FN-READ-BYTE 1)
(define FN-PATH-BYTE 2)     ; push a path byte to the host
(define FN-OPEN-READ 3)     ; open accumulated path; fd or -1
(define FN-OPEN-WRITE 4)
(define FN-FREAD 5)         ; (fd) -> byte or -1
(define FN-FWRITE 6)        ; (fd byte)
(define FN-FCLOSE 7)
(define N-IMPORTS 8)

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
             (let ((name (cadr e)) (bs (caddr e)) (body (cdddr e)))
               (xpand `((letrec ((,name (lambda ,(map car bs) . ,body)))
                          ,name)
                        . ,(map cadr bs))))
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
         ;; libraries splice their definitions; exports are advisory
         ;; (dead code elimination prunes what goes unused) and the
         ;; driver has already inlined the imports
         (cons 'begin
               (xpand* (filter (lambda (f)
                                 (not (and (pair? f)
                                           (memq (resolve-tag (car f))
                                                 '(export import)))))
                               (cddr e)))))
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
   (else (errorf 'schwasm "bad field spec ~s" fs))))

;; case compiles to eq? chains; fixnums, characters, symbols and
;; booleans are all eq-comparable in schwasm
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
    string-append string=? free-identifier=? bound-identifier=?
    syntax->datum datum->syntax generate-temporaries void))
(define (base-meta-env)
  (map (lambda (n) (cons n (cons mv-prim n))) meta-prims))

(define (make-transformer spec)
  (let ((v (meta-eval spec (base-meta-env))))
    (unless (mv? mv-closure v)
      (errorf 'schwasm "transformer is not a procedure: ~s" spec))
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
             (errorf 'schwasm "set! of unbound ~s in transformer" (cadr e)))
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
                  (errorf 'schwasm "pattern variable ~s at wrong depth" name))
              v))
        (let ((o (marked-origin name)))
          (if o
              (meta-ref o env)
              (errorf 'schwasm "unbound ~s in transformer" name))))))
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
            (errorf 'schwasm "too few arguments in transformer call"))
          (bind (cdr ps) (cdr as) (cons (cons (car ps) (car as)) env)))
         (rest (meta-seq body (cons (cons rest as) env)))
         ((null? as) (meta-seq body env))
         (else (errorf 'schwasm "too many arguments in transformer call"))))))
   ((mv? mv-prim f) (meta-prim-apply (cdr f) args))
   (else (errorf 'schwasm "transformer applied a non-procedure"))))

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
    ((map) (if (pair? (cddr args))
               (map2* (lambda (x y) (meta-apply (a) (list x y)))
                      (b) (caddr args))
               (map (lambda (x) (meta-apply (a) (list x))) (b))))
    ((error) (errorf 'macro-transformer "~s" args))
    ((gensym) (gensym (if (and (pair? args) (string? (a))) (a) "g")))
    ((string->symbol) (string->symbol (a)))
    ((symbol->string) (symbol->string (unmark (a))))
    ((string-append) (fold-left string-append "" args))
    ((string=?) (string=? (a) (b)))
    ((free-identifier=?) (eq? (unmark (a)) (unmark (b))))
    ((bound-identifier=?) (eq? (a) (b)))
    ((syntax->datum) (strip-marks (a)))
    ((datum->syntax) (b))
    ((generate-temporaries) (map (lambda (x) (gensym "t")) (a)))
    ((void) (void))
    (else (errorf 'schwasm "unhandled transformer primitive ~s" name))))

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
                                (errorf 'schwasm "missing pattern variable ~s"
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
          (errorf 'schwasm "no matching syntax-case clause for ~s" v)
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
            (errorf 'schwasm "with-syntax pattern mismatch: ~s" (caar bs)))
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
                (errorf 'schwasm "too few ellipses after ~s" tmpl)))
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
      (errorf 'schwasm "no pattern variables under ellipsis in template"))
    (let ((n (length (pvar-value (cdar vars)))))
      (unless (all-true? (lambda (v) (= (length (pvar-value (cdr v))) n)) vars)
        (errorf 'schwasm "mismatched ellipsis counts in template"))
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
(define *lifted* '())     ; fn index -> (type-idx n-params extra code)
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
    (errorf 'schwasm "duplicate function index ~s" idx))
  (set! *lifted* (cons (cons idx entry) *lifted*)))

(define (clos-ty arity)
  (let ((e (assv arity *clos-ty*)))
    (unless e (errorf 'schwasm "missing closure type for arity ~s" arity))
    (cdr e)))
(define (rec-ty nfields)
  (let ((e (assv nfields *rec-ty*)))
    (unless e (errorf 'schwasm "missing record type for ~s fields" nfields))
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
    (%write-byte . 1)))

(define primitives
  '(+ - * quotient remainder = < eq? cons car cdr pair? null? zero?
    set-car! set-cdr! fixnum? char? string? symbol? boolean? procedure?
    flonum? fl+ fl- fl* fl/ fl=? fl<? flsqrt flfloor fltruncate
    fixnum->flonum %fl->fx
    %bignum? %make-bignum %bignum-sign %bignum-limbs
    %ratio? %make-ratio %ratio-num %ratio-den
    %complex? %make-complex %cx-re %cx-im
    %path-byte %open-read %open-write %fread %fwrite %fclose
    char->integer integer->char string-length string-ref symbol->string
    string-set! eof-object eof-object?
    bitwise-and bitwise-ior bitwise-xor
    bitwise-arithmetic-shift-left bitwise-arithmetic-shift-right
    vector? vector-length vector-ref vector-set!
    bytevector? bytevector-length bytevector-u8-ref bytevector-u8-set!
    %make-vector %make-bytevector
    %record %record? %record-ref %record-set! %recbase? %record-rtd
    %write-byte %read-byte %make-string %make-symbol %interned-symbols
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
      ((begin) (compile-body (cdr e) locals cell tail?))
      ((lambda) (compile-lambda (cadr e) (cddr e) locals cell))
      ((set!) (compile-global-set e locals cell))
      ((apply) (compile-apply e locals cell tail?))
      ((call/cc call-with-current-continuation)
       (compile-callcc e locals cell))
      (else (compile-app e locals cell tail?))))
   (else (errorf 'schwasm "cannot compile ~s" e))))

(define (compile-ref e locals cell)
  ;; lexical bindings are found by identity; unbound marked
  ;; identifiers resolve like the identifier they renamed
  (let ((slot (assq e locals)))
    (if slot
        (local-get (cdr slot))
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
                          (errorf 'schwasm "unbound variable ~s" e))))))))))

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
           (list TY-FNG 2 1
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
                 (list TY-FNG 2 1
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
                 (list (car tys) (+ nfixed 1) 0
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
    ;; arithmetic (works on host bignums under Chez and on schwasm
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
   (else (errorf 'schwasm "unsupported datum ~s" d))))

(define (compile-if e locals cell tail?)
  ;; compile in source order: codegen effects (function indices,
  ;; interned literals) must not depend on the host's argument
  ;; evaluation order
  (let* ((t (compile-test (cadr e) locals cell))
         (c (compile-exp (caddr e) locals cell tail?))
         (a (if (null? (cdddr e))
                (global-get G-VOID)
                (compile-exp (cadddr e) locals cell tail?))))
    (list t #x04 T-EQREF c #x05 a #x0B)))
;; a test position wants an i32; predicates skip the boolean
;; boxing/unboxing round trip
(define (compile-test e locals cell)
  (if (and (pair? e)
           (symbol? (car e))
           (memq (unmark (car e)) i32-predicates)
           (let ((expect (assq (unmark (car e)) prim-arity)))
             (and expect (= (length (cdr e)) (cdr expect))))
           (not (assq (car e) locals))
           (not (assq (unmark (car e)) *fns*)))
      (pred-i32 (unmark (car e))
                (map-in-order (lambda (a) (compile-exp a locals cell #f))
                              (cdr e))
                cell)
      (list (compile-exp e locals cell #f) (truthy))))

(define (compile-let e locals cell tail?)
  (let loop ((bs (cadr e)) (code '()) (scope locals))
    (if (null? bs)
        (list (reverse code)
              (compile-body (cddr e) scope cell tail?))
        (let* ((b (car bs))
               (slot (fresh-local! cell)))
          (loop (cdr bs)
                (cons (list (compile-exp (cadr b) locals cell #f)
                            (local-set slot))
                      code)
                (cons (cons (car b) slot) scope))))))

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
    (unless v (errorf 'schwasm "set! of unbound variable ~s" (cadr e)))
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
         (code (list prologue (compile-body body locals cell #t))))
    (record-fn! idx (list (car tys) (+ arity 1)
                          (- (car cell) (+ arity 1)) code))))

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
         (code (list prologue (compile-body body locals cell #t))))
    (record-fn! idx (list TY-FNG 2 (- (car cell) 2) code))))

;;; applications

(define (compile-app e locals cell tail?)
  (let* ((op (car e))
         (args (cdr e))
         (rop (and (symbol? op) (unmark op))))
    (cond
     ((and (symbol? op) (assq op locals))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ((and rop (memq rop primitives) (not (assq rop *fns*)))
      (compile-prim rop args locals cell))
     ((and rop (assq rop *fns*))
      (compile-direct (cdr (assq rop *fns*)) e args locals cell tail?))
     ((and rop (assq rop *vars*))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ((pair? op)
      (compile-indirect (compile-exp op locals cell #f) args locals cell tail?))
     (else (errorf 'schwasm "cannot call ~s" op)))))

(define (compile-direct entry e args locals cell tail?)
  (let ((idx (car entry))
        (nfixed (cadr entry))
        (variadic? (caddr entry)))
    (if variadic?
        ;; extra arguments are consed into the rest list at the call
        (let ((n (length args)))
          (when (< n nfixed)
            (errorf 'schwasm "too few arguments in ~s" e))
          (let* ((fixed (map-in-order (lambda (a) (compile-exp a locals cell #f))
                                      (first-n args nfixed)))
                 (extras (arg-chain (list-tail args nfixed)
                                    (global-get G-NULL) locals cell)))
            (list fixed extras (if tail? #x12 #x10) (uleb idx))))
        (begin
          (unless (= nfixed (length args))
            (errorf 'schwasm "wrong argument count in ~s" e))
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
      (errorf 'schwasm "apply needs an argument list in ~s" e))
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
    (unless f (errorf 'schwasm "missing generic helper ~s" name))
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

(define (compile-prim op args locals cell)
  ;; arguments compile once, in source order
  (define argc (map-in-order (lambda (a) (compile-exp a locals cell #f)) args))
  (define (arg i) (list-ref argc i))
  ;; a silently dropped argument is a miscompile; check arities here
  (let ((expect (assq op prim-arity)))
    (when (and expect
               (not (memq op '(+ - *)))
               (not (= (length args) (cdr expect))))
      (errorf 'schwasm "wrong argument count for primitive ~s" op)))
  (case op
    ((+ - *)
     ;; n-ary as nested binary ops, each with a fixnum fast path and
     ;; a generic fallback (bignum promotion, flonum contagion)
     (cond
      ((and (eq? op '-) (= (length args) 1))
       (arith2 '- (emit-fixnum 0) (arg 0) cell))
      ((< (length args) 2)
       (errorf 'schwasm "primitive ~s needs two or more arguments" op))
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
    ((fl+ fl- fl* fl/)
     (list (arg 0) (unwrap-fl) (arg 1) (unwrap-fl)
           (case op ((fl+) #xA0) ((fl-) #xA1) ((fl*) #xA2) (else #xA3))
           (struct-new TY-FLONUM)))
    ((fl=? fl<?)
     (list (arg 0) (unwrap-fl) (arg 1) (unwrap-fl)
           (if (eq? op 'fl=?) #x61 #x63)
           (boolify)))
    ((flsqrt flfloor fltruncate)
     (list (arg 0) (unwrap-fl)
           (case op ((flsqrt) #x9F) ((flfloor) #x9C) (else #x9D))
           (struct-new TY-FLONUM)))
    ((fixnum->flonum)
     (list (arg 0) (unwrap-int) #xB7 (struct-new TY-FLONUM)))
    ((%fl->fx)
     (list (arg 0) (unwrap-fl) #xAA (wrap-int)))
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
    (else (errorf 'schwasm "unhandled primitive ~s" op))))

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
         (locals (number-locals names 0)))
    (list (cdr (assv arity *plain-ty*))
          arity
          (let ((code (compile-body (cddr form) locals cell #t)))
            (cons (- (car cell) arity) code)))))

(define (fn-code-entry n-params extra code)
  (sized (list (if (zero? extra)
                   (counted '())
                   (counted (list (list (uleb extra) T-EQREF))))
               code
               #x0B)))

;; expand each top-level form; a define-syntax produced by a macro is
;; collected, so macros can define macros
(define (expand-forms fs)
  (let loop ((fs fs) (acc '()))
    (if (null? fs)
        (reverse acc)
        (loop (cdr fs) (expand-spliced (xpand (car fs)) acc)))))
(define (expand-spliced x acc)
  (cond
   ((and (pair? x) (symbol? (car x)) (eq? (unmark (car x)) 'begin))
    ;; top-level begin splices (its subforms are already expanded),
    ;; so macros and define-record-type can produce several defines
    (let splice ((subs (cdr x)) (acc acc))
      (if (null? subs)
          acc
          (let ((sub (car subs)))
            (if (macro-def? sub)
                (begin (add-macro! sub) (splice (cdr subs) acc))
                (splice (cdr subs) (cons (normalize-define sub) acc)))))))
   ((macro-def? x) (add-macro! x) acc)
   (else (cons (normalize-define x) acc))))
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

(define (compile-program forms)
  (set! *marks* '())
  (set! *renames* '())
  (set! *macros* '())
  ;; collect explicit macro definitions first so they can be used
  ;; before their definition
  (for-each (lambda (f) (when (macro-def? f) (add-macro! f))) forms)
  (let* ((expanded (expand-forms
                    (filter (lambda (f) (not (macro-def? f))) forms)))
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
                 (map-in-order convert-assignments
                     (filter (lambda (f)
                               (not (and (pair? f) (symbol? (car f))
                                         (eq? (unmark (car f)) 'export))))
                             expanded))
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
      (let* ((fn-entries (map-in-order compile-toplevel-fn fn-defs))
             (main-entry
              (let ((cell (list 0)))
                (list (cdr (assv 0 *plain-ty*))
                      0
                      (let ((code (compile-body
                                   (if (null? main-steps) '((begin)) main-steps)
                                   '() cell #t)))
                        (cons (car cell) code)))))
             (reg-entry
              ;; the interned-symbol list, now that interning is done
              (record-fn!
               *reg-fn*
               (list (cdr (assv 0 *plain-ty*)) 0 0
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
                                    (car (caddr e)) (cdr (caddr e))))
                            fn-entries)
                       (list (list (car main-entry) (cadr main-entry)
                                   (car (caddr main-entry))
                                   (cdr (caddr main-entry))))
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
                  (list #x60 (counted (list T-I32 T-I32)) (counted '())))
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
                            #x00 (uleb TY-IOFN)))))
    ;; function section
    (section 3 (counted (map (lambda (e) (uleb (car e))) entries)))
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
                       (export-entry "false" #x03 G-FALSE)
                       (export-entry "true" #x03 G-TRUE)
                       (export-entry "null" #x03 G-NULL)
                       (export-entry "void" #x03 G-VOID))
                 (map (lambda (n)
                        (let ((f (assq n *fns*)))
                          (unless f
                            (errorf 'schwasm "exported name is not a function ~s" n))
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
                        (fn-code-entry (cadr e) (caddr e) (cadddr e)))
                      entries))))))

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
