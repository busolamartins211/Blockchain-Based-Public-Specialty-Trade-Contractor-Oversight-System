;; Elevator Installation Licensing Contract
;; Manages permits and certifications for elevator and escalator installation companies

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CONTRACTOR-NOT-FOUND (err u101))
(define-constant ERR-INVALID-LICENSE-TYPE (err u102))
(define-constant ERR-LICENSE-EXPIRED (err u103))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u104))
(define-constant ERR-ALREADY-EXISTS (err u105))

;; License types
(define-constant LICENSE-BASIC u1)
(define-constant LICENSE-ADVANCED u2)
(define-constant LICENSE-MASTER u3)

;; Data Variables
(define-data-var contract-owner principal CONTRACT-OWNER)
(define-data-var license-fee uint u1000000) ;; 1 STX in microSTX

;; Data Maps
(define-map contractors
  { contractor-id: principal }
  {
    company-name: (string-ascii 100),
    license-type: uint,
    issue-date: uint,
    expiry-date: uint,
    is-active: bool,
    violation-count: uint,
    total-installations: uint
  }
)

(define-map permits
  { permit-id: uint }
  {
    contractor-id: principal,
    building-address: (string-ascii 200),
    permit-type: (string-ascii 50),
    issue-date: uint,
    completion-date: (optional uint),
    is-completed: bool,
    inspection-passed: bool
  }
)

(define-map regulators
  { regulator-id: principal }
  { is-authorized: bool }
)

;; Permit counter
(define-data-var next-permit-id uint u1)

;; Authorization functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-private (is-authorized-regulator)
  (default-to false (get is-authorized (map-get? regulators { regulator-id: tx-sender })))
)

(define-private (can-manage-licenses)
  (or (is-contract-owner) (is-authorized-regulator))
)

;; Admin functions
(define-public (add-regulator (regulator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-set regulators { regulator-id: regulator } { is-authorized: true }))
  )
)

(define-public (remove-regulator (regulator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-delete regulators { regulator-id: regulator }))
  )
)

(define-public (set-license-fee (new-fee uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set license-fee new-fee))
  )
)

;; Contractor management
(define-public (register-contractor
  (contractor principal)
  (company-name (string-ascii 100))
  (license-type uint))
  (let
    (
      (current-block block-height)
      (expiry-block (+ current-block u52560)) ;; ~1 year in blocks
    )
    (begin
      (asserts! (can-manage-licenses) ERR-NOT-AUTHORIZED)
      (asserts! (and (>= license-type LICENSE-BASIC) (<= license-type LICENSE-MASTER)) ERR-INVALID-LICENSE-TYPE)
      (asserts! (is-none (map-get? contractors { contractor-id: contractor })) ERR-ALREADY-EXISTS)
      (ok (map-set contractors
        { contractor-id: contractor }
        {
          company-name: company-name,
          license-type: license-type,
          issue-date: current-block,
          expiry-date: expiry-block,
          is-active: true,
          violation-count: u0,
          total-installations: u0
        }
      ))
    )
  )
)

(define-public (renew-license (contractor principal))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
      (current-block block-height)
      (new-expiry (+ current-block u52560))
    )
    (begin
      (asserts! (can-manage-licenses) ERR-NOT-AUTHORIZED)
      (ok (map-set contractors
        { contractor-id: contractor }
        (merge contractor-data { expiry-date: new-expiry, is-active: true })
      ))
    )
  )
)

(define-public (suspend-license (contractor principal))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
    )
    (begin
      (asserts! (can-manage-licenses) ERR-NOT-AUTHORIZED)
      (ok (map-set contractors
        { contractor-id: contractor }
        (merge contractor-data { is-active: false })
      ))
    )
  )
)

;; Permit management
(define-public (issue-permit
  (contractor principal)
  (building-address (string-ascii 200))
  (permit-type (string-ascii 50)))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
      (permit-id (var-get next-permit-id))
      (current-block block-height)
    )
    (begin
      (asserts! (can-manage-licenses) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active contractor-data) ERR-LICENSE-EXPIRED)
      (asserts! (< current-block (get expiry-date contractor-data)) ERR-LICENSE-EXPIRED)
      (map-set permits
        { permit-id: permit-id }
        {
          contractor-id: contractor,
          building-address: building-address,
          permit-type: permit-type,
          issue-date: current-block,
          completion-date: none,
          is-completed: false,
          inspection-passed: false
        }
      )
      (var-set next-permit-id (+ permit-id u1))
      (ok permit-id)
    )
  )
)

(define-public (complete-installation (permit-id uint))
  (let
    (
      (permit-data (unwrap! (map-get? permits { permit-id: permit-id }) ERR-CONTRACTOR-NOT-FOUND))
      (contractor-id (get contractor-id permit-data))
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor-id }) ERR-CONTRACTOR-NOT-FOUND))
    )
    (begin
      (asserts! (or (is-eq tx-sender contractor-id) (can-manage-licenses)) ERR-NOT-AUTHORIZED)
      (map-set permits
        { permit-id: permit-id }
        (merge permit-data {
          completion-date: (some block-height),
          is-completed: true
        })
      )
      (map-set contractors
        { contractor-id: contractor-id }
        (merge contractor-data {
          total-installations: (+ (get total-installations contractor-data) u1)
        })
      )
      (ok true)
    )
  )
)

(define-public (pass-inspection (permit-id uint))
  (let
    (
      (permit-data (unwrap! (map-get? permits { permit-id: permit-id }) ERR-CONTRACTOR-NOT-FOUND))
    )
    (begin
      (asserts! (can-manage-licenses) ERR-NOT-AUTHORIZED)
      (ok (map-set permits
        { permit-id: permit-id }
        (merge permit-data { inspection-passed: true })
      ))
    )
  )
)

;; Read-only functions
(define-read-only (get-contractor (contractor principal))
  (map-get? contractors { contractor-id: contractor })
)

(define-read-only (get-permit (permit-id uint))
  (map-get? permits { permit-id: permit-id })
)

(define-read-only (is-license-valid (contractor principal))
  (match (map-get? contractors { contractor-id: contractor })
    contractor-data (and
      (get is-active contractor-data)
      (< block-height (get expiry-date contractor-data))
    )
    false
  )
)

(define-read-only (get-license-fee)
  (var-get license-fee)
)
