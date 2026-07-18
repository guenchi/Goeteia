;; sx: reactive DOM templates.
;;
;; (sx (div (@ (class "box") (on-click ,handler))
;;       "static text"
;;       (span ,(signal-ref count))))
;;
;; The template is split at expansion time: the static structure is
;; carried as a quoted datum and built once; each unquote becomes a
;; hole -- an `on-*` attribute hole is evaluated once and attached as
;; an event listener, every other hole becomes a thunk rerun inside
;; its own effect, updating just that text node or attribute.  The
;; DOM is a write-only surface: nothing is ever read back from it.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web sx)
  (export sx sx-mount sx-list $sx-build)
  (import (rnrs) (web js) (web dom) (web reactive))

  (define-syntax sx
    (lambda (x)
      (syntax-case x ()
        ((_ tmpl)
         (let ((listeners '()) (thunks '()) (nl 0) (nd 0))
           (letrec
               ((unq?
                 (lambda (t)
                   (and (pair? t) (eq? (car t) 'unquote)
                        (pair? (cdr t)) (null? (cddr t)))))
                (on-attr?
                 (lambda (s)
                   (let ((str (symbol->string s)))
                     (and (< 3 (string-length str))
                          (string=? (substring str 0 3) "on-")))))
                (add-listener!
                 (lambda (e)
                   (set! listeners (cons e listeners))
                   (set! nl (+ nl 1))
                   (cons '$sx-l (- nl 1))))
                (add-thunk!
                 (lambda (e)
                   (set! thunks (cons (list 'lambda '() e) thunks))
                   (set! nd (+ nd 1))
                   (cons '$sx-d (- nd 1))))
                (walk-attr
                 (lambda (a)
                   (let ((name (car a)) (v (cadr a)))
                     (if (unq? v)
                         (if (on-attr? name)
                             (list name (add-listener! (cadr v)))
                             (list name (add-thunk! (cadr v))))
                         a))))
                (walk
                 (lambda (t)
                   (cond
                    ((unq? t) (add-thunk! (cadr t)))
                    ((pair? t)
                     (let ((tag (car t)) (rest (cdr t)))
                       (if (and (pair? rest) (pair? (car rest))
                                (eq? (car (car rest)) '@))
                           (cons tag
                                 (cons (cons '@ (map walk-attr
                                                     (cdr (car rest))))
                                       (map walk (cdr rest))))
                           (cons tag (map walk rest)))))
                    (else t)))))
             (let ((anno (walk tmpl)))
               (list '$sx-build (list 'quote anno)
                     (cons 'list (reverse listeners))
                     (cons 'list (reverse thunks))))))))))

  ;; hole markers: ($sx-l . n) indexes listeners, ($sx-d . n) thunks
  (define ($sx-l? t) (and (pair? t) (eq? (car t) '$sx-l)))
  (define ($sx-d? t) (and (pair? t) (eq? (car t) '$sx-d)))

  (define ($sx-text v)
    (cond
     ((string? v) v)
     ((number? v) (number->string v))
     ((or (eq? v #f) (null? v) (eq? v (void))) "")
     (else (with-output-to-string (lambda () (display v))))))

  ;; live element properties, set directly rather than as attributes
  (define $sx-props '(value checked disabled))

  (define ($sx-set-attr el name v)
    (let ((n (symbol->string name)))
      (cond
       ((memq name $sx-props) (js-set! el n v))
       ((eq? v #f) (js-method el "removeAttribute" n))
       ((eq? v #t) (set-attribute! el n ""))
       ((number? v) (set-attribute! el n (number->string v)))
       (else (set-attribute! el n v)))))

  (define ($sx-attr el a ls ds)
    (let ((name (car a)) (v (cadr a)))
      (cond
       (($sx-l? v)
        (let ((n (symbol->string name)))
          (add-event-listener! el (substring n 3 (string-length n))
                               (list-ref ls (cdr v)))))
       (($sx-d? v)
        (let ((th (list-ref ds (cdr v))))
          (effect (lambda () ($sx-set-attr el name (th))))))
       (else ($sx-set-attr el name v)))))

  (define ($sx-kid el k ls ds)
    (if ($sx-d? k)
        (let ((cur (make-text "")))
          (append-child! el cur)
          (effect
           (lambda ()
             (let* ((v ((list-ref ds (cdr k))))
                    (new (if (js-ref? v) v (make-text ($sx-text v)))))
               (replace-child! el new cur)
               (set! cur new)))))
        (append-child! el ($sx-build k ls ds))))

  (define ($sx-build t ls ds)
    (cond
     ((string? t) (make-text t))
     ((number? t) (make-text (number->string t)))
     ((pair? t)
      (let* ((tag (car t))
             (rest (cdr t))
             (attrs? (and (pair? rest) (pair? (car rest))
                          (eq? (car (car rest)) '@)))
             (attrs (if attrs? (cdr (car rest)) '()))
             (kids (if attrs? (cdr rest) rest))
             (el (create-element (symbol->string tag))))
        (for-each (lambda (a) ($sx-attr el a ls ds)) attrs)
        (for-each (lambda (k) ($sx-kid el k ls ds)) kids)
        el))
     (else (error 'sx "bad template item" t))))

  (define (sx-mount container node)
    (append-child! container node)
    node)

  ;; a dynamic list of nodes: (thunk) yields the items, (render item)
  ;; yields a node per item; the host's children track the list.
  ;; Without a key the rebuild is naive (clear + re-render); with
  ;; (sx-list thunk render key) nodes are keyed: an item whose key
  ;; survives keeps its node, its effects and its DOM state, and only
  ;; moves.  The child order is mirrored on the Scheme side, so the
  ;; DOM stays write-only.
  (define (sx-list thunk render . key)
    (if (null? key)
        ($sx-list-naive thunk render)
        ($sx-list-keyed thunk render (car key))))

  (define ($sx-list-naive thunk render)
    (let ((host (create-element "div")))
      (effect
       (lambda ()
         (let ((items (thunk)))
           (remove-all-children! host)
           (for-each (lambda (it) (append-child! host (render it)))
                     items))))
      host))

  ;; state entries: (key node dispose), in DOM order
  (define ($sx-list-keyed thunk render key)
    (let ((host (create-element "div"))
          (state '()))
      (effect
       (lambda ()
         (let* ((items (thunk))
                (desired
                 (map (lambda (it)
                        (let* ((k (key it))
                               (old (assoc k state)))
                          (or old
                              ;; item effects live under their own
                              ;; root: they survive list reruns and
                              ;; die when the key vanishes
                              (let ((rd (root (lambda () (render it)))))
                                (list k (car rd) (cdr rd))))))
                      items)))
           ;; drop vanished keys
           (for-each (lambda (ent)
                       (unless (assoc (car ent) desired)
                         ((caddr ent))
                         (remove-child! host (cadr ent))))
                     state)
           ;; insert new nodes / move survivors into place, walking
           ;; the mirror of the surviving old order
           (let loop ((mirror (filter (lambda (ent)
                                        (assoc (car ent) desired))
                                      state))
                      (ds desired))
             (unless (null? ds)
               (let ((d (car ds)))
                 (if (and (pair? mirror)
                          (equal? (car (car mirror)) (car d)))
                     (loop (cdr mirror) (cdr ds))
                     (begin
                       (if (pair? mirror)
                           (insert-before! host (cadr d)
                                           (cadr (car mirror)))
                           (append-child! host (cadr d)))
                       (loop (filter (lambda (ent)
                                       (not (equal? (car ent) (car d))))
                                     mirror)
                             (cdr ds)))))))
           (set! state desired))))
      host)))
