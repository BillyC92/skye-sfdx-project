/**
 * OpportunityTaskService
 *
 * Service class responsible for creating follow-up Tasks when an Opportunity
 * transitions to Closed Won.
 *
 * Responsibilities:
 *   - Determine the correct Task assignee: Account owner if active, else
 *     fall back to the Opportunity owner. This ensures Tasks are never
 *     assigned to inactive/deactivated users.
 *   - Construct a Task per Opportunity with standardised Subject, ActivityDate,
 *     WhatId, and OwnerId values.
 *   - Perform a single bulk DML insert — no DML inside loops.
 *
 * Called by: OpportunityTriggerHandler (after update, Closed Won transition)
 */
public with sharing class OpportunityTaskService {

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    /**
     * createFollowUpTasks
     *
     * Builds and inserts follow-up Tasks for a list of Opportunities that have
     * just transitioned to Closed Won.
     *
     * @param closedWonOpps  Opportunities that transitioned to Closed Won this
     *                       transaction. Must not be null or empty.
     * @param accountMap     Map of Account Id -> Account (with OwnerId and
     *                       Owner.IsActive populated) for every Account
     *                       referenced by the supplied Opportunities.
     *                       Accounts not present in the map are handled
     *                       gracefully — the Opportunity owner is used instead.
     */
    public static void createFollowUpTasks(
        List<Opportunity> closedWonOpps,
        Map<Id, Account> accountMap
    ) {
        if (closedWonOpps == null || closedWonOpps.isEmpty()) {
            return;
        }

        List<Task> tasksToInsert = buildTasks(closedWonOpps, accountMap);

        if (tasksToInsert.isEmpty()) {
            return;
        }

        try {
            insert tasksToInsert;
        } catch (DmlException ex) {
            // Log and re-throw so the handler can surface the error cleanly.
            // Using addError on the first failing Opportunity keeps the UX
            // consistent with other trigger-based validation messages.
            System.debug(
                LoggingLevel.ERROR,
                'OpportunityTaskService.createFollowUpTasks DML failure: '
                    + ex.getMessage()
            );
            throw ex;
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /**
     * buildTasks
     *
     * Constructs the Task list without performing any DML. Kept separate so
     * it can be exercised in unit tests without requiring DML permissions.
     *
     * Assignee resolution logic:
     *   1. Look up the Account for this Opportunity.
     *   2. If the Account exists in accountMap AND its Owner is active,
     *      assign the Task to the Account owner.
     *   3. Otherwise fall back to the Opportunity owner (OwnerId on the
     *      Opportunity record itself).
     *
     * @param closedWonOpps  Non-null, non-empty list of Closed Won Opportunities.
     * @param accountMap     Account data keyed by Account Id.
     * @return               List of unsaved Task records ready for bulk insert.
     */
    @TestVisible
    private static List<Task> buildTasks(
        List<Opportunity> closedWonOpps,
        Map<Id, Account> accountMap
    ) {
        List<Task> tasks = new List<Task>();

        for (Opportunity opp : closedWonOpps) {
            Id assigneeId = resolveAssignee(opp, accountMap);

            Task t = new Task(
                Subject      = 'Follow up: ' + opp.Name,
                // ActivityDate = CloseDate + 7 days — gives the assigned user
                // a one-week window after the deal closes to action the follow-up.
                ActivityDate = opp.CloseDate != null
                                   ? opp.CloseDate.addDays(7)
                                   : Date.today().addDays(7),
                WhatId       = opp.Id,
                OwnerId      = assigneeId,
                Status       = 'Not Started',
                Priority     = 'Normal'
            );

            tasks.add(t);
        }

        return tasks;
    }

    /**
     * resolveAssignee
     *
     * Returns the Id of the user who should own the follow-up Task.
     *
     * Priority:
     *   1. Account owner — if the Opportunity has an AccountId, the Account
     *      is present in accountMap, and that Account's owner is active.
     *   2. Opportunity owner — used as a safe fallback in all other cases
     *      (no Account, Account not in map, Account owner inactive).
     *
     * @param opp         The Opportunity being processed.
     * @param accountMap  Account data keyed by Account Id.
     * @return            Id of the resolved assignee.
     */
    @TestVisible
    private static Id resolveAssignee(
        Opportunity opp,
        Map<Id, Account> accountMap
    ) {
        if (opp.AccountId != null && accountMap != null) {
            Account acc = accountMap.get(opp.AccountId);
            // acc.Owner.IsActive is populated by the handler's SOQL query.
            // If the relationship is not queried, IsActive defaults to false,
            // which safely triggers the fallback rather than assigning to an
            // unknown user.
            if (acc != null && acc.Owner != null && acc.Owner.IsActive) {
                return acc.OwnerId;
            }
        }

        // Fallback: Opportunity owner is always a valid, known user.
        return opp.OwnerId;
    }
}
