/**
 * UdcOnboardingServiceTest
 *
 * Test class for UdcOnboardingService covering all 7 Gherkin scenarios
 * defined in the spec (REQ-1 through REQ-8).
 *
 * TDD Cycle: tests were written BEFORE implementation (RED phase).
 * Each test fails against the stub and passes after Phase 3 GREEN implementation.
 *
 * Test runner: sf apex run test -n UdcOnboardingServiceTest
 * API Version: 66.0
 *
 * Coverage note — HTTP 409 and 422:
 * Unit tests cannot construct a platform DmlException with a controlled getDmlType(0) value.
 * The 409 (DUPLICATE_RECORD) and 422 (VALIDATION_RULE_VIOLATION) paths are verified in
 * integration testing against a sandbox org with active Duplicate Rules and Validation Rules.
 */
@isTest(SeeAllData=false)
private class UdcOnboardingServiceTest {

    // =========================================================================
    // Shared Test Data Constants
    // =========================================================================

    private static final String VALID_ORG_NAME     = 'Acme Dental';
    private static final String VALID_LAST_NAME     = 'Smith';
    private static final String VALID_EMAIL         = 'john.smith@example.com';
    private static final String ROLLBACK_ORG_NAME   = 'RollbackTest';
    private static final String ONBOARD_TYPE_UDC    = 'udesign.cloud';

    // =========================================================================
    // RestContext Setup Helper
    // =========================================================================

    /**
     * Configures RestContext.request and RestContext.response for each test.
     * Must be called inside Test.startTest()/stopTest() to count toward governor limits.
     *
     * @param jsonBody  The raw JSON string to set as the request body
     */
    private static void setupRestContext(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        req.httpMethod  = 'POST';
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    // =========================================================================
    // Helper: build a valid full JSON payload
    // =========================================================================

    /**
     * Returns a valid JSON payload string with all required fields.
     *
     * @param orgName       Value for org_name
     * @param lastName      Value for user.last_name
     * @param email         Value for user.email
     * @param onboardType   Value for onboard_type (pass null to omit the field)
     * @param orgSfdcId     Value for org_sfdc_id (pass null to omit — triggers Branch A: create new Account)
     */
    private static String buildPayload(
        String orgName,
        String lastName,
        String email,
        String onboardType,
        String orgSfdcId
    ) {
        String onboardTypeFragment = (onboardType != null)
            ? '"onboard_type": "' + onboardType + '",'
            : '';

        String orgSfdcIdFragment = (orgSfdcId != null)
            ? '"org_sfdc_id": "' + orgSfdcId + '",'
            : '';

        return '{'
            + onboardTypeFragment
            + orgSfdcIdFragment
            + '"org_id": "12345",'
            + '"is_parent": "false",'
            + '"org_name": ' + (orgName != null ? '"' + orgName + '"' : 'null') + ','
            + '"org_type": "Dental Practice",'
            + '"org_status": "Prospect",'
            + '"shipping_address_1": "123 Main St",'
            + '"shipping_city": "Dallas",'
            + '"shipping_country": "US",'
            + '"shipping_region": "TX",'
            + '"shipping_zip": "75001",'
            + '"phone": "2145550100",'
            + '"billing_address_1": "123 Main St",'
            + '"billing_city": "Dallas",'
            + '"billing_country": "US",'
            + '"billing_region": "TX",'
            + '"billing_zip": "75001",'
            + '"signature_required": "false",'
            + '"out_of_service_area": "false",'
            + '"user": {'
            +   '"first_name": "John",'
            +   '"last_name": ' + (lastName != null ? '"' + lastName + '"' : 'null') + ','
            +   '"email": "' + (email != null ? email : '') + '",'
            +   '"phone": "2145550101",'
            +   '"mailing_address_1": "456 Elm St",'
            +   '"mailing_city": "Dallas",'
            +   '"mailing_country": "US",'
            +   '"mailing_state": "TX",'
            +   '"mailing_zipcode": "75001",'
            +   '"user_type": "Customer Account Owner",'
            +   '"role": "Orthodontist",'
            +   '"user_id": "USR001"'
            + '}'
            + '}';
    }

    // =========================================================================
    // Scenario 1 — REQ-2: Missing org_name → HTTP 400 INVALID_INPUT
    // =========================================================================

    /**
     * GIVEN a payload with a null org_name
     * WHEN POST is received
     * THEN statusCode == 400, errorCode == INVALID_INPUT, no DML executed
     *
     * TDD: RED against stub (stub returns null → NullPointerException on statusCode access).
     */
    @isTest
    static void testMissingOrgName() {
        String payload = buildPayload(null, VALID_LAST_NAME, VALID_EMAIL, null, null);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Expected HTTP 400 when org_name is missing');
        System.assertEquals(false, resp.success,
            'Expected success=false for missing org_name');
        System.assertEquals('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for missing org_name');
        // Confirm no Account was inserted
        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :VALID_ORG_NAME];
        System.assertEquals(true, accounts.isEmpty(),
            'No Account should be created when validation fails');
    }

    // =========================================================================
    // Scenario 2 — REQ-2: Missing user.last_name → HTTP 400
    // =========================================================================

    /**
     * GIVEN a payload with a null user.last_name
     * WHEN POST is received
     * THEN statusCode == 400, errorCode == INVALID_INPUT
     *
     * Triangulates Scenario 1 — different field, same validation gate.
     */
    @isTest
    static void testMissingLastName() {
        String payload = buildPayload(VALID_ORG_NAME, null, VALID_EMAIL, null, null);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Expected HTTP 400 when user.last_name is missing');
        System.assertEquals(false, resp.success,
            'Expected success=false for missing last_name');
        System.assertEquals('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for missing last_name');
    }

    // =========================================================================
    // Scenario 3 — REQ-2: Malformed email → HTTP 400
    // =========================================================================

    /**
     * GIVEN a payload with a malformed user.email (no @ symbol)
     * WHEN POST is received
     * THEN statusCode == 400, errorCode == INVALID_INPUT
     *
     * Triangulates validation: third distinct validation rule.
     */
    @isTest
    static void testInvalidEmail() {
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, 'not-an-email', null, null);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Expected HTTP 400 for malformed email');
        System.assertEquals(false, resp.success,
            'Expected success=false for invalid email');
        System.assertEquals('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for invalid email');
    }

    // =========================================================================
    // Scenario 4 — REQ-3/REQ-4/REQ-5: Success, UDC flag true
    // =========================================================================

    /**
     * GIVEN a valid full payload with onboard_type = 'udesign.cloud'
     * WHEN POST is received
     * THEN statusCode == 201, both records created, UDC_Onboarding__c == true on both
     */
    @isTest
    static void testSuccessUdcFlagTrue() {
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_UDC, null);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode,
            'Expected HTTP 201 for successful creation');
        System.assertEquals(true, resp.success,
            'Expected success=true for valid payload');
        System.assertNotEquals(null, resp.accountId,
            'Expected accountId to be populated on success');
        System.assertNotEquals(null, resp.contactId,
            'Expected contactId to be populated on success');

        // Verify Account persisted with UDC flag
        List<Account> accounts = [
            SELECT Id, Name, UDC_Onboarding__c, uLab_Acct_Number__c
            FROM Account
            WHERE Id = :resp.accountId
        ];
        System.assertEquals(1, accounts.size(),
            'Expected exactly 1 Account to be inserted');
        System.assertEquals(true, accounts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = true on Account when onboard_type = udesign.cloud');
        System.assertEquals(12345, accounts[0].uLab_Acct_Number__c,
            'Expected uLab_Acct_Number__c to be populated from org_id');

        // Verify Contact persisted with UDC flag and linked to Account
        List<Contact> contacts = [
            SELECT Id, AccountId, UDC_Onboarding__c, Portal_User_ID__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        System.assertEquals(1, contacts.size(),
            'Expected exactly 1 Contact to be inserted');
        System.assertEquals(true, contacts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = true on Contact when onboard_type = udesign.cloud');
        System.assertEquals(resp.accountId, contacts[0].AccountId,
            'Expected Contact to be linked to the created Account');
        System.assertEquals('USR001', contacts[0].Portal_User_ID__c,
            'Expected Portal_User_ID__c to be populated from user_id');
    }

    // =========================================================================
    // Scenario 5 — REQ-5: Success, UDC flag false (no onboard_type)
    // =========================================================================

    /**
     * GIVEN a valid payload WITHOUT onboard_type
     * WHEN POST is received
     * THEN statusCode == 201, UDC_Onboarding__c == false on both records
     *
     * Triangulates Scenario 4: different onboard_type value → different flag outcome.
     */
    @isTest
    static void testSuccessUdcFlagFalse() {
        // null onboardType, null orgSfdcId → Branch A (create new Account)
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, null);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode,
            'Expected HTTP 201 for valid payload without onboard_type');
        System.assertEquals(true, resp.success,
            'Expected success=true for valid payload');

        // Verify UDC flag is false on Account
        List<Account> accounts = [
            SELECT Id, UDC_Onboarding__c, uLab_Acct_Number__c
            FROM Account
            WHERE Id = :resp.accountId
        ];
        System.assertEquals(1, accounts.size(),
            'Expected exactly 1 Account to be inserted');
        System.assertEquals(false, accounts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = false on Account when onboard_type is absent');
        System.assertEquals(12345, accounts[0].uLab_Acct_Number__c,
            'Expected uLab_Acct_Number__c to be populated from org_id');

        // Verify UDC flag is false on Contact
        List<Contact> contacts = [
            SELECT Id, UDC_Onboarding__c, Portal_User_ID__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        System.assertEquals(1, contacts.size(),
            'Expected exactly 1 Contact to be inserted');
        System.assertEquals(false, contacts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = false on Contact when onboard_type is absent');
        System.assertEquals('USR001', contacts[0].Portal_User_ID__c,
            'Expected Portal_User_ID__c to be populated from user_id');
    }

    // =========================================================================
    // Scenario 6 — REQ-6: Contact failure → rollback Account
    // =========================================================================

    /**
     * GIVEN a valid payload that passes validation but triggers Contact DML failure
     *       (via @TestVisible forceContactFailure flag)
     * WHEN POST is received
     * THEN statusCode == 500, no Account persists in the database (rollback verified via SOQL)
     */
    @isTest
    static void testRollbackOnContactFailure() {
        String payload = buildPayload(ROLLBACK_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, null);
        setupRestContext(payload);

        // Activate the @TestVisible flag to force Contact DML failure
        UdcOnboardingService.forceContactFailure = true;

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode,
            'Expected HTTP 500 when Contact DML fails');
        System.assertEquals(false, resp.success,
            'Expected success=false when Contact DML fails');
        System.assertEquals('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR on DML failure');

        // Critical rollback assertion: Account must NOT exist in DB after rollback
        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :ROLLBACK_ORG_NAME];
        System.assertEquals(true, accounts.isEmpty(),
            'Account must not persist after Contact DML failure — rollback must have executed');
    }

    // =========================================================================
    // Scenario 7 — REQ-6/REQ-7: Account insert failure → HTTP 500
    // =========================================================================

    /**
     * GIVEN a payload that passes validation but causes Account DML failure
     *       (org_name exceeds 255 chars → triggers platform-level field length error)
     * WHEN POST is received
     * THEN statusCode == 500, no Contact created (Account failed first)
     *
     * Approach: Pass a 256-character org_name. validateInput() only checks for
     * null/empty; the platform enforces the 255-char Name limit at DML time,
     * guaranteeing a deterministic Account DML failure without relying on
     * org-specific validation rules.
     */
    @isTest
    static void testAccountInsertFailure() {
        // 256 chars — exceeds Salesforce Account.Name limit of 255
        String longName = 'A'.repeat(256);
        String payload = buildPayload(longName, VALID_LAST_NAME, VALID_EMAIL, null, null);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode,
            'Expected HTTP 500 when Account DML fails due to field length violation');
        System.assertEquals(false, resp.success,
            'Expected success=false when Account DML fails');
        System.assertEquals('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR on Account DML failure');

        // Verify no Contact was created (Account failed first, no AccountId existed)
        List<Contact> contacts = [SELECT Id FROM Contact WHERE LastName = :VALID_LAST_NAME];
        System.assertEquals(true, contacts.isEmpty(),
            'No Contact should be created when Account DML fails');
    }

    // =========================================================================
    // Scenario 8 — Branch B: org_sfdc_id provided but Account not found → HTTP 404
    // =========================================================================

    /**
     * GIVEN a payload with org_sfdc_id that does not match any Account in the org
     * WHEN POST is received
     * THEN statusCode == 404, errorCode == ACCOUNT_NOT_FOUND, no DML executed
     *
     * Uses a well-formed but non-existent Salesforce Account Id.
     * The SOQL query returns empty → endpoint returns 404 without touching the DB.
     */
    @isTest
    static void testOrgSfdcIdNotFound() {
        // Valid Salesforce Id format but guaranteed not to exist in test context
        String fakeAccountId = '0016g00000000001AAA';
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, fakeAccountId);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(404, RestContext.response.statusCode,
            'Expected HTTP 404 when org_sfdc_id does not match any Account');
        System.assertEquals(false, resp.success,
            'Expected success=false when Account not found');
        System.assertEquals('ACCOUNT_NOT_FOUND', resp.errorCode,
            'Expected errorCode ACCOUNT_NOT_FOUND');
        System.assert(resp.message.contains(fakeAccountId),
            'Expected error message to include the org_sfdc_id that was searched');

        // Confirm no records were inserted
        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :VALID_ORG_NAME];
        System.assertEquals(true, accounts.isEmpty(),
            'No Account should be created when Branch B cannot find the existing Account');
    }

    // =========================================================================
    // Scenario 9 — Branch B: org_sfdc_id found → Account updated + Contact created → HTTP 201
    // =========================================================================

    /**
     * GIVEN a payload with a valid org_sfdc_id that matches an existing Account
     * WHEN POST is received
     * THEN statusCode == 201, the existing Account is updated (not a new one created),
     *      and a new Contact is created linked to that Account
     *
     * Setup: inserts a test Account first, then passes its Id in the payload.
     * Assertions verify that only ONE Account exists (the pre-existing one, updated)
     * and that the Contact is linked to it.
     */
    @isTest
    static void testOrgSfdcIdFoundUpdatesAccountAndCreatesContact() {
        // Insert a pre-existing Account to simulate what Branch B would look up
        Account existing = new Account(
            Name         = 'Original Name',
            Type         = 'Other',
            Account_Status__c = 'Prospect',
            RecordTypeId = Schema.SObjectType.Account
                .getRecordTypeInfosByDeveloperName()
                .get('Commercial')
                .getRecordTypeId()
        );
        insert existing;

        // Build payload pointing to the existing Account's real Id
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_UDC, existing.Id);
        setupRestContext(payload);

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode,
            'Expected HTTP 201 when org_sfdc_id matches an existing Account');
        System.assertEquals(true, resp.success,
            'Expected success=true for Branch B happy path');
        System.assertEquals(existing.Id, resp.accountId,
            'Expected accountId to be the pre-existing Account, not a newly created one');
        System.assertNotEquals(null, resp.contactId,
            'Expected contactId to be populated on success');

        // Verify the Account was UPDATED (not a new one inserted) — only 1 Account with this Id
        List<Account> accounts = [
            SELECT Id, Name, UDC_Onboarding__c, uLab_Acct_Number__c
            FROM Account
            WHERE Id = :existing.Id
        ];
        System.assertEquals(1, accounts.size(),
            'Expected exactly 1 Account with the pre-existing Id');
        System.assertEquals(VALID_ORG_NAME, accounts[0].Name,
            'Expected Account Name to be updated to payload org_name');
        System.assertEquals(true, accounts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = true on updated Account');
        System.assertEquals(12345, accounts[0].uLab_Acct_Number__c,
            'Expected uLab_Acct_Number__c to be populated from org_id on Account update');

        // Verify no NEW Account was created (total Accounts in test = 1)
        List<Account> allAccounts = [SELECT Id FROM Account];
        System.assertEquals(1, allAccounts.size(),
            'Branch B must not create a new Account — only the pre-existing one should exist');

        // Verify Contact is linked to the pre-existing Account
        List<Contact> contacts = [
            SELECT Id, AccountId, UDC_Onboarding__c, LastName, Portal_User_ID__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        System.assertEquals(1, contacts.size(),
            'Expected exactly 1 Contact to be created');
        System.assertEquals(existing.Id, contacts[0].AccountId,
            'Expected Contact to be linked to the pre-existing Account');
        System.assertEquals(true, contacts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = true on Contact');
        System.assertEquals(VALID_LAST_NAME, contacts[0].LastName,
            'Expected Contact LastName to match payload user.last_name');
        System.assertEquals('USR001', contacts[0].Portal_User_ID__c,
            'Expected Portal_User_ID__c to be populated from user_id');
    }

    // =========================================================================
    // Scenario 10 — buildDmlErrorResponse: DUPLICATE_VALUE StatusCode → HTTP 409
    // =========================================================================

    /**
     * GIVEN a DML failure whose StatusCode is overridden to DUPLICATE_VALUE
     * WHEN POST is received
     * THEN statusCode == 409, errorCode == DUPLICATE_RECORD
     *
     * Technique: trigger a real DmlException via a 256-char Account name, then
     * inject the StatusCode via @TestVisible forceDmlStatusCodeOverride so the
     * helper classifies it as a duplicate without relying on org Duplicate Rules.
     */
    @isTest
    static void testDuplicateRecordReturns409() {
        String longName = 'A'.repeat(256);
        String payload = buildPayload(longName, VALID_LAST_NAME, VALID_EMAIL, null, null);
        setupRestContext(payload);

        UdcOnboardingService.forceDmlStatusCodeOverride = StatusCode.DUPLICATE_VALUE;

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(409, RestContext.response.statusCode,
            'Expected HTTP 409 for duplicate record StatusCode');
        System.assertEquals(false, resp.success,
            'Expected success=false on duplicate error');
        System.assertEquals('DUPLICATE_RECORD', resp.errorCode,
            'Expected errorCode DUPLICATE_RECORD for DUPLICATE_VALUE StatusCode');
        System.assert(resp.message.contains('Duplicate record detected'),
            'Expected message to indicate duplicate detection');
    }

    // =========================================================================
    // Scenario 11 — buildDmlErrorResponse: FIELD_CUSTOM_VALIDATION_EXCEPTION → HTTP 422
    // =========================================================================

    /**
     * GIVEN a DML failure whose StatusCode is overridden to FIELD_CUSTOM_VALIDATION_EXCEPTION
     * WHEN POST is received
     * THEN statusCode == 422, errorCode == VALIDATION_RULE_VIOLATION
     *
     * Same injection technique as Scenario 10 — real DmlException via 256-char name,
     * StatusCode overridden via @TestVisible flag.
     */
    @isTest
    static void testValidationRuleViolationReturns422() {
        String longName = 'A'.repeat(256);
        String payload = buildPayload(longName, VALID_LAST_NAME, VALID_EMAIL, null, null);
        setupRestContext(payload);

        UdcOnboardingService.forceDmlStatusCodeOverride = StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION;

        Test.startTest();
        UdcOnboardingService.OnboardingResponse resp = UdcOnboardingService.handlePost();
        Test.stopTest();

        System.assertEquals(422, RestContext.response.statusCode,
            'Expected HTTP 422 for validation rule StatusCode');
        System.assertEquals(false, resp.success,
            'Expected success=false on validation rule rejection');
        System.assertEquals('VALIDATION_RULE_VIOLATION', resp.errorCode,
            'Expected errorCode VALIDATION_RULE_VIOLATION for FIELD_CUSTOM_VALIDATION_EXCEPTION StatusCode');
        System.assert(resp.message.contains('validation rule rejected'),
            'Expected message to reference validation rule rejection');
    }
}
