# Proposal: sfdc-accountuser-event

## Intent

The UDC onboarding service must notify the uDC system about the outcome of the Account + Contact creation process. We are solving the need to establish and persist ID mapping (Salesforce ID to UDC internal IDs) in the UDC system by publishing Platform Events for both success and failure scenarios immediately.

## Scope

### In Scope
- Creation of two new Platform Event types: `Sfdc_Accountuser_CreatedSuccess__e` and `Sfdc_Accountuser_CreatedFailed__e`.
- Implementing `publishSuccessEvent` and `publishFailedEvent` in `UdcOnboardingService.cls`.
- Firing the events from convergence points (`insertContact()` for success and DML failure, `handlePost()` for validation failure, `handleExistingAccount()` for 404).
- Using `PUBLISH_IMMEDIATELY` behavior to guarantee delivery of failure events even if the DML transaction is rolled back.
- Silently swallowing and logging publish errors so HTTP responses remain unaffected.
- Extending `insertContact()` signature with `orgId: String` and `userId: String` parameters.
- Comprehensive test coverage for success and failure event scenarios.

### Out of Scope
- UDC subscription configuration and client-side ingestion logic.
- Creation of new Platform Event Channel metadata (subscribers will use standard channels).
- CDC or Streaming API changes.
- Modifications to the existing REST API request/response JSON payload structures.

## Capabilities

> This section is the CONTRACT between proposal and specs phases.
> The sdd-spec agent reads this to know exactly which spec files to create or update.

### New Capabilities
- `accountuser-event-notification`: Platform Event publishing of onboarding outcomes (success and failure) to enable system ID mapping integration with uDC.

### Modified Capabilities
- None

## Approach

We will introduce two new `PUBLISH_IMMEDIATELY` Platform Event objects to represent the success and failure states of the onboarding request. `UdcOnboardingService` will be updated to extract the necessary logical IDs from the request payload and Salesforce records. We will add private helper methods to instantiate and publish these events via `EventBus.publish()`, wrapped in a try/catch to silently handle exceptions. These helpers will be invoked at the known request termination paths. By choosing `PUBLISH_IMMEDIATELY`, we guarantee failure events reach UDC even when the transaction rolls back.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `force-app/main/default/objects/Sfdc_Accountuser_CreatedSuccess__e/` | New | New platform event for successful onboarding |
| `force-app/main/default/objects/Sfdc_Accountuser_CreatedFailed__e/` | New | New platform event for failed onboarding |
| `force-app/main/default/classes/UdcOnboardingService.cls` | Modified | Add event publish helpers, update `insertContact()` signature |
| `force-app/main/default/classes/UdcOnboardingServiceTest.cls` | Modified | Add test scenarios for platform events |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Unhandled Exceptions blocking HTTP response | Low | Wrap `EventBus.publish()` in try-catch and log errors internally. |
| Incomplete test coverage for PE | Low | Use `Test.getEventBus().deliver()` to accurately test published events. |
| Publish limits exceeded | Low | Governor limits monitor (250k/24h Enterprise) is sufficient for onboarding volumes. |

## Rollback Plan

If deployment or integration issues occur, we will deploy a quick fix or revert `UdcOnboardingService.cls` to its prior commit hash, removing the `EventBus.publish()` calls. The platform event metadata does not strictly need immediate deletion and can be cleaned up later.

## Dependencies

- Integration dependency: uDC must be configured to subscribe to the new standard Platform Events.

## Success Criteria

- [ ] Successful HTTP 201 requests publish a `Sfdc_Accountuser_CreatedSuccess__e` event containing populated Salesforce and request IDs.
- [ ] Failed DML/validation HTTP requests publish a `Sfdc_Accountuser_CreatedFailed__e` event populated only with the available request IDs (Salesforce IDs null).
- [ ] A rolled-back transaction successfully emits the failed event.
- [ ] Any failure during `EventBus.publish()` does not alter the original REST response.
