#lang racket/base
;; HLL pattern analysis & processing

(provide (for-syntax analyze-pattern)
         (struct-out predicate-match)
         match-value/captures
         ?
         )

(require (for-syntax racket/base))
(require (for-syntax racket/match))
(require (for-syntax syntax/parse))

(require racket/match)
(require "support/struct.rkt")
(require "treap.rkt")
(require "core.rkt")

(require auxiliary-macro-context)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-auxiliary-macro-context
  #:context-name assertion-expander
  #:prop-name prop:assertion-expander
  #:prop-predicate-name assertion-expander?
  #:prop-accessor-name assertion-expander-proc
  #:macro-definer-name define-assertion-expander
  #:introducer-parameter-name current-assertion-expander-introducer
  #:local-introduce-name syntax-local-assertion-expander-introduce
  #:expander-form-predicate-name assertion-expander-form?
  #:expander-transform-name assertion-expander-transform)

(provide (for-syntax
          prop:assertion-expander
          assertion-expander?
          assertion-expander-proc
          syntax-local-assertion-expander-introduce
          assertion-expander-form?
          assertion-expander-transform)
         define-assertion-expander)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(struct predicate-match (predicate sub-pattern) #:transparent)

;; Value Projection -> (Option (Listof Value))
;; Match a single value against a projection, returning a list of
;; captured values.
(define (match-value/captures v p)
  (define (walk v p captures-rev)
    (match* (v p)
      [(_ (capture sub))
       (match (walk v sub '())
         [#f #f]
         [nested-captures-rev (append nested-captures-rev (list v) captures-rev)])]
      [(_ (predicate-match pred? sub)) #:when (pred? v)
       (walk v sub captures-rev)]
      [((== ?) _)
       captures-rev]
      [(_ (== ?))
       captures-rev]
      [((cons v1 v2) (cons p1 p2))
       (match (walk v1 p1 captures-rev)
         [#f #f]
         [c (walk v2 p2 c)])]
      [((? vector? v) (? vector? p)) #:when (= (vector-length v) (vector-length p))
       (define limit (vector-length v))
       (do ((c captures-rev (walk (vector-ref v i) (vector-ref p i) c))
            (i 0 (+ i 1)))
           ((or (= i limit) (not c)) c))]
      [(_ _) #:when (or (treap? v) (treap? p))
       (error 'match-value/captures "Cannot match on treaps at present")]
      [((? non-object-struct?) (? non-object-struct?))
       #:when (eq? (struct->struct-type v) (struct->struct-type p))
       (walk (struct->vector v) (struct->vector p) captures-rev)]
      [(_ _) #:when (equal? v p)
       captures-rev]
      [(_ _)
       #f]))
  (define captures-rev (walk v p '()))
  (and captures-rev (reverse captures-rev)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-for-syntax orig-insp
  (variable-reference->module-declaration-inspector (#%variable-reference)))

(begin-for-syntax
  (define (dollar-id? stx)
    (and (identifier? stx)
         (char=? (string-ref (symbol->string (syntax-e stx)) 0) #\$)))

  (define (undollar stx)
    (and (dollar-id? stx)
         (datum->syntax stx (string->symbol (substring (symbol->string (syntax-e stx)) 1)))))

  (define (is-message-pattern? outer-expr-stx)
    (syntax-parse outer-expr-stx
      #:literals [message]
      [(message _ ...) '#t]
      [_ #f]))

  ;; Syntax -> (Values Projection AssertionSetPattern (ListOf Identifier) Syntax)
  (define (analyze-pattern outer-expr-stx pat-stx0)
    (let walk ((armed-pat-stx pat-stx0))
      (define pat-stx (syntax-disarm armed-pat-stx orig-insp))
      (syntax-case pat-stx ($ ? quasiquote unquote quote)
        ;; Extremely limited support for quasiquoting and quoting
        [(quasiquote (unquote p)) (walk #'p)]
        [(quasiquote (p ...)) (walk #'(list (quasiquote p) ...))]
        [(quasiquote p) (values #''p #''p '() #''p)]
        [(quote p) (values #''p #''p '() #''p)]

        [$v
         (dollar-id? #'$v)
         (with-syntax [(v (undollar #'$v))]
           (values #'(?!)
                   #'?
                   (list #'v)
                   #'v))]

        [($ v)
         (values #'(?!)
                 #'?
                 (list #'v)
                 #'v)]

        [($ v p)
         (let ()
           (define-values (pr g bs _ins) (walk #'p))
           (when (and (not (null? bs)) (not (is-message-pattern? outer-expr-stx)))
             (raise-syntax-error #f
                                 "Nested bindings only supported in message events"
                                 outer-expr-stx
                                 pat-stx))
           (values #`(?! #,pr)
                   g
                   (cons #'v bs)
                   #'v))]

        [(? pred? p)
         ;; TODO: support pred? in asserted/retracted as well as message events
         (let ()
           (when (not (is-message-pattern? outer-expr-stx))
             (raise-syntax-error #f
                                 "Predicate '?' matching only supported in message events"
                                 outer-expr-stx
                                 pat-stx))
           (define-values (pr g bs ins) (walk #'p))
           (values #`(predicate-match pred? #,pr)
                   g
                   bs
                   ins))]

        [expander
         (assertion-expander-form? #'expander)
         (assertion-expander-transform pat-stx (lambda (r) (walk (syntax-rearm r pat-stx))))]

        [(ctor p ...)
         (let ()
           (define parts (if (identifier? #'ctor) #'(p ...) #'(ctor p ...)))
           (define-values (pr g bs ins)
             (for/fold [(pr '()) (g '()) (bs '()) (ins '())] [(p (syntax->list parts))]
               (define-values (pr1 g1 bs1 ins1) (walk p))
               (values (cons pr1 pr)
                       (cons g1 g)
                       (append bs bs1)
                       (cons ins1 ins))))
           (if (identifier? #'ctor)
               (values (cons #'ctor (reverse pr))
                       (cons #'ctor (reverse g))
                       bs
                       (cons #'ctor (reverse ins)))
               (values (reverse pr)
                       (reverse g)
                       bs
                       (reverse ins))))]

        [?
         (raise-syntax-error #f
                             "Invalid use of '?' in pattern; use '_' instead"
                             outer-expr-stx
                             pat-stx)]

        [non-pair
         (if (and (identifier? #'non-pair)
                  (free-identifier=? #'non-pair #'_))
             (values #'?
                     #'?
                     '()
                     #'?)
             (values #'non-pair
                     #'non-pair
                     '()
                     #'non-pair))]))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(module+ test
  (require rackunit)

  (check-equal? (match-value/captures (list 1 2 3)
                                      (list 1 2 3))
                '())
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list 1 22 3))
                #f)
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) (?!) (?!)))
                (list 1 2 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) 2 (?!)))
                (list 1 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) ? (?!)))
                (list 1 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) (?! 2) (?!)))
                (list 1 2 3))
  (check-equal? (match-value/captures (list 1 2 3)
                                      (list (?!) (?! 22) (?!)))
                #f)

  (struct x (a b) #:prefab)
  (struct y (z w) #:prefab)

  (check-equal? (match-value/captures (x 1 2) (x 1 2)) '())
  (check-equal? (match-value/captures (x 1 22) (x 1 2)) #f)
  (check-equal? (match-value/captures (x 1 2) (x 1 22)) #f)
  (check-equal? (match-value/captures (x 1 2) (?! (x ? ?))) (list (x 1 2)))
  (check-equal? (match-value/captures (x 1 2) (?! (x ? 2))) (list (x 1 2)))
  (check-equal? (match-value/captures (x 1 2) (?! (x ? 22))) #f)

  (check-equal? (match-value/captures 123 (predicate-match even? ?)) #f)
  (check-equal? (match-value/captures 124 (predicate-match even? ?)) '())
  (check-equal? (match-value/captures (list 123) (list (predicate-match even? ?))) #f)
  (check-equal? (match-value/captures (list 124) (list (predicate-match even? ?))) '())
  (check-equal? (match-value/captures (list 124) (?! (list (predicate-match even? ?)))) '((124))))
