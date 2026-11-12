;; expect: #t
;; Macros and local bindings of keyword names, in both directions, and
;; definitions that a macro produces.
;;   - a template's own keyword stays the keyword under the caller's local
;;     binding of that name, and a template's own binding of a keyword's name
;;     does not take the keyword the caller passed in;
;;   - a definition a macro produces binds from where it stands: a later call
;;     of that name is a call, whatever macro or derived form the name is, and
;;     its own right-hand side may call it;
;;   - used as a value, such a name is a variable, also when it is apply,
;;     begin, lambda or call/cc;
;;   - a binding written inside the scope of such a definition, of the same
;;     name, is an ordinary binding again: a let, a formal or an inner
;;     definition of if under a macro-produced if is called like any other;
;;   - a body-level macro use that defines its own name is still that macro
;;     use;
;;   - datum->syntax with a context the template itself wrote names the
;;     template's binding; with the caller's keyword as context it names the
;;     caller's, as it did.
;; One row is NOT Chez's answer and is pinned as it is (ledger R43d): a use
;; of a derived form inside an earlier procedure, where a macro then defines
;; that name later in the same body, keeps the form's meaning when the
;; procedure runs.
;;
;; Every answer is the one Chez 10 gives, except the row marked pinned.
;;
;; ON THE TREE BEFORE THE CHANGE a macro-produced definition named like a macro or a
;; derived form does not compile, and datum->syntax against the template's
;; own binder answers 2.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define rows '())
(define (row! name thunk expect) (set! rows (cons (list name thunk expect) rows)))

(define (tag . args) (cons 'called args))
(define-syntax my-if (syntax-rules () ((_ c a b) (if c a b))))
(define-syntax with-if (syntax-rules () ((_ e) (let ((if tag)) e))))
(define-syntax call-own-if (syntax-rules () ((_) (let ((if tag)) (if 1 2 3 4)))))
(define-syntax my-list (syntax-rules () ((_ a b) (list a b))))
(define-syntax with-list (syntax-rules () ((_ e) (let ((list tag)) (cons (list 0) e)))))
(define-syntax decl (syntax-rules () ((_ n v) (define n v))))
(define-syntax decl-proc (syntax-rules () ((_ n) (define (n . args) (cons 'called args)))))
(define-syntax counter (syntax-rules () ((_ n) (define n 0))))
(define-syntax defn (syntax-rules () ((_ n v) (define n v))))
(define-syntax datum-bind
  (lambda (stx)
    (syntax-case stx ()
      ((_)
       (with-syntax ((ref (datum->syntax (syntax if) 'if)))
         (syntax (let ((if (lambda args (length args)))) (ref 1 2 3 4))))))))
(define-syntax aif
  (lambda (stx)
    (syntax-case stx ()
      ((k c e)
       (with-syntax ((it (datum->syntax (syntax k) 'it)))
         (syntax (let ((it c)) e)))))))

(row! 'template-keyword (lambda () (let ((if tag)) (my-if #t 1 2))) '1)
(row! 'template-binder (lambda () (with-if (if #t 1 2))) '1)
(row! 'template-own-binding (lambda () (call-own-if)) '(called 1 2 3 4))
(row! 'template-procedure (lambda () (let ((list tag)) (my-list 1 2))) '(1 2))
(row! 'template-binder-procedure (lambda () (with-list (list 2))) '((called 0) 2))
(row! 'late-prelude-macro (lambda () (let () (decl-proc assert) (assert 1 2 3))) '(called 1 2 3))
(row! 'late-user-macro (lambda () (let () (decl-proc my-if) (my-if 1 2 3))) '(called 1 2 3))
(row! 'late-derived (lambda () (let () (decl-proc when) (when 1 2 3))) '(called 1 2 3))
(row! 'late-own-right-hand-side (lambda () (let () (decl unless (lambda (n) (if (= n 0) 'done (unless (- n 1))))) (unless 3))) 'done)
(row! 'late-value (lambda () (let () (decl when 5) (+ when 1))) '6)
(row! 'late-value-dispatched (lambda () (list (let () (decl apply 5) (+ apply 1)) (let () (decl begin 5) (+ begin 1)) (let () (decl lambda 5) (+ lambda 1)) (let () (decl call/cc 5) (+ call/cc 1)))) '(6 6 6 6))
(row! 'defines-its-own-name (lambda () (let () (counter counter) counter)) '0)
(row! 'defines-an-earlier-macro (lambda () (let () (defn a 1) (decl defn 5) (+ a defn))) '6)
(row! 'earlier-use-not-run (lambda () (let () (define (h) (unless #f 7)) (decl unless 5) (+ unless 1))) '6)
(row! 'late-then-rebound-let (lambda () (let () (decl if 5) (let ((if tag)) (if 1 2)))) '(called 1 2))
(row! 'late-then-rebound-formal (lambda () (let () (decl if 5) ((lambda (if) (if 1 2)) tag))) '(called 1 2))
(row! 'late-then-inner-definition (lambda () (let () (decl if 5) (let () (define (if . xs) (cons 'inner xs)) (if 1 2)))) '(inner 1 2))
(row! 'late-then-loop-parameter (lambda () (let () (decl quote 5) (let loop ((quote 0)) (cond ((< quote 3) (loop (+ quote 1))) (else quote))))) '3)
(row! 'late-derived-under-a-renamed-binder (lambda () ((lambda (begin) (let () (decl-proc when) (list (when 1) (begin 2)))) tag)) '((called 1) (called 2)))
(row! 'late-macro-under-a-renamed-binder (lambda () (let ((if tag)) (let () (decl-proc assert) (list (assert 1) (if 2))))) '((called 1) (called 2)))
(row! 'datum-template-context (lambda () (datum-bind)) '4)
(row! 'datum-caller-context (lambda () (aif 5 (+ it 1))) '6)
;; pinned: goeteia's answer; Chez answers otherwise (ledger R43d)
(row! 'earlier-use-run (lambda () (let () (define (h) (unless #f 7)) (decl unless 5) (h))) '7)

(for-each (lambda (r) (want (car r) (guard (c (#t 'raised)) ((cadr r))) (caddr r))) (reverse rows))
(display (if (null? fails) #t (reverse fails)))
