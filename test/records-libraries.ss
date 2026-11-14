;; expect: #t
;; record types across libraries: a record name is exported and imported like
;; a variable, a child names an imported parent under any import clause, a
;; library's private record names stay its own, a library's macro defines a
;; child of the library's type, and one nongenerative uid in two libraries
;; is one type.
;;
;; Each row's answer is the one Chez 10 gives for this same file.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: a record name was
;; not a binding and the parent clause was dropped.
(library (shapes)
  (export shape make-shape shape? shape-name
          solid make-solid solid? solid-mass
          define-shape-kind private-count)
  (import (rnrs))
  (define-record-type shape (fields name))
  ;; a parent with a protocol, whose protocol calls a private helper
  (define (double n) (* 2 n))
  (define-record-type solid (parent shape) (fields mass)
    (protocol (lambda (n) (lambda (name mass) ((n name) (double mass))))))
  ;; a private type, and a private child of it
  (define-record-type hidden (fields v))
  (define-record-type hidden-child (parent hidden) (fields w))
  (define (private-count)
    (let ((h (make-hidden-child 1 2)))
      (list (hidden? h) (hidden-child? h) (hidden-v h) (hidden-child-w h))))
  ;; a macro that defines a child of this library's own type; the new
  ;; type's names come from the macro's user
  (define-syntax define-shape-kind
    (syntax-rules ()
      ((_ kind make pred field acc)
       (define-record-type (kind make pred) (parent shape) (fields (immutable field acc)))))))
(library (other)
  (export describe make-hidden-thing)
  (import (rnrs))
  ;; a private record with the name another library uses privately
  (define-record-type hidden (fields a b))
  (define (make-hidden-thing) (make-hidden 10 20))
  (define (describe h) (list (hidden? h) (hidden-a h) (hidden-b h))))
(library (stamps one)
  (export stamp make-stamp stamp? stamp-n)
  (import (rnrs))
  (define-record-type stamp (fields n) (nongenerative stamps-uid-41)))
(library (stamps two)
  (export seal make-seal seal? seal-n)
  (import (rnrs))
  (define-record-type seal (fields n) (nongenerative stamps-uid-41)))
;; a macro whose template names a parent its library imports under another
;; name, used from a program that has its own record of that spelling
(library (base2)
  (export node make-node node? node-a node-b)
  (import (rnrs))
  (define-record-type node (fields a b)))
(library (mid2)
  (export define-nd-child)
  (import (rnrs) (rename (base2) (node nd)))
  (define-syntax define-nd-child
    (syntax-rules ()
      ((_ kind make pred field acc)
       (define-record-type (kind make pred) (parent nd) (fields (immutable field acc)))))))
(import (rnrs)
        (shapes)
        (rename (only (shapes) shape) (shape form))
        (prefix (only (shapes) solid make-solid) s:)
        (other)
        (stamps one) (stamps two)
        (base2) (mid2))

;; the program's own record of a name a library uses privately
(define-record-type hidden (fields mine))
(define-record-type nd (fields zzz))
(define-nd-child kid make-kid kid? extra kid-extra)
;; children of imported types, the parent written plain, renamed, prefixed
(define-record-type circle (parent shape) (fields r))
(define-record-type square (parent form) (fields side))
(define-record-type ball (parent s:solid) (fields r)
  (protocol (lambda (n) (lambda (name mass r) ((n name mass) r)))))
(define-shape-kind line make-line line? len line-len)
(define-record-type stamp-child (parent seal) (fields m))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'child-of-an-imported-type
      (guard (c (#t 'raised))
        (let ((c (make-circle 'c 3))) (list (shape? c) (circle? c) (shape-name c) (circle-r c))))
      '(#t #t c 3))
(want 'parent-written-renamed
      (guard (c (#t 'raised))
        (let ((q (make-square 'q 4))) (list (shape? q) (square? q) (shape-name q) (square-side q) (circle? q))))
      '(#t #t q 4 #f))
(want 'parent-written-prefixed-with-a-protocol
      (guard (c (#t 'raised))
        (let ((b (make-ball 'b 5 2))) (list (shape? b) (solid? b) (ball? b) (shape-name b) (solid-mass b) (ball-r b))))
      '(#t #t #t b 10 2))
(want 'the-parents-own-constructor
      (guard (c (#t 'raised))
        (let ((s (make-solid 's 7))) (list (shape? s) (solid? s) (solid-mass s) (ball? s))))
      '(#t #t 14 #f))
(want 'child-from-a-librarys-macro
      (guard (c (#t 'raised))
        (let ((l (make-line 'l 9))) (list (shape? l) (line? l) (shape-name l) (line-len l) (circle? l))))
      '(#t #t l 9 #f))
(want 'private-types-of-a-library
      (guard (c (#t 'raised))
        (private-count))
      '(#t #t 1 2))
(want 'one-name-private-in-two-libraries-and-the-program
      (guard (c (#t 'raised))
        (let ((mine (make-hidden 'own)) (theirs (make-hidden-thing))) (list (hidden? mine) (hidden-mine mine) (hidden? theirs) (describe theirs) (guard (c (#t 'raised)) (describe mine)))))
      '(#t own #f (#t 10 20) raised))
(want 'one-uid-in-two-libraries
      (guard (c (#t 'raised))
        (let ((a (make-stamp 1)) (b (make-seal 2))) (list (stamp? b) (seal? a) (stamp-n b) (seal-n a) (eq? (record-rtd a) (record-rtd b)))))
      '(#t #t 2 1 #t))
(want 'child-of-the-second-library-s-name
      (guard (c (#t 'raised))
        (let ((c (make-stamp-child 1 2))) (list (stamp? c) (seal? c) (stamp-n c) (stamp-child-m c))))
      '(#t #t 1 2))
(want 'descriptors-across-scopes
      (guard (c (#t 'raised))
        (list (eq? (record-type-descriptor form) (record-type-descriptor shape)) (eq? (record-type-parent (record-type-descriptor circle)) (record-type-descriptor shape)) (eq? (record-type-parent (record-type-descriptor ball)) (record-type-descriptor s:solid)) (record-type-name (record-type-descriptor form))))
      '(#t #t #t shape))
(want 'macro-names-a-parent-its-library-imports-renamed
      (guard (c (#t 'raised))
        (let ((k (make-kid 1 2 3)) (own (make-nd 'z))) (list (node? k) (kid? k) (nd? k) (node-a k) (node-b k) (kid-extra k) (nd? own) (node? own) (nd-zzz own))))
      '(#t #t #f 1 2 3 #t #f z))

(display (if (null? fails) #t (reverse fails)))
