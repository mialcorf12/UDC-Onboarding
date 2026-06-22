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
     * Callers can override individual values by using String.replace on the result,
     * but most tests simply use named parameters directly in their payload string.
     *
     * @param orgName       Value for org_name
     * @param lastName      Value for user.last_name
     * @param email         Value for user.email
     * @param onboardType   Value for onboard_type (pass null to omit the field)
     */
    private static String buildPayload(
        String orgName,
        String lastName,
        String email,
        String onboardType
    ) {
        String onboardTypeFragment = (onboardType != null)
            ? '"onboard_type": "' + onboardType + '",'
            : '';

        return '{'
            + onboardTypeFragment
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
            +   '"role": "Orthodontist"'
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
        String payload = buildPayload(null, VALID_LAST_NAME, VALID_EMAIL, null);
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
        String payload = buildPayload(VALID_ORG_NAME, null, VALID_EMAIL, null);
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
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, 'not-an-email', null);
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
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_UDC);
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
            SELECT Id, Name, UDC_Onboarding__c
            FROM Account
            WHERE Id = :resp.accountId
        ];
        System.assertEquals(1, accounts.size(),
            'Expected exactly 1 Account to be inserted');
        System.assertEquals(true, accounts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = true on Account when onboard_type = udesign.cloud');

        // Verify Contact persisted with UDC flag and linked to Account
        List<Contact> contacts = [
            SELECT Id, AccountId, UDC_Onboarding__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        System.assertEquals(1, contacts.size(),
            'Expected exactly 1 Contact to be inserted');
        System.assertEquals(true, contacts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = true on Contact when onboard_type = udesign.cloud');
        System.assertEquals(resp.accountId, contacts[0].AccountId,
            'Expected Contact to be linked to the created Account');
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
        // null onboardType → field is omitted from JSON
        String payload = buildPayload(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null);
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
            SELECT Id, UDC_Onboarding__c
            FROM Account
            WHERE Id = :resp.accountId
        ];
        System.assertEquals(1, accounts.size(),
            'Expected exactly 1 Account to be inserted');
        System.assertEquals(false, accounts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = false on Account when onboard_type is absent');

        // Verify UDC flag is false on Contact
        List<Contact> contacts = [
            SELECT Id, UDC_Onboarding__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        System.assertEquals(1, contacts.size(),
            'Expected exactly 1 Contact to be inserted');
        System.assertEquals(false, contacts[0].UDC_Onboarding__c,
            'Expected UDC_Onboarding__c = false on Contact when onboard_type is absent');
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
        String payload = buildPayload(ROLLBACK_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null);
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
        String payload = buildPayload(longName, VALID_LAST_NAME, VALID_EMAIL, null);
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
}
