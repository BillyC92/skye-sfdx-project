/**
 * OpportunityTriggerHandler
 *
 *              Follows the single-trigger-per-object pattern with a dedicated handler.
 *              Business logic is delegated to OpportunityService (KAN-5).
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

    private static final Decimal EXECUTIVE_APPROVAL_THRESHOLD = 500000.00;
    private static final Decimal LARGE_DEAL_THRESHOLD         = 100000.00;

    /** Allowed forward stage transitions (simplified Acme Corp sales process). */
    private static final Map<String, Set<String>> VALID_STAGE_TRANSITIONS = new Map<String, Set<String>>{
        'Prospecting'           => new Set<String>{ 'Qualification', 'Closed Lost' },
        'Qualification'         => new Set<String>{ 'Needs Analysis', 'Closed Lost' },
        'Needs Analysis'        => new Set<String>{ 'Value Proposition', 'Closed Lost' },
        'Value Proposition'     => new Set<String>{ 'Id. Decision Makers', 'Closed Lost' },
        'Id. Decision Makers'   => new Set<String>{ 'Perception Analysis', 'Closed Lost' },
        'Perception Analysis'   => new Set<String>{ 'Proposal/Price Quote', 'Closed Lost' },
        'Proposal/Price Quote'  => new Set<String>{ 'Negotiation/Review', 'Closed Lost' },
        'Negotiation/Review'    => new Set<String>{ 'Closed Won', 'Closed Lost' }
    };

    // ---------------------------------------------------------------------------
    // Trigger Entry Points
    // ---------------------------------------------------------------------------

    /**
     * @description Executes before-insert logic.
     * @param newOpps Trigger.new list.
     */
    public void handleBeforeInsert(List<Opportunity> newOpps) {
        stampDefaultFields(newOpps);
        validateAmountThresholds(newOpps);
    }

    /**
     * @description Executes after-insert logic.
     *              Sends custom in-app notifications for Opportunities over $50k
     *              to the Sales Manager role user on the Account (KAN-5 AC #3–5).
     * @param newOpps Trigger.new list.
     */
    public void handleAfterInsert(List<Opportunity> newOpps) {
        OpportunityService.sendLargeDealNotifications(newOpps);
    }

    /**
     * @description Executes before-update logic.
     * @param newOpps Trigger.new list.
     * @param oldMap  Trigger.oldMap.
     */
    public void handleBeforeUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        validateStageTransitions(newOpps, oldMap);
        validateAmountThresholds(newOpps);
        flagLargeDealChanges(newOpps, oldMap);
    }

    /**
     * @description Executes after-update logic (notifications, chatter posts).
     * @param newOpps Trigger.new list.
     * @param oldMap  Trigger.oldMap.
     */
    public void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        notifyOnClosedWon(newOpps, oldMap);
        createStageChangeHistoryTasks(newOpps, oldMap);
    }

    // ---------------------------------------------------------------------------
    // Before-Insert Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Sets sensible defaults on new Opportunity records when values
     *              are not provided by the user.
     */
    private void stampDefaultFields(List<Opportunity> newOpps) {
        for (Opportunity opp : newOpps) {
            if (opp.StageName == null) {
                opp.StageName = 'Prospecting';
            }

            if (opp.CloseDate == null) {
                opp.CloseDate = Date.today().addDays(90);
            }

            if (opp.LeadSource == null) {
                opp.LeadSource = 'Web';
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Before-Update Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Validates that stage transitions follow the allowed Acme Corp
     *              sales methodology. Prevents skipping stages or moving backwards
     *              unless the target is "Closed Lost".
     */
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

    // ---------------------------------------------------------------------------
    // After-Update Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Creates a follow-up Task when an Opportunity transitions to Closed Won.
     *
     *              KAN-5 requirements:
     *                - Subject  : "Follow up: {Opportunity Name}"
     *                - Owner    : Account owner (active). Falls back to Opp owner if inactive.
     *                - Due date : CloseDate + 7 days
     *
     *              Delegates to OpportunityService to keep this handler thin.
     */
    private void notifyOnClosedWon(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        OpportunityService.createClosedWonFollowUpTasks(newOpps, oldMap);
    }

    /**
     * @description Creates a lightweight Task record to log every stage change,
     *              providing a queryable audit trail without custom objects.
     */
    private void createStageChangeHistoryTasks(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        List<Task> historyTasks = new List<Task>();

        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.StageName != oldOpp.StageName) {
                historyTasks.add(new Task(
                    Subject     = 'Stage Change: ' + oldOpp.StageName + ' → ' + opp.StageName,
                    WhatId      = opp.Id,
                    OwnerId     = opp.OwnerId,
                    Status      = 'Completed',
                    Priority    = 'Low',
                    ActivityDate = Date.today(),
                    Description = 'Automated stage-change log by Skieward trigger framework.'
                ));
            }
        }

        if (!historyTasks.isEmpty()) {
            insert historyTasks;
        }
    }

    // ---------------------------------------------------------------------------
    // Utility
    // ---------------------------------------------------------------------------

    /**
     * @description Simplified admin bypass check. In production this would use
     *              Custom Permissions or a Custom Metadata Type.
     * @return Boolean true if the running user should bypass stage validation.
     */
    @TestVisible
    private Boolean isAdminBypass() {
        return FeatureManagement.checkPermission('Bypass_Opportunity_Stage_Validation');
    }
}
