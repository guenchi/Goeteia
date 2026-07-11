;; schwasm — a Scheme to WebAssembly-GC compiler.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
;;
;; Milestone 2: closures (typed function references, call_ref), set!
;; with assignment conversion, top-level variables, and the derived
;; forms and/or/not/when/unless/cond/let*/letrec/named-let/do.
;;
;; A program is a sequence of top-level defines and expressions; the
;; expressions run in order and the last one's value is the result,
;; exported as `main`.

(import (chezscheme))

;;;; ------------------------------------------------------------------
;;;; byte trees
;;;;
;;;; Instructions and sections are built as nested lists of byte
;;;; integers and flattened once at the end.

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

;; a wasm vector: element count, then the elements
(define (counted items)
  (cons (uleb (length items)) items))

;; a size-prefixed blob (sections, code bodies)
(define (sized tree)
  (let ((flat (flatten tree)))
    (list (uleb (length flat)) flat)))

(define (section id tree)
  (list id (sized tree)))

;;;; ------------------------------------------------------------------
;;;; wasm constants

;; The universal Scheme value type is eqref: fixnums are i31ref,
;; everything else is a GC struct, and eq? is ref.eq.
(define T-EQREF #x6D)
(define T-I31 #x6C)
(define T-I32 #x7F)

;; fixed type-table prefix
(define TY-PAIR 0)                      ; (struct (mut eqref) (mut eqref))
(define TY-SINGLETON 1)                 ; (struct i32)

;; singleton globals, in index order
(define G-FALSE 0)
(define G-TRUE 1)
(define G-NULL 2)
(define G-VOID 3)
(define G-FIRST-VAR 4)                  ; top-level variables from here

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
(define (emit-fixnum n)
  (list #x41 (sleb n) (gc-op #x1C)))    ; i32.const; ref.i31
(define (unwrap-fixnum)
  ;; eqref -> i32
  (list (gc-op #x16 T-I31)              ; ref.cast (ref i31)
        (gc-op #x1D)))                  ; i31.get_s
(define (ref-cast ty)
  (gc-op #x16 (sleb ty)))
(define (struct-get ty i)
  (gc-op #x02 (uleb ty) (uleb i)))
(define (struct-set ty i)
  (gc-op #x05 (uleb ty) (uleb i)))
(define (struct-new ty)
  (gc-op #x00 (uleb ty)))
(define (ref-func idx)
  (list #xD2 (uleb idx)))

;; turn an i32 on the stack into a Scheme boolean
(define (boolify)
  (list #x04 T-EQREF                    ; if (result eqref)
        (global-get G-TRUE)
        #x05
        (global-get G-FALSE)
        #x0B))

;; turn a Scheme value on the stack into an i32 truth flag
(define (truthy)
  (list (global-get G-FALSE) OP-REF-EQ OP-I32-EQZ))

;;;; ------------------------------------------------------------------
;;;; the expander: derived forms
;;;;
;;;; Non-hygienic for now; hygienic macros arrive in a later
;;;; milestone.  Core forms after expansion: quote if let begin lambda
;;;; set! define, plus applications.

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
             ;; named let
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
         ;; (do ((v init step?) ...) (test result ...) command ...)
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
;;;; assignment conversion
;;;;
;;;; Lexical variables that are ever assigned get boxed in a pair:
;;;; the binding allocates (cons v '()), references become (car v),
;;;; and (set! v e) becomes (set-car! v e).  Closures capture the box,
;;;; which is what makes mutation visible across scopes.  set! of a
;;;; top-level variable survives to codegen as a global store.

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

;; scope: list of (name . boxed?)
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
             `(set-car! ,(cadr e) ,v)   ; assigned lexicals are boxed
             `(set! ,(cadr e) ,v))))    ; top-level variable
      ((lambda)
       (let* ((formals (cadr e))
              (boxed (filter (lambda (p) (memq p assigned)) formals))
              (scope* (append (map (lambda (p)
                                     (cons p (and (memq p assigned) #t)))
                                   formals)
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
               (boxed (filter (lambda (p) (memq p assigned)) formals))
               (scope (map (lambda (p) (cons p (and (memq p assigned) #t)))
                           formals))
               (body (avc* (cddr form) scope assigned)))
          (if (null? boxed)
              `(define ,(cadr form) . ,body)
              `(define ,(cadr form)
                 (let ,(map (lambda (p) `(,p (cons ,p '()))) boxed)
                   . ,body))))
        (avc form '() assigned))))

;;;; ------------------------------------------------------------------
;;;; program state
;;;;
;;;; The compiler processes one program per run, so the tables live in
;;;; top-level cells.

(define *fns* '())        ; name -> (index . arity), top-level functions
(define *vars* '())       ; name -> global index, top-level variables
(define *plain-ty* '())   ; arity -> type index, for top-level functions
(define *clos-ty* '())    ; arity -> (fn-type . struct-type) rec pairs
(define *lifted* '())     ; fn index -> (type-idx n-params extra code)
(define *next-fn* 0)      ; next function index
(define *wrappers* '())   ; top-level fn name -> wrapper closure fn index

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

;;;; ------------------------------------------------------------------
;;;; free variables (over the converted core language)

(define (free-vars e bound)
  (cond
   ((symbol? e) (if (memq e bound) '() (list e)))
   ((pair? e)
    (case (car e)
      ((quote) '())
      ((set!) (free-vars (caddr e) bound))
      ((lambda) (free-vars-body (cddr e) (append (cadr e) bound)))
      ((let)
       (union (free-vars-body (map cadr (cadr e)) bound)
              (free-vars-body (cddr e)
                              (append (map car (cadr e)) bound))))
      ((begin) (free-vars-body (cdr e) bound))
      ((if) (free-vars-body (cdr e) bound))
      (else (free-vars-body e bound))))
   (else '())))
(define (free-vars-body es bound)
  (fold-left (lambda (acc e) (union acc (free-vars e bound))) '() es))
(define (union a b)
  (fold-left (lambda (acc x) (if (memq x acc) acc (cons x acc))) a b))

;;;; ------------------------------------------------------------------
;;;; expression compiler
;;;;
;;;; Produces a byte tree that leaves one eqref on the stack.
;;;; locals: alist name -> slot; cell: mutable local counter;
;;;; tail? marks tail position.

(define (fresh-local! cell)
  (let ((i (car cell)))
    (set-car! cell (+ i 1))
    i))

(define primitives
  '(+ - * = < eq? cons car cdr pair? null? zero? set-car! set-cdr!))

(define (compile-exp e locals cell tail?)
  (cond
   ((and (integer? e) (exact? e)) (emit-fixnum e))
   ((boolean? e) (global-get (if e G-TRUE G-FALSE)))
   ((symbol? e) (compile-ref e locals cell))
   ((pair? e)
    (case (car e)
      ((quote) (compile-datum (cadr e)))
      ((if) (compile-if e locals cell tail?))
      ((let) (compile-let e locals cell tail?))
      ((begin) (compile-body (cdr e) locals cell tail?))
      ((lambda) (compile-lambda (cadr e) (cddr e) locals cell))
      ((set!) (compile-global-set e locals cell))
      (else (compile-app e locals cell tail?))))
   (else (errorf 'schwasm "cannot compile ~s" e))))

(define (compile-ref e locals cell)
  (cond
   ((assq e locals) => (lambda (s) (local-get (cdr s))))
   ((assq e *vars*) => (lambda (v) (global-get (cdr v))))
   ((assq e *fns*) =>
    ;; a top-level function used as a value: wrap it in a closure
    (lambda (f) (compile-fn-value (car f) (cadr f) (cddr f))))
   (else (errorf 'schwasm "unbound variable ~s" e))))

(define (compile-fn-value name idx arity)
  (let ((w (assq name *wrappers*)))
    (list (ref-func
           (if w
               (cdr w)
               (let* ((widx (alloc-fn!))
                      (tys (clos-ty arity)))
                 (set! *wrappers* (cons (cons name widx) *wrappers*))
                 (record-fn!
                  widx
                  (list (car tys)
                        (+ arity 1)
                        0
                        (list (map (lambda (i) (local-get (+ i 1)))
                                   (iota arity))
                              #x12 (uleb idx)))) ; return_call f
                 widx)))
          (global-get G-NULL)                    ; empty environment
          (struct-new (cdr (clos-ty arity))))))

(define (compile-datum d)
  (cond
   ((and (integer? d) (exact? d)) (emit-fixnum d))
   ((boolean? d) (global-get (if d G-TRUE G-FALSE)))
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
  ;; bindings evaluate in the outer scope, then land in fresh locals
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
  (let* ((arity (length formals))
         (tys (clos-ty arity))
         (free (filter (lambda (v) (assq v locals))
                       (free-vars-body body (append formals '()))))
         (idx (alloc-fn!)))
    (lift-lambda! idx (car tys) formals body free)
    (list (ref-func idx)
          (env-chain free locals)
          (struct-new (cdr tys)))))

(define (env-chain free locals)
  (if (null? free)
      (global-get G-NULL)
      (list (local-get (cdr (assq (car free) locals)))
            (env-chain (cdr free) locals)
            (struct-new TY-PAIR))))

(define (lift-lambda! idx fn-ty formals body free)
  ;; the closure body: (closure formals...) -> eqref, with a prologue
  ;; that unpacks the captured environment chain into locals
  (let* ((arity (length formals))
         (cell (list (+ arity 1)))
         (locals (let number ((fs formals) (i 1))
                   (if (null? fs)
                       '()
                       (cons (cons (car fs) i)
                             (number (cdr fs) (+ i 1))))))
         (envtmp (and (pair? free) (fresh-local! cell)))
         (locals (let slot ((vs free) (acc locals))
                   (if (null? vs)
                       acc
                       (slot (cdr vs)
                             (cons (cons (car vs) (fresh-local! cell)) acc)))))
         (prologue
          (if (null? free)
              '()
              (list (local-get 0)
                    (struct-get (cdr (clos-ty arity)) 1)
                    (local-set envtmp)
                    (map (lambda (v)
                           (list (local-get envtmp) (ref-cast TY-PAIR)
                                 (struct-get TY-PAIR 0)
                                 (local-set (cdr (assq v locals)))
                                 (local-get envtmp) (ref-cast TY-PAIR)
                                 (struct-get TY-PAIR 1)
                                 (local-set envtmp)))
                         free))))
         (code (list prologue (compile-body body locals cell #t))))
    (record-fn! idx (list fn-ty (+ arity 1) (- (car cell) (+ arity 1)) code))))

;;; applications

(define (compile-app e locals cell tail?)
  (let ((op (car e))
        (args (cdr e)))
    (cond
     ((and (symbol? op) (assq op locals))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ((and (symbol? op) (memq op primitives))
      (compile-prim op args locals cell))
     ((and (symbol? op) (assq op *fns*))
      (let ((f (cdr (assq op *fns*))))
        (unless (= (cdr f) (length args))
          (errorf 'schwasm "wrong argument count in ~s" e))
        (list (map (lambda (a) (compile-exp a locals cell #f)) args)
              (if tail? #x12 #x10)      ; return_call / call
              (uleb (car f)))))
     ((and (symbol? op) (assq op *vars*))
      (compile-indirect (compile-ref op locals cell) args locals cell tail?))
     ((pair? op)
      (compile-indirect (compile-exp op locals cell #f) args locals cell tail?))
     (else (errorf 'schwasm "cannot call ~s" op)))))

(define (compile-indirect fcode args locals cell tail?)
  (let* ((arity (length args))
         (tys (clos-ty arity))
         (tmp (fresh-local! cell)))
    (list fcode (local-set tmp)
          (local-get tmp) (ref-cast (cdr tys))
          (map (lambda (a) (compile-exp a locals cell #f)) args)
          (local-get tmp) (ref-cast (cdr tys)) (struct-get (cdr tys) 0)
          (if tail? #x15 #x14)          ; return_call_ref / call_ref
          (uleb (car tys)))))

(define (compile-prim op args locals cell)
  (define (arg i) (compile-exp (list-ref args i) locals cell #f))
  (case op
    ((+ - * = <)
     (let ((ints (list (arg 0) (unwrap-fixnum) (arg 1) (unwrap-fixnum))))
       (case op
         ((+) (list ints #x6A (gc-op #x1C)))
         ((-) (list ints #x6B (gc-op #x1C)))
         ((*) (list ints #x6C (gc-op #x1C)))
         ((=) (list ints #x46 (boolify)))
         ((<) (list ints #x48 (boolify))))))
    ((zero?) (list (arg 0) (unwrap-fixnum) OP-I32-EQZ (boolify)))
    ((eq?) (list (arg 0) (arg 1) OP-REF-EQ (boolify)))
    ((cons) (list (arg 0) (arg 1) (struct-new TY-PAIR)))
    ((car) (list (arg 0) (ref-cast TY-PAIR) (struct-get TY-PAIR 0)))
    ((cdr) (list (arg 0) (ref-cast TY-PAIR) (struct-get TY-PAIR 1)))
    ((set-car!) (list (arg 0) (ref-cast TY-PAIR) (arg 1)
                      (struct-set TY-PAIR 0) (global-get G-VOID)))
    ((set-cdr!) (list (arg 0) (ref-cast TY-PAIR) (arg 1)
                      (struct-set TY-PAIR 1) (global-get G-VOID)))
    ((pair?) (list (arg 0) (gc-op #x14 (sleb TY-PAIR)) (boolify)))
    ((null?) (list (arg 0) (global-get G-NULL) OP-REF-EQ (boolify)))
    (else (errorf 'schwasm "unhandled primitive ~s" op))))

;;;; ------------------------------------------------------------------
;;;; top level

(define (define-form? f)
  (and (pair? f) (eq? (car f) 'define)))
(define (fn-define? f)
  (and (define-form? f) (pair? (cadr f))))
(define (var-define? f)
  (and (define-form? f) (symbol? (cadr f))))

;; every application arity or lambda arity might need a closure type
(define (scan-arities e acc)
  (if (pair? e)
      (case (car e)
        ((quote) acc)
        ((lambda)
         (scan-arities (cddr e)
                       (let ((a (length (cadr e))))
                         (if (memv a acc) acc (cons a acc)))))
        ((if begin set! define)
         (scan-arities (cdr e) acc))
        ((let)
         (scan-arities (map cadr (cadr e))
                       (scan-arities (cddr e) acc)))
        (else
         (let ((a (length (cdr e))))
           (scan-arities (car e)
                         (scan-arities (cdr e)
                                       (if (memv a acc) acc (cons a acc)))))))
      acc))

(define (compile-toplevel-fn form)
  ;; -> (type-idx n-params extra code)
  (let* ((formals (cdadr form))
         (arity (length formals))
         (cell (list arity))
         (locals (let number ((fs formals) (i 0))
                   (if (null? fs)
                       '()
                       (cons (cons (car fs) i) (number (cdr fs) (+ i 1)))))))
    (list (cdr (assv arity *plain-ty*))
          arity
          #f                            ; extra filled after body compiles
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
         ;; main runs var initializations and expressions in order
         (main-steps (filter (lambda (f) (not (fn-define? f))) forms))
         (main-steps (map (lambda (f)
                            (if (var-define? f)
                                `(set! ,(cadr f) ,(caddr f))
                                f))
                          main-steps)))
    ;; reset program state
    (set! *fns* '())
    (set! *vars* '())
    (set! *lifted* '())
    (set! *wrappers* '())
    (set! *next-fn* (+ (length fn-defs) 1))
    ;; number the top-level functions and variables
    (let number ((ds fn-defs) (i 0))
      (unless (null? ds)
        (set! *fns* (cons (cons (car (cadr (car ds)))
                                (cons i (length (cdadr (car ds)))))
                          *fns*))
        (number (cdr ds) (+ i 1))))
    (let number ((ds var-defs) (g G-FIRST-VAR))
      (unless (null? ds)
        (set! *vars* (cons (cons (cadr (car ds)) g) *vars*))
        (number (cdr ds) (+ g 1))))
    ;; type table: pair, singleton, plain fn types, closure rec groups
    (let* ((plain-arities (sort < (fold-left
                                   (lambda (acc d)
                                     (let ((a (length (cdadr d))))
                                       (if (memv a acc) acc (cons a acc))))
                                   '(0)
                                   fn-defs)))
           (clos-arities (sort < (scan-arities forms '())))
           (next (let number ((as plain-arities) (i 2))
                   (if (null? as)
                       i
                       (begin
                         (set! *plain-ty* (cons (cons (car as) i) *plain-ty*))
                         (number (cdr as) (+ i 1)))))))
      (let number ((as clos-arities) (i next))
        (unless (null? as)
          (set! *clos-ty* (cons (cons (car as) (cons i (+ i 1))) *clos-ty*))
          (number (cdr as) (+ i 2))))
      ;; compile: top-level functions, then main; lambdas lift as we go
      (let* ((fn-entries (map compile-toplevel-fn fn-defs))
             (main-entry
              (let ((cell (list 0)))
                (list (cdr (assv 0 *plain-ty*))
                      0
                      #f
                      (let ((code (compile-body
                                   (if (null? main-steps) '((begin)) main-steps)
                                   '() cell #t)))
                        (cons (car cell) code)))))
             (lifted (sort (lambda (a b) (< (car a) (car b))) *lifted*))
             (entries (append
                       (map (lambda (e)
                              (list (car e) (cadr e)
                                    (car (cadddr e)) (cdr (cadddr e))))
                            fn-entries)
                       (list (list (car main-entry) (cadr main-entry)
                                   (car (cadddr main-entry))
                                   (cdr (cadddr main-entry))))
                       (map cdr lifted)))
             (declared (map car lifted)))
        (emit-module plain-arities clos-arities (length var-defs)
                     entries declared (length fn-defs))))))

(define (emit-module plain-arities clos-arities n-vars entries declared main-idx)
  (flatten
   (list
    #x00 #x61 #x73 #x6D  #x01 #x00 #x00 #x00
    ;; type section
    (section 1 (counted
                (append
                 ;; $pair
                 (list (list #x5F (counted (list (list T-EQREF #x01)
                                                 (list T-EQREF #x01))))
                       ;; $singleton
                       (list #x5F (counted (list (list T-I32 #x00)))))
                 ;; plain function types: (eqref^n) -> eqref
                 (map (lambda (a)
                        (list #x60
                              (counted (make-list a T-EQREF))
                              (counted (list T-EQREF))))
                      plain-arities)
                 ;; closure rec groups:
                 ;;   $fnN  = (func (ref $closN) eqref^n -> eqref)
                 ;;   $closN = (struct (ref $fnN) eqref)
                 (map (lambda (a)
                        (let ((tys (clos-ty a)))
                          (list #x4E (uleb 2)
                                (list #x60
                                      (counted
                                       (cons (list #x64 (sleb (cdr tys)))
                                             (make-list a T-EQREF)))
                                      (counted (list T-EQREF)))
                                (list #x5F
                                      (counted
                                       (list (list #x64 (sleb (car tys)) #x00)
                                             (list T-EQREF #x00)))))))
                      clos-arities))))
    ;; function section
    (section 3 (counted (map (lambda (e) (uleb (car e))) entries)))
    ;; global section: singletons, then top-level variables
    (section 6 (counted
                (append
                 (map (lambda (tag)
                        (list #x64 (sleb TY-SINGLETON) #x00
                              #x41 (sleb tag)
                              (struct-new TY-SINGLETON)
                              #x0B))
                      '(0 1 2 3))
                 (map (lambda (_)
                        (list T-EQREF #x01
                              #xD0 T-EQREF ; ref.null eq
                              #x0B))
                      (iota n-vars)))))
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

(define (export-entry name kind idx)
  (let ((chars (string->list name)))
    (list (uleb (length chars))
          (map char->integer chars)
          kind
          (uleb idx))))

;;;; ------------------------------------------------------------------
;;;; driver

(define (read-forms port)
  (let ((form (read port)))
    (if (eof-object? form)
        '()
        (cons form (read-forms port)))))

(define (compile-file in out)
  (let ((forms (call-with-input-file in read-forms)))
    (let ((bytes (compile-program forms)))
      (when (file-exists? out) (delete-file out))
      (call-with-port (open-file-output-port out)
        (lambda (p) (put-bytevector p (u8-list->bytevector bytes)))))))

(let ((args (cdr (command-line))))
  (if (or (null? args) (null? (cdr args)))
      (begin (display "usage: schwasmc <input.ss> <output.wasm>\n")
             (exit 1))
      (compile-file (car args) (cadr args))))
