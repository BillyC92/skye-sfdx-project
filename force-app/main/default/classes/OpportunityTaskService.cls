/**
 * OpportunityTaskService
 *
 * Responsible for bulk Task creation when Opportunities transition to Closed Won.
 *
 * Design decisions:
 * - Account owner data is pre-fetched by the caller (OpportunityTriggerHandler) to keep
 *   this service free of SOQL and fully bulkified. This class performs zero queries.
 * - If the Account owner is inactive (or no Account is linked), the Task falls back to
 *   the Opportunity owner. This ensures Tasks are never orphaned.
 * - A single DML insert handles all Tasks to respect governor limits.
 * - ActivityDate is set to CloseDate + 7 days. If CloseDate is null (should not happen
 *   on Closed Won, but defensive), today + 7 is used as a safe fallback.
 */
public with sharing class OpportunityTaskService {

    // Subject prefix — stored as a constant so it can be referenced in tests
    // and changed in one place if the business requirement evolves.
    @TestVisible
    private static final String TASK_SUBJECT_PREFIX = 'Follow up: ';

    @TestVisible
    private static final String TASK_STATUS = 'Not Started';

    @TestVisible
    private static final Integer FOLLOW_UP_DAYS = 7;

    /**
     * Creates follow-up Tasks for a list of Closed Won Opportunities.
     *
     * @param opportunities  List of Opportunity records that have just become Closed Won.
     *                       Must include: Id, Name, OwnerId, CloseDate, AccountId.
     * @param accountOwnerMap  Map of Account Id -> User (the Account's owner).
     *                         The User record must include: Id, IsActive.
     *                         Caller is responsible for populating this map.
     */
    public static void createFollowUpTasks(
        List<Opportunity> opportunities,
        Map<Id, User> accountOwnerMap
    ) {
        if (opportunities == null || opportunities.isEmpty()) {
            return;
        }

        List<Task> tasksToInsert = new List<Task>();

        for (Opportunity opp : opportunities) {
            Id assignedToId = resolveTaskOwner(opp, accountOwnerMap);
            Date activityDate = resolveActivityDate(opp.CloseDate);

            Task t = new Task(
                Subject      = TASK_SUBJECT_PREFIX + opp.Name,
                OwnerId      = assignedToId,
                WhatId       = opp.Id,
                ActivityDate = activityDate,
                Status       = TASK_STATUS
            );

            tasksToInsert.add(t);
        }

        if (!tasksToInsert.isEmpty()) {
            try {
                insert tasksToInsert;
            } catch (DmlException e) {
                // Log and rethrow so the trigger can surface the error to the user.
                // In a more mature org this would write to a custom log object.
                System.debug(
                    LoggingLevel.ERROR,
                    'OpportunityTaskService.createFollowUpTasks DML failure: ' + e.getMessage()
                );
                throw e;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Determines who the Task should be assigned to.
     *
     * Rules (in priority order):
     *  1. Account owner, if the Opportunity has an Account AND that owner is active.
     *  2. Opportunity owner in all other cases (no Account, no owner found, inactive owner).
     */
    private static Id resolveTaskOwner(
        Opportunity opp,
        Map<Id, User> accountOwnerMap
    ) {
        if (opp.AccountId != null && accountOwnerMap != null) {
            User accountOwner = accountOwnerMap.get(opp.AccountId);
            if (accountOwner != null && accountOwner.IsActive) {
                return accountOwner.Id;
            }
        }
        // Fall back to the Opportunity owner
        return opp.OwnerId;
    }

    /**
     * Returns CloseDate + FOLLOW_UP_DAYS.
     * Falls back to today + FOLLOW_UP_DAYS if CloseDate is somehow null
     * (defensive — Closed Won should always have a CloseDate).
     */
    private static Date resolveActivityDate(Date closeDate) {
        Date base = (closeDate != null) ? closeDate : Date.today();
        return base.addDays(FOLLOW_UP_DAYS);
    }
}
