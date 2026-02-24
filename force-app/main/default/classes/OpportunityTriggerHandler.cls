/**
 * OpportunityTriggerHandler
 *
 * Handler class for all Opportunity trigger logic.
 * Follows the single-trigger-per-object pattern; this class is invoked
 * exclusively by OpportunityTrigger.
 *
 * Responsibilities:
 *  - Create follow-up Tasks when an Opportunity reaches Closed Won
 *  - Send custom notifications to Sales Managers for large (>$50k) opportunities
 *    created via insert only (not on update, per business requirement)
 */
public with sharing class OpportunityTriggerHandler {

    // ─── Constants ────────────────────────────────────────────────────────────

    private static final String STAGE_CLOSED_WON              = 'Closed Won';
    private static final String TASK_SUBJECT_PREFIX           = 'Follow up: ';
    private static final Integer TASK_DUE_DATE_OFFSET_DAYS    = 7;
    private static final String SALES_MANAGER_ROLE_NAME       = 'Sales Manager';
    private static final String NOTIFICATION_TYPE_DEV_NAME    = 'OpportunityFollowUpNotification';
    private static final Decimal LARGE_OPPORTUNITY_THRESHOLD  = 50000;

    // ─── Public Entry Points ──────────────────────────────────────────────────

    /**
     * Called from the trigger's after insert context.
     * Handles Task creation for any records already Closed Won on insert,
     * and fires notifications for large opportunities.
     *
     * @param newList  Trigger.new — newly inserted Opportunity records
     */
    public void handleAfterInsert(List<Opportunity> newList) {
        List<Opportunity> closedWonOpps = filterClosedWon(newList);
        if (!closedWonOpps.isEmpty()) {
            createClosedWonTasks(closedWonOpps);
        }

        List<Opportunity> largeOpps = filterLargeOpportunities(newList);
        if (!largeOpps.isEmpty()) {
            sendLargeOpportunityNotifications(largeOpps);
        }
    }

    /**
     * Called from the trigger's after update context.
     * Handles Task creation only for records transitioning INTO Closed Won.
     * Notifications are intentionally NOT sent on update (insert-only requirement).
     *
     * @param newList  Trigger.new
     * @param oldMap   Trigger.oldMap
     */
    public void handleAfterUpdate(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        List<Opportunity> transitionedOpps = filterClosedWonTransitions(newList, oldMap);
        if (!transitionedOpps.isEmpty()) {
            createClosedWonTasks(transitionedOpps);
        }
    }

    // ─── Private Filter Helpers ───────────────────────────────────────────────

    /**
     * Returns opportunities already in Closed Won stage.
     */
    private List<Opportunity> filterClosedWon(List<Opportunity> opps) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (opp.StageName == STAGE_CLOSED_WON) {
                result.add(opp);
            }
        }
        return result;
    }

    /**
     * Returns opportunities that transitioned to Closed Won in this update
     * (i.e., old stage was NOT Closed Won, new stage IS Closed Won).
     */
    private List<Opportunity> filterClosedWonTransitions(
        List<Opportunity> newList,
        Map<Id, Opportunity> oldMap
    ) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (opp.StageName == STAGE_CLOSED_WON && oldOpp.StageName != STAGE_CLOSED_WON) {
                result.add(opp);
            }
        }
        return result;
    }

    /**
     * Returns opportunities with Amount strictly greater than the large-opp threshold.
     */
    private List<Opportunity> filterLargeOpportunities(List<Opportunity> opps) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (opp.Amount != null && opp.Amount > LARGE_OPPORTUNITY_THRESHOLD) {
                result.add(opp);
            }
        }
        return result;
    }

    // ─── Task Creation ────────────────────────────────────────────────────────

    /**
     * Creates a follow-up Task for each Closed Won opportunity.
     *
     * Task assignment logic:
     *  - If the related Account has an active owner  → assign to Account owner
     *  - Otherwise                                   → assign to Opportunity owner
     *
     * All SOQL is performed outside loops; a single DML insert is used.
     *
     * @param closedWonOpps  List of Closed Won Opportunity records
     */
    private void createClosedWonTasks(List<Opportunity> closedWonOpps) {
        // Collect Account Ids (some opps may have no Account)
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : closedWonOpps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        // Bulk-query Account owners and their active status
        Map<Id, Account> accountMap = new Map<Id, Account>();
        if (!accountIds.isEmpty()) {
            for (Account acc : [
                SELECT Id, OwnerId, Owner.IsActive
                FROM Account
                WHERE Id IN :accountIds
            ]) {
                accountMap.put(acc.Id, acc);
            }
        }

        // Build Task list — no DML inside the loop
        List<Task> tasksToInsert = new List<Task>();
        for (Opportunity opp : closedWonOpps) {
            Id taskOwnerId = opp.OwnerId; // default: Opportunity owner

            if (opp.AccountId != null && accountMap.containsKey(opp.AccountId)) {
                Account relatedAccount = accountMap.get(opp.AccountId);
                // Only use Account owner if they are an active user
                if (relatedAccount.Owner.IsActive) {
                    taskOwnerId = relatedAccount.OwnerId;
                }
            }

            Task t = new Task(
                Subject      = TASK_SUBJECT_PREFIX + opp.Name,
                ActivityDate = (opp.CloseDate != null)
                                   ? opp.CloseDate.addDays(TASK_DUE_DATE_OFFSET_DAYS)
                                   : Date.today().addDays(TASK_DUE_DATE_OFFSET_DAYS),
                WhatId       = opp.Id,
                OwnerId      = taskOwnerId,
                Status       = 'Not Started',
                Priority     = 'Normal'
            );
            tasksToInsert.add(t);
        }

        if (!tasksToInsert.isEmpty()) {
            try {
                insert tasksToInsert;
            } catch (DmlException e) {
                // Log and re-throw so the transaction is not silently swallowed
                System.debug(LoggingLevel.ERROR,
                    'OpportunityTriggerHandler.createClosedWonTasks DML error: ' + e.getMessage());
                throw e;
            }
        }
    }

    // ─── Custom Notification Dispatch ────────────────────────────────────────

    /**
     * Sends a CustomNotification to all users with the 'Sales Manager' role
     * for each large opportunity (Amount > $50k) created via insert.
     *
     * Silent-return conditions (no exception thrown):
     *  - No UserRole named 'Sales Manager' exists
     *  - No active users hold that role
     *  - CustomNotificationType 'OpportunityFollowUpNotification' not found
     *
     * All SOQL is performed outside loops.
     *
     * @param largeOpps  Opportunities with Amount > LARGE_OPPORTUNITY_THRESHOLD
     */
    private void sendLargeOpportunityNotifications(List<Opportunity> largeOpps) {
        // ── 1. Resolve the Sales Manager role ──────────────────────────────
        List<UserRole> salesManagerRoles = [
            SELECT Id
            FROM UserRole
            WHERE Name = :SALES_MANAGER_ROLE_NAME
            LIMIT 1
        ];
        if (salesManagerRoles.isEmpty()) {
            // No Sales Manager role configured — nothing to do
            System.debug(LoggingLevel.WARN,
                'OpportunityTriggerHandler: UserRole "' + SALES_MANAGER_ROLE_NAME + '" not found. ' +
                'Skipping large opportunity notifications.');
            return;
        }
        Id salesManagerRoleId = salesManagerRoles[0].Id;

        // ── 2. Resolve active users in that role ───────────────────────────
        List<User> salesManagers = [
            SELECT Id
            FROM User
            WHERE UserRoleId = :salesManagerRoleId
              AND IsActive = TRUE
        ];
        if (salesManagers.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'OpportunityTriggerHandler: No active users found for role "' +
                SALES_MANAGER_ROLE_NAME + '". Skipping notifications.');
            return;
        }

        // ── 3. Resolve the CustomNotificationType ─────────────────────────
        List<CustomNotificationType> notifTypes = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT 1
        ];
        if (notifTypes.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'OpportunityTriggerHandler: CustomNotificationType "' +
                NOTIFICATION_TYPE_DEV_NAME + '" not found. Skipping notifications.');
            return;
        }
        String notifTypeId = notifTypes[0].Id;

        // ── 4. Bulk-query Opportunity owners for display names ─────────────
        Set<Id> ownerIds = new Set<Id>();
        for (Opportunity opp : largeOpps) {
            ownerIds.add(opp.OwnerId);
        }
        Map<Id, User> ownerMap = new Map<Id, User>([
            SELECT Id, Name
            FROM User
            WHERE Id IN :ownerIds
        ]);

        // ── 5. Build recipient set (reused across all notifications) ───────
        Set<String> recipientIds = new Set<String>();
        for (User mgr : salesManagers) {
            recipientIds.add(mgr.Id);
        }

        // ── 6. Send one notification per large opportunity ─────────────────
        for (Opportunity opp : largeOpps) {
            String ownerName = ownerMap.containsKey(opp.OwnerId)
                ? ownerMap.get(opp.OwnerId).Name
                : 'Unknown';

            // Format: '{Opp Name} ({Amount}) was just created by {Owner Name}'
            String formattedAmount = formatCurrency(opp.Amount);
            String body = opp.Name + ' (' + formattedAmount + ') was just created by ' + ownerName;

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notifTypeId);
            notification.setTargetId(opp.Id);
            notification.setTitle('Large Opportunity Alert');
            notification.setBody(body);

            try {
                notification.send(recipientIds);
            } catch (Exception e) {
                // Log but do not re-throw — a notification failure should not
                // roll back the underlying Opportunity DML transaction.
                System.debug(LoggingLevel.ERROR,
                    'OpportunityTriggerHandler.sendLargeOpportunityNotifications error ' +
                    'for Opportunity ' + opp.Id + ': ' + e.getMessage());
            }
        }
    }

    // ─── Utility ──────────────────────────────────────────────────────────────

    /**
     * Formats a Decimal amount as a simple currency string, e.g. "$75,000.00".
     * Avoids locale-dependent formatting issues in notification body text.
     */
    private String formatCurrency(Decimal amount) {
        if (amount == null) {
            return '$0.00';
        }
        // Use Salesforce's built-in formatting via String.format is not available
        // for currency; we construct it manually to keep it readable.
        return '$' + amount.setScale(2).toPlainString()
                           .replaceAll('(\\d)(?=(\\d{3})+\\.)', '$1,');
    }
}