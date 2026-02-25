/**
 * OpportunityTriggerHandler
 *
 * Coordinates business logic for Opportunity trigger events.
 * Acts as the single point of delegation from OpportunityTrigger,
 * keeping the trigger itself thin and this class focused on orchestration.
 *
 * Design decisions:
 * - A single bulkified SOQL query fetches Account + Owner data here so that
 *   neither service class needs its own Account query. This keeps service
 *   classes stateless and prevents redundant queries when both services run.
 * - After-insert fires both Task creation (Closed Won at insert) and
 *   high-value notifications ($50k+).
 * - After-update fires Task creation only for Opps that *transition* to
 *   Closed Won in this DML; notifications are insert-only per requirements.
 */
public with sharing class OpportunityTriggerHandler {

    // -------------------------------------------------------------------------
    // Public entry points called by OpportunityTrigger
    // -------------------------------------------------------------------------

    /**
     * Handles after-insert context.
     * Covers Opportunities created directly in Closed Won stage and
     * high-value Opportunities (Amount > 50,000) for notifications.
     *
     * @param newOpps  Trigger.new cast to List<Opportunity>
     */
    public void handleAfterInsert(List<Opportunity> newOpps) {
        // Collect unique Account Ids so we can fetch owner data in one query
        Set<Id> accountIds = collectAccountIds(newOpps);
        Map<Id, Account> accountMap = fetchAccountMap(accountIds);

        // Task creation: only for Opps already in Closed Won at insert time
        List<Opportunity> closedWonOpps = filterClosedWon(newOpps);
        if (!closedWonOpps.isEmpty()) {
            OpportunityTaskService.createFollowUpTasks(closedWonOpps, accountMap);
        }

        // Notifications: for all inserted Opps over $50k (service filters internally)
        OpportunityNotificationService.sendHighValueNotifications(newOpps, accountMap);
    }

    /**
     * Handles after-update context.
     * Only creates Tasks for Opportunities that *transitioned* to Closed Won
     * in this specific update (i.e., were not already Closed Won before).
     * Notifications are intentionally skipped on update per requirements.
     *
     * @param newOpps  Trigger.new cast to List<Opportunity>
     * @param oldMap   Trigger.oldMap cast to Map<Id, Opportunity>
     */
    public void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        // Identify only the Opps that moved INTO Closed Won during this update
        List<Opportunity> newlyClosedWon = filterNewlyClosedWon(newOpps, oldMap);

        if (newlyClosedWon.isEmpty()) {
            return; // Nothing to do — exit early to avoid unnecessary SOQL
        }

        Set<Id> accountIds = collectAccountIds(newlyClosedWon);
        Map<Id, Account> accountMap = fetchAccountMap(accountIds);

        OpportunityTaskService.createFollowUpTasks(newlyClosedWon, accountMap);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Collects non-null AccountId values from a list of Opportunities.
     * Null-safe: Opportunities without an Account are simply excluded.
     */
    private Set<Id> collectAccountIds(List<Opportunity> opps) {
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }
        return accountIds;
    }

    /**
     * Performs a single bulkified SOQL query to retrieve Account records
     * along with their Owner's IsActive flag and UserRole DeveloperName.
     * These fields are required by both service classes.
     *
     * Returns an empty map when accountIds is empty to avoid a pointless query.
     */
    private Map<Id, Account> fetchAccountMap(Set<Id> accountIds) {
        if (accountIds.isEmpty()) {
            return new Map<Id, Account>();
        }

        return new Map<Id, Account>(
            [
                SELECT Id, OwnerId, Owner.IsActive, Owner.UserRoleId, Owner.UserRole.DeveloperName
                FROM Account
                WHERE Id IN :accountIds
            ]
        );
    }

    /**
     * Returns Opportunities whose StageName is 'Closed Won'.
     * Used for after-insert to catch Opps created directly in that stage.
     */
    private List<Opportunity> filterClosedWon(List<Opportunity> opps) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (opp.StageName == 'Closed Won') {
                result.add(opp);
            }
        }
        return result;
    }

    /**
     * Returns Opportunities that transitioned TO 'Closed Won' in this update.
     * An Opp qualifies only if its new StageName is 'Closed Won' AND its
     * previous StageName was something different — preventing duplicate Tasks
     * if a Closed Won Opp is updated again without a stage change.
     */
    private List<Opportunity> filterNewlyClosedWon(
        List<Opportunity> newOpps,
        Map<Id, Opportunity> oldMap
    ) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (opp.StageName == 'Closed Won' && oldOpp.StageName != 'Closed Won') {
                result.add(opp);
            }
        }
        return result;
    }
}
