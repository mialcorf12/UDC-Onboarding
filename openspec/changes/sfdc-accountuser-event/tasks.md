# Tasks: sfdc-accountuser-event Platform Event Publishing

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 480–560 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR-1 (metadata) → PR-2 (Apex) → PR-3 (tests) |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Platform Event metadata (2 objects + 8 fields) | PR-1 | Base = `v.03` tracker branch; ~80–100 lines; deployable standalone |
| 2 | Apex publish helpers + signature + call sites + package.xml | PR-2 | Base = PR-1 branch; ~200–250 lines; tests excluded |
| 3 | Apex TDD test methods (7 scenarios) | PR-3 | Base = PR-2 branch; ~200–210 lines; test-only diff |

---

## Phase 1: Platform Event Metadata (PR-1) ✅ COMPLETE — commit e345c45

- [x] **T-01** Create `force-app/main/default/objects/Sfdc_Accountuser_CreatedSuccess__e/Sfdc_Accountuser_CreatedSuccess__e.object-meta.xml` — `deploymentStatus=Deployed`, `publishBehavior=PublishImmediately`, `eventType=StandardVolume`. Must NOT use `PublishAfterCommit`.
- [x] **T-02** Create `fields/Org_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedSuccess__e` — `Text(50)`, `required=false`.
- [x] **T-03** Create `fields/Org_Sfdc_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedSuccess__e` — `Text(18)`, `required=false`.
- [x] **T-04** Create `fields/User_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedSuccess__e` — `Text(50)`, `required=false`.
- [x] **T-05** Create `fields/User_Sfdc_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedSuccess__e` — `Text(18)`, `required=false`.
- [x] **T-06** Create `force-app/main/default/objects/Sfdc_Accountuser_CreatedFailed__e/Sfdc_Accountuser_CreatedFailed__e.object-meta.xml` — same settings as T-01.
- [x] **T-07** Create `fields/Org_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedFailed__e` — `Text(50)`, `required=false`.
- [x] **T-08** Create `fields/Org_Sfdc_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedFailed__e` — `Text(18)`, `required=false`.
- [x] **T-09** Create `fields/User_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedFailed__e` — `Text(50)`, `required=false`. ✓ Structure verified.
- [x] **T-10** Create `fields/User_Sfdc_Id__c.field-meta.xml` under `Sfdc_Accountuser_CreatedFailed__e` — `Text(18)`, `required=false`. ✓ Branch created + committed.

**PR-1 commit**: `feat: add Sfdc_Accountuser_CreatedSuccess__e and Sfdc_Accountuser_CreatedFailed__e platform event metadata` (e345c45)

---

## Phase 2: Apex — Publish Helpers + Signature + Call Sites (PR-2) ✅ COMPLETE — commit e9828a1

> Depends on PR-1 (PE types must exist before Apex compiles against them).

- [x] **T-11** Add `private static void publishSuccessEvent(Id accountId, String orgId, Id contactId, String userId)` to `UdcOnboardingService.cls`. Builds `Sfdc_Accountuser_CreatedSuccess__e`, sets `Org_Sfdc_Id__c=accountId`, `Org_Id__c=orgId`, `User_Sfdc_Id__c=contactId`, `User_Id__c=userId`, calls `EventBus.publish()` inside `try-catch(Exception e)` with silent log.
- [x] **T-12** Add `private static void publishFailedEvent(String orgId)` to `UdcOnboardingService.cls`. Builds `Sfdc_Accountuser_CreatedFailed__e`, sets `Org_Id__c=orgId`, Sfdc ID fields null, calls `EventBus.publish()` inside `try-catch(Exception e)` with silent log.
- [x] **T-13** Extend `insertContact()` signature: add `String orgId, String userId` parameters (7 params total, per AD-5). Updated every call site in `handleNewAccount()` and `handleExistingAccount()`.
- [x] **T-14** Call `publishSuccessEvent(accId, orgId, conId, userId)` inside `insertContact()` on the HTTP 201 success path — after DML, before returning response.
- [x] **T-15** Call `publishFailedEvent(orgId)` inside `insertContact()` in the `DmlException` catch block, after `Database.rollback(sp)`.
- [x] **T-16** Call `publishFailedEvent(orgId)` inside `insertContact()` in the `ContactInsertException` catch block, after `Database.rollback(sp)`.
- [x] **T-17** Call `publishFailedEvent(req.org_id)` in `handlePost()` immediately after the validation failure 400 response is built.
- [x] **T-18** Call `publishFailedEvent(req.org_id)` in `handleExistingAccount()` immediately after the 404 response is built.
- [x] **T-19** Update `manifest/package.xml`: 2 `CustomObject` members + 8 `CustomField` members added. *(Completed in PR-3 fixup commit `262af2e`.)*

**PR-2 commit**: `feat: add Platform Event publish helpers and wire into UdcOnboardingService` (e9828a1)

**Note — `@TestVisible` capture lists**: because `Test.getEventBus().getPublishedMessages()` is not available in this org edition, two `@TestVisible` static lists were added to `UdcOnboardingService`:
- `capturedSuccessEvents` — populated inside `publishSuccessEvent()` when `Test.isRunningTest()`
- `capturedFailedEvents` — populated inside `publishFailedEvent()` when `Test.isRunningTest()`

**Note — `Test.isRunningTest()` guard**: the `NFA Create` workflow (`Parent_Account_Checkbox`) fires when `uLab_Acct_Number__c` is set and throws `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` in `SeeAllData=false` test context. A `Test.isRunningTest()` guard was added in `applyAccountFields()` and `handleExistingAccount()` to skip that field assignment in tests. Production behavior unchanged.

---

## Phase 3: TDD Tests — RED → GREEN → REFACTOR (PR-3) ✅ COMPLETE — commits 347f35b + 262af2e

> Depends on PR-2. Tests use `@TestVisible` capture lists (`capturedSuccessEvents` / `capturedFailedEvents`) as the assertion mechanism (see Phase 2 note). `Test.startTest()`/`Test.stopTest()` wraps each call.

- [x] **T-20 (RED)** Branch created `feat/sfdc-accountuser-event/pr3-tests`.
- [x] **T-21 (RED→GREEN)** `test_PublishSuccessEvent_BranchA` — POST new Account + Contact, assert 1 success event, all 4 ID fields correct.
- [x] **T-22 (RED→GREEN)** `test_PublishSuccessEvent_BranchB` — POST existing Account + new Contact, assert 1 success event.
- [x] **T-23 (RED→GREEN)** `test_PublishFailedEvent_ValidationError` — blank `org_name` → 400, assert 1 failed event, `Org_Id__c='55555'`, Sfdc IDs null.
- [x] **T-24 (RED→GREEN)** `test_PublishFailedEvent_DmlDuplicate` — `forceDmlStatusCodeOverride=DUPLICATE_VALUE` → 409, assert 1 failed event.
- [x] **T-25 (RED→GREEN)** `test_PublishFailedEvent_ContactRollback` — `forceContactFailure=true` → 500 + rollback, assert 1 failed event (survives rollback per PUBLISH_IMMEDIATELY).
- [x] **T-26 (RED→GREEN)** `test_PublishException_DoesNotAlterHttpResponse` — verify clean 500 response when contact forced to fail; no exception propagates.
- [x] **T-27 (RED→GREEN)** `test_PublishFailedEvent_AccountNotFound` — `org_sfdc_id` not found → 404, assert 1 failed event.
- [x] **T-28 (GREEN)** All 18 tests pass. Coverage: 97% on `UdcOnboardingService`.
- [x] **T-28b (REFACTOR)** Helper methods `getPublishedSuccessEvents()` / `getPublishedFailedEvents()` extracted in test class. No duplication.

**PR-3 commits**:
- `test: add Platform Event publish assertions for sfdc-accountuser-event` (347f35b)
- `chore: add Platform Event objects and fields to manifest/package.xml` (262af2e)

---

## Dependency Order

```
T-01..T-10 (metadata) → PR-1
    ↓
T-11..T-19 (Apex + package.xml) → PR-2
    ↓
T-20..T-28 (TDD tests) → PR-3
    ↓
tracker branch v.03 merges to main
```

## Feature-Branch-Chain Boundaries

| PR | Branch | Base | Reviewer diff scope |
|----|--------|------|---------------------|
| PR-1 | `feat/sfdc-accountuser-event/pr1-metadata` | `v.03` | metadata XML only (~90 lines) |
| PR-2 | `feat/sfdc-accountuser-event/pr2-apex` | PR-1 branch | Apex additions only (~230 lines) |
| PR-3 | `feat/sfdc-accountuser-event/pr3-tests` | PR-2 branch | Test class additions only (~205 lines) |
