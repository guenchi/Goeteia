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

(import (chezscheme))

;;;; ------------------------------------------------------------------
;;;; byte trees

(define (flatten tree)
  (let walk ((x tree) (tail '()))
    (cond
     ((null? x) tail)
     ((pair? x) (walk (car x) (walk (cdr x) tail)))
     (else (cons x tail)))))

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
(define TY-FIRST-FREE 8)

;; imported functions come first in the function index space
(define FN-WRITE-BYTE 0)
(define N-IMPORTS 1)

;; singleton globals, in index order
(define G-FALSE 0)
(define G-TRUE 1)
(define G-NULL 2)
(define G-VOID 3)
(define G-FIRST-VAR 4)

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
(define (emit-fixnum n)
  (list (i32const (* n 2)) (gc-op #x1C)))          ; ref.i31
(define (emit-char c)
  (list (i32const (+ (* (char->integer c) 2) 1)) (gc-op #x1C)))
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
;;;; the expander: derived forms (non-hygienic until the macro
;;;; milestone).  Core forms after expansion: quote if let begin
;;;; lambda set! define, plus applications.

(define (xpand e)
  (if (pair? e)
      (case (car e)
        ((quote) e)
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
        (else (xpand* e)))
      e))
(define (xpand* es)
  (if (pair? es)
      (cons (xpand (car es)) (xpand* (cdr es)))
      es))
(define (xpand-cond clauses)
  (if (null? clauses)
      '(begin)
      (let ((c (car clauses)))
        (cond
         ((eq? (car c) 'else) (xpand `(begin . ,(cdr c))))
         ((null? (cdr c))
          (let ((t (gensym "t")))
            `(let ((,t ,(xpand (car c))))
               (if ,t ,t ,(xpand-cond (cdr clauses))))))
         (else `(if ,(xpand (car c))
                    ,(xpand `(begin . ,(cdr c)))
                    ,(xpand-cond (cdr clauses))))))))

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
      (case (car e)
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
    (case (car e)
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
              (body (avc* (cddr e) scope* assigned)))
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
            . ,(avc* (cddr e) scope* assigned))))
      (else (avc* e scope assigned))))
   (else e)))
(define (avc* es scope assigned)
  (if (pair? es)
      (cons (avc (car es) scope assigned) (avc* (cdr es) scope assigned))
      es))

(define (convert-assignments form)
  (let ((assigned (assigned-vars form '())))
    (if (and (pair? form) (eq? (car form) 'define) (pair? (cadr form)))
        (let* ((formals (cdadr form))
               (names (formals-names formals))
               (boxed (filter (lambda (p) (memq p assigned)) names))
               (scope (map (lambda (p) (cons p (and (memq p assigned) #t)))
                           names))
               (body (avc* (cddr form) scope assigned)))
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
(define *lifted* '())     ; fn index -> (type-idx n-params extra code)
(define *next-fn* 0)
(define *wrappers* '())   ; top-level fn name -> wrapper fn index
(define *adapters* '())   ; arity -> generic-entry adapter fn index
(define *interned* '())   ; (kind . datum) -> global index
(define *next-global* 0)

(define (alloc-fn!)
  (let ((i *next-fn*))
    (set! *next-fn* (+ i 1))
    i))
(define (record-fn! idx entry)
  (set! *lifted* (cons (cons idx entry) *lifted*)))

(define (clos-ty arity)
  (let ((e (assv arity *clos-ty*)))
    (unless e (errorf 'schwasm "missing closure type for arity ~s" arity))
    (cdr e)))

(define (intern! kind datum)
  (let find ((es *interned*))
    (cond
     ((null? es)
      (let ((g *next-global*))
        (set! *next-global* (+ g 1))
        (set! *interned* (cons (cons (cons kind datum) g) *interned*))
        g))
     ((and (eq? (caaar es) kind) (equal? (cdaar es) datum))
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

(define primitives
  '(+ - * quotient remainder = < eq? cons car cdr pair? null? zero?
    set-car! set-cdr! number? char? string? symbol? boolean? procedure?
    char->integer integer->char string-length string-ref symbol->string
    %write-byte))

(define (compile-exp e locals cell tail?)
  (cond
   ((and (integer? e) (exact? e)) (emit-fixnum e))
   ((boolean? e) (global-get (if e G-TRUE G-FALSE)))
   ((char? e) (emit-char e))
   ((string? e) (global-get (intern! 'str e)))
   ((symbol? e) (compile-ref e locals cell))
   ((pair? e)
    (case (car e)
      ((quote) (compile-datum (cadr e)))
      ((if) (compile-if e locals cell tail?))
      ((let) (compile-let e locals cell tail?))
      ((begin) (compile-body (cdr e) locals cell tail?))
      ((lambda) (compile-lambda (cadr e) (cddr e) locals cell))
      ((set!) (compile-global-set e locals cell))
      ((apply) (compile-apply e locals cell tail?))
      (else (compile-app e locals cell tail?))))
   (else (errorf 'schwasm "cannot compile ~s" e))))

(define (compile-ref e locals cell)
  (cond
   ((assq e locals) => (lambda (s) (local-get (cdr s))))
   ((assq e *vars*) => (lambda (v) (global-get (cdr v))))
   ((assq e *fns*) => (lambda (f) (compile-fn-value (car f) (cdr f))))
   (else (errorf 'schwasm "unbound variable ~s" e))))

;; walk an argument list held in local t, pushing n elements
(define (unpack-args t n)
  (map (lambda (_)
         (list (local-get t) (ref-cast TY-PAIR) (struct-get TY-PAIR 0)
               (local-get t) (ref-cast TY-PAIR) (struct-get TY-PAIR 1)
               (local-set t)))
       (iota n)))

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
                                  (iota nfixed))
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

(define (compile-datum d)
  (cond
   ((and (integer? d) (exact? d)) (emit-fixnum d))
   ((boolean? d) (global-get (if d G-TRUE G-FALSE)))
   ((char? d) (emit-char d))
   ((string? d) (global-get (intern! 'str d)))
   ((symbol? d) (global-get (intern! 'sym d)))
   ((null? d) (global-get G-NULL))
   ((pair? d) (list (compile-datum (car d))
                    (compile-datum (cdr d))
                    (struct-new TY-PAIR)))
   (else (errorf 'schwasm "unsupported datum ~s" d))))

(define (compile-if e locals cell tail?)
  (list (compile-exp (cadr e) locals cell #f)
        (truthy)
        #x04 T-EQREF
        (compile-exp (caddr e) locals cell tail?)
        #x05
        (if (null? (cdddr e))
            (global-get G-VOID)
            (compile-exp (cadddr e) locals cell tail?))
        #x0B))

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
   (else (list (compile-exp (car es) locals cell #f)
               OP-DROP
               (compile-body (cdr es) locals cell tail?)))))

(define (compile-global-set e locals cell)
  (let ((v (assq (cadr e) *vars*)))
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
  (let ((op (car e))
        (args (cdr e)))
    (cond
     ((and (symbol? op) (assq op locals))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ((and (symbol? op) (memq op primitives) (not (assq op *fns*)))
      (compile-prim op args locals cell))
     ((and (symbol? op) (assq op *fns*))
      (compile-direct (cdr (assq op *fns*)) e args locals cell tail?))
     ((and (symbol? op) (assq op *vars*))
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
          (list (map (lambda (a) (compile-exp a locals cell #f))
                     (list-head args nfixed))
                (arg-chain (list-tail args nfixed) (global-get G-NULL)
                           locals cell)
                (if tail? #x12 #x10)
                (uleb idx)))
        (begin
          (unless (= nfixed (length args))
            (errorf 'schwasm "wrong argument count in ~s" e))
          (list (map (lambda (a) (compile-exp a locals cell #f)) args)
                (if tail? #x12 #x10)
                (uleb idx))))))

(define (arg-chain args tail-code locals cell)
  (if (null? args)
      tail-code
      (list (compile-exp (car args) locals cell #f)
            (arg-chain (cdr args) tail-code locals cell)
            (struct-new TY-PAIR))))

(define (compile-indirect fcode args locals cell tail?)
  ;; dual dispatch: the fast arity-typed entry when the callee's
  ;; closure type matches this call's arity, the generic list-taking
  ;; entry otherwise (variadic callee or arity mismatch)
  (let* ((arity (length args))
         (tys (clos-ty arity))
         (tmp (fresh-local! cell)))
    (list fcode (local-set tmp)
          (local-get tmp) (ref-test (cdr tys))
          #x04 T-EQREF
          (local-get tmp) (ref-cast (cdr tys))
          (map (lambda (a) (compile-exp a locals cell #f)) args)
          (local-get tmp) (ref-cast (cdr tys)) (struct-get (cdr tys) 0)
          (if tail? #x15 #x14)
          (uleb (car tys))
          #x05
          (local-get tmp) (ref-cast TY-CLOSBASE)
          (arg-chain args (global-get G-NULL) locals cell)
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
    (let* ((leading (list-head args (- (length args) 1)))
           (final (car (list-tail args (- (length args) 1))))
           (tmp (fresh-local! cell)))
      (list (compile-exp f locals cell #f) (local-set tmp)
            (local-get tmp) (ref-cast TY-CLOSBASE)
            (arg-chain leading (compile-exp final locals cell #f) locals cell)
            (local-get tmp) (ref-cast TY-CLOSBASE) (struct-get TY-CLOSBASE 1)
            (if tail? #x15 #x14)
            (uleb TY-FNG)))))

(define (compile-prim op args locals cell)
  (define (arg i) (compile-exp (list-ref args i) locals cell #f))
  (case op
    ((+ - * quotient remainder)
     ;; fixnums carry a *2 tag; + and - preserve it directly
     (case op
       ((+) (list (arg 0) (untag) (arg 1) (untag) #x6A (gc-op #x1C)))
       ((-) (list (arg 0) (untag) (arg 1) (untag) #x6B (gc-op #x1C)))
       ((*) (list (arg 0) (unwrap-int) (arg 1) (untag) #x6C (gc-op #x1C)))
       ((quotient) (list (arg 0) (unwrap-int) (arg 1) (unwrap-int)
                         #x6D (wrap-int)))
       ((remainder) (list (arg 0) (untag) (arg 1) (untag)
                          #x6F (gc-op #x1C)))))
    ((= < )
     ;; tagged comparison is order-preserving
     (let ((ints (list (arg 0) (untag) (arg 1) (untag))))
       (case op
         ((=) (list ints #x46 (boolify)))
         ((<) (list ints #x48 (boolify))))))
    ((zero?) (list (arg 0) (untag) OP-I32-EQZ (boolify)))
    ((eq?) (list (arg 0) (arg 1) OP-REF-EQ (boolify)))
    ((cons) (list (arg 0) (arg 1) (struct-new TY-PAIR)))
    ((car) (list (arg 0) (ref-cast TY-PAIR) (struct-get TY-PAIR 0)))
    ((cdr) (list (arg 0) (ref-cast TY-PAIR) (struct-get TY-PAIR 1)))
    ((set-car!) (list (arg 0) (ref-cast TY-PAIR) (arg 1)
                      (struct-set TY-PAIR 0) (global-get G-VOID)))
    ((set-cdr!) (list (arg 0) (ref-cast TY-PAIR) (arg 1)
                      (struct-set TY-PAIR 1) (global-get G-VOID)))
    ((pair?) (list (arg 0) (ref-test TY-PAIR) (boolify)))
    ((null?) (list (arg 0) (global-get G-NULL) OP-REF-EQ (boolify)))
    ((number? char?)
     ;; i31 with the right tag bit
     (let ((tmp (fresh-local! cell)))
       (list (arg 0) (local-set tmp)
             ;; abstract heap types are single-byte negative codes,
             ;; not sleb-encoded type indices
             (local-get tmp) (gc-op #x14 T-I31)
             #x04 T-I32
             (local-get tmp) (untag) (i32const 1) #x71 ; i32.and
             (if (eq? op 'number?) OP-I32-EQZ '())
             #x05 (i32const 0) #x0B
             (boolify))))
    ((string?) (list (arg 0) (ref-test TY-STRING) (boolify)))
    ((symbol?) (list (arg 0) (ref-test TY-SYMBOL) (boolify)))
    ((procedure?) (list (arg 0) (ref-test TY-CLOSBASE) (boolify)))
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
    ((%write-byte)
     (list (arg 0) (unwrap-int) #x10 (uleb FN-WRITE-BYTE)
           (global-get G-VOID)))
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

(define (compile-program forms)
  (let* ((forms (map convert-assignments (map xpand forms)))
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
    (set! *lifted* '())
    (set! *wrappers* '())
    (set! *adapters* '())
    (set! *interned* '())
    ;; function index space: imports, top-level functions, main, lifted
    (set! *next-fn* (+ N-IMPORTS (length fn-defs) 1))
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
    (let* ((plain-arities (sort < (fold-left
                                   (lambda (acc d)
                                     (let ((a (length (formals-names (cdadr d)))))
                                       (if (memv a acc) acc (cons a acc))))
                                   '(0)
                                   fn-defs)))
           (clos-arities (sort < (scan-arities forms '())))
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
      (let* ((fn-entries (map compile-toplevel-fn fn-defs))
             (main-entry
              (let ((cell (list 0)))
                (list (cdr (assv 0 *plain-ty*))
                      0
                      (let ((code (compile-body
                                   (if (null? main-steps) '((begin)) main-steps)
                                   '() cell #t)))
                        (cons (car cell) code)))))
             (lifted (sort (lambda (a b) (< (car a) (car b))) *lifted*))
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
        (emit-module plain-arities clos-arities (length var-defs)
                     entries declared (+ N-IMPORTS (length fn-defs)))))))

(define (emit-module plain-arities clos-arities n-vars entries declared main-idx)
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
                  (list #x60 (counted (list T-I32)) (counted '())))
                 ;; plain function types
                 (map (lambda (a)
                        (list #x60
                              (counted (make-list a T-EQREF))
                              (counted (list T-EQREF))))
                      plain-arities)
                 ;; per-arity closure rec groups, each closN <: closbase
                 (map (lambda (a)
                        (let ((tys (clos-ty a)))
                          (list #x4E (uleb 2)
                                (list #x60
                                      (counted
                                       (cons (list #x64 (sleb (cdr tys)))
                                             (make-list a T-EQREF)))
                                      (counted (list T-EQREF)))
                                (list #x4F (counted (list (uleb TY-CLOSBASE)))
                                      #x5F
                                      (counted
                                       (list (list #x64 (sleb (car tys)) #x00)
                                             (list #x64 (sleb TY-FNG) #x00)
                                             (list T-EQREF #x00)))))))
                      clos-arities))))
    ;; import section: io.write_byte
    (section 2 (counted
                (list (list (name-bytes "io") (name-bytes "write_byte")
                            #x00 (uleb TY-IOFN)))))
    ;; function section
    (section 3 (counted (map (lambda (e) (uleb (car e))) entries)))
    ;; global section: singletons, variables, interned literals
    (section 6 (counted
                (append
                 (map (lambda (tag)
                        (list #x64 (sleb TY-SINGLETON) #x00
                              (i32const tag)
                              (struct-new TY-SINGLETON)
                              #x0B))
                      '(0 1 2 3))
                 (map (lambda (_)
                        (list T-EQREF #x01
                              #xD0 T-EQREF ; ref.null eq
                              #x0B))
                      (iota n-vars))
                 (map emit-interned
                      (sort (lambda (a b) (< (cdr a) (cdr b))) *interned*)))))
    ;; export section
    (section 7 (counted
                (list (export-entry "main" #x00 main-idx)
                      (export-entry "false" #x03 G-FALSE)
                      (export-entry "true" #x03 G-TRUE)
                      (export-entry "null" #x03 G-NULL)
                      (export-entry "void" #x03 G-VOID))))
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
         (bytes (map char->integer (string->list str)))
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
    (list (uleb (length chars)) (map char->integer chars))))

(define (export-entry name kind idx)
  (list (name-bytes name) kind (uleb idx)))

;;;; ------------------------------------------------------------------
;;;; driver

(define (read-forms port)
  (let ((form (read port)))
    (if (eof-object? form)
        '()
        (cons form (read-forms port)))))

(define (load-prelude user-forms)
  ;; the prelude lives next to this script; user definitions override
  ;; same-named prelude definitions
  (let* ((here (path-parent (car (command-line))))
         (file (string-append here "/prelude.ss"))
         (forms (call-with-input-file file read-forms))
         (user-names (fold-left (lambda (acc f)
                                  (if (fn-define? f)
                                      (cons (car (cadr f)) acc)
                                      acc))
                                '()
                                user-forms)))
    (filter (lambda (f)
              (not (and (fn-define? f)
                        (memq (car (cadr f)) user-names))))
            forms)))

(define (compile-file in out)
  (let* ((user (call-with-input-file in read-forms))
         (forms (append (load-prelude user) user))
         (bytes (compile-program forms)))
    (when (file-exists? out) (delete-file out))
    (call-with-port (open-file-output-port out)
      (lambda (p) (put-bytevector p (u8-list->bytevector bytes))))))

(let ((args (cdr (command-line))))
  (if (or (null? args) (null? (cdr args)))
      (begin (display "usage: schwasmc <input.ss> <output.wasm>\n")
             (exit 1))
      (compile-file (car args) (cadr args))))
