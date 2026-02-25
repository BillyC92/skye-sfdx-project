/**
 * OpportunityTaskService
 *
 * Stateless service class responsible for creating follow-up Tasks on Opportunities
 * that have transitioned to Closed Won.
 *
 * Design decisions:
 * - No SOQL is performed here; the caller (OpportunityTriggerHandler) is responsible
 *   for fetching and passing in the Account map so this class stays query-free.
 * - Account owner is preferred as the Task owner because they have the relationship
 *   context. We fall back to the Opportunity owner when the Account owner is inactive,
 *   ensuring the Task always has a valid, active owner.
 * - A single DML insert is performed after the loop to stay within governor limits
 *   regardless of how many Opportunities are processed (bulk-safe).
 */
public with sharing class OpportunityTaskService {

    // Exposed as a Custom Label candidate — kept as a constant here for now
    // so it is easy to locate and extract if localisation becomes a requirement.
    @TestVisible
    private static final String TASK_SUBJECT_PREFIX = 'Follow up: ';

    @TestVisible
    private static final Integer TASK_DUE_DATE_OFFSET_DAYS = 7;

    @TestVisible
    private static final String TASK_STATUS = 'Not Started';

    @TestVisible
    private static final String TASK_PRIORITY = 'Normal';

    /**
     * createFollowUpTasks
     *
     * Builds and inserts one follow-up Task per Opportunity in the provided list.
     *
     * @param closedWonOpps  Opportunities that are (or have just become) Closed Won.
     *                       Assumed to be non-null; an empty list is a no-op.
     * @param accountMap     Map of Account Id -> Account (with OwnerId and Owner.IsActive
     *                       populated by the caller). May be empty if no related Accounts
     *                       were found — the method handles this gracefully.
     */
    public static void createFollowUpTasks(
        List<Opportunity> closedWonOpps,
        Map<Id, Account> accountMap
    ) {
        if (closedWonOpps == null || closedWonOpps.isEmpty()) {
            return;
        }

        List<Task> tasksToInsert = new List<Task>();

        for (Opportunity opp : closedWonOpps) {
            Id taskOwnerId = resolveTaskOwner(opp, accountMap);

            // ActivityDate: CloseDate + 7 days.
            // If CloseDate is null (edge case — validation rules should prevent this
            // in production, but we handle it defensively to avoid a NullPointerException).
            Date dueDate = opp.CloseDate != null
                ? opp.CloseDate.addDays(TASK_DUE_DATE_OFFSET_DAYS)
                : Date.today().addDays(TASK_DUE_DATE_OFFSET_DAYS);

            Task t = new Task(
                Subject      = TASK_SUBJECT_PREFIX + opp.Name,
                ActivityDate = dueDate,
                WhatId       = opp.Id,
                OwnerId      = taskOwnerId,
                Status       = TASK_STATUS,
                Priority     = TASK_PRIORITY
            );

            tasksToInsert.add(t);
        }

        if (!tasksToInsert.isEmpty()) {
            // Single DML statement — bulk-safe regardless of list size.
            insert tasksToInsert;
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * resolveTaskOwner
     *
     * Returns the Account owner's Id when the Account exists and its owner is active.
     * Falls back to the Opportunity owner otherwise.
     *
     * Why: The Account owner has the broadest relationship context for follow-up work.
     * An inactive user cannot action a Task, so the Opportunity owner is the safest
     * fallback — they are guaranteed to be active (Salesforce prevents deactivating
     * a user who owns open records, but we check IsActive explicitly for safety).
     *
     * @param opp        The Opportunity being processed.
     * @param accountMap Map populated by the caller; may not contain the Opp's AccountId.
     * @return           The Id of the user who should own the Task.
     */
    @TestVisible
    private static Id resolveTaskOwner(
        Opportunity opp,
        Map<Id, Account> accountMap
    ) {
        if (opp.AccountId != null && accountMap != null && accountMap.containsKey(opp.AccountId)) {
            Account relatedAccount = accountMap.get(opp.AccountId);

            // Owner.IsActive is expected to be populated by the caller via a relationship
            // query (e.g. SELECT Id, OwnerId, Owner.IsActive FROM Account).
            // If the sub-object is null for any reason, we fall back safely.
            if (relatedAccount.Owner != null && relatedAccount.Owner.IsActive) {
                return relatedAccount.OwnerId;
            }
        }

        // Fallback: use the Opportunity owner.
        return opp.OwnerId;
    }
}
