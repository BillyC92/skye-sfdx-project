/**
 * OpportunityTriggerHandler
 *
 * Handler class for all Opportunity trigger business logic.
 * Called exclusively by OpportunityTrigger — contains zero DML or SOQL inside loops.
 *
 * Responsibilities:
 *   1. On Closed Won (insert or update transition): create a follow-up Task assigned
 *      to the Account owner (falls back to Opportunity owner if Account owner is inactive).
 *   2. On Amount > 50,000 (insert only): send a Custom Notification to all Users
 *      whose UserRole is 'Sales Manager'.
 *
 * Prerequisites:
 *   - Custom Notification Type with DeveloperName 'Opportunity_Alert' must exist in the org.
 *     Deployment succeeds without it, but runtime notification calls will throw.
 */
public with sharing class OpportunityTriggerHandler {

    // ─── Constants ────────────────────────────────────────────────────────────

    /** Stage name that triggers Task creation. */
    @TestVisible
    private static final String CLOSED_WON_STAGE = 'Closed Won';

    /** Amount threshold above which Sales Manager notifications are sent. */
    @TestVisible
    private static final Decimal LARGE_OPP_THRESHOLD = 50000;

    /** DeveloperName of the Custom Notification Type configured in Setup. */
    @TestVisible
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'Opportunity_Alert';

    /** Subject used on the auto-created follow-up Task. */
    @TestVisible
    private static final String TASK_SUBJECT = 'Follow up on Closed Won Opportunity';

    /** UserRole Name used to identify Sales Managers for notifications. */
    @TestVisible
    private static final String SALES_MANAGER_ROLE_NAME = 'Sales Manager';

    // ─── Public Entry Points ──────────────────────────────────────────────────

    /**
     * Called from the trigger's after insert context.
     * Evaluates every new Opportunity for Closed Won and large-amount conditions.
     *
     * @param newList  Trigger.new cast to List<Opportunity>
     */
    public void handleAfterInsert(List<Opportunity> newList) {
        List<Opportunity> closedWonOpps = new List<Opportunity>();
        List<Opportunity> largeOpps     = new List<Opportunity>();

        for (Opportunity opp : newList) {
            if (opp.StageName == CLOSED_WON_STAGE) {
                closedWonOpps.add(opp);
            }
            // Notify on insert only; Amount must be strictly greater than threshold
            if (opp.Amount != null && opp.Amount > LARGE_OPP_THRESHOLD) {
                largeOpps.add(opp);
            }
        }

        if (!closedWonOpps.isEmpty()) {
            createClosedWonTasks(closedWonOpps);
        }
        if (!largeOpps.isEmpty()) {
            sendLargeOpportunityNotifications(largeOpps);
        }
    }

    /**
     * Called from the trigger's after update context.
     * Detects Opportunities that *transitioned* to Closed Won in this DML operation.
     * Large-amount notifications are intentionally NOT re-sent on update.
     *
     * @param newList  Trigger.new cast to List<Opportunity>
     * @param oldMap   Trigger.oldMap
     */
    public void handleAfterUpdate(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        List<Opportunity> closedWonTransitions = new List<Opportunity>();

        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            // Only act on records that just became Closed Won — not ones already there
            Boolean wasClosedWon = (oldOpp.StageName == CLOSED_WON_STAGE);
            Boolean isClosedWon  = (opp.StageName   == CLOSED_WON_STAGE);

            if (isClosedWon && !wasClosedWon) {
                closedWonTransitions.add(opp);
            }
        }

        if (!closedWonTransitions.isEmpty()) {
            createClosedWonTasks(closedWonTransitions);
        }
    }

    // ─── Private Business Logic ───────────────────────────────────────────────

    /**
     * Creates one follow-up Task per Closed Won Opportunity.
     *
     * Task owner resolution:
     *   - Preferred: the owner of the Opportunity's related Account (if active).
     *   - Fallback:  the Opportunity's own OwnerId when the Account owner is
     *                inactive, the Opportunity has no Account, or the Account
     *                cannot be found.
     *
     * All SOQL is performed once, outside any loop.
     *
     * @param closedWonOpps  Opportunities confirmed to be in Closed Won stage
     */
    private void createClosedWonTasks(List<Opportunity> closedWonOpps) {
        // Collect AccountIds — some Opportunities may have no Account
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : closedWonOpps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        // Single SOQL: fetch Account owners and their active status
        Map<Id, Account> accountMap = new Map<Id, Account>();
        if (!accountIds.isEmpty()) {
            for (Account acc : [
                SELECT Id, OwnerId, Owner.IsActive
                FROM   Account
                WHERE  Id IN :accountIds
            ]) {
                accountMap.put(acc.Id, acc);
            }
        }

        // Build Task list — one per Opportunity
        List<Task> tasksToInsert = new List<Task>();
        for (Opportunity opp : closedWonOpps) {
            Id taskOwnerId = opp.OwnerId; // default / fallback

            if (opp.AccountId != null && accountMap.containsKey(opp.AccountId)) {
                Account relatedAccount = accountMap.get(opp.AccountId);
                if (relatedAccount.Owner.IsActive) {
                    // Account owner is active — preferred assignee
                    taskOwnerId = relatedAccount.OwnerId;
                }
                // If Account owner is inactive, taskOwnerId stays as Opp owner (fallback)
            }

            tasksToInsert.add(new Task(
                Subject      = TASK_SUBJECT,
                WhatId       = opp.Id,
                OwnerId      = taskOwnerId,
                Status       = 'Not Started',
                Priority     = 'Normal',
                ActivityDate = Date.today().addDays(7)
            ));
        }

        if (!tasksToInsert.isEmpty()) {
            try {
                insert tasksToInsert;
            } catch (DmlException ex) {
                // Log and re-throw so the triggering transaction is not silently swallowed
                System.debug(LoggingLevel.ERROR,
                    'OpportunityTriggerHandler.createClosedWonTasks DML error: ' + ex.getMessage());
                throw ex;
            }
        }
    }

    /**
     * Sends a Custom Notification to all active Users whose UserRole is 'Sales Manager'.
     *
     * Behaviour:
     *   - If no UserRole named 'Sales Manager' exists, returns silently (no exception).
     *   - If no active Users hold that role, returns silently.
     *   - Notification is sent once per large Opportunity; each recipient receives
     *     one notification per qualifying Opportunity.
     *
     * All SOQL is performed outside loops.
     *
     * @param largeOpps  Opportunities with Amount strictly greater than LARGE_OPP_THRESHOLD
     */
    private void sendLargeOpportunityNotifications(List<Opportunity> largeOpps) {
        // ── Step 1: Resolve the Custom Notification Type ──────────────────────
        List<CustomNotificationType> notifTypes = [
            SELECT Id
            FROM   CustomNotificationType
            WHERE  DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT  1
        ];

        if (notifTypes.isEmpty()) {
            // Prerequisite not met — log a warning and exit gracefully
            System.debug(LoggingLevel.WARN,
                'OpportunityTriggerHandler: CustomNotificationType "' +
                NOTIFICATION_TYPE_DEV_NAME + '" not found. Skipping notifications.');
            return;
        }
        String notifTypeId = notifTypes[0].Id;

        // ── Step 2: Find the Sales Manager role ───────────────────────────────
        List<UserRole> salesManagerRoles = [
            SELECT Id
            FROM   UserRole
            WHERE  Name = :SALES_MANAGER_ROLE_NAME
            LIMIT  1
        ];

        if (salesManagerRoles.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'OpportunityTriggerHandler: UserRole "' +
                SALES_MANAGER_ROLE_NAME + '" not found. Skipping notifications.');
            return;
        }
        Id salesManagerRoleId = salesManagerRoles[0].Id;

        // ── Step 3: Collect active Users with that role ───────────────────────
        List<User> salesManagers = [
            SELECT Id
            FROM   User
            WHERE  UserRoleId = :salesManagerRoleId
            AND    IsActive   = TRUE
        ];

        if (salesManagers.isEmpty()) {
            System.debug(LoggingLevel.INFO,
                'OpportunityTriggerHandler: No active Users found with role "' +
                SALES_MANAGER_ROLE_NAME + '". Skipping notifications.');
            return;
        }

        Set<String> recipientIds = new Set<String>();
        for (User u : salesManagers) {
            recipientIds.add(u.Id);
        }

        // ── Step 4: Send one notification per large Opportunity ───────────────
        for (Opportunity opp : largeOpps) {
            try {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(notifTypeId);
                notification.setTargetId(opp.Id);
                notification.setTitle('Large Opportunity Alert');
                notification.setBody(
                    'Opportunity "' + opp.Name + '" has an amount of ' +
                    opp.Amount.format() + ', exceeding the $' +
                    LARGE_OPP_THRESHOLD.format() + ' threshold.'
                );
                notification.send(recipientIds);
            } catch (Exception ex) {
                // Notification failure must not roll back the Opportunity save
                System.debug(LoggingLevel.ERROR,
                    'OpportunityTriggerHandler.sendLargeOpportunityNotifications error for Opp ' +
                    opp.Id + ': ' + ex.getMessage());
            }
        }
    }
}
