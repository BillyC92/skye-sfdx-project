/**
 * OpportunityTriggerHandler
 *
 * Central handler class for the Opportunity trigger. Contains no business logic itself —
 * it is responsible for:
 *   1. Identifying which records meet criteria for downstream processing
 *   2. Performing all bulk SOQL queries (single query per object, outside loops)
 *   3. Delegating to OpportunityTaskService and OpportunityNotificationService
 *
 * Trigger contexts handled:
 *   - afterInsert  : Notify Sales Manager for Opportunities with Amount > 50,000
 *   - afterUpdate  : Create follow-up Tasks for Closed Won transitions
 *
 * NOTE: Before-insert context is wired in the trigger but not currently used here.
 *       It is included so the handler can be extended without modifying the trigger.
 */
public with sharing class OpportunityTriggerHandler {

    // ─── Constants ────────────────────────────────────────────────────────────

    private static final String CLOSED_WON_STAGE   = 'Closed Won';
    private static final Decimal NOTIFICATION_THRESHOLD = 50000;

    // ─── Entry Points (called by OpportunityTrigger) ──────────────────────────

    /**
     * Handles logic that must run after Opportunity records are inserted.
     * Currently: sends custom notifications for high-value Opportunities.
     *
     * @param newList  Trigger.new — the newly inserted Opportunity records
     */
    public static void afterInsert(List<Opportunity> newList) {
        List<Opportunity> highValueOpps = filterHighValueOpportunities(newList);

        if (highValueOpps.isEmpty()) {
            return;
        }

        // Bulk-query Account data for all qualifying Opportunities in one SOQL
        Map<Id, Account> accountMap = queryAccountData(highValueOpps);

        OpportunityNotificationService.sendHighValueNotifications(highValueOpps, accountMap);
    }

    /**
     * Handles logic that must run after Opportunity records are updated.
     * Currently: creates follow-up Tasks for records transitioning to Closed Won.
     *
     * @param newList   Trigger.new — updated Opportunity records
     * @param oldMap    Trigger.oldMap — previous state of the same records
     */
    public static void afterUpdate(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        List<Opportunity> closedWonTransitions = filterClosedWonTransitions(newList, oldMap);

        if (closedWonTransitions.isEmpty()) {
            return;
        }

        // Bulk-query Account data (including owner active status) in one SOQL
        Map<Id, Account> accountMap = queryAccountData(closedWonTransitions);

        OpportunityTaskService.createFollowUpTasks(closedWonTransitions, accountMap);
    }

    // ─── Filtering Helpers ────────────────────────────────────────────────────

    /**
     * Returns Opportunities that are transitioning TO Closed Won in this update.
     * A transition is defined as: new stage = 'Closed Won' AND old stage != 'Closed Won'.
     * This prevents re-processing records that were already Closed Won.
     *
     * @param newList  Updated records
     * @param oldMap   Previous record state
     * @return         Subset of newList that represent genuine Closed Won transitions
     */
    @TestVisible
    private static List<Opportunity> filterClosedWonTransitions(
        List<Opportunity> newList,
        Map<Id, Opportunity> oldMap
    ) {
        List<Opportunity> transitions = new List<Opportunity>();

        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            Boolean isNowClosedWon  = opp.StageName == CLOSED_WON_STAGE;
            Boolean wasNotClosedWon = oldOpp == null || oldOpp.StageName != CLOSED_WON_STAGE;

            if (isNowClosedWon && wasNotClosedWon) {
                transitions.add(opp);
            }
        }

        return transitions;
    }

    /**
     * Returns Opportunities with Amount strictly greater than the notification threshold.
     * Boundary: Amount > 50,000 (exclusive — exactly 50,000 does NOT qualify).
     * Null Amount values are treated as zero and excluded.
     *
     * @param opps  List of Opportunities to evaluate
     * @return      Subset where Amount > NOTIFICATION_THRESHOLD
     */
    @TestVisible
    private static List<Opportunity> filterHighValueOpportunities(List<Opportunity> opps) {
        List<Opportunity> highValue = new List<Opportunity>();

        for (Opportunity opp : opps) {
            if (opp.Amount != null && opp.Amount > NOTIFICATION_THRESHOLD) {
                highValue.add(opp);
            }
        }

        return highValue;
    }

    // ─── Bulk Data Retrieval ──────────────────────────────────────────────────

    /**
     * Queries Account records (with Owner active status) for all Opportunities
     * in the provided list. Executes a single SOQL query regardless of list size.
     *
     * Fields retrieved:
     *   - Account.Id, Account.Name
     *   - Account.OwnerId — used to assign Tasks to the Account owner
     *   - Account.Owner.IsActive — used to determine fallback Task assignment
     *
     * Opportunities without an AccountId are silently excluded from the map;
     * downstream services must handle a missing Account gracefully.
     *
     * @param opps  Opportunities whose Account data is needed
     * @return      Map of Account.Id → Account (with Owner sub-query populated)
     */
    @TestVisible
    private static Map<Id, Account> queryAccountData(List<Opportunity> opps) {
        Set<Id> accountIds = new Set<Id>();

        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        if (accountIds.isEmpty()) {
            return new Map<Id, Account>();
        }

        Map<Id, Account> accountMap = new Map<Id, Account>(
            [
                SELECT Id, Name, OwnerId, Owner.IsActive
                FROM   Account
                WHERE  Id IN :accountIds
            ]
        );

        return accountMap;
    }
}
