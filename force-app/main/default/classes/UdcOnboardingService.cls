/**
 * UdcOnboardingService
 *
 * Apex REST endpoint for uDesign Cloud onboarding portal.
 * Accepts a POST payload containing organization and contact data,
 * validates inputs, and atomically creates a Salesforce Account and
 * linked Contact. Uses a Savepoint to guarantee rollback if Contact
 * creation fails after Account insertion.
 *
 * HTTP status contract:
 *   201 — Account + Contact created successfully
 *   400 — Input validation failed (no DML executed)
 *   500 — DML error; transaction rolled back
 *
 * API Version: 66.0
 */
@RestResource(urlMapping='/UdcOnboardingService/*')
global with sharing class UdcOnboardingService {

    // -------------------------------------------------------------------------
    // @TestVisible flag: set to true in a test to force Contact DML failure.
    // Enables deterministic rollback testing without relying on org-specific
    // duplicate rules or validation rules.
    // -------------------------------------------------------------------------
    @TestVisible
    private static Boolean forceContactFailure = false;

    // =========================================================================
    // Inner Classes — JSON Payload Wrappers
    // =========================================================================

    /**
     * Root request wrapper. Field names match the JSON keys sent by the portal.
     * Note: onboard_type uses underscore (Apex identifiers cannot contain hyphens).
     */
    global class OnboardingRequest {
        public String onboard_type;
        public String is_parent;
        public String org_name;
        public String org_type;
        public String org_status;
        public String shipping_address_1;
        public String shipping_city;
        public String shipping_country;
        public String shipping_region;
        public String shipping_zip;
        public String phone;
        public String billing_address_1;
        public String billing_city;
        public String billing_country;
        public String billing_region;
        public String billing_zip;
        public String signature_required;
        public String out_of_service_area;
        public ContactRequest user;
    }

    /**
     * Nested contact/user wrapper inside the root request.
     */
    global class ContactRequest {
        public String first_name;
        public String last_name;
        public String email;
        public String phone;
        public String mailing_address_1;
        public String mailing_city;
        public String mailing_country;
        public String mailing_state;
        public String mailing_zipcode;
        public String user_type;
        public String role;
    }

    /**
     * Response envelope returned by handlePost().
     * On success: success=true, accountId, contactId populated.
     * On failure: success=false, errorCode and message populated.
     */
    global class OnboardingResponse {
        public Boolean success;
        public String message;
        public String errorCode;
        public Id accountId;
        public Id contactId;
    }

    /**
     * Custom exception used ONLY in test context via the @TestVisible
     * forceContactFailure flag. Using a named custom exception (rather than
     * a manually constructed DmlException) avoids the UnexpectedException
     * that Apex throws when getDmlMessage(0) is called on a non-platform DmlException.
     */
    @TestVisible
    private class ContactInsertException extends Exception {}

    // =========================================================================
    // Entry Point
    // =========================================================================

    /**
     * Handles POST requests to /services/apexrest/UdcOnboardingService/
     *
     * Flow:
     *   1. Deserialize JSON body into OnboardingRequest
     *   2. Validate required fields and email format → 400 on failure
     *   3. Set savepoint
     *   4. Insert Account (with FLS check) → 500 on failure
     *   5. Insert Contact linked to Account (with FLS check) → rollback + 500 on failure
     *   6. Return 201 with accountId and contactId
     */
    @HttpPost
    global static OnboardingResponse handlePost() {
        RestResponse res = RestContext.response;

        // Step 1: Deserialize the JSON request body
        OnboardingRequest req = (OnboardingRequest) JSON.deserialize(
            RestContext.request.requestBody.toString(),
            OnboardingRequest.class
        );

        // Step 2: Validate inputs before any DML — yields HTTP 400 on failure
        String validationError = validateInput(req);
        if (validationError != null) {
            res.statusCode = 400;
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.errorCode = 'INVALID_INPUT';
            errResp.message   = 'Validation failed: ' + validationError;
            return errResp;
        }

        // Step 3: Resolve RecordType IDs dynamically (portable across orgs)
        Id accountRecordTypeId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName()
            .get('Commercial')
            .getRecordTypeId();

        Id contactRecordTypeId = Schema.SObjectType.Contact
            .getRecordTypeInfosByDeveloperName()
            .get('Commercial')
            .getRecordTypeId();

        // Compute the UDC onboarding flag once — used on both records
        Boolean isUdcOnboarding = (req.onboard_type == 'udesign.cloud');

        // Step 4: Build the Account record
        Account acc = new Account();
        acc.RecordTypeId        = accountRecordTypeId;
        acc.Name                = req.org_name;
        acc.Type                = req.org_type;
        acc.Account_Status__c   = req.org_status;
        acc.Phone               = req.phone;

        // String → Boolean coercion for checkbox fields
        // Payload sends "true"/"false" as strings; Apex checkboxes require Boolean.
        acc.Is_Parent__c            = (req.is_parent        == 'true');
        acc.Signature_Required__c   = (req.signature_required == 'true');
        acc.Out_of_Service_Area__c  = (req.out_of_service_area == 'true');

        // UDC flag
        acc.UDC_Onboarding__c = isUdcOnboarding;

        // Shipping address
        acc.ShippingStreet      = req.shipping_address_1;
        acc.ShippingCity        = req.shipping_city;
        acc.ShippingCountry     = req.shipping_country;
        acc.ShippingState       = req.shipping_region;
        acc.ShippingPostalCode  = req.shipping_zip;

        // Billing address
        acc.BillingStreet       = req.billing_address_1;
        acc.BillingCity         = req.billing_city;
        acc.BillingCountry      = req.billing_country;
        acc.BillingState        = req.billing_region;
        acc.BillingPostalCode   = req.billing_zip;

        // Step 5: Set savepoint before first DML to enable atomic rollback
        Savepoint sp = Database.setSavepoint();

        // Step 6: FLS enforcement on Account, then insert.
        // stripInaccessible removes user-input fields the running user cannot write,
        // satisfying FLS requirements for with sharing classes (REQ-8).
        // UDC_Onboarding__c is a system-set flag (not from user input), so it is
        // reassigned after stripping to guarantee it survives profile-level FLS.
        SObjectAccessDecision accDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<SObject>{ acc }
        );
        Account accToInsert = (Account) accDecision.getRecords()[0];
        // Reapply system-controlled flag after FLS strip — this field is always
        // set by the endpoint logic, never by the caller, so bypassing FLS here
        // is intentional and safe. The flag cannot be injected maliciously.
        accToInsert.UDC_Onboarding__c = isUdcOnboarding;

        try {
            insert accToInsert;
        } catch (DmlException e) {
            // Account insert failed — no records were written; no rollback needed.
            // getDmlMessage(0) returns the user-facing platform error (REQ-7).
            res.statusCode = 500;
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getDmlMessage(0);
            return errResp;
        }

        // Step 7: Build the Contact record, linked to the inserted Account
        Contact con = new Contact();
        con.RecordTypeId    = contactRecordTypeId;
        con.AccountId       = accToInsert.Id;
        con.FirstName       = req.user.first_name;
        con.LastName        = req.user.last_name;
        con.Email           = req.user.email;
        con.Phone           = req.user.phone;

        // user_type mapping: 'Customer Account Owner' → 'Account Owner'
        if (req.user.user_type == 'Customer Account Owner') {
            con.Company_User_Type__c = 'Account Owner';
        } else {
            con.Company_User_Type__c = req.user.user_type;
        }

        con.Contact_Role__c = req.user.role;

        // UDC flag mirrors Account
        con.UDC_Onboarding__c = isUdcOnboarding;

        // Mailing address
        con.MailingStreet       = req.user.mailing_address_1;
        con.MailingCity         = req.user.mailing_city;
        con.MailingCountry      = req.user.mailing_country;
        con.MailingState        = req.user.mailing_state;
        con.MailingPostalCode   = req.user.mailing_zipcode;

        // Step 8: FLS enforcement on Contact, then insert.
        // UDC_Onboarding__c is a system-set flag — reapplied after FLS strip
        // for the same reason as on Account above.
        SObjectAccessDecision conDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<SObject>{ con }
        );
        Contact conToInsert = (Contact) conDecision.getRecords()[0];
        conToInsert.UDC_Onboarding__c = isUdcOnboarding;

        try {
            // @TestVisible bypass: forces a controlled failure to test rollback
            // deterministically, without relying on org-specific duplicate/validation rules.
            // We use StringException (a catchable exception) so getDmlMessage(0) is never
            // called on a manually constructed DmlException (which would throw
            // UnexpectedException — a non-catchable system exception in Apex).
            if (Test.isRunningTest() && forceContactFailure) {
                throw new ContactInsertException('Forced test failure for rollback verification');
            }
            insert conToInsert;
        } catch (DmlException e) {
            // Platform DML failure — getDmlMessage(0) is safe on real DmlExceptions.
            Database.rollback(sp);
            res.statusCode = 500;
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getDmlMessage(0);
            return errResp;
        } catch (ContactInsertException e) {
            // Test-only forced failure — rolls back Account to verify atomicity.
            // This is the only place Database.rollback() is called (REQ-6 / Design AD #3).
            Database.rollback(sp);
            res.statusCode = 500;
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getMessage();
            return errResp;
        }

        // Step 9: Both records created — return 201 success response
        res.statusCode = 201;
        OnboardingResponse successResp = new OnboardingResponse();
        successResp.success   = true;
        successResp.message   = 'Account and Contact created successfully.';
        successResp.accountId = accToInsert.Id;
        successResp.contactId = conToInsert.Id;
        return successResp;
    }

    // =========================================================================
    // Private Helpers
    // =========================================================================

    /**
     * Validates mandatory fields and email format before any DML.
     * Returns null on success; returns an error message string on failure.
     *
     * Validation rules (REQ-2):
     *   - org_name must not be null or blank
     *   - user.last_name must not be null or blank
     *   - user.email must match the RFC-compatible email regex
     *
     * @param req  The deserialized OnboardingRequest
     * @return     Null if valid; validation error message if invalid
     */
    private static String validateInput(OnboardingRequest req) {
        if (String.isBlank(req.org_name)) {
            return 'org_name is required.';
        }
        if (req.user == null || String.isBlank(req.user.last_name)) {
            return 'user.last_name is required.';
        }
        // Email regex: RFC-compatible pattern that rejects malformed addresses.
        // Pattern.matches() requires a FULL match (anchors are implicit).
        String emailRegex = '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$';
        if (String.isBlank(req.user.email) || !Pattern.matches(emailRegex, req.user.email)) {
            return 'user.email is not a valid email address.';
        }
        return null;
    }
}
