# Exploration: sfdc-accountuser-event Platform Event Feature

**Change**: sfdc-accountuser-event
**Date**: 2026-07-03
**Branch**: v.03
**Status**: explored
**Artifact store**: hybrid (Engram + OpenSpec files)

---

## Executive Summary

`UdcOnboardingService.cls` is a Salesforce Apex REST endpoint that atomically creates
or updates Account + Contact records. It has a single convergence point — `insertContact()`
— where success (201) is confirmed and both `accountId` / `contactId` are available
on the `OnboardingResponse`. The Platform Event feature adds a publish call at every
outcome path: `Sfdc_Accountuser_CreatedSuccess__e` on HTTP 201, and
`Sfdc_Accountuser_CreatedFailed__e` on any non-201 outcome. All publish calls use
`EventBus.publish()` with default `PublishImmediately` behavior — events are NOT
transactional and survive DML rollback.

> **⚠️ Superseded recommendation**: this artifact originally recommended a single
> polymorphic PE with `Status__c` discriminator. The client's integration standard
> requires **two separate Platform Event types**. See `proposal.md` and `design.md`
> (AD-2) for the authoritative decision.

---

## Current State

### Architecture

```
POST /services/apexrest/UdcOnboardingService/
│
├─ handlePost()                        ← entry point; JSON deserialize + validate
│   ├─ [Branch A] handleNewAccount()   ← insert Account → insertContact()
│   └─ [Branch B] handleExistingAccount() ← SOQL lookup + update Account → insertContact()
│
├─ insertContact()                     ← SINGLE CONVERGENCE POINT
│   ├─ SUCCESS → res.statusCode=201, OnboardingResponse{success:true, accountId, contactId}
│   └─ FAILURE → buildDmlErrorResponse() → res.statusCode=4xx/5xx
│
└─ buildDmlErrorResponse()             ← DML error classifier (409/422/500)
```

### Key Facts from Code Reading

| Item | Detail |
|------|--------|
| `OnboardingResponse.accountId` | `Account.Id` — available on success in `insertContact()` L452-457 |
| `OnboardingResponse.contactId` | `Contact.Id` — available on success in `insertContact()` L452-457 |
| `Account.uLab_Acct_Number__c` | `Decimal` field — maps to `org.id` in payload as `org_id` |
| `Contact.Portal_User_ID__c` | `String` field — maps to `user.id` in payload as `user_id` |
| Success path | `insertContact()` lines 452–458: `res.statusCode = 201` |
| DML failure path | `buildDmlErrorResponse()` called from both `insertContact()` and `handleNewAccount()`/`handleExistingAccount()` |
| Validation failure path | `handlePost()` lines 148–154 — returns early at HTTP 400, no DML |
| Rollback mechanism | `Database.rollback(sp)` inside `buildDmlErrorResponse()` and `insertContact()` catch |
| `@TestVisible` flags | `forceContactFailure`, `forceDmlStatusCodeOverride` |

### Existing Metadata

```
force-app/main/default/
├── classes/
│   ├── UdcOnboardingService.cls
│   ├── UdcOnboardingService.cls-meta.xml
│   ├── UdcOnboardingServiceTest.cls
│   └── UdcOnboardingServiceTest.cls-meta.xml
└── objects/
    ├── Account/
    │   ├── Account.object-meta.xml
    │   └── fields/UDC_Onboarding__c.field-meta.xml
    └── Contact/
        ├── Contact.object-meta.xml
        └── fields/UDC_Onboarding__c.field-meta.xml

NO platformEvents/ directory exists yet.
```

### Test Class State

- 11 scenarios, all passing (Strict TDD confirmed via prior sessions)
- Coverage: ~97%
- Uses `@TestVisible` flags for DML-path determinism
- `Test.startTest()/stopTest()` wraps `handlePost()` — Platform Events published inside
  `Test.startTest()/stopTest()` are processed synchronously in test context; use
  `Test.getEventBus().deliver()` if needed for assertion

---

## Affected Areas

| File | Change Type | Reason |
|------|------------|--------|
| `force-app/main/default/classes/UdcOnboardingService.cls` | Modify | Add `publishEvent()` helper; call it in `insertContact()` on success and in `buildDmlErrorResponse()` on failure |
| `force-app/main/default/classes/UdcOnboardingServiceTest.cls` | Modify | Add test scenarios for event publishing — verify payload fields; mock or use `Test.getEventBus()` |
| `force-app/main/default/objects/platformEvents/` *(new)* | Create | Platform Event type metadata (`sfdc_accountuser__e` — single type approach) |
| `manifest/package.xml` | Modify | Add `PlatformEventChannel` or `CustomObject` member for the Platform Event |

---

## Approaches

### Approach 1 — Two Separate Platform Event Types

Create `sfdc_accountuser_createdSuccess__e` and `sfdc_accountuser_createdFailed__e` as
two distinct Salesforce Platform Event objects.

- **Pros**:
  - Subscriber routing is implicit — uDC subscribes to different channels per outcome
  - No conditional field reading by uDC
  - Clear semantic naming per channel

- **Cons**:
  - Two metadata objects to maintain, deploy, version, and keep in sync
  - Each event type has its own governor limit allotment entry
  - uDC needs to maintain two active subscriptions and two subscriber handlers
  - Adding a third outcome (e.g., `updatedSuccess`) requires a third object
  - Platform Event API name length constraint: `sfdc_accountuser_createdSuccess__e` =
    35 chars (API names have a 40-char hard cap in Salesforce) — borderline but fits

- **Effort**: Medium

### Approach 2 — Single Polymorphic Platform Event Type ~~✅ RECOMMENDED~~ ❌ SUPERSEDED

Create one event type `Sfdc_Accountuser__e` (API: `Sfdc_Accountuser__e`) with a
`Status__c` text field (`SUCCESS` / `FAILED`) and all payload fields on the same object.

- **Pros**:
  - Single metadata object to maintain and deploy
  - uDC subscribes once; routes by `Status__c` value in subscriber logic
  - Easier to extend (add fields without a second object)
  - Half the governor limit consumption footprint
  - Event name communicated to uDC via field value, matching the logical names
    (`sfdc.accountuser.createdSuccess` / `sfdc.accountuser.createdFailed`) semantically
  - Mirrors common enterprise PE patterns (single channel, typed by a discriminator field)

- **Cons**:
  - uDC subscriber must branch on `Status__c` (one extra conditional)
  - Failure payload fields will be null on success events and vice versa (sparse)
  - Schema must accommodate both success and failure fields even when some are null

- **Effort**: Low

### Approach 3 — Queueable-wrapped publish (async isolation)

Wrap `EventBus.publish()` inside a `Queueable` to decouple publish from the REST
transaction entirely.

- **Pros**: Total isolation — publish failure cannot affect REST response
- **Cons**: Adds Queueable complexity; `EventBus.publish()` already does not throw on
  delivery failure and is transactionally independent; adds latency. Overkill for this
  use case.
- **Effort**: High

---

## Recommendation

> **⚠️ SUPERSEDED** — client standard requires two PE types. Approach 1 was selected.
> See `proposal.md` and `design.md` AD-2 for rationale.

~~**Use Approach 2 — single Platform Event type `Sfdc_Accountuser__e`.**~~

**Implemented: Approach 1 — two separate Platform Event types.**
- `Sfdc_Accountuser_CreatedSuccess__e` — published on HTTP 201
- `Sfdc_Accountuser_CreatedFailed__e` — published on any non-201 outcome

### Rationale

1. `EventBus.publish()` is **fire-and-forget** and does not participate in the
   surrounding DML transaction. If publish fails (delivery error), it does NOT roll
   back the already-committed Account + Contact DML. This is the critical architectural
   property that makes publish safe to call directly inside `insertContact()` and
   `buildDmlErrorResponse()`.

2. A single event type with a `Status__c` discriminator is the established enterprise
   pattern. uDC already subscribes to Platform Events and can route by field value.

3. Two types doubles maintenance surface with no Apex or governor-limit benefit.

### Injection Point

```
insertContact() — AFTER "res.statusCode = 201" (line 452), BEFORE return:
    publishOnboardingEvent('SUCCESS', accountId, accULabNumber, contactId, contactPortalUserId);

buildDmlErrorResponse() — AFTER setting errResp fields, BEFORE return:
    publishOnboardingEvent('FAILED', null, null, null, null);
```

The `publishOnboardingEvent()` helper must be called **after** the DML commit (outside
the try/catch DML block) and must NOT throw — wrap in its own try/catch that swallows
or logs the error without re-throwing, so a PE delivery issue never converts a 201 into
a 500.

### Platform Event Object Design

**API Name**: `Sfdc_Accountuser__e`
**Label**: SFDC Account User

**Fields**:

| Logical Key (JSON) | Field API Name | Type | Length | Notes |
|--------------------|---------------|------|--------|-------|
| *(discriminator)* | `Status__c` | Text | 10 | `SUCCESS` or `FAILED` |
| `org.id` | `Org_Id__c` | Text | 50 | = `Account.uLab_Acct_Number__c` (Decimal → String) |
| `org.sfdc_id` | `Org_Sfdc_Id__c` | Text | 18 | = `Account.Id` |
| `user.id` | `User_Id__c` | Text | 50 | = `Contact.Portal_User_ID__c` |
| `user.user_sfdc_id` | `User_Sfdc_Id__c` | Text | 18 | = `Contact.Id` |

> **Note on Salesforce PE naming constraints**: Platform Event field API names cannot
> contain dots or hyphens. The logical JSON keys (`org.id`, `user.id`) must be mapped
> to valid Apex identifiers. The mapping above is the proposed canonical field naming.

**Publish Mode**: `PublishImmediately` (default for standard Platform Events) — events
are NOT rolled back with DML. This ensures FAILED events always arrive even when the
DML transaction was rolled back. **Do NOT use `PublishAfterCommit`.**

---

## Governor Limit Analysis

| Limit | Value (Enterprise/Unlimited) | Impact |
|-------|------------------------------|--------|
| Platform Event publishes | 250,000 / 24h (shared across all PE types) | Each POST publishes 1 event; at scale (~250k onboardings/day) this could be reached — but this is an onboarding endpoint, not a bulk processor |
| `EventBus.publish()` DML limit | Does NOT count against DML governor (150) | Safe to call after DML commit |
| `EventBus.publish()` SOQL limit | 0 SOQL consumed | No additional query cost |
| PE publish in test context | `Test.getEventBus().deliver()` required | Must call after `Test.stopTest()` to process in-flight events |
| Async PE delivery | Not guaranteed immediately | uDC must be resilient to delayed delivery (standard PE behavior) |

---

## Event Field Naming — Constraint Analysis

Salesforce Platform Event custom field API names:
- Must be valid Apex identifiers (alphanumeric + underscore, must start with letter)
- Cannot contain dots (`.`), hyphens (`-`), or spaces
- Must end with `__c`

| Logical JSON Key | Problem | Proposed API Name |
|-----------------|---------|------------------|
| `org.id` | Dot not allowed | `Org_Id__c` |
| `org.sfdc_id` | Dot + underscore | `Org_Sfdc_Id__c` |
| `user.id` | Dot not allowed | `User_Id__c` |
| `user.user_sfdc_id` | Dot not allowed | `User_Sfdc_Id__c` |

uDC subscriber transforms the flat PE fields back into the nested JSON structure if needed.

---

## Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| **Publish failure silently swallowed** | Medium | Wrap `EventBus.publish()` in try/catch; log `Database.SaveResult` from publish; never re-throw |
| **PE publish counted against 250k/day limit at scale** | Low | Onboarding endpoint is not bulk; monitor via Event Monitoring in production |
| **DML commit + publish non-atomicity** | Low (by design) | PE delivery is inherently async/eventually consistent; uDC must handle replay gap |
| **Test context: PE not delivered without explicit `Test.getEventBus().deliver()`** | Medium | Existing tests use `Test.startTest()/stopTest()`; add `Test.getEventBus().deliver()` in new test scenarios |
| **`insertContact()` is `static private`** | None | `publishOnboardingEvent()` can be `static private` too; called from `insertContact()` and `buildDmlErrorResponse()` without any refactor |
| **`buildDmlErrorResponse()` lacks Account/Contact Ids on DML failure** | Low | On failure path, `Org_Id__c`, `Org_Sfdc_Id__c`, `User_Id__c`, `User_Sfdc_Id__c` will be null — uDC subscribes knowing failure events carry no IDs |
| **Account insert failure (Branch A lines 222–226) uses `buildDmlErrorResponse(e, res, null)`** — Account never committed, so no sfdc_id available | None (expected) | Failure event published with null IDs; uDC ignores IDs on failure events |
| **`PublishAfterCommit` mode**: if transaction is rolled back after savepoint, event is NOT published | Important | Correct behavior — rolled-back transactions should NOT emit success events. Only committed DML produces the event. |

---

## Implementation Sketch (for Design phase)

```apex
// New private helper — added to UdcOnboardingService
private static void publishOnboardingEvent(
    String status,
    Id accountId,
    String orgULabNumber,
    Id contactId,
    String portalUserId
) {
    Sfdc_Accountuser__e evt = new Sfdc_Accountuser__e();
    evt.Status__c       = status;
    evt.Org_Sfdc_Id__c  = (accountId != null) ? String.valueOf(accountId) : null;
    evt.Org_Id__c       = orgULabNumber;
    evt.User_Sfdc_Id__c = (contactId != null) ? String.valueOf(contactId) : null;
    evt.User_Id__c      = portalUserId;

    try {
        Database.SaveResult sr = EventBus.publish(evt);
        // sr.isSuccess() == false means delivery queuing failed — log but do not throw
    } catch (Exception ex) {
        // Never let publish failure affect the REST response
    }
}
```

Injection points:

```
insertContact() — success path (currently line 452):
    res.statusCode = 201;
    // ... build successResp ...
    publishOnboardingEvent('SUCCESS', accountId, accULabNumber, conToInsert.Id, conToInsert.Portal_User_ID__c);
    return successResp;

buildDmlErrorResponse() — after errResp built, before return:
    publishOnboardingEvent('FAILED', null, null, null, null);
    return errResp;
```

> **Challenge**: `insertContact()` currently receives `accountId` as an `Id` parameter
> but does NOT receive `Account.uLab_Acct_Number__c`. The method signature must be
> extended (or a new parameter added) to pass the org number for the event payload.
> This is the only signature change required.

---

## Ready for Proposal

**Yes.** The codebase is well-understood, the injection point is clear (`insertContact()`
and `buildDmlErrorResponse()`), the metadata design is resolved (single PE type), and
governor limit implications are acceptable. The design phase can proceed directly from
this exploration.

---

## Metadata to Create

```
force-app/main/default/
└── objects/
    └── Sfdc_Accountuser__e/                          ← NEW Platform Event
        ├── Sfdc_Accountuser__e.object-meta.xml
        └── fields/
            ├── Status__c.field-meta.xml
            ├── Org_Id__c.field-meta.xml
            ├── Org_Sfdc_Id__c.field-meta.xml
            ├── User_Id__c.field-meta.xml
            └── User_Sfdc_Id__c.field-meta.xml
```

`package.xml` additions:

```xml
<types>
    <members>Sfdc_Accountuser__e</members>
    <members>Sfdc_Accountuser__e.Status__c</members>
    <members>Sfdc_Accountuser__e.Org_Id__c</members>
    <members>Sfdc_Accountuser__e.Org_Sfdc_Id__c</members>
    <members>Sfdc_Accountuser__e.User_Id__c</members>
    <members>Sfdc_Accountuser__e.User_Sfdc_Id__c</members>
    <name>CustomObject</name>
</types>
```

---

---

## Implementation Status

**COMPLETE** — implemented as Approach 1 (two PE types). Commits:
- PR-1 `e345c45` — Platform Event metadata (2 objects + 8 fields)
- PR-2 `e9828a1` — Apex publish helpers + 5 call sites
- PR-3 `347f35b` + `262af2e` — 7 test scenarios GREEN + package.xml

18/18 tests passing. Coverage: 97% on `UdcOnboardingService`.

*Artifact: sdd/sfdc-accountuser-event/explore | type: architecture | store: hybrid*
