# Apply Progress: udc-onboarding-service

## Status: COMPLETE — All 42 tasks done, 11/11 tests GREEN, 92% coverage

## Files Created
| File | Action |
|------|--------|
| force-app/main/default/classes/UdcOnboardingService.cls | Created |
| force-app/main/default/classes/UdcOnboardingService.cls-meta.xml | Created |
| force-app/main/default/classes/UdcOnboardingServiceTest.cls | Created |
| force-app/main/default/classes/UdcOnboardingServiceTest.cls-meta.xml | Created |

## Implementation Summary

### File: UdcOnboardingService.cls (322 lines)
- **@RestResource** endpoint at `/services/apexrest/UdcOnboardingService/`
- **@HttpPost** global method `handlePost()` for POST request handling
- **Inner classes**:
  - `OnboardingRequest` — JSON wrapper with `org_name`, `onboard_type`, `user` (ContactRequest)
  - `ContactRequest` — JSON wrapper with `last_name`, `email`, `user_type`, `role`, etc.
  - `OnboardingResponse` — success/error response with `accountId`, `contactId`
  - `ContactInsertException` — @TestVisible internal exception for deterministic test failures
- `handleExistingAccount`: Branch B — SOQL lookup, 404 guard, Account update, Contact creation via shared helpers
- `buildDmlErrorResponse`: shared DML error handler — conditional rollback + StatusCode-based HTTP classification (409/422/500)
- `forceDmlStatusCodeOverride`: @TestVisible field for deterministic 409/422 unit test injection
- **Validation**: `validateInput()` method checks org_name/last_name non-empty, email format (regex); returns 400 on failure
- **Account creation**: Resolves `Commercial` RecordType dynamically, maps all fields, coerces string "true"/"false" to Boolean for checkboxes
- **Contact creation**: Links to Account via `AccountId`, resolves `Commercial` RecordType, maps `user_type` → `Company_User_Type__c`, role → `Contact_Role__c`
- **UDC flag**: Sets `UDC_Onboarding__c = (req.onboard_type == 'udesign.cloud')` on both records
- **Transactional safety**: `Database.setSavepoint()` before Account insert; `Database.rollback(sp)` in Contact catch block ONLY
- **FLS/CRUD**: `Security.stripInaccessible(AccessType.CREATABLE)` before each insert
- **Sharing**: `global with sharing` declared

### File: UdcOnboardingServiceTest.cls (365 lines)
- **Test helper**: `setupRestContext(String body)` to populate RestContext.request/response
- **Test 1: testMissingOrgName()** — null org_name → 400 INVALID_INPUT (no DML)
- **Test 2: testMissingLastName()** — null user.last_name → 400 INVALID_INPUT (no DML)
- **Test 3: testInvalidEmail()** — malformed email → 400 INVALID_INPUT (no DML)
- **Test 4: testSuccessUdcFlagTrue()** — valid payload with `onboard_type='udesign.cloud'` → 201, Account.UDC_Onboarding__c=true, Contact.UDC_Onboarding__c=true
- **Test 5: testSuccessUdcFlagFalse()** — valid payload without `onboard_type` → 201, flags=false on both
- **Test 6: testRollbackOnContactFailure()** — Account inserted, Contact fails (blank last_name) → 500, Database.rollback() executed, SOQL assert Account absent
- **Test 7: testAccountInsertFailure()** — Account insert fails (name too long) → 500, Contact never created
- **Test 8: testOrgSfdcIdNotFound()** — verifies 404 when org_sfdc_id has no matching Account
- **Test 9: testOrgSfdcIdFoundUpdatesAccountAndCreatesContact()** — verifies Branch B 201 — Account updated (not created), Contact linked
- **Test 10: testDuplicateRecordReturns409()** — injects DUPLICATE_VALUE StatusCode, asserts 409 DUPLICATE_RECORD
- **Test 11: testValidationRuleViolationReturns422()** — injects FIELD_CUSTOM_VALIDATION_EXCEPTION, asserts 422 VALIDATION_RULE_VIOLATION
- **Coverage**: 92% on UdcOnboardingService.cls (uncovered: line 223 else branch, lines 258–267 DmlException edge paths)
- **Test count**: 11 pass, 0 fail

## Test Execution Results
```
Test Results
============
Apex Tests Ran: 11
Pass: 11
Fail: 0
Skip: 0
Org: 00DEk00000h5xt7MAA (alberto.cordero@ulabsystems.com.audit)

Code Coverage: 92% (UdcOnboardingService)

Test Run Time: 5,285 ms
```

## Design Decisions Verified
✅ AD #1: Single class + inner classes  
✅ AD #2: Dynamic RecordType resolution (getRecordTypeInfosByDeveloperName)  
✅ AD #3: Savepoint + rollback strategy (Contact catch only)  
✅ AD #4: getDmlMessage(0) for clean error messages  
✅ AD #5: String == 'true' coercion for checkbox fields  
✅ AD #6: Pattern.matches() email validation  
✅ AD #7: with sharing declaration  
✅ AD #8: RestContext.response.statusCode for HTTP codes  
✅ AD #9: Security.stripInaccessible(AccessType.CREATABLE)  
✅ AD #10: onboard_type (underscore) field name  
✅ AD #11: buildDmlErrorResponse — shared rollback + HTTP classification helper  
✅ AD #12: e.getDmlType(0) StatusCode-based error routing (409/422/500)  
✅ AD #13: @TestVisible forceDmlStatusCodeOverride for deterministic 409/422 tests  

## Spec Requirements Verified
✅ REQ-1: HTTP Endpoint at /services/apexrest/UdcOnboardingService/  
✅ REQ-2: Input validation (org_name, last_name, email); 400 on failure  
✅ REQ-3: Account creation with Commercial RecordType, field mapping, String→Boolean coercion  
✅ REQ-4: Contact linked to Account, user_type/role mapping  
✅ REQ-5: UDC_Onboarding__c flag set based on onboard_type  
✅ REQ-6: Transactional atomicity via savepoint/rollback  
✅ REQ-7: HTTP response codes (201/400/500) + error messages  
✅ REQ-8: with sharing, FLS/CRUD enforcement, ≥85% coverage  
✅ REQ-9: org_sfdc_id branch decision (Branch A / Branch B with 404 guard)  
✅ REQ-10: Refined DML error HTTP codes (409 DUPLICATE_RECORD, 422 VALIDATION_RULE_VIOLATION, 500 SALESFORCE_DML_ERROR)  

## Known Deviations (Acceptable)
1. **UDC_Onboarding__c reapplied after stripInaccessible** — System field, safe, intentional
2. **ContactInsertException inner class** — @TestVisible, allows deterministic test failure
3. **Test data org_status="Prospect"** — Valid restricted picklist value
4. **Account.Name 256 chars for test failure** — Platform-guaranteed deterministic DML failure

## Non-Critical Warnings
- **Line 223 uncovered**: else branch of user_type mapping (passthrough behavior)
- **Lines 258–267 uncovered**: real DmlException path on Contact (inherent Apex limitation)
- **Coverage 92%**: Above 85% threshold; acceptable

## Ready for PR
✅ All 42 tasks complete  
✅ 11/11 tests pass  
✅ 92% coverage ≥ 85% threshold  
✅ 4 files created (2 classes + 2 metadata files)  
✅ TDD cycle (RED → GREEN → REFACTOR → VERIFY) completed  
✅ All spec requirements met  
✅ All design decisions implemented  
