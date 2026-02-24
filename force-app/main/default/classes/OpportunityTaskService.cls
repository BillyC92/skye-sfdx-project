/**
 * OpportunityTaskService
 *
 * Responsible for creating follow-up Tasks when an Opportunity transitions
 * to 'Closed Won'. This service is called by OpportunityTriggerHandler and
 * is designed to be fully bulkified — a single DML insert handles all Tasks
 * regardless of batch size.
 *
 * Task assignment logic:
 *   - Primary owner: Account owner (if the user is active)
 *   - Fallback owner: Opportunity owner (if Account owner is inactive or absent)
 *
 * Why a service class rather than inline handler logic:
 *   Keeping this responsibility isolated makes it independently testable and
 *   easier to extend (e.g., adding recurrence rules or custom fields later)
 *   without touching the handler or other services.
 */
public with sharing class OpportunityTaskService {

    // Surfaced as a constant so callers and tests can reference the canonical
    // stage value without hardcoding strings in multiple places.
    @TestVisible
    private static final String CLOSED_WON_STAGE = 'Closed Won';

    // Number of days after CloseDate to set the Task ActivityDate.
    @TestVisible
    private static final Integer FOLLOW_UP_DAYS_OFFSET = 7;

    /**
     * createFollowUpTasks
     *
     * Entry point called by OpportunityTriggerHandler for both insert and
     * update contexts.
     *
     * @param newOpportunities  Trigger.new — the current state of each Opportunity.
     * @param oldOpportunityMap Trigger.oldMap — previous state (null on insert).
     * @param accountMap        Map of Account Id → Account (with Owner populated),
     *                          pre-queried by the handler to avoid SOQL inside
     *                          this service.
     */
    public static void createFollowUpTasks(
        List<Opportunity> newOpportunities,
        Map<Id, Opportunity> oldOpportunityMap,
        Map<Id, Account> accountMap
    ) {
        if (newOpportunities == null || newOpportunities.isEmpty()) {
            return;
        }

        List<Task> tasksToInsert = new List<Task>();

        for (Opportunity opp : newOpportunities) {
            // Determine whether this record represents a *new* Closed Won
            // transition. On insert, oldOpportunityMap is null so any Closed
            // Won record qualifies. On update, the previous stage must differ.
            Boolean isNewClosedWon = isTransitioningToClosedWon(opp, oldOpportunityMap);

            if (!isNewClosedWon) {
                continue;
            }

            // Resolve the Task owner: prefer the Account owner when active,
            // fall back to the Opportunity owner.
            Id taskOwnerId = resolveTaskOwner(opp, accountMap);

            // Guard: if for any reason we cannot determine an owner, skip
            // rather than inserting a Task with a null OwnerId (which would
            // fail DML and roll back the entire batch).
            if (taskOwnerId == null) {
                continue;
            }

            Task followUpTask = buildTask(opp, taskOwnerId);
            tasksToInsert.add(followUpTask);
        }

        if (!tasksToInsert.isEmpty()) {
            try {
                insert tasksToInsert;
            } catch (DmlException e) {
                // Log the error rather than swallowing it silently. In a
                // production org this would integrate with a platform logging
                // framework; for now we re-throw so the trigger surfaces the
                // failure to the end user / calling process.
                throw new OpportunityTaskServiceException(
                    'Failed to insert follow-up Tasks: ' + e.getMessage(), e
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Returns true when the Opportunity is currently 'Closed Won' AND was not
     * already 'Closed Won' before this DML operation.
     *
     * On insert (oldOpportunityMap is null) any Closed Won record qualifies.
     * On update, the previous stage must be something other than Closed Won.
     */
    @TestVisible
    private static Boolean isTransitioningToClosedWon(
        Opportunity opp,
        Map<Id, Opportunity> oldOpportunityMap
    ) {
        if (opp.StageName != CLOSED_WON_STAGE) {
            return false;
        }

        // Insert context — no previous state to compare.
        if (oldOpportunityMap == null) {
            return true;
        }

        Opportunity oldOpp = oldOpportunityMap.get(opp.Id);

        // Defensive: if the old record is somehow absent, treat as a new entry.
        if (oldOpp == null) {
            return true;
        }

        // Only create a Task when the stage is *changing* to Closed Won, not
        // when it was already Closed Won (prevents duplicate Tasks on
        // unrelated field edits).
        return oldOpp.StageName != CLOSED_WON_STAGE;
    }

    /**
     * Determines the OwnerId for the Task.
     *
     * Preference order:
     *   1. Account owner — if the Account is present in accountMap and its
     *      owner is an active user.
     *   2. Opportunity owner — fallback for inactive Account owners or when
     *      the Opportunity has no associated Account.
     */
    @TestVisible
    private static Id resolveTaskOwner(
        Opportunity opp,
        Map<Id, Account> accountMap
    ) {
        if (opp.AccountId != null && accountMap != null) {
            Account relatedAccount = accountMap.get(opp.AccountId);

            if (relatedAccount != null
                && relatedAccount.Owner != null
                && relatedAccount.Owner.IsActive
            ) {
                return relatedAccount.OwnerId;
            }
        }

        // Fall back to the Opportunity owner. This will always be populated
        // on a valid Opportunity record.
        return opp.OwnerId;
    }

    /**
     * Constructs a single Task record for a Closed Won Opportunity.
     *
     * ActivityDate defaults to CloseDate + FOLLOW_UP_DAYS_OFFSET. If CloseDate
     * is null (edge case on insert), ActivityDate is left null rather than
     * throwing an exception — the Task is still created so the owner is aware.
     */
    @TestVisible
    private static Task buildTask(Opportunity opp, Id ownerId) {
        Date activityDate = opp.CloseDate != null
            ? opp.CloseDate.addDays(FOLLOW_UP_DAYS_OFFSET)
            : null;

        return new Task(
            Subject      = 'Follow up: ' + opp.Name,
            ActivityDate = activityDate,
            Status       = 'Not Started',
            WhatId       = opp.Id,
            OwnerId      = ownerId
        );
    }

    // -------------------------------------------------------------------------
    // Custom exception
    // -------------------------------------------------------------------------

    public class OpportunityTaskServiceException extends Exception {}
}
