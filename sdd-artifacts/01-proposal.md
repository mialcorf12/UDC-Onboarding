# Proposal: udc-onboarding-service

## Intent
The uDesign Cloud onboarding portal needs a reliable, atomic way to create a complete customer record (Account + Contact). Two separate API calls risk orphan records. This single custom Apex REST endpoint ensures both records are created safely or both fail, maintaining consistent data state.

## Scope

### In Scope
- POST `/services/apexrest/UdcOnboardingService/`
- Input validation (org_name, user.last_name, user.email format)
- Atomic creation of Account and Contact (RecordType=Commercial)
- Mapping payload fields to Salesforce standard/custom fields
- Setting `UDC_Onboarding__c` true when `onboard_type=="udesign.cloud"`
- Transactional rollback on DML failure
- 7 comprehensive Gherkin test scenarios (validation, success, DML errors)

### Out of Scope
- Assignment of User lookups (account_owner, clinical_dev_spec, etc.)
- Handling `onboard_type` values other than "udesign.cloud"
- Upsert/deduplication logic (insert only)

## Capabilities

### New Capabilities
- `udc-onboarding-api`: Atomic REST endpoint accepting JSON payload to create Account and Contact linked records, providing data validation, field mapping, and transactional safety.

### Modified Capabilities
- None

## Approach
Create an Apex REST service `UdcOnboardingService` (@RestResource). Define internal request wrappers matching the JSON payload. Validate inputs manually before DML to return HTTP 400. Use a `Savepoint` before Account insert; if Account or Contact insert fails, use `Database.rollback()` and catch `DmlException` to return HTTP 500 with `e.getDmlMessage(0)`. Resolve Record Types dynamically.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `classes/UdcOnboardingService.cls` | New | Apex REST service logic and wrappers |
| `classes/UdcOnboardingServiceTest.cls` | New | Test class covering 7 Gherkin scenarios |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|-----------|
| Orphaned Accounts | Low | Explicit `Savepoint` and `Database.rollback()` in catch blocks |
| Duplicate Rule blocks | Med | Exception handling catches DmlException to return HTTP 500 safely |

## Rollback Plan
Delete the deployed Apex classes from the target org. Revert metadata changes in version control.

## Dependencies
- Existing `UDC_Onboarding__c` custom fields.
- `Commercial` RecordType must exist on Account and Contact in target Org.

## Success Criteria
- [ ] Endpoint successfully accepts POST payload and creates Account + linked Contact.
- [ ] If Contact fails, Account is not created (rolled back).
- [ ] 7 defined Gherkin scenarios pass via `sf apex run test` with >=85% coverage.
