# User Story — UDC Onboarding REST Service

## Title
**As** the uDesign Cloud client portal, **I want** to call a Salesforce REST endpoint that creates a linked Account and Contact in a single transaction, **so that** a new clinical organization is fully onboarded without multiple API calls, with all records tagged, typed, and assigned to the correct Record Type from the start.

---

## Background

The uDesign Cloud onboarding portal needs to create a complete customer record (organization + primary contact) as an atomic unit. Two independent calls expose the operation to inconsistent states: an Account without a Contact, or a Contact without an Account. The service must guarantee both records are created — or neither is persisted. All records must carry the `Commercial` Record Type and, when the payload identifies a uDesign Cloud onboarding source, both records must be flagged with `UDC_Onboarding__c` for downstream automation.

---

## API Contract

| Property | Value |
|---|---|
| **Method** | `POST` |
| **URL** | `/services/apexrest/UdcOnboardingService/` |
| **Auth** | OAuth 2.0 Bearer Token |
| **API Version** | `66.0` |

### Request Payload

```json
{
  "onboard_type": "udesign.cloud",
  "is_parent": "true",
  "org_name": "uDesign Cloud India cc test",
  "org_type": "Orthodontist",
  "org_status": "uLab Account",
  "shipping_address_1": "111 Main St.\nBLDG 2\nSuite 33",
  "shipping_city": "Fremont",
  "shipping_country": "AU",
  "shipping_region": "QLD",
  "shipping_zip": "J5V3B2",
  "phone": "5104099105",
  "billing_address_1": "111 Main St.\nBLDG 2\nSuite 33",
  "billing_city": "Fremont",
  "billing_country": "AU",
  "billing_region": "QLD",
  "billing_zip": "J5V3B2",
  "signature_required": "false",
  "out_of_service_area": "false",
  "user": {
    "first_name": "Test01",
    "last_name": "Test",
    "email": "activationusertest1@mailinator.com",
    "phone": "5104099105",
    "mailing_address_1": "333 Central Ave",
    "mailing_city": "Fremont",
    "mailing_country": "AU",
    "mailing_state": "QLD",
    "mailing_zipcode": "J6Y3V2",
    "user_type": "Customer Account Owner",
    "role": "Orthodontist"
  }
}
```

---

## Field Mapping (Definitive Contract)

### Account

| JSON Field | SF API Name | Type | Notes |
|---|---|---|---|
| `org_name` | `Name` | Text | **Required** |
| `org_type` | `Type` | Picklist | Validated by Salesforce; active values: `Internal`, `Lab`, `Misc Company`, `Orthodontic Practice`, `Other`, `University` |
| `org_status` | `Account_Status__c` | Picklist (restricted) | Valid values: `Prospect`, `uLab Account`, `uLab Child Account`, `Suspended`, `Inactive` |
| `is_parent` | `Is_Parent__c` | Checkbox | String `"true"/"false"` → Boolean conversion required |
| `phone` | `Phone` | Phone | |
| `shipping_address_1` | `ShippingStreet` | Text | |
| `shipping_city` | `ShippingCity` | Text | |
| `shipping_country` | `ShippingCountry` | Text | |
| `shipping_region` | `ShippingState` | Text | |
| `shipping_zip` | `ShippingPostalCode` | Text | |
| `billing_address_1` | `BillingStreet` | Text | |
| `billing_city` | `BillingCity` | Text | |
| `billing_country` | `BillingCountry` | Text | |
| `billing_region` | `BillingState` | Text | |
| `billing_zip` | `BillingPostalCode` | Text | |
| `signature_required` | `Signature_Required__c` | Checkbox | String `"true"/"false"` → Boolean conversion required |
| `out_of_service_area` | `Out_of_Service_Area__c` | Checkbox | String `"true"/"false"` → Boolean conversion required |
| `onboard_type` = `"udesign.cloud"` | `UDC_Onboarding__c` | Checkbox | Set to `true` when value equals `"udesign.cloud"`; otherwise `false` |
| *(hardcoded)* | `RecordTypeId` | Lookup | Resolved to `Commercial` via `SObjectType.Account.getRecordTypeInfosByDeveloperName()` |
| `shipping_name` | — | — | **Discarded** — redundant with `org_name` |
| `billing_name` | — | — | **Discarded** — redundant with `org_name` |
| `clinical_dev_spec` | — | — | **Out of scope** — requires User ID resolution; future story |
| `clinical_ed_spec` | — | — | **Out of scope** — requires User ID resolution; future story |
| `account_owner` | — | — | **Out of scope** — requires User ID resolution; future story |

### Contact (object `user`)

| JSON Field | SF API Name | Type | Notes |
|---|---|---|---|
| `first_name` | `FirstName` | Text | |
| `last_name` | `LastName` | Text | **Required** |
| `email` | `Email` | Email | **Required** + regex format validation |
| `phone` | `Phone` | Phone | |
| `mailing_address_1` | `MailingStreet` | Text | |
| `mailing_city` | `MailingCity` | Text | |
| `mailing_country` | `MailingCountry` | Text | |
| `mailing_state` | `MailingState` | Text | |
| `mailing_zipcode` | `MailingPostalCode` | Text | |
| `user_type` = `"Customer Account Owner"` | `Company_User_Type__c` | Picklist | Mapped to `"Account Owner"` (confirmed) |
| `role` | `Contact_Role__c` | Picklist | Direct mapping; `"Orthodontist"` is active in Record Type `Commercial` |
| `onboard_type` = `"udesign.cloud"` *(from root)* | `UDC_Onboarding__c` | Checkbox | Set to `true` when root `onboard_type` equals `"udesign.cloud"`; otherwise `false` |
| *(hardcoded)* | `RecordTypeId` | Lookup | Resolved to `Commercial` via `SObjectType.Contact.getRecordTypeInfosByDeveloperName()` |
| `mailing_name` | — | — | **Discarded** — redundant with `first_name` + `last_name` |
| `mailing_phone` | — | — | **Discarded** — redundant with `user.phone` |

---

## Acceptance Criteria

**Scenario 1 — Happy path: both records created successfully**
```gherkin
Given  the portal sends a POST with valid org_name, org_status, user.last_name, user.email,
       user_type "Customer Account Owner", role "Orthodontist",
       and onboard_type "udesign.cloud"
When   the service processes the payload
Then   it returns HTTP 201
And    the response body includes success: true, accountId and contactId
And    Contact.AccountId equals the newly created Account.Id
And    Account.RecordType.DeveloperName equals "Commercial"
And    Contact.RecordType.DeveloperName equals "Commercial"
And    Account.UDC_Onboarding__c equals true
And    Contact.UDC_Onboarding__c equals true
And    Contact.Company_User_Type__c equals "Account Owner"
And    Contact.Contact_Role__c equals "Orthodontist"
```

**Scenario 2 — UDC Onboarding flag: onboard-type is absent or not "udesign.cloud"**
```gherkin
Given  the portal sends a POST with all required fields
And    "onboard_type" is absent, null, or any value other than "udesign.cloud"
When   the service processes the payload
Then   it returns HTTP 201
And    Account.UDC_Onboarding__c equals false
And    Contact.UDC_Onboarding__c equals false
```

**Scenario 3 — Input validation: org_name is missing**
```gherkin
Given  the portal sends a POST with org_name null or empty
When   the service evaluates the payload before any DML
Then   it returns HTTP 400
And    the body includes success: false, errorCode: "INVALID_INPUT"
And    the message states that org_name is required
And    no records are inserted in Salesforce
```

**Scenario 4 — Input validation: user.last_name is missing**
```gherkin
Given  the portal sends a POST with user.last_name null or empty
When   the service evaluates the payload before any DML
Then   it returns HTTP 400
And    errorCode: "INVALID_INPUT" with a message stating user.lastName is required
And    no records are inserted
```

**Scenario 5 — Input validation: user.email has invalid format**
```gherkin
Given  the portal sends user.email with value "not-an-email"
When   the service evaluates the payload before any DML
Then   it returns HTTP 400
And    errorCode: "INVALID_INPUT" with a message about invalid email format
And    no records are inserted
```

**Scenario 6 — Rollback: Contact insert fails**
```gherkin
Given  the Account is inserted successfully
And    the Contact insert fails (trigger, validation rule, or duplicate rule)
When   the service catches the DMLException
Then   it executes Database.rollback() to the savepoint defined before the first DML
And    it returns HTTP 500 with errorCode: "SALESFORCE_DML_ERROR"
And    the message includes the native Salesforce error via e.getDmlMessage(0)
And    a SOQL query confirms the Account was also not persisted
```

**Scenario 7 — Rollback: Account insert fails**
```gherkin
Given  the payload is structurally valid
And    the Account insert fails (duplicate rule, trigger, or validation rule)
When   the service catches the DMLException
Then   it returns HTTP 500 with errorCode: "SALESFORCE_DML_ERROR"
And    the Contact is never processed
And    no orphan records exist in Salesforce
```

---

## API Responses

**HTTP 201 — Success:**
```json
{
  "success": true,
  "message": "Account and Contact created successfully.",
  "accountId": "001XXXXXXXXXXXXXXX",
  "contactId": "003XXXXXXXXXXXXXXX"
}
```

**HTTP 400 — Input Validation Error:**
```json
{
  "success": false,
  "errorCode": "INVALID_INPUT",
  "message": "Validation failed: 'org_name' is required. 'user.email' must have a valid format."
}
```

**HTTP 500 — Salesforce DML Error:**
```json
{
  "success": false,
  "errorCode": "SALESFORCE_DML_ERROR",
  "message": "The transaction was rolled back. Original Salesforce error: [FIELD_CUSTOM_VALIDATION_EXCEPTION] The email address is already registered to another active contact."
}
```

---

## Salesforce Non-Functional AC

- [ ] `with sharing` declared explicitly on the Apex REST class
- [ ] FLS and CRUD checked for Account and Contact (all fields written)
- [ ] Record Type resolved via `getRecordTypeInfosByDeveloperName()` — no hardcoded IDs
- [ ] `UDC_Onboarding__c` evaluated from root `onboard_type` before any DML; set on both Account and Contact
- [ ] `user_type: "Customer Account Owner"` mapped to `Company_User_Type__c = 'Account Owner'` in Apex code
- [ ] String-to-Boolean conversion applied to `is_parent`, `signature_required`, `out_of_service_area` before DML
- [ ] Savepoint defined before first DML; `Database.rollback()` executed on any subsequent failure
- [ ] DML errors surfaced with `e.getDmlMessage(0)`, never with the full stack trace
- [ ] Test coverage ≥ 85% with success, validation failure, and rollback scenarios
- [ ] Compatible with API version **66.0**
- [ ] > Note: `package.xml` is currently on `67.0` — confirm alignment with the team before deployment

---

## Out of Scope

- Resolution of `account_owner`, `clinical_dev_spec`, `clinical_ed_spec` from name string to User ID — future story
- `onboard-type` values other than `"udesign.cloud"` — flag stays `false`
- Upsert / deduplication — duplicate rules enforced by Salesforce; HTTP 500 is the expected response
- Update of existing records

---

## Story Points

**8** — Apex REST class with two-layer validation (input + DML), Record Type resolution on both objects, `UDC_Onboarding__c` conditional flag logic, three String-to-Boolean conversions, savepoint/rollback transaction control, and a test class covering seven Gherkin scenarios including SOQL-verified rollback.

---

## Subtasks

- [x] Deploy `UDC_Onboarding__c` Checkbox field on Account — `force-app/main/default/objects/Account/fields/UDC_Onboarding__c.field-meta.xml`
- [x] Deploy `UDC_Onboarding__c` Checkbox field on Contact — `force-app/main/default/objects/Contact/fields/UDC_Onboarding__c.field-meta.xml`
- [ ] Create `UdcOnboardingService` Apex class with `@RestResource` and `@HttpPost` method
- [ ] Implement inner class `OnboardingRequest` — wrapper for JSON deserialization
- [ ] Implement private method `validateInput()` — validates `org_name`, `user.last_name`, `user.email` regex
- [ ] Implement private method `resolveRecordTypeId(String sObjectType, String developerName)` — no hardcoded IDs
- [ ] Map payload → Account fields including `UDC_Onboarding__c`, `RecordTypeId`, and Boolean conversions
- [ ] Map payload `user` → Contact fields including `UDC_Onboarding__c`, `Company_User_Type__c`, `Contact_Role__c`, `RecordTypeId`
- [ ] Implement try-catch block with `Savepoint` + `Database.rollback()` around all DML
- [ ] Implement inner class `OnboardingResponse` — serializes HTTP 201/400/500 responses
- [ ] Create `UdcOnboardingServiceTest` covering all 7 Gherkin scenarios
- [ ] Rollback test: verify with `[SELECT Id FROM Account WHERE Name = :testOrgName]` that no Account persists after Contact failure

---

## Open Questions

- [ ] **`package.xml` version mismatch** — story targets API 66.0 but `manifest/package.xml` is on 67.0. Confirm which version the team deploys against before submitting the Apex class.
- [ ] **Active Duplicate Rules** — are there active duplicate rules on Account or Contact in this org? Affects rollback test design.
