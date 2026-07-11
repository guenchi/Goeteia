;; schwasm — a Scheme to WebAssembly-GC compiler.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
;;
;; Milestone 1: fixnums, booleans, pairs, arithmetic, comparisons,
;; if/let/begin/quote, top-level function definitions with direct
;; (and tail) calls.
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

;; fixed type-table layout
(define TY-PAIR 0)                      ; (struct (mut eqref) (mut eqref))
(define TY-SINGLETON 1)                 ; (struct i32)
(define TY-FIRST-FN 2)                  ; arity types allocated from here

;; singleton globals, in index order
(define G-FALSE 0)
(define G-TRUE 1)
(define G-NULL 2)
(define G-VOID 3)

;;;; ------------------------------------------------------------------
;;;; instruction emitters

(define (global-get g) (list #x23 (uleb g)))
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
(define (cast-pair)
  (gc-op #x16 (sleb TY-PAIR)))          ; ref.cast (ref $pair)
(define (pair-field-get i)
  (gc-op #x02 (uleb TY-PAIR) (uleb i))) ; struct.get $pair i
(define (pair-new)
  (gc-op #x00 (uleb TY-PAIR)))          ; struct.new $pair

;; turn an i32 on the stack into a Scheme boolean
(define (boolify)
  (list #x04 T-EQREF                    ; if (result eqref)
        (global-get G-TRUE)
        #x05                            ; else
        (global-get G-FALSE)
        #x0B))                          ; end

;; turn a Scheme value on the stack into an i32 truth flag
(define (truthy)
  (list (global-get G-FALSE) OP-REF-EQ OP-I32-EQZ))

;;;; ------------------------------------------------------------------
;;;; compile-time environments

;; functions: alist of name -> (index . arity)
(define (fn-entry fns name)
  (let ((e (assq name fns)))
    (unless e (errorf 'schwasm "call to undefined function ~s" name))
    (cdr e)))

;; locals: alist of name -> local index; fresh slots come from a
;; mutable counter cell
(define (fresh-local! cell)
  (let ((i (car cell)))
    (set-car! cell (+ i 1))
    i))

;;;; ------------------------------------------------------------------
;;;; expression compiler
;;;;
;;;; Produces a byte tree that leaves one eqref on the stack.
;;;; tail? marks tail position, where calls become return_call.

(define (compile-exp e locals fns cell tail?)
  (cond
   ((and (integer? e) (exact? e)) (emit-fixnum e))
   ((boolean? e) (global-get (if e G-TRUE G-FALSE)))
   ((symbol? e)
    (let ((slot (assq e locals)))
      (unless slot (errorf 'schwasm "unbound variable ~s" e))
      (local-get (cdr slot))))
   ((pair? e)
    (case (car e)
      ((quote) (compile-datum (cadr e)))
      ((if) (compile-if e locals fns cell tail?))
      ((let) (compile-let e locals fns cell tail?))
      ((begin) (compile-body (cdr e) locals fns cell tail?))
      ((+ - * = <) (compile-arith e locals fns cell))
      ((eq?) (compile-eq (cadr e) (caddr e) locals fns cell))
      ((cons) (list (compile-exp (cadr e) locals fns cell #f)
                    (compile-exp (caddr e) locals fns cell #f)
                    (pair-new)))
      ((car) (list (compile-exp (cadr e) locals fns cell #f)
                   (cast-pair) (pair-field-get 0)))
      ((cdr) (list (compile-exp (cadr e) locals fns cell #f)
                   (cast-pair) (pair-field-get 1)))
      ((pair?) (list (compile-exp (cadr e) locals fns cell #f)
                     (gc-op #x14 (sleb TY-PAIR)) ; ref.test (ref $pair)
                     (boolify)))
      ((null?) (compile-eq-global (cadr e) G-NULL locals fns cell))
      ((not) (compile-eq-global (cadr e) G-FALSE locals fns cell))
      (else (compile-call e locals fns cell tail?))))
   (else (errorf 'schwasm "cannot compile ~s" e))))

(define (compile-datum d)
  (cond
   ((and (integer? d) (exact? d)) (emit-fixnum d))
   ((boolean? d) (global-get (if d G-TRUE G-FALSE)))
   ((null? d) (global-get G-NULL))
   ((pair? d) (list (compile-datum (car d))
                    (compile-datum (cdr d))
                    (pair-new)))
   (else (errorf 'schwasm "unsupported datum ~s" d))))

(define (compile-if e locals fns cell tail?)
  (list (compile-exp (cadr e) locals fns cell #f)
        (truthy)
        #x04 T-EQREF
        (compile-exp (caddr e) locals fns cell tail?)
        #x05
        (if (null? (cdddr e))
            (global-get G-VOID)
            (compile-exp (cadddr e) locals fns cell tail?))
        #x0B))

(define (compile-let e locals fns cell tail?)
  ;; bindings evaluate in the outer scope, then land in fresh locals
  (let loop ((bs (cadr e)) (code '()) (scope locals))
    (if (null? bs)
        (list (reverse code)
              (compile-body (cddr e) scope fns cell tail?))
        (let* ((b (car bs))
               (slot (fresh-local! cell)))
          (loop (cdr bs)
                (cons (list (compile-exp (cadr b) locals fns cell #f)
                            (local-set slot))
                      code)
                (cons (cons (car b) slot) scope))))))

(define (compile-body exps locals fns cell tail?)
  (cond
   ((null? exps) (global-get G-VOID))
   ((null? (cdr exps)) (compile-exp (car exps) locals fns cell tail?))
   (else (list (compile-exp (car exps) locals fns cell #f)
               OP-DROP
               (compile-body (cdr exps) locals fns cell tail?)))))

(define (compile-arith e locals fns cell)
  (let ((op (car e))
        (a (compile-exp (cadr e) locals fns cell #f))
        (b (compile-exp (caddr e) locals fns cell #f)))
    (let ((ints (list a (unwrap-fixnum) b (unwrap-fixnum))))
      (case op
        ((+) (list ints #x6A (gc-op #x1C)))
        ((-) (list ints #x6B (gc-op #x1C)))
        ((*) (list ints #x6C (gc-op #x1C)))
        ((=) (list ints #x46 (boolify)))
        ((<) (list ints #x48 (boolify)))))))

(define (compile-eq a b locals fns cell)
  (list (compile-exp a locals fns cell #f)
        (compile-exp b locals fns cell #f)
        OP-REF-EQ
        (boolify)))

(define (compile-eq-global e g locals fns cell)
  (list (compile-exp e locals fns cell #f)
        (global-get g)
        OP-REF-EQ
        (boolify)))

(define (compile-call e locals fns cell tail?)
  (let ((entry (fn-entry fns (car e)))
        (args (cdr e)))
    (unless (= (cdr entry) (length args))
      (errorf 'schwasm "wrong argument count in ~s" e))
    (list (map (lambda (a) (compile-exp a locals fns cell #f)) args)
          (if tail? #x12 #x10)          ; return_call / call
          (uleb (car entry)))))

;;;; ------------------------------------------------------------------
;;;; top level

(define (define-form? f)
  (and (pair? f) (eq? (car f) 'define)))
(define (def-name f) (car (cadr f)))
(define (def-formals f) (cdr (cadr f)))
(define (def-body f) (cddr f))

(define (compile-function formals body fns)
  ;; -> (extra-local-count . code-tree)
  (let* ((cell (list (length formals)))
         (locals (let number ((fs formals) (i 0))
                   (if (null? fs)
                       '()
                       (cons (cons (car fs) i)
                             (number (cdr fs) (+ i 1))))))
         (code (compile-body body locals fns cell #t)))
    (cons (- (car cell) (length formals)) code)))

(define (fn-code-entry extra code)
  (sized (list (if (zero? extra)
                   (counted '())
                   (counted (list (list (uleb extra) T-EQREF))))
               code
               #x0B)))

(define (compile-program forms)
  (let* ((defs (filter define-form? forms))
         (exprs (remp define-form? forms))
         (fns (let number ((ds defs) (i 0))
                (if (null? ds)
                    '()
                    (cons (cons (def-name (car ds))
                                (cons i (length (def-formals (car ds)))))
                          (number (cdr ds) (+ i 1))))))
         (arities (let collect ((as (list 0)) (ds defs))
                    (if (null? ds)
                        (sort < as)
                        (collect (let ((a (length (def-formals (car ds)))))
                                   (if (memv a as) as (cons a as)))
                                 (cdr ds)))))
         (arity-ty (let number ((as arities) (i TY-FIRST-FN))
                     (if (null? as)
                         '()
                         (cons (cons (car as) i)
                               (number (cdr as) (+ i 1))))))
         (main-idx (length defs))
         (bodies (append
                  (map (lambda (d)
                         (compile-function (def-formals d) (def-body d) fns))
                       defs)
                  (list (compile-function
                         '()
                         (if (null? exprs) (list '(quote ())) exprs)
                         fns)))))
    (flatten
     (list
      ;; header
      #x00 #x61 #x73 #x6D  #x01 #x00 #x00 #x00
      ;; type section: pair, singleton, one func type per arity
      (section 1 (counted
                  (append
                   (list (list #x5F (counted (list (list T-EQREF #x01)
                                                   (list T-EQREF #x01))))
                         (list #x5F (counted (list (list T-I32 #x00)))))
                   (map (lambda (a)
                          (list #x60
                                (counted (make-list a T-EQREF))
                                (counted (list T-EQREF))))
                        arities))))
      ;; function section: a type index per function
      (section 3 (counted
                  (append
                   (map (lambda (d)
                          (uleb (cdr (assv (length (def-formals d)) arity-ty))))
                        defs)
                   (list (uleb (cdr (assv 0 arity-ty)))))))
      ;; global section: the four singletons
      (section 6 (counted
                  (map (lambda (tag)
                         (list #x64 (sleb TY-SINGLETON) #x00     ; (ref $singleton) const
                               #x41 (sleb tag)                   ; i32.const tag
                               (gc-op #x00 (uleb TY-SINGLETON))  ; struct.new
                               #x0B))
                       '(0 1 2 3))))
      ;; export section: main plus the singletons (for host decoding)
      (section 7 (counted
                  (list (export-entry "main" #x00 main-idx)
                        (export-entry "false" #x03 G-FALSE)
                        (export-entry "true" #x03 G-TRUE)
                        (export-entry "null" #x03 G-NULL)
                        (export-entry "void" #x03 G-VOID))))
      ;; code section
      (section 10 (counted
                   (map (lambda (b) (fn-code-entry (car b) (cdr b)))
                        bodies)))))))

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
