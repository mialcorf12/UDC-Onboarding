# accountuser-event-notification Specification

## Purpose

Platform Event publishing of onboarding outcomes (success and failure) to enable system ID mapping integration with uDC.

## Requirements

### Requirement: REQ-PE-1 Two Platform Event metadata objects

The system MUST define two Platform Event objects: `Sfdc_Accountuser_CreatedSuccess__e` and `Sfdc_Accountuser_CreatedFailed__e`.
Each MUST have fields: `Org_Id__c` (Text 50), `Org_Sfdc_Id__c` (Text 18), `User_Id__c` (Text 50), `User_Sfdc_Id__c` (Text 18).
Both MUST use `PUBLISH_IMMEDIATELY` publish behavior.

#### Scenario: Platform Events Metadata Exists
- GIVEN the Salesforce environment
- WHEN checking object metadata
- THEN `Sfdc_Accountuser_CreatedSuccess__e` and `Sfdc_Accountuser_CreatedFailed__e` MUST exist with `PUBLISH_IMMEDIATELY` behavior

### Requirement: REQ-PE-2 Success event published on HTTP 201

The system MUST publish `Sfdc_Accountuser_CreatedSuccess__e` with all four ID fields populated after Account and Contact are successfully committed (both Branch A and Branch B).

#### Scenario: Success event published after Branch A (new Account + Contact created)
- GIVEN a valid request for a new Account and Contact
- WHEN the request is processed successfully
- THEN `Sfdc_Accountuser_CreatedSuccess__e` MUST be published
- AND all four ID fields MUST be populated

#### Scenario: Success event published after Branch B (existing Account updated + Contact created)
- GIVEN a valid request for an existing Account and new Contact
- WHEN the request is processed successfully
- THEN `Sfdc_Accountuser_CreatedSuccess__e` MUST be published
- AND all four ID fields MUST be populated

### Requirement: REQ-PE-3 Failed event published on any non-201 outcome

The system MUST publish `Sfdc_Accountuser_CreatedFailed__e` on validation failure (400), Account not found (404), duplicate (409), validation rule (422), or DML error (500).
`Org_Id__c` MUST be populated from `request.org_id` if present; all Sfdc ID fields MUST be null.
The event MUST be published EVEN IF the DML transaction was rolled back.

#### Scenario: Failed event published on validation error (400)
- GIVEN a request with validation errors
- WHEN the request is processed
- THEN `Sfdc_Accountuser_CreatedFailed__e` MUST be published
- AND `Org_Id__c` MUST carry the requested `org_id`

#### Scenario: Failed event published on DML duplicate error (409)
- GIVEN a request causing a duplicate DML error
- WHEN the transaction is rolled back
- THEN `Sfdc_Accountuser_CreatedFailed__e` MUST be published after rollback

#### Scenario: Failed event published when forceContactFailure=true
- GIVEN a request where Contact creation fails
- WHEN the transaction is rolled back
- THEN `Sfdc_Accountuser_CreatedFailed__e` MUST be published

#### Scenario: Failed event published when Account not found (404)
- GIVEN a request targeting a non-existent Account
- WHEN the request is processed
- THEN `Sfdc_Accountuser_CreatedFailed__e` MUST be published

### Requirement: REQ-PE-4 Publish failure isolation

The system MUST catch and silently swallow publish exceptions. A failure to publish either event MUST NOT alter the HTTP response code or response body.

#### Scenario: Publish failure does not change HTTP response
- GIVEN a processing request (success or failure)
- WHEN the EventBus publish throws an exception
- THEN the exception MUST be silently swallowed
- AND the HTTP response MUST remain unchanged

### Requirement: REQ-PE-5 Signature extension

The `insertContact()` method MUST carry `orgId: String` and `userId: String` parameters.
These values MUST be extracted from the request payload BEFORE any DML.

#### Scenario: Payload IDs extracted before DML
- GIVEN an incoming request payload
- WHEN processing begins
- THEN `orgId` and `userId` MUST be extracted before DML operations

### Requirement: REQ-PE-6 Two publish helper methods

The `UdcOnboardingService` MUST have two `private static` helper methods: `publishSuccessEvent(Id, String, Id, String)` and `publishFailedEvent(String)`.

#### Scenario: Publish helpers are available
- GIVEN the `UdcOnboardingService` class
- WHEN checking its methods
- THEN `publishSuccessEvent` and `publishFailedEvent` MUST exist as private static methods

### Requirement: REQ-NFR-1 No extra SOQL or DML

Publish calls MUST NOT introduce additional SOQL queries or DML statements.

#### Scenario: Publish does not consume SOQL/DML limits
- GIVEN an incoming request
- WHEN the event is published
- THEN the SOQL query and DML statement counts MUST NOT increase

### Requirement: REQ-NFR-2 Code coverage

Both helpers MUST be covered by Apex unit tests (≥85% overall coverage maintained).

#### Scenario: Unit tests cover publish helpers
- GIVEN the test suite
- WHEN running tests
- THEN the new publish helper methods MUST be executed and verified

### Requirement: REQ-NFR-3 Governor limit impact

The system MUST publish exactly 1 PE per request (success XOR failure), never both.

#### Scenario: Exactly one event is published per request
- GIVEN any onboarding request
- WHEN processing completes
- THEN exactly one Platform Event MUST be published
