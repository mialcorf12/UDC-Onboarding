# Design: UDC Onboarding Service

## Technical Approach
A single `@RestResource(urlMapping='/UdcOnboardingService/*')` global class with a `@HttpPost` `handlePost()` method. Inner classes model the JSON payload for type-safe deserialization. Validation runs before any DML (HTTP 400 path); a savepoint guards atomicity for the Account+Contact insert sequence (HTTP 500 path). Maps to spec REQ-1..REQ-8. Greenfield code — no Apex exists yet; custom fields and `Commercial` record types are already deployed.

## Architecture Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Class structure | Single class + inner classes (`OnboardingRequest`, `ContactRequest`, `OnboardingResponse`) | Scope is one endpoint; inner wrappers give clean `JSON.deserialize` mapping without utility-class sprawl |
| 2 | RecordType resolution | `Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Commercial').getRecordTypeId()` at runtime | Hardcoded IDs differ per org and break on deploy; dynamic lookup is portable |
| 3 | Transaction control | `Database.setSavepoint()` before Account insert; `Database.rollback(sp)` in Contact catch ONLY | Account catch returns 500 immediately — rollback not called there because no savepoint operations have executed yet. Only Contact catch calls rollback(sp) to undo the Account insert. |
| 4 | Error extraction | `e.getDmlMessage(0)` | Returns the user-facing validation message; `getMessage()` adds stack-trace noise (REQ-7) |
| 5 | String→Boolean | Compare payload string `== 'true'` before assigning Checkbox fields | Payload sends "true"/"false" as strings for Is_Parent__c, Signature_Required__c, Out_of_Service_Area__c (REQ-3) |
| 6 | Email validation | `Pattern.matches('^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$', email)` | Pre-DML format check yields HTTP 400 not 500 (REQ-2) |
| 7 | Sharing model | `with sharing` | Required for external-facing REST; respects org sharing rules (REQ-8) |
| 8 | HTTP status | Set `RestContext.response.statusCode` (201/400/500) before return | @RestResource does not derive status from return value |
| 9 | FLS/CRUD enforcement | `Security.stripInaccessible(AccessType.CREATABLE, records)` before each insert | `with sharing` covers record-level sharing only; stripInaccessible enforces FLS on writable fields (REQ-8). No SOQL reads in happy path so WITH SECURITY_ENFORCED is N/A. |
| 10 | Payload field name | `onboard_type` (underscore) in JSON and inner class | Apex field names cannot contain hyphens; portal team confirmed rename from `onboard-type` to `onboard_type`. No workaround needed — direct JSON.deserialize mapping works. |
| AD-11 | Extract `buildDmlErrorResponse` as shared helper | Three catch blocks had identical rollback + error construction logic. Single method eliminates duplication and ensures consistent classification across all DML failure points. |
| AD-12 | Classify DML errors by `e.getDmlType(0)` StatusCode | Parsing error messages is brittle. `StatusCode` enum is the authoritative platform signal. Maps to 409/422/500 without string matching. |
| AD-13 | `@TestVisible forceDmlStatusCodeOverride` for 409/422 coverage | Platform `DmlException` with a controlled `getDmlType(0)` cannot be constructed in unit tests. This field mirrors the existing `forceContactFailure` pattern and keeps production code clean (`Test.isRunningTest()` guard). |

## Data Flow
```
Portal HTTP POST  { "onboard_type": "udesign.cloud", ... }
  → handlePost()
  → JSON.deserialize → OnboardingRequest
  → validateInput() ──fail──→ statusCode=400 INVALID_INPUT (no DML)
  → sp = Database.setSavepoint()
  → stripInaccessible(CREATABLE, [acc]) → insert Account
      └──DmlException──→ catch → statusCode=500 SALESFORCE_DML_ERROR (no rollback needed)
  → stripInaccessible(CREATABLE, [con]) → insert Contact (AccountId=acc.Id)
      └──DmlException──→ catch → rollback(sp) → statusCode=500 SALESFORCE_DML_ERROR
  → statusCode=201 { success:true, accountId, contactId }
```

### Branch B Data Flow (org_sfdc_id provided)

1. Deserialize JSON → validate inputs (same gate as Branch A) → 400 on failure
2. SOQL: `SELECT Id FROM Account WHERE Id = :req.org_sfdc_id LIMIT 1`
3. If empty → return 404 `ACCOUNT_NOT_FOUND` (no DML)
4. `applyAccountFields` onto retrieved Account → `Security.stripInaccessible(UPDATABLE)` → `update`
5. `buildContact` → `insertContact` (same helper as Branch A)
6. Return 201 with existing `accountId` + new `contactId`

DML Error Classification (both branches, all DML points):

```
DmlException.getDmlType(0)
  DUPLICATE_VALUE / DUPLICATES_DETECTED  → 409 DUPLICATE_RECORD
  FIELD_CUSTOM_VALIDATION_EXCEPTION /
  REQUIRED_FIELD_MISSING                 → 422 VALIDATION_RULE_VIOLATION
  anything else                          → 500 SALESFORCE_DML_ERROR
```

## File Changes
| File | Action | Description |
|------|--------|-------------|
| classes/UdcOnboardingService.cls | Create | REST service + inner request/response classes |
| classes/UdcOnboardingService.cls-meta.xml | Create | API 66.0, status Active |
| classes/UdcOnboardingServiceTest.cls | Create | 7 Gherkin scenarios + rollback SOQL assert |
| classes/UdcOnboardingServiceTest.cls-meta.xml | Create | API 66.0 |

## Interfaces
- `global with sharing class UdcOnboardingService` — `@HttpPost global static OnboardingResponse handlePost()`
- Inner: `OnboardingRequest { String org_name; String onboard_type; ContactRequest user; ... }`, `ContactRequest { String last_name; String email; String user_type; String role; ... }`, `OnboardingResponse { Boolean success; String message; String errorCode; Id accountId; Id contactId; }`
- Onboarding flag: `UDC_Onboarding__c = (req.onboard_type == 'udesign.cloud')` on both records.

## Testing Strategy (TDD, runner `sf apex run test`)
| Layer | Test | Approach |
|-------|------|----------|
| Unit | Missing org_name → 400 | Set `RestContext.request`/`response`, assert statusCode |
| Unit | Missing last_name → 400 | Null user.last_name payload |
| Unit | Invalid email → 400 | Malformed email payload |
| Unit | Success → 201 + UDC flags true | Assert accountId/contactId + Account.UDC_Onboarding__c=true + Contact.UDC_Onboarding__c=true (onboard_type="udesign.cloud") |
| Unit | onboard_type absent → flags false | Assert checkbox false on both records |
| Unit | Contact failure → rollback | Force Contact DML fail with blank LastName (platform-required, deterministic); assert `[SELECT Id FROM Account WHERE Name = :testName]` is empty |
| Unit | Account failure → 500 | Force Account DML fail; assert Contact never processed |

Target ≥85% coverage. Each test sets up `RestContext` (standard Apex REST pattern).

## Migration / Rollout
No data migration. Deploy classes; rollback = delete classes and revert VCS.

## Open Questions
None blocking.
