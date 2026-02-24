/**
 * OpportunityTriggerHandler
 *
 * Orchestrating handler for the Opportunity trigger. This class is the single
 * entry point from OpportunityTrigger and is responsible for:
 *   - Determining which contexts require action
 *   - Performing all bulk SOQL queries so that service classes receive
 *     pre-fetched data and remain independently testable
 *   - Delegating to OpportunityTaskService and OpportunityNotificationService
 *
 * Design decisions:
 *   - All SOQL lives here, not in service classes, to keep services pure and
 *     easy to unit-test with injected data.
 *   - Notification is only sent on after insert (new pipeline entries), not on
 *     update, per the agreed acceptance criteria.
 *   - The handler accepts explicit context booleans rather than reading
 *     Trigger.* statics directly, making it fully testable outside a trigger
 *     execution context.
 */
public with sharing class OpportunityTriggerHandler {

    // -------------------------------------------------------------------------
    // Entry points called by OpportunityTrigger
    // -------------------------------------------------------------------------

    /**
     * Called from the trigger for the after insert context.
     *
     * Queries Account + Account owner data for all inserted Opportunities that
     * have an AccountId, then delegates to both service classes.
     *
     * @param newOpps  Trigger.new cast to List<Opportunity>
     */
    public void onAfterInsert(List<Opportunity> newOpps) {
        if (newOpps == null || newOpps.isEmpty()) {
            return;
        }

        Map<Id, Account> accountMap = queryAccountsForOpportunities(newOpps);

        // Task service handles Closed Won records created directly in that stage
        OpportunityTaskService.createFollowUpTasks(newOpps, accountMap);

        // Notification service fires only on insert for the $50k threshold
        OpportunityNotificationService.notifySalesManagerOfLargeOpportunities(
            newOpps,
            accountMap
        );
    }

    /**
     * Called from the trigger for the after update context.
     *
     * Queries Account + Account owner data for Opportunities that have
     * transitioned to Closed Won in this update, then delegates to the Task
     * service only (notifications are not re-sent on update).
     *
     * @param newOpps   Trigger.new cast to List<Opportunity>
     * @param oldMap    Trigger.oldMap cast to Map<Id, Opportunity>
     */
    public void onAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (newOpps == null || newOpps.isEmpty()) {
            return;
        }

        // Filter down to only the records that just transitioned to Closed Won
        // so we avoid unnecessary SOQL when nothing relevant changed.
        List<Opportunity> closedWonTransitions = getClosedWonTransitions(newOpps, oldMap);

        if (closedWonTransitions.isEmpty()) {
            return;
        }

        Map<Id, Account> accountMap = queryAccountsForOpportunities(closedWonTransitions);

        // Notification is intentionally NOT called on update per requirements
        OpportunityTaskService.createFollowUpTasks(closedWonTransitions, accountMap);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Returns the subset of Opportunities whose StageName just became
     * 'Closed Won' (i.e. it was something else before this DML).
     *
     * Keeping this logic here rather than in the service means the service
     * can be called with a pre-filtered list and does not need to know about
     * the old values.
     *
     * @param newOpps  Full Trigger.new list
     * @param oldMap   Full Trigger.oldMap
     * @return         Filtered list — may be empty, never null
     */
    @TestVisible
    private List<Opportunity> getClosedWonTransitions(
        List<Opportunity> newOpps,
        Map<Id, Opportunity> oldMap
    ) {
        List<Opportunity> transitions = new List<Opportunity>();
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (
                opp.StageName == 'Closed Won' &&
                (oldOpp == null || oldOpp.StageName != 'Closed Won')
            ) {
                transitions.add(opp);
            }
        }
        return transitions;
    }

    /**
     * Queries Account records (including the Account owner's IsActive flag and
     * Name) for all Opportunities that carry an AccountId.
     *
     * A single SOQL query is issued regardless of how many Opportunities are
     * in the list, satisfying the bulkification requirement.
     *
     * @param opps  Opportunities to derive Account IDs from
     * @return      Map of Account Id -> Account; empty map if none have an AccountId
     */
    @TestVisible
    private Map<Id, Account> queryAccountsForOpportunities(List<Opportunity> opps) {
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        if (accountIds.isEmpty()) {
            return new Map<Id, Account>();
        }

        // Owner fields are needed by OpportunityTaskService to determine
        // whether to assign the follow-up Task to the Account owner or fall
        // back to the Opportunity owner.
        return new Map<Id, Account>(
            [
                SELECT Id, Name, OwnerId, Owner.IsActive, Owner.Name
                FROM Account
                WHERE Id IN :accountIds
                WITH SECURITY_ENFORCED
            ]
        );
    }
}
