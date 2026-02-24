/**
 * OpportunityTriggerHandler
 *
 * Central handler for all Opportunity trigger events. This class is the single
 * entry point from OpportunityTrigger and is responsible for:
 *   1. Bulkifying related data lookups (Accounts + Account owners) in one SOQL query
 *      so downstream services never need to query Account data themselves.
 *   2. Routing to OpportunityTaskService for Closed Won follow-up Task creation
 *      (fires on both insert and update).
 *   3. Routing to OpportunityNotificationService for >$50k new Opportunity
 *      notifications (fires on insert only).
 *
 * Why a handler class rather than logic in the trigger?
 *   - Keeps the trigger file thin and version-control-friendly.
 *   - Makes unit testing possible without DML trigger invocation.
 *   - Allows future contexts (before delete, undelete, etc.) to be added cleanly.
 */
public with sharing class OpportunityTriggerHandler {

    // -------------------------------------------------------------------------
    // Public entry points — called directly by OpportunityTrigger
    // -------------------------------------------------------------------------

    /**
     * Handles after-insert logic.
     *
     * @param newOpps  Trigger.new cast to List<Opportunity>
     */
    public void onAfterInsert(List<Opportunity> newOpps) {
        Map<Id, Account> accountMap = buildAccountMap(newOpps);

        // Task creation for any Opportunity inserted directly as Closed Won
        OpportunityTaskService.createFollowUpTasks(newOpps, null, accountMap);

        // Notification for Opportunities over $50k — insert only
        OpportunityNotificationService.sendHighValueNotifications(newOpps, accountMap);
    }

    /**
     * Handles after-update logic.
     *
     * @param newOpps   Trigger.new cast to List<Opportunity>
     * @param oldMap    Trigger.oldMap cast to Map<Id, Opportunity>
     */
    public void onAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Map<Id, Account> accountMap = buildAccountMap(newOpps);

        // Task creation only when transitioning INTO Closed Won (not already there)
        OpportunityTaskService.createFollowUpTasks(newOpps, oldMap, accountMap);

        // Notifications are insert-only; no call to OpportunityNotificationService here
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Builds a map of Account Id -> Account (with owner details) for all
     * Opportunities in the current batch. A single SOQL query covers the
     * entire batch regardless of how many records are in Trigger.new.
     *
     * Owner.IsActive is fetched here so that downstream services can apply
     * the "Account owner inactive → fall back to Opportunity owner" rule
     * without issuing additional queries.
     *
     * @param opps  The list of Opportunities being processed
     * @return      Map keyed by Account Id; Opportunities with no AccountId
     *              will simply not find a match in the map (handled downstream)
     */
    private Map<Id, Account> buildAccountMap(List<Opportunity> opps) {
        // Collect the distinct set of Account Ids present in this batch
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        Map<Id, Account> accountMap = new Map<Id, Account>();
        if (accountIds.isEmpty()) {
            return accountMap;
        }

        // Single SOQL query — fetches Account owner info needed by both services
        for (Account acc : [
            SELECT Id, OwnerId, Owner.IsActive
            FROM Account
            WHERE Id IN :accountIds
        ]) {
            accountMap.put(acc.Id, acc);
        }

        return accountMap;
    }
}
