;; Communications Wiring Oversight Contract
;; Manages permits for telephone, internet, and cable installation

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-CONTRACTOR-NOT-FOUND (err u401))
(define-constant ERR-INVALID-PERMIT-TYPE (err u402))
(define-constant ERR-PERMIT-EXPIRED (err u403))
(define-constant ERR-INSTALLATION-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-EXISTS (err u405))

;; Permit types
(define-constant PERMIT-RESIDENTIAL u1)
(define-constant PERMIT-COMMERCIAL u2)
(define-constant PERMIT-FIBER-OPTIC u3)
(define-constant PERMIT-INFRASTRUCTURE u4)

;; Service types
(define-constant SERVICE-TELEPHONE u1)
(define-constant SERVICE-INTERNET u2)
(define-constant SERVICE-CABLE-TV u3)
(define-constant SERVICE-FIBER u4)

;; Data Variables
(define-data-var contract-owner principal CONTRACT-OWNER)
(define-data-var permit-fee uint u500000) ;; 0.5 STX

;; Data Maps
(define-map contractors
  { contractor-id: principal }
  {
    company-name: (string-ascii 100),
    permit-type: uint,
    issue-date: uint,
    expiry-date: uint,
    is-active: bool,
    safety-certification: bool,
    installations-completed: uint,
    violations: uint
  }
)

(define-map installations
  { installation-id: uint }
  {
    contractor-id: principal,
    service-address: (string-ascii 200),
    service-type: uint,
    installation-date: uint,
    completion-date: (optional uint),
    is-completed: bool,
    inspection-required: bool,
    inspection-passed: bool
  }
)

(define-map infrastructure-projects
  { project-id: uint }
  {
    contractor-id: principal,
    project-name: (string-ascii 100),
    start-location: (string-ascii 200),
    end-location: (string-ascii 200),
    cable-length: uint,
    project-start: uint,
    estimated-completion: uint,
    actual-completion: (optional uint),
    environmental-clearance: bool
  }
)

(define-map regulators
  { regulator-id: principal }
  { is-authorized: bool }
)

;; Counters
(define-data-var next-installation-id uint u1)
(define-data-var next-project-id uint u1)

;; Authorization functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-private (is-authorized-regulator)
  (default-to false (get is-authorized (map-get? regulators { regulator-id: tx-sender })))
)

(define-private (can-manage-permits)
  (or (is-contract-owner) (is-authorized-regulator))
)

;; Admin functions
(define-public (add-regulator (regulator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-set regulators { regulator-id: regulator } { is-authorized: true }))
  )
)

(define-public (set-permit-fee (new-fee uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set permit-fee new-fee))
  )
)

;; Contractor management
(define-public (issue-permit
  (contractor principal)
  (company-name (string-ascii 100))
  (permit-type uint)
  (safety-certification bool))
  (let
    (
      (current-block block-height)
      (expiry-block (+ current-block u52560)) ;; ~1 year
    )
    (begin
      (asserts! (can-manage-permits) ERR-NOT-AUTHORIZED)
      (asserts! (and (>= permit-type PERMIT-RESIDENTIAL) (<= permit-type PERMIT-INFRASTRUCTURE)) ERR-INVALID-PERMIT-TYPE)
      (asserts! (is-none (map-get? contractors { contractor-id: contractor })) ERR-ALREADY-EXISTS)
      (ok (map-set contractors
        { contractor-id: contractor }
        {
          company-name: company-name,
          permit-type: permit-type,
          issue-date: current-block,
          expiry-date: expiry-block,
          is-active: true,
          safety-certification: safety-certification,
          installations-completed: u0,
          violations: u0
        }
      ))
    )
  )
)

(define-public (renew-permit (contractor principal))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
      (current-block block-height)
      (new-expiry (+ current-block u52560))
    )
    (begin
      (asserts! (can-manage-permits) ERR-NOT-AUTHORIZED)
      (ok (map-set contractors
        { contractor-id: contractor }
        (merge contractor-data { expiry-date: new-expiry, is-active: true })
      ))
    )
  )
)

;; Installation management
(define-public (register-installation
  (contractor principal)
  (service-address (string-ascii 200))
  (service-type uint)
  (inspection-required bool))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
      (installation-id (var-get next-installation-id))
    )
    (begin
      (asserts! (or (is-eq tx-sender contractor) (can-manage-permits)) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active contractor-data) ERR-PERMIT-EXPIRED)
      (asserts! (< block-height (get expiry-date contractor-data)) ERR-PERMIT-EXPIRED)
      (asserts! (and (>= service-type SERVICE-TELEPHONE) (<= service-type SERVICE-FIBER)) ERR-INVALID-PERMIT-TYPE)
      (map-set installations
        { installation-id: installation-id }
        {
          contractor-id: contractor,
          service-address: service-address,
          service-type: service-type,
          installation-date: block-height,
          completion-date: none,
          is-completed: false,
          inspection-required: inspection-required,
          inspection-passed: false
        }
      )
      (var-set next-installation-id (+ installation-id u1))
      (ok installation-id)
    )
  )
)

(define-public (complete-installation (installation-id uint))
  (let
    (
      (installation-data (unwrap! (map-get? installations { installation-id: installation-id }) ERR-INSTALLATION-NOT-FOUND))
      (contractor-id (get contractor-id installation-data))
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor-id }) ERR-CONTRACTOR-NOT-FOUND))
    )
    (begin
      (asserts! (or (is-eq tx-sender contractor-id) (can-manage-permits)) ERR-NOT-AUTHORIZED)
      (map-set installations
        { installation-id: installation-id }
        (merge installation-data {
          completion-date: (some block-height),
          is-completed: true
        })
      )
      (map-set contractors
        { contractor-id: contractor-id }
        (merge contractor-data {
          installations-completed: (+ (get installations-completed contractor-data) u1)
        })
      )
      (ok true)
    )
  )
)

;; Infrastructure project management
(define-public (register-infrastructure-project
  (contractor principal)
  (project-name (string-ascii 100))
  (start-location (string-ascii 200))
  (end-location (string-ascii 200))
  (cable-length uint)
  (estimated-completion uint)
  (environmental-clearance bool))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
      (project-id (var-get next-project-id))
    )
    (begin
      (asserts! (can-manage-permits) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active contractor-data) ERR-PERMIT-EXPIRED)
      (asserts! (is-eq (get permit-type contractor-data) PERMIT-INFRASTRUCTURE) ERR-INVALID-PERMIT-TYPE)
      (map-set infrastructure-projects
        { project-id: project-id }
        {
          contractor-id: contractor,
          project-name: project-name,
          start-location: start-location,
          end-location: end-location,
          cable-length: cable-length,
          project-start: block-height,
          estimated-completion: estimated-completion,
          actual-completion: none,
          environmental-clearance: environmental-clearance
        }
      )
      (var-set next-project-id (+ project-id u1))
      (ok project-id)
    )
  )
)

(define-public (complete-infrastructure-project (project-id uint))
  (let
    (
      (project-data (unwrap! (map-get? infrastructure-projects { project-id: project-id }) ERR-INSTALLATION-NOT-FOUND))
      (contractor-id (get contractor-id project-data))
    )
    (begin
      (asserts! (or (is-eq tx-sender contractor-id) (can-manage-permits)) ERR-NOT-AUTHORIZED)
      (ok (map-set infrastructure-projects
        { project-id: project-id }
        (merge project-data { actual-completion: (some block-height) })
      ))
    )
  )
)

;; Inspection functions
(define-public (pass-inspection (installation-id uint))
  (let
    (
      (installation-data (unwrap! (map-get? installations { installation-id: installation-id }) ERR-INSTALLATION-NOT-FOUND))
    )
    (begin
      (asserts! (can-manage-permits) ERR-NOT-AUTHORIZED)
      (ok (map-set installations
        { installation-id: installation-id }
        (merge installation-data { inspection-passed: true })
      ))
    )
  )
)

;; Violation management
(define-public (record-violation (contractor principal))
  (let
    (
      (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor }) ERR-CONTRACTOR-NOT-FOUND))
    )
    (begin
      (asserts! (can-manage-permits) ERR-NOT-AUTHORIZED)
      (ok (map-set contractors
        { contractor-id: contractor }
        (merge contractor-data {
          violations: (+ (get violations contractor-data) u1)
        })
      ))
    )
  )
)

;; Read-only functions
(define-read-only (get-contractor (contractor principal))
  (map-get? contractors { contractor-id: contractor })
)

(define-read-only (get-installation (installation-id uint))
  (map-get? installations { installation-id: installation-id })
)

(define-read-only (get-infrastructure-project (project-id uint))
  (map-get? infrastructure-projects { project-id: project-id })
)

(define-read-only (is-permit-valid (contractor principal))
  (match (map-get? contractors { contractor-id: contractor })
    contractor-data (and
      (get is-active contractor-data)
      (< block-height (get expiry-date contractor-data))
      (get safety-certification contractor-data)
    )
    false
  )
)

(define-read-only (get-contractor-stats (contractor principal))
  (match (map-get? contractors { contractor-id: contractor })
    contractor-data {
      installations-completed: (get installations-completed contractor-data),
      violations: (get violations contractor-data),
      is-active: (get is-active contractor-data)
    }
    { installations-completed: u0, violations: u0, is-active: false }
  )
)
