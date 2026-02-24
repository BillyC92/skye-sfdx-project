/**
 * OpportunityTaskService
 *
 * Service class responsible for creating follow-up Tasks when an Opportunity
 * transitions to (or is inserted as) Closed Won.
 *
 * WHY this class exists:
 * Keeping Task creation logic isolated from the trigger handler and notification
 * logic makes each piece independently testable and easier to maintain. The
 * handler is responsible for all SOQL; this class receives pre-queried data
 * and performs a single DML insert — no queries, fully bulkified.
 *
 * Assignment logic:
 *   - If the related Account owner is active  → assign Task to Account owner
 *   - If the Account owner is inactive, or no Account exists → assign to Opp owner
 */
public with sharing class OpportunityTaskService {

    // -----------------------------------------------------------------------
    // Constants — use Custom Metadata / Custom Settings if these ever need
    // to be configurable without a deployment.
    // -----------------------------------------------------------------------
    @TestVisible private static final String TASK_SUBJECT_PREFIX = 'Follow up: ';
    @TestVisible private static final Integer FOLLOW_UP_DAYS     = 7;
    @TestVisible private static final String TASK_STATUS         = 'Not Started';
    @TestVisible private static final String TASK_PRIORITY       = 'Normal';
    @TestVisible private static final String CLOSED_WON          = 'Closed Won';

    /**
     * createFollowUpTasks
     *
     * Evaluates each Opportunity in the provided list and creates a follow-up
     * Task for those that are Closed Won. Callers are responsible for passing
     * only the Opportunities that are relevant (e.g. newly Closed Won), but
     * this method defensively re-checks StageName so it is safe to call with
     * a broader list.
     *
     * @param opportunities   List of Opportunity records to evaluate.
     *                        Must include: Id, Name, StageName, CloseDate,
     *                        OwnerId, AccountId.
     * @param accountMap      Map of Account Id → Account (with Owner sub-query:
     *                        Owner.IsActive). May be empty but must not be null.
     */
    public static void createFollowUpTasks(
        List<Opportunity> opportunities,
        Map<Id, Account> accountMap
    ) {
        if (opportunities == null || opportunities.isEmpty()) {
            return;
        }

        List<Task> tasksToInsert = new List<Task>();

        for (Opportunity opp : opportunities) {

            // Defensive re-check: only act on Closed Won records.
            if (opp.StageName != CLOSED_WON) {
                continue;
            }

            Id assignedToId = resolveTaskOwner(opp, accountMap);

            Task t = new Task(
                Subject      = TASK_SUBJECT_PREFIX + opp.Name,
                ActivityDate = opp.CloseDate != null
                                   ? opp.CloseDate.addDays(FOLLOW_UP_DAYS)
                                   : Date.today().addDays(FOLLOW_UP_DAYS),
                WhatId       = opp.Id,
                OwnerId      = assignedToId,
                Status       = TASK_STATUS,
                Priority     = TASK_PRIORITY
            );

            tasksToInsert.add(t);
        }

        if (!tasksToInsert.isEmpty()) {
            // Use Database.insert with allOrNone = false so a single bad record
            // does not roll back Tasks for all other Opportunities in the batch.
            // Errors are logged; callers can inspect results if needed.
            List<Database.SaveResult> results =
                Database.insert(tasksToInsert, false);

            logInsertErrors(results, tasksToInsert);
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /**
     * Determines which user should own the Task.
     *
     * Priority:
     *   1. Account owner, if Account exists and owner IsActive == true
     *   2. Opportunity owner (fallback)
     */
    private static Id resolveTaskOwner(
        Opportunity opp,
        Map<Id, Account> accountMap
    ) {
        if (opp.AccountId != null && accountMap.containsKey(opp.AccountId)) {
            Account acc = accountMap.get(opp.AccountId);
            // Owner sub-object must have been queried by the caller.
            if (acc.Owner != null && acc.Owner.IsActive) {
                return acc.OwnerId;
            }
        }
        // Fallback: assign to the Opportunity owner.
        return opp.OwnerId;
    }

    /**
     * Logs any DML errors from a bulk insert without throwing an exception.
     * This prevents a single bad Task from surfacing as an unhandled error
     * to the end user while still leaving a trace in the debug log.
     */
    private static void logInsertErrors(
        List<Database.SaveResult> results,
        List<Task> tasks
    ) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'OpportunityTaskService: Failed to insert Task for Opportunity '
                        + tasks[i].WhatId
                        + ' — ' + err.getStatusCode()
                        + ': ' + err.getMessage()
                    );
                }
            }
        }
    }
}
