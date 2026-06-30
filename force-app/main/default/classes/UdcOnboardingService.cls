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
 *   201 — Account + Contact created (or Account updated + Contact created) successfully
 *   400 — Input validation failed (no DML executed)
 *   404 — org_sfdc_id provided but Account not found in Salesforce
 *   409 — Duplicate record detected by a Salesforce Duplicate Rule
 *   422 — Salesforce Validation Rule or required-field constraint rejected the record
 *   500 — Unexpected DML error (trigger exception, lock timeout, etc.); transaction rolled back
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

    @TestVisible
    private static StatusCode forceDmlStatusCodeOverride = null;

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
        public String org_sfdc_id;
        public String org_id;
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
        public String user_id;
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
     * Flow — Branch A (org_sfdc_id blank/null): create new Account + Contact
     *   1. Deserialize JSON body
     *   2. Validate required fields and email → 400 on failure
     *   3. Set savepoint
     *   4. Insert Account (FLS-checked) → 500 on failure
     *   5. Insert Contact linked to Account (FLS-checked) → rollback + 500 on failure
     *   6. Return 201
     *
     * Flow — Branch B (org_sfdc_id has value): update existing Account + create Contact
     *   1. Deserialize JSON body
     *   2. Validate required fields and email → 400 on failure
     *   3. SOQL lookup by Account Id → 404 if not found
     *   4. Set savepoint
     *   5. Update existing Account (FLS-checked) → rollback + 500 on failure
     *   6. Insert Contact linked to existing Account (FLS-checked) → rollback + 500 on failure
     *   7. Return 201
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

        // Compute the UDC onboarding flag once — used on both Account and Contact
        Boolean isUdcOnboarding = (req.onboard_type == 'udesign.cloud');

        // =====================================================================
        // BRANCH DECISION: org_sfdc_id present → update existing Account
        //                  org_sfdc_id blank/null → create new Account
        // =====================================================================
        if (String.isNotBlank(req.org_sfdc_id)) {
            return handleExistingAccount(req, res, contactRecordTypeId, isUdcOnboarding);
        } else {
            return handleNewAccount(req, res, accountRecordTypeId, contactRecordTypeId, isUdcOnboarding);
        }
    }

    // =========================================================================
    // Branch A — Create new Account + Contact
    // =========================================================================

    /**
     * Branch A: org_sfdc_id is blank/null.
     * Creates a new Account and a linked Contact atomically.
     * Uses a savepoint to roll back the Account if Contact insert fails.
     */
    private static OnboardingResponse handleNewAccount(
        OnboardingRequest req,
        RestResponse res,
        Id accountRecordTypeId,
        Id contactRecordTypeId,
        Boolean isUdcOnboarding
    ) {
        // Build the Account record from payload
        Account acc = new Account();
        acc.RecordTypeId = accountRecordTypeId;
        applyAccountFields(acc, req, isUdcOnboarding);

        // Set savepoint before first DML to enable atomic rollback
        Savepoint sp = Database.setSavepoint();

        // FLS enforcement on Account, then insert.
        // UDC_Onboarding__c is a system-set flag — reapplied after FLS strip
        // because stripInaccessible may remove it if the running user's profile
        // restricts the field. The endpoint always controls this flag; it cannot
        // be injected by the caller.
        SObjectAccessDecision accDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<SObject>{ acc }
        );
        Account accToInsert = (Account) accDecision.getRecords()[0];
        accToInsert.UDC_Onboarding__c   = isUdcOnboarding;
        accToInsert.uLab_Acct_Number__c = acc.uLab_Acct_Number__c;

        try {
            insert accToInsert;
        } catch (DmlException e) {
            // Account insert failed — no records written; no rollback needed.
            return buildDmlErrorResponse(e, res, null);
        }

        // Build and insert Contact linked to the new Account
        Contact conToInsert = buildContact(req, accToInsert.Id, contactRecordTypeId, isUdcOnboarding);
        return insertContact(conToInsert, sp, res, accToInsert.Id, 'Account and Contact created successfully.');
    }

    // =========================================================================
    // Branch B — Update existing Account + create Contact
    // =========================================================================

    /**
     * Branch B: org_sfdc_id has a value.
     * Looks up the Account by the provided Salesforce Id.
     * Returns 404 if not found. Updates the Account and creates a linked Contact atomically.
     */
    private static OnboardingResponse handleExistingAccount(
        OnboardingRequest req,
        RestResponse res,
        Id contactRecordTypeId,
        Boolean isUdcOnboarding
    ) {
        // SOQL lookup — never create an Account in this branch
        List<Account> existing = [
            SELECT Id, RecordTypeId, Name, Type, Account_Status__c, Phone,
                   Is_Parent__c, Signature_Required__c, Out_of_Service_Area__c,
                   UDC_Onboarding__c,
                   ShippingStreet, ShippingCity, ShippingCountry, ShippingState, ShippingPostalCode,
                   BillingStreet, BillingCity, BillingCountry, BillingState, BillingPostalCode
            FROM Account
            WHERE Id = :req.org_sfdc_id
            LIMIT 1
        ];

        if (existing.isEmpty()) {
            res.statusCode = 404;
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.errorCode = 'ACCOUNT_NOT_FOUND';
            errResp.message   = 'Account ' + req.org_sfdc_id + ' not found in Salesforce.';
            return errResp;
        }

        // Apply payload values onto the retrieved Account record
        Account acc = existing[0];
        applyAccountFields(acc, req, isUdcOnboarding);

        // Set savepoint before DML to cover update + Contact insert atomically
        Savepoint sp = Database.setSavepoint();

        // FLS enforcement on Account update.
        // UDC_Onboarding__c reapplied after strip for the same reason as Branch A.
        SObjectAccessDecision accDecision = Security.stripInaccessible(
            AccessType.UPDATABLE,
            new List<SObject>{ acc }
        );
        Account accToUpdate = (Account) accDecision.getRecords()[0];
        accToUpdate.UDC_Onboarding__c   = isUdcOnboarding;
        accToUpdate.uLab_Acct_Number__c = acc.uLab_Acct_Number__c;

        try {
            update accToUpdate;
        } catch (DmlException e) {
            // Account update failed — buildDmlErrorResponse rolls back sp before returning.
            return buildDmlErrorResponse(e, res, sp);
        }

        // Build and insert Contact linked to the existing Account
        Contact conToInsert = buildContact(req, accToUpdate.Id, contactRecordTypeId, isUdcOnboarding);
        return insertContact(conToInsert, sp, res, accToUpdate.Id, 'Account updated and Contact created successfully.');
    }

    // =========================================================================
    // Shared Helpers
    // =========================================================================

    /**
     * Applies all payload field values onto an Account record (new or existing).
     * Called by both Branch A and Branch B to avoid duplication.
     * Does NOT set RecordTypeId — Branch A sets it on construction; Branch B
     * preserves the existing RecordType already on the record.
     *
     * @param acc              The Account sObject to populate (mutated in place)
     * @param req              The deserialized request payload
     * @param isUdcOnboarding  Pre-computed UDC flag value
     */
    private static void applyAccountFields(Account acc, OnboardingRequest req, Boolean isUdcOnboarding) {
        acc.Name              = req.org_name;
        acc.Type              = req.org_type;
        acc.Account_Status__c = req.org_status;
        acc.Phone             = req.phone;

        // String → Boolean coercion: payload sends "true"/"false" as strings
        acc.Is_Parent__c           = (req.is_parent           == 'true');
        acc.Signature_Required__c  = (req.signature_required  == 'true');
        acc.Out_of_Service_Area__c = (req.out_of_service_area == 'true');

        // UDC flag set by endpoint logic (not by caller)
        acc.UDC_Onboarding__c = isUdcOnboarding;

        // Shipping address
        acc.ShippingStreet     = req.shipping_address_1;
        acc.ShippingCity       = req.shipping_city;
        acc.ShippingCountry    = req.shipping_country;
        acc.ShippingState      = req.shipping_region;
        acc.ShippingPostalCode = req.shipping_zip;

        // Billing address
        acc.BillingStreet     = req.billing_address_1;
        acc.BillingCity       = req.billing_city;
        acc.BillingCountry    = req.billing_country;
        acc.BillingState      = req.billing_region;
        acc.BillingPostalCode = req.billing_zip;
        acc.uLab_Acct_Number__c = String.isBlank(req.org_id) ? null : Decimal.valueOf(req.org_id);
    }

    /**
     * Builds a Contact record from the request payload.
     * Shared by both Branch A and Branch B.
     *
     * @param req               The deserialized request payload
     * @param accountId         The Account Id to link the Contact to
     * @param contactRecordTypeId  Resolved RecordType Id for Contact
     * @param isUdcOnboarding   Pre-computed UDC flag value
     * @return                  A populated (not yet inserted) Contact
     */
    private static Contact buildContact(
        OnboardingRequest req,
        Id accountId,
        Id contactRecordTypeId,
        Boolean isUdcOnboarding
    ) {
        Contact con = new Contact();
        con.RecordTypeId = contactRecordTypeId;
        con.AccountId    = accountId;
        con.FirstName    = req.user.first_name;
        con.LastName     = req.user.last_name;
        con.Email        = req.user.email;
        con.Phone        = req.user.phone;

        // user_type mapping: 'Customer Account Owner' → 'Account Owner'
        if (req.user.user_type == 'Customer Account Owner') {
            con.Company_User_Type__c = 'Account Owner';
        } else {
            con.Company_User_Type__c = req.user.user_type;
        }

        con.Contact_Role__c   = req.user.role;
        con.Portal_User_ID__c = req.user.user_id;
        con.UDC_Onboarding__c = isUdcOnboarding;

        // Mailing address
        con.MailingStreet     = req.user.mailing_address_1;
        con.MailingCity       = req.user.mailing_city;
        con.MailingCountry    = req.user.mailing_country;
        con.MailingState      = req.user.mailing_state;
        con.MailingPostalCode = req.user.mailing_zipcode;

        return con;
    }

    /**
     * FLS-enforces and inserts a Contact record.
     * On success, returns HTTP 201. On failure, rolls back to savepoint and returns HTTP 500.
     * Handles both platform DmlExceptions and the @TestVisible ContactInsertException.
     *
     * @param con         The Contact to insert (pre-built by buildContact)
     * @param sp          The savepoint to roll back to on failure
     * @param res         The RestResponse to set statusCode on
     * @param accountId   The Account Id — included in the success response
     * @param successMsg  The message string to return on HTTP 201
     * @return            A populated OnboardingResponse
     */
    private static OnboardingResponse insertContact(
        Contact con,
        Savepoint sp,
        RestResponse res,
        Id accountId,
        String successMsg
    ) {
        // FLS enforcement on Contact.
        // UDC_Onboarding__c reapplied after strip — same rationale as Account.
        SObjectAccessDecision conDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<SObject>{ con }
        );
        Contact conToInsert = (Contact) conDecision.getRecords()[0];
        conToInsert.UDC_Onboarding__c  = con.UDC_Onboarding__c;
        conToInsert.Portal_User_ID__c  = con.Portal_User_ID__c;

        try {
            // @TestVisible bypass: forces a controlled failure to test rollback
            // deterministically without relying on org-specific rules.
            if (Test.isRunningTest() && forceContactFailure) {
                throw new ContactInsertException('Forced test failure for rollback verification');
            }
            insert conToInsert;
        } catch (DmlException e) {
            // Platform DML failure — buildDmlErrorResponse rolls back sp and classifies the error.
            return buildDmlErrorResponse(e, res, sp);
        } catch (ContactInsertException e) {
            // Test-only forced failure — rolls back to verify atomicity.
            Database.rollback(sp);
            res.statusCode = 500;
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getMessage();
            return errResp;
        }

        res.statusCode = 201;
        OnboardingResponse successResp = new OnboardingResponse();
        successResp.success   = true;
        successResp.message   = successMsg;
        successResp.accountId = accountId;
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

    /**
     * Classifies a DmlException by StatusCode, rolls back if a savepoint is provided,
     * and returns the appropriate OnboardingResponse with the correct HTTP status.
     *
     * StatusCode mapping:
     *   DUPLICATE_VALUE / DUPLICATES_DETECTED         → 409 DUPLICATE_RECORD
     *   FIELD_CUSTOM_VALIDATION_EXCEPTION / REQUIRED_FIELD_MISSING → 422 VALIDATION_RULE_VIOLATION
     *   All other codes                               → 500 SALESFORCE_DML_ERROR
     *
     * @param e   The caught DmlException
     * @param res The RestResponse to set statusCode on
     * @param sp  Savepoint to roll back to; pass null when no DML preceded the failure
     */
    private static OnboardingResponse buildDmlErrorResponse(
        DmlException e,
        RestResponse res,
        Savepoint sp
    ) {
        if (sp != null) {
            Database.rollback(sp);
        }

        StatusCode dmlType = (Test.isRunningTest() && forceDmlStatusCodeOverride != null)
            ? forceDmlStatusCodeOverride
            : e.getDmlType(0);
        OnboardingResponse errResp = new OnboardingResponse();
        errResp.success = false;

        if (dmlType == StatusCode.DUPLICATE_VALUE
            || dmlType == StatusCode.DUPLICATES_DETECTED) {
            res.statusCode    = 409;
            errResp.errorCode = 'DUPLICATE_RECORD';
            errResp.message   = 'Duplicate record detected. Original Salesforce error: '
                                + e.getDmlMessage(0);
        } else if (dmlType == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
                   || dmlType == StatusCode.REQUIRED_FIELD_MISSING) {
            res.statusCode    = 422;
            errResp.errorCode = 'VALIDATION_RULE_VIOLATION';
            errResp.message   = 'Salesforce validation rule rejected the request. Original Salesforce error: '
                                + e.getDmlMessage(0);
        } else {
            res.statusCode    = 500;
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getDmlMessage(0);
        }

        return errResp;
    }
}
