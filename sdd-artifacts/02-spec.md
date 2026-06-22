# udc-onboarding-rest-service Specification

## Purpose
Defines an atomic REST endpoint for uDesign Cloud onboarding, enabling synchronous, validated creation of Account and Contact records without risking orphan records.

## Requirements

### Requirement: REQ-1 HTTP Endpoint
The system MUST expose a POST endpoint at `/services/apexrest/UdcOnboardingService/` requiring an OAuth 2.0 Bearer Token.

#### Scenario: Authorized access
- GIVEN a valid OAuth 2.0 session
- WHEN a POST request is sent to the endpoint
- THEN the system processes the request.

### Requirement: REQ-2 Input Validation
The system MUST validate the payload before any DML. `org_name` and `user.last_name` MUST NOT be null or empty. `user.email` MUST match a valid email regex. Validation failures MUST NOT produce DML side effects and MUST return HTTP 400.

#### Scenario: Missing required fields
- GIVEN a payload missing `org_name` or `user.last_name`
- WHEN the request is received
- THEN the system returns HTTP 400 `INVALID_INPUT` without executing DML.

#### Scenario: Invalid email
- GIVEN a payload with a malformed `user.email`
- WHEN the request is received
- THEN the system returns HTTP 400 `INVALID_INPUT` without executing DML.

### Requirement: REQ-3 Account Creation
The system MUST create an Account with RecordType `Commercial` (resolved dynamically). It MUST map all payload fields (Name, Type, Phone, Addresses). String values "true"/"false" for `Is_Parent__c`, `Signature_Required__c`, and `Out_of_Service_Area__c` MUST map to Booleans.

#### Scenario: Successful Account creation
- GIVEN a valid payload
- WHEN the request is processed
- THEN an Account is inserted with correct mappings and the `Commercial` Record Type.

### Requirement: REQ-4 Contact Creation
The system MUST create a Contact linked to the Account (`AccountId` = `Account.Id`) with RecordType `Commercial`. Payload fields MUST map correctly. `user_type` "Customer Account Owner" MUST map to `Company_User_Type__c` = 'Account Owner', and role "Orthodontist" to `Contact_Role__c` = 'Orthodontist'.

#### Scenario: Successful Contact linkage
- GIVEN a successful Account insertion
- WHEN the Contact is created
- THEN the Contact is linked to the Account and values are mapped correctly.

### Requirement: REQ-5 UDC Onboarding Flag
The system MUST set `UDC_Onboarding__c` to true on both Account and Contact WHEN `onboard_type` == "udesign.cloud". Otherwise, both flags MUST be false.

Note: the payload field is `onboard_type` (underscore). The portal sends this key; Apex inner class field maps directly.

#### Scenario: UDC Onboarding Flag Present
- GIVEN `onboard_type` is "udesign.cloud"
- WHEN the records are created
- THEN `UDC_Onboarding__c` is true on both records.

#### Scenario: UDC Onboarding Flag Absent
- GIVEN `onboard_type` is absent or any other value
- WHEN the records are created
- THEN `UDC_Onboarding__c` is false on both records.

### Requirement: REQ-6 Transactional Atomicity
The system MUST set a Savepoint before the first DML. If Account insert fails, it MUST throw/catch immediately and not process Contact. If Contact insert fails, it MUST execute `Database.rollback()` to the savepoint. After rollback, both records MUST be absent from the database.

#### Scenario: Rollback on Contact Failure
- GIVEN an Account is inserted but Contact fails
- WHEN the failure occurs
- THEN the system rolls back to the savepoint
- AND neither Account nor Contact exists in the database.

### Requirement: REQ-7 Response Contract
The system MUST return HTTP 201 (or 200) on success with `{ success: true, message, accountId, contactId }`. DML errors MUST return HTTP 500 with `errorCode: SALESFORCE_DML_ERROR` and `message: e.getDmlMessage(0)`.

#### Scenario: DML Exception Response
- GIVEN a database error occurs during DML
- WHEN the error is caught
- THEN the system returns HTTP 500 with `SALESFORCE_DML_ERROR` and the localized DML message.

### Requirement: REQ-8 Security and Tests
The system MUST declare `with sharing`. FLS and CRUD MUST be enforced via `Security.stripInaccessible(AccessType.CREATABLE, ...)` before each insert. The system MUST NOT execute SOQL/DML inside loops. The system MUST achieve ≥ 85% Apex coverage covering all scenarios, including querying for absence of records on rollback.

#### Scenario: Rollback verification test
- GIVEN a test simulating a Contact insert failure
- WHEN the test executes
- THEN the test asserts via SOQL that the Account was not persisted.
