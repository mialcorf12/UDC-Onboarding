# Tasks: udc-onboarding-service

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~360–420 |
| 400-line budget risk | Medium |
| Chained PRs recommended | No (within range; single PR acceptable) |
| Suggested split | Single PR |
| Delivery strategy | auto-forecast |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | All 4 files in one atomic PR | PR 1 | Foundation + RED + GREEN + VERIFY + Cleanup together; ~400 lines total; Medium risk accepted |

---

## Phase 1: Foundation — Skeletons & Meta

- [x] 1.1 Create `UdcOnboardingService.cls-meta.xml` — API 66.0, status Active, no logic.
- [x] 1.2 Create `UdcOnboardingServiceTest.cls-meta.xml` — API 66.0, status Active, no logic.
- [x] 1.3 Create `UdcOnboardingService.cls` skeleton — `global with sharing class`, `@RestResource(urlMapping='/UdcOnboardingService/*')`, empty inner classes `OnboardingRequest` (includes field `String onboard_type`), `ContactRequest`, `OnboardingResponse` (all fields declared, no methods yet). Compiles clean.
- [x] 1.4 Add empty `@HttpPost global static OnboardingResponse handlePost()` stub — returns null; class still compiles.

## Phase 2: RED — Failing Tests First

- [x] 2.1 Create `UdcOnboardingServiceTest.cls` skeleton — `@isTest` class with `RestContext` setup helper method (`setupRestContext(String body)`).
- [x] 2.2 Add `testMissingOrgName()` — sets payload with null org_name; asserts `statusCode == 400` (REQ-2). Test fails (stub returns null).
- [x] 2.3 Add `testMissingLastName()` — sets payload with null user.last_name; asserts `statusCode == 400` (REQ-2).
- [x] 2.4 Add `testInvalidEmail()` — sets malformed email; asserts `statusCode == 400` (REQ-2).
- [x] 2.5 Add `testSuccessUdcFlagTrue()` — valid payload with `onboard_type = 'udesign.cloud'`; asserts `statusCode == 201`, `UDC_Onboarding__c == true` on both Account and Contact (REQ-3, REQ-4, REQ-5).
- [x] 2.6 Add `testSuccessUdcFlagFalse()` — valid payload, onboard_type absent; asserts `statusCode == 201`, `UDC_Onboarding__c == false` on both records (REQ-5).
- [x] 2.7 Add `testRollbackOnContactFailure()` — valid Account payload but blank `last_name` on contact (forces platform DML error); asserts `statusCode == 500` AND `[SELECT Id FROM Account WHERE Name = :testName].isEmpty()` (REQ-6).
- [x] 2.8 Add `testAccountInsertFailure()` — force Account DML failure; asserts `statusCode == 500`, no Contact created (REQ-6/REQ-7).
- [x] 2.9 Run `sf apex run test -n UdcOnboardingServiceTest` — confirm all 7 tests compile and FAIL as expected (RED confirmed). ✅ 0% pass rate confirmed.

## Phase 3: GREEN — Implement Service Logic

- [x] 3.1 Implement `OnboardingRequest`, `ContactRequest`, `OnboardingResponse` inner class fields — field `onboard_type` (underscore) maps directly from JSON key `onboard_type` via `JSON.deserialize`. No aliasing needed.
- [x] 3.2 Implement `validateInput(OnboardingRequest req)` private static method — null/empty check on `org_name` and `user.last_name`; email regex via `Pattern.matches(...)` (REQ-2).
- [x] 3.3 Implement Account field mapping in `handlePost()` — `RecordTypeId` via `Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Commercial').getRecordTypeId()`; map Name, Type, Phone, address fields, string→Boolean coercion for `Is_Parent__c`, `Signature_Required__c`, `Out_of_Service_Area__c` (REQ-3).
- [x] 3.4 Assign `UDC_Onboarding__c = (req.onboard_type == 'udesign.cloud')` on Account and Contact (REQ-5). Note: field must be reapplied AFTER stripInaccessible to survive FLS stripping.
- [x] 3.5 Implement Contact field mapping — `AccountId = acc.Id`, `RecordTypeId` for Contact `Commercial`, map name/email/phone/mailing address, `user_type` → `Company_User_Type__c = 'Account Owner'`, `role` → `Contact_Role__c` (REQ-4).
- [x] 3.6 Implement savepoint + DML sequence: `sp = Database.setSavepoint()` → `Security.stripInaccessible(CREATABLE, [acc])` → `insert acc` (catch DmlException → 500, return) → `Security.stripInaccessible(CREATABLE, [con])` → `insert con` (catch DmlException/ContactInsertException → `Database.rollback(sp)` → 500, return) (REQ-6, REQ-8).
- [x] 3.7 Implement success response — `statusCode = 201`, return `OnboardingResponse { success=true, accountId=acc.Id, contactId=con.Id }` (REQ-7).
- [x] 3.8 Run `sf apex run test -n UdcOnboardingServiceTest` — confirm all 7 tests PASS (GREEN confirmed). ✅ 100% pass rate.

## Phase 4: VERIFY — Coverage & Assertions

- [x] 4.1 Run `sf apex run test -n UdcOnboardingServiceTest --code-coverage` — 92% coverage on `UdcOnboardingService.cls` (≥85% threshold met) ✅
- [x] 4.2 Rollback test verified — SOQL confirms 0 RollbackTest accounts post-test
- [x] 4.3 RestContext.response.statusCode confirmed: 400 in 3 tests, 500 in 2 tests, 201 in 2 tests ✅

## Phase 5: Cleanup — Comments & Final Review

- [x] 5.1 Inline comments added to UdcOnboardingService.cls documenting savepoint strategy, string→Boolean coercion, UDC flag reapplication rationale
- [x] 5.2 All field mappings verified against spec REQ-3 and REQ-4 — no missed fields
- [x] 5.3 with sharing declared ✅; no SOQL/DML in loops ✅; stripInaccessible applied before both inserts ✅

---

## Phase 6 — Branch B + Error Code Refinement (2026-06-30)

| # | Task | Status |
|---|------|--------|
| 28 | Add `org_sfdc_id` field to `OnboardingRequest` inner class | [x] |
| 29 | Implement branch decision logic in `handlePost` | [x] |
| 30 | Implement `handleExistingAccount` (SOQL lookup, 404 guard, Account update, savepoint) | [x] |
| 31 | Reuse `buildContact` + `insertContact` helpers in Branch B | [x] |
| 32 | RED: write `testOrgSfdcIdNotFound` (expect 404) | [x] |
| 33 | RED: write `testOrgSfdcIdFoundUpdatesAccountAndCreatesContact` (expect 201, verify update not insert) | [x] |
| 34 | GREEN: deploy Branch B — Scenarios 8 and 9 pass | [x] |
| 35 | Extract `buildDmlErrorResponse` helper (rollback + StatusCode classification) | [x] |
| 36 | Add `@TestVisible forceDmlStatusCodeOverride` field | [x] |
| 37 | Replace three inline `catch(DmlException)` blocks with `buildDmlErrorResponse` calls | [x] |
| 38 | RED: write `testDuplicateRecordReturns409` (inject DUPLICATE_VALUE StatusCode) | [x] |
| 39 | RED: write `testValidationRuleViolationReturns422` (inject FIELD_CUSTOM_VALIDATION_EXCEPTION) | [x] |
| 40 | GREEN: deploy — all 11/11 tests pass | [x] |
| 41 | Update HTTP contract comment in class Javadoc (add 409, 422) | [x] |
| 42 | Update jira/ and sdd-artifacts/ docs | [x] |

---

## Phase 7 — org_id and user_id Fields (2026-06-30)

| # | Task | Status |
|---|------|--------|
| 43 | Add `org_id` to `OnboardingRequest` inner class | [x] |
| 44 | Add `user_id` to `ContactRequest` inner class | [x] |
| 45 | Map `org_id` → `Account.uLab_Acct_Number__c` in `applyAccountFields` (Decimal.valueOf with null guard) | [x] |
| 46 | Map `user_id` → `Contact.Portal_User_ID__c` in `buildContact` | [x] |
| 47 | Reapply `uLab_Acct_Number__c` after `stripInaccessible` in `handleNewAccount` (Branch A) | [x] |
| 48 | Reapply `uLab_Acct_Number__c` after `stripInaccessible` in `handleExistingAccount` (Branch B) | [x] |
| 49 | Reapply `Portal_User_ID__c` after `stripInaccessible` in `insertContact` | [x] |
| 50 | Update `buildPayload` helper with `org_id: "12345"` and `user_id: "USR001"` | [x] |
| 51 | Add `uLab_Acct_Number__c` + `Portal_User_ID__c` to SOQL and assertions in 3 success tests | [x] |
| 52 | Deploy and verify: 11/11 tests GREEN | [x] |

**COMPLETE — 52/52 tasks, 11/11 tests GREEN, 2026-06-30**
