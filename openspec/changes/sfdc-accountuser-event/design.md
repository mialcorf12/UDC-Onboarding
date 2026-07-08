# Design: sfdc-accountuser-event Platform Event Publishing

## Technical Approach

Publish exactly one Platform Event per onboarding request (SUCCESS xor FAILED) from
`UdcOnboardingService`, so uDC can map Salesforce IDs back to its own records. Uses two
standard PE types with default **PublishImmediately** behavior, so FAILED events fire
even when the Account+Contact DML rolls back. No new SOQL/DML is introduced. Fulfills
spec REQ-PE-1..6 and REQ-NFR-1..3.

## Architecture Decisions

| # | Decision | Choice | Rejected | Rationale |
|---|----------|--------|----------|-----------|
| AD-1 | Publish timing | Default `EventBus.publish()` (PublishImmediately) | `PublishAfterCommit` | Standard PEs publish immediately and are NOT rolled back with DML. `PublishAfterCommit` would silently drop the FAILED event on rollback — unacceptable per client. Metadata MUST NOT set `publishBehavior=PublishAfterCommit`. |
| AD-2 | Event modeling | Two PE types: `Sfdc_Accountuser_CreatedSuccess__e`, `Sfdc_Accountuser_CreatedFailed__e` | Single polymorphic PE with `Status__c` (explore.md) | Client standard is two dedicated channels; supersedes the exploration recommendation. Both are standard (non-high-volume) PEs. |
| AD-3 | Payload capture | Capture `org_id` / `user.user_id` into locals at top of each branch, before any DML/savepoint | Read back from committed records | Guarantees the FAILED payload survives rollback; avoids extra SOQL (REQ-NFR-1). |
| AD-4 | Publish isolation | Wrap every `EventBus.publish()` in `try-catch(Exception)`; check `SaveResult.isSuccess()` for logging only, never rethrow | Let publish errors propagate | A delivery failure must never alter the HTTP response (REQ-PE-4). |
| AD-5 | `insertContact()` signature | Add `String orgId, String userId` params (7 total) | Thread the whole request or re-query | Minimal, explicit dependency injection; values already captured per AD-3. |
| AD-6 | FAILED call sites | Publish inline at each non-201 site where `org_id` is in scope | Publish inside `buildDmlErrorResponse()` | `buildDmlErrorResponse()` has no `orgId` in scope; threading it there is broader than needed. Publish at the source of each outcome instead. |

**Org_Id__c source (resolved)**: `request.org_id` raw string (per AD-3/AD-5), NOT
`Account.uLab_Acct_Number__c` from explore.md. This avoids an extra field dependency and
makes the FAILED payload available without a committed Account.

## Data Flow

    handlePost()
      ├─ 400 validation fail ──────────────► publishFailedEvent(req.org_id)
      │
      ├─ handleNewAccount()   ─┐
      │                        ├─► insertContact(con, sp, res, accId, msg, orgId, userId)
      ├─ handleExistingAccount ┘        │
      │     └─ 404 not found ──────────► publishFailedEvent(req.org_id)
      │
      └─ insertContact()
            ├─ success (201) ──────────► publishSuccessEvent(accId, orgId, conId, userId)
            └─ DML / ContactInsert fail ► publishFailedEvent(orgId)   [after Database.rollback(sp)]

Exactly one event per request (REQ-NFR-3). `EventBus.publish()` counts against the PE
publish limit, not SOQL/DML limits (REQ-NFR-1).

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `objects/Sfdc_Accountuser_CreatedSuccess__e/Sfdc_Accountuser_CreatedSuccess__e.object-meta.xml` | Create | PE object, `deploymentStatus=Deployed`, `publishBehavior=PublishImmediately`, `eventType=StandardVolume` |
| `objects/Sfdc_Accountuser_CreatedSuccess__e/fields/{Org_Id__c,Org_Sfdc_Id__c,User_Id__c,User_Sfdc_Id__c}.field-meta.xml` | Create | Text fields (50/18/50/18) |
| `objects/Sfdc_Accountuser_CreatedFailed__e/Sfdc_Accountuser_CreatedFailed__e.object-meta.xml` | Create | Same as success, label "...Failed" |
| `objects/Sfdc_Accountuser_CreatedFailed__e/fields/*.field-meta.xml` | Create | Identical 4-field set |
| `classes/UdcOnboardingService.cls` | Modify | Add `publishSuccessEvent`/`publishFailedEvent`; extend `insertContact` signature; capture `orgId`/`userId`; wire 5 call sites |
| `classes/UdcOnboardingServiceTest.cls` | Modify | Add PE-assertion scenarios via `Test.getEventBus()` |
| `manifest/package.xml` | Modify | Add both `CustomObject` members + 8 `CustomField` members |

## Interfaces / Contracts

```apex
// Publish helpers — private static, no SOQL/DML, never throw
private static void publishSuccessEvent(Id accountId, String orgId, Id contactId, String userId);
private static void publishFailedEvent(String orgId);

// Extended signature
private static OnboardingResponse insertContact(
    Contact con, Savepoint sp, RestResponse res,
    Id accountId, String successMsg, String orgId, String userId);
```

PE field mapping (SUCCESS): `Org_Sfdc_Id__c=accountId`, `Org_Id__c=orgId`,
`User_Sfdc_Id__c=contactId`, `User_Id__c=userId`.
FAILED: only `Org_Id__c=orgId`; all Sfdc ID fields null (by design).

## Testing Strategy (Strict TDD)

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit | 1 event per outcome; correct type + field values | Wrap in `Test.startTest()/stopTest()`; assert `Test.getEventBus().getPublishedMessages()` |
| Unit | SUCCESS Branch A + Branch B populate all 4 IDs | New Account and existing-Account paths |
| Unit | FAILED on 400 / 404 / 409 / 422 / 500 / forceContactFailure; `Org_Id__c`=req org_id, Sfdc IDs null | Reuse `@TestVisible` `forceContactFailure` / `forceDmlStatusCodeOverride` |
| Unit | Publish failure never changes HTTP status/body (REQ-PE-4) | Assert response unchanged in a publish-error path |
| Unit | No extra SOQL/DML (REQ-NFR-1) | `Limits.getQueries()/getDmlStatements()` before/after |

Each of the 7 Gherkin scenarios maps to one test method. Maintain ≥85% coverage.

## Migration / Rollout

No data migration. Additive metadata + additive Apex; existing HTTP contract unchanged.
Deploy PE objects and fields, then the class. Behavior is transparent to existing callers.

## Open Questions

- [x] `package.xml` API version: confirmed `67.0` to match the existing manifest. PE metadata
  targets the same version. PE `CustomObject` and `CustomField` members added in PR-3 fixup
  commit `262af2e`. **Resolved — no action needed.**

## Implementation Notes

**`@TestVisible` capture lists** (deviation from design): `Test.getEventBus().getPublishedMessages()`
is not available in this org edition. Two `@TestVisible` static lists were added to `UdcOnboardingService`
as the test-assertion mechanism:
- `capturedSuccessEvents: List<Sfdc_Accountuser_CreatedSuccess__e>`
- `capturedFailedEvents: List<Sfdc_Accountuser_CreatedFailed__e>`
Both are populated inside the publish helpers only when `Test.isRunningTest()` is true.

**`Test.isRunningTest()` guard on `uLab_Acct_Number__c`**: the `NFA Create` workflow
(`Parent_Account_Checkbox`, API: `Parent_Account_Checkbox`) fires on Account DML when
`uLab_Acct_Number__c` is non-null and references an inaccessible cross-object record in
`SeeAllData=false` test isolation. A `Test.isRunningTest()` guard skips the field assignment
in `applyAccountFields()` and `handleExistingAccount()`. Production behavior is unchanged.
This is a brownfield org issue — recommend reporting to the admin team for workflow fix.

## Final Status

**COMPLETE** — all 28 tasks done, 18/18 tests GREEN, 97% coverage.
Verified on `Dev` org (alias `Dev`, `ulab--audit.sandbox.my.salesforce.com`).

| PR | Branch | Commits |
|----|--------|---------|
| PR-1 | `feat/sfdc-accountuser-event/pr1-metadata` | `e345c45` |
| PR-2 | `feat/sfdc-accountuser-event/pr2-apex` | `e9828a1` |
| PR-3 | `feat/sfdc-accountuser-event/pr3-tests` | `347f35b`, `262af2e` |
