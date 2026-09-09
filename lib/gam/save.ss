;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; A saved game in the browser's local storage, and the difference
;; between "there is nothing to load" and "this machine cannot save".
;;
;; Those two are the whole design.  Collapsing them -- answering #f for
;; both -- produces the worst failure a save system has: every launch
;; starts a new game, every save appears to work, and nothing is ever
;; written.  So they are split by what kind of fact they are:
;;
;;   about the SAVE       -> #f from save-load: nothing stored, a
;;                           version this build cannot read, contents
;;                           the caller's own validator rejected, or
;;                           text that is no longer readable at all.
;;                           All four mean the same thing to a caller:
;;                           start a new game.
;;   about the MACHINE    -> a named error: there is no local storage
;;                           here, or writing to it is refused.  The
;;                           caller cannot fix it and must not silently
;;                           carry on as though there were no save.
;;
;; save-available? asks the second question on its own, so a caller can
;; find out once at startup rather than by having a load raise.
;;
;; WHY THERE IS JAVASCRIPT IN HERE.  A store can throw: a browser in a
;; private window keeps localStorage in place and refuses setItem, and a
;; full quota does the same.  A JavaScript exception is NOT a Scheme
;; condition in this system -- `guard' does not see it and the program
;; ends -- so a try/catch has to exist on the JavaScript side of the
;; call for the refusal to come back as a value at all.  That is what
;; the bridge below is: three functions that answer a status code
;; instead of throwing.  Installing them with js-eval at load time is
;; the same shape (web sexpr) uses for its float codec.
;;
;; WHY THE STORED TEXT IS AN S-EXPRESSION.  (web sexpr) is already this
;; system's wire format, and it carries what a save file is made of
;; exactly: exact and inexact numbers keep their kind, a flonum crosses
;; as its eight IEEE bytes so nothing is lost to a decimal round trip,
;; and anything off its whitelist fails loudly rather than arriving as
;; something else.  The version travels as a WRAPPER around the caller's
;; datum, not as a field written into it: writing a field in would mean
;; this library mutates the value it was handed, and would put a name of
;; its own into the caller's data where a validator then has to know
;; about it.
(library (gam save)
  (export make-save-store save-available? save-load save-write!)
  (import (rnrs) (web js) (web sexpr))

  ;; The bridge.  Every entry answers #(status value):
  ;;   status 0  the store is not usable here (absent, or it threw)
  ;;   status 1  usable; for a read, nothing is stored under that key
  ;;   status 2  usable; value is the stored text
  ;; A status is a number rather than a boolean because "unusable" and
  ;; "nothing there" must not both arrive as a falsy value.
  (define $bridge-source
    (string-append
     "globalThis.__gamSave={"
     "probe(){try{const s=globalThis.localStorage;if(!s)return [0,null];"
     "const k='__gam_save_probe';s.setItem(k,'1');s.removeItem(k);return [1,null];}"
     "catch(e){return [0,null];}},"
     "get(k){try{const s=globalThis.localStorage;if(!s)return [0,null];"
     "const v=s.getItem(k);return v===null||v===undefined?[1,null]:[2,String(v)];}"
     "catch(e){return [0,null];}},"
     "set(k,v){try{const s=globalThis.localStorage;if(!s)return [0,null];"
     "s.setItem(k,v);return [1,null];}catch(e){return [0,null];}}};"))

  (define $installed (js-eval $bridge-source))

  ;; Looked up on every call rather than held: a test that installs a
  ;; different store, and a page that loads this before its shims, both
  ;; work only if the object is read when it is used.
  (define ($bridge) (js-get (js-global) "__gamSave"))
  (define ($status r) (js->number (js-index r 0)))
  (define ($value r) (js-index r 1))

  ;; #(gam-save key version validator)
  (define ($store? s)
    (and (vector? s) (= (vector-length s) 4)
         (eq? (vector-ref s 0) 'gam-save)))
  (define ($key s) (vector-ref s 1))
  (define ($version s) (vector-ref s 2))
  (define ($validator s) (vector-ref s 3))

  (define ($need-store who s)
    (unless ($store? s) (error who "not a save store" s)))

  ;; The version is an exact integer because it is compared for
  ;; equality: an inexact one would make "the same version" a question
  ;; about rounding, and a save that reads back only sometimes is worse
  ;; than one that never does.
  (define (make-save-store key version validator)
    (unless (string? key)
      (error 'make-save-store "a storage key is a string" key))
    (unless (and (integer? version) (exact? version))
      (error 'make-save-store "a version is an exact integer" key version))
    (unless (procedure? validator)
      (error 'make-save-store "a validator is a procedure of one value" key))
    (vector 'gam-save key version validator))

  ;; Answers, and never raises: this is the question a caller asks in
  ;; order to avoid the raise.  It writes and removes a probe key,
  ;; because a store that is present is not the same as one that accepts
  ;; a write -- which is exactly the case this whole library exists for.
  (define (save-available? s)
    ($need-store 'save-available? s)
    (= ($status (js-method ($bridge) "probe")) 1))

  (define ($need-storage who r)
    (when (= ($status r) 0)
      (error who "this browser will not let the game save" 'local-storage))
    r)

  ;; Four different disappointments, one answer.  A caller that got #f
  ;; has exactly one thing to do -- start a new game -- and telling the
  ;; four apart here would only invite it to act on a distinction it
  ;; cannot do anything about.  The machine's refusal is NOT one of the
  ;; four, and that one raises.
  (define (save-load s)
    ($need-store 'save-load s)
    (let ((r ($need-storage 'save-load (js-method ($bridge) "get" ($key s)))))
      (and (= ($status r) 2)
           (let ((datum (guard (e (#t #f))
                          (string->sexpr (js->string ($value r))))))
             (and (pair? datum)
                  (eq? (car datum) 'gam-save)
                  (pair? (cdr datum))
                  (equal? (cadr datum) ($version s))
                  (pair? (cddr datum))
                  (let ((payload (caddr datum)))
                    (and (($validator s) payload) payload)))))))

  ;; Deliberately NOT symmetric with save-load.  On the way in, a value
  ;; the validator rejects is the caller's own bug -- it assembled the
  ;; thing it is trying to store -- and answering #f would let a game
  ;; write nothing for an hour and find out at the next launch.  On the
  ;; way out, a rejected value is a fact about a file that may have been
  ;; written by an older build or edited by hand, which is not the
  ;; caller's mistake and not worth ending a launch over.
  (define (save-write! s value)
    ($need-store 'save-write! s)
    (unless (($validator s) value)
      (error 'save-write! "the validator refused the value being saved" ($key s)))
    (let ((text (sexpr->string (list 'gam-save ($version s) value))))
      ($need-storage 'save-write! (js-method ($bridge) "set" ($key s) text))
      #t)))
