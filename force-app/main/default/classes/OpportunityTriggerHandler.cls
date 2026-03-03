/**
 * @description Trigger handler for Opportunity events. Implements stage-transition
 *              validation, amount-threshold enforcement, notification dispatch,
 *              and audit-trail tasks for the Acme Corp / Meridian Sales Cloud process.
 *
 *              Follows the single-trigger-per-object pattern with a dedicated handler.
 *              Business logic introduced in KAN-5 is delegated to OpportunityService.
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 * @group   Opportunity Management
 */
public with sharing class OpportunityTriggerHandler {

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    private static final Decimal EXECUTIVE_APPROVAL_THRESHOLD = 500000.00;
    private static final Decimal LARGE_DEAL_THRESHOLD         = 100000.00;

    /** Stage name that triggers Task creation and notification (KAN-5). */
    @TestVisible
    private static final String  CLOSED_WON_STAGE = 'Closed Won';

    /** Amount threshold above which Sales Manager notifications are sent (KAN-5 AC #3). */
    @TestVisible
    private static final Decimal LARGE_OPP_THRESHOLD = 50000;

    /** DeveloperName of the Custom Notification Type for the large-deal alert. */
    @TestVisible
    private static final String  NOTIFICATION_TYPE_DEV_NAME = 'Opportunity_Alert';

    /** UserRole Name used to identify Sales Managers for notifications (KAN-5 AC #3). */
    @TestVisible
    private static final String  SALES_MANAGER_ROLE_NAME = 'Sales Manager';

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
     * @description Executes after-update logic (follow-up tasks, stage-history audit trail).
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
    private void validateStageTransitions(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.StageName == oldOpp.StageName) {
                continue;
            }

            // Allow admin overrides via custom permission
            if (isAdminBypass()) {
                continue;
            }

            Set<String> allowedNextStages = VALID_STAGE_TRANSITIONS.get(oldOpp.StageName);

            if (allowedNextStages == null) {
                // Current stage is terminal (Closed Won / Closed Lost) — no transitions allowed
                opp.StageName.addError(
                    'Opportunity in stage "' + oldOpp.StageName + '" cannot be moved to another stage. ' +
                    'Please clone the record if you need a new opportunity.'
                );
                continue;
            }

            if (!allowedNextStages.contains(opp.StageName)) {
                opp.StageName.addError(
                    'Invalid stage transition from "' + oldOpp.StageName + '" to "' +
                    opp.StageName + '". Allowed next stages: ' +
                    String.join(new List<String>(allowedNextStages), ', ') + '.'
                );
            }
        }
    }

    /**
     * @description Enforces amount thresholds. Opportunities above the executive
     *              approval threshold require the Description field to be populated
     *              (as a proxy for justification notes).
     */
    private void validateAmountThresholds(List<Opportunity> opps) {
        for (Opportunity opp : opps) {
            if (opp.Amount != null && opp.Amount >= EXECUTIVE_APPROVAL_THRESHOLD) {
                if (String.isBlank(opp.Description)) {
                    opp.Description.addError(
                        'Opportunities of $' + EXECUTIVE_APPROVAL_THRESHOLD.setScale(0).toPlainString() +
                        ' or more require a justification in the Description field.'
                    );
                }
            }
        }
    }

    /**
     * @description Flags opportunities where the Amount increased by more than 20%
     *              in a single edit — adds a note to the Description for audit trail.
     */
    private void flagLargeDealChanges(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.Amount == null || oldOpp.Amount == null || oldOpp.Amount == 0) {
                continue;
            }

            Decimal percentChange = ((opp.Amount - oldOpp.Amount) / oldOpp.Amount) * 100;

            if (percentChange > 20) {
                String auditNote = '\n[Skieward Audit] Amount increased by ' +
                    percentChange.setScale(1) + '% on ' + String.valueOf(Date.today()) + '.';

                opp.Description = (String.isNotBlank(opp.Description) ? opp.Description : '') + auditNote;
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
     *              Delegates to OpportunityService to keep this handler thin and testable.
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
                    Subject      = 'Stage Change: ' + oldOpp.StageName + ' → ' + opp.StageName,
                    WhatId       = opp.Id,
                    OwnerId      = opp.OwnerId,
                    Status       = 'Completed',
                    Priority     = 'Low',
                    ActivityDate = Date.today(),
                    Description  = 'Automated stage-change log by Skieward trigger framework.'
                ));
            }
        }

        if (!historyTasks.isEmpty()) {
            insert historyTasks;
        }
    }

    /**
     * @description Creates one follow-up Task per Closed Won Opportunity.
     *              Retained from the initial KAN-5 implementation for backwards compatibility.
     *              New callers should use OpportunityService.createClosedWonFollowUpTasks
     *              which correctly uses CloseDate + 7 days and the "Follow up: {Name}" subject.
     *
     * @param closedWonOpps  Opportunities confirmed to be in Closed Won stage.
     */
    private void createClosedWonTasks(List<Opportunity> closedWonOpps) {
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : closedWonOpps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

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

        List<Task> tasksToInsert = new List<Task>();
        for (Opportunity opp : closedWonOpps) {
            Id taskOwnerId = opp.OwnerId;

            if (opp.AccountId != null && accountMap.containsKey(opp.AccountId)) {
                Account relatedAccount = accountMap.get(opp.AccountId);
                if (relatedAccount.Owner.IsActive) {
                    taskOwnerId = relatedAccount.OwnerId;
                }
            }

            tasksToInsert.add(new Task(
                Subject      = 'Follow up: ' + opp.Name,
                WhatId       = opp.Id,
                OwnerId      = taskOwnerId,
                Status       = 'Not Started',
                Priority     = 'Normal',
                ActivityDate = opp.CloseDate != null ? opp.CloseDate.addDays(7) : Date.today().addDays(7)
            ));
        }

        if (!tasksToInsert.isEmpty()) {
            insert tasksToInsert;
        }
    }

    /**
     * @description Sends a Custom Notification to all active Users in the Sales Manager role.
     *              Retained from the initial KAN-5 implementation.
     *              New callers should use OpportunityService.sendLargeDealNotifications
     *              which uses the correct notification body format from AC #4.
     *
     * @param largeOpps  Opportunities with Amount strictly > LARGE_OPP_THRESHOLD.
     */
    private void sendLargeOpportunityNotifications(List<Opportunity> largeOpps) {
        List<CustomNotificationType> notifTypes = [
            SELECT Id
            FROM   CustomNotificationType
            WHERE  DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT  1
        ];
        if (notifTypes.isEmpty()) {
            return;
        }
        String notifTypeId = notifTypes[0].Id;

        List<UserRole> salesManagerRoles = [
            SELECT Id
            FROM   UserRole
            WHERE  Name = :SALES_MANAGER_ROLE_NAME
            LIMIT  1
        ];
        if (salesManagerRoles.isEmpty()) {
            return;
        }
        Id salesManagerRoleId = salesManagerRoles[0].Id;

        List<User> salesManagers = [
            SELECT Id
            FROM   User
            WHERE  UserRoleId = :salesManagerRoleId
            AND    IsActive   = TRUE
        ];
        if (salesManagers.isEmpty()) {
            return;
        }

        Set<String> recipientIds = new Set<String>();
        for (User u : salesManagers) {
            recipientIds.add(u.Id);
        }

        for (Opportunity opp : largeOpps) {
            try {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(notifTypeId);
                notification.setTargetId(opp.Id);
                notification.setTitle('Large Opportunity Alert');
                notification.setBody(
                    opp.Name + ' (' + (opp.Amount != null ? opp.Amount.format() : '0') +
                    ') was just created by ' + UserInfo.getName()
                );
                notification.send(recipientIds);
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR,
                    'sendLargeOpportunityNotifications error for Opp ' + opp.Id + ': ' + ex.getMessage());
            }
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
