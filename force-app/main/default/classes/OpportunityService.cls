/**
 * @description Service class encapsulating Opportunity business logic introduced in KAN-5.
 *              Handles Closed Won follow-up Task creation and large-deal custom notifications.
 *
 *              Follows the Skieward service-layer pattern: all business logic lives here,
 *              making it reusable from triggers, Batch Apex, REST controllers, and LWC.
 *
 * @author  Skieward Consulting
 * @date    2026-03-03
 * @group   Opportunity Management
 */
public with sharing class OpportunityService {

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    @TestVisible private static final String  CLOSED_WON             = 'Closed Won';
    @TestVisible private static final Decimal NOTIFICATION_THRESHOLD = 50000.00;
    @TestVisible private static final String  SALES_MANAGER_ROLE     = 'Sales Manager';
    @TestVisible private static final String  NOTIF_TYPE_DEV_NAME    = 'Opportunity_Large_Deal';
    @TestVisible private static final Integer FOLLOW_UP_DAYS         = 7;

    // ---------------------------------------------------------------------------
    // Closed Won Follow-Up Tasks  (KAN-5 AC #2, #6)
    // ---------------------------------------------------------------------------

    /**
     * @description Creates a follow-up Task when an Opportunity transitions to Closed Won.
     *
     *              - Task subject  : "Follow up: {Opportunity Name}"
     *              - Task owner    : Account owner (active). Falls back to Opportunity owner
     *                               when the Account owner's IsActive == false.
     *              - Due date      : CloseDate + 7 days
     *
     *              Fully bulkified — performs one SOQL and one DML for any batch size.
     *
     * @param newOpps Trigger.new list (after update context).
     * @param oldMap  Trigger.oldMap.
     */
    public static void createClosedWonFollowUpTasks(
        List<Opportunity> newOpps,
        Map<Id, Opportunity> oldMap
    ) {
        // ── 1. Identify newly-Closed-Won records and collect their Account IDs ──────
        List<Opportunity> closedWonOpps = new List<Opportunity>();
        Set<Id>           accountIds    = new Set<Id>();

        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (opp.StageName == CLOSED_WON && oldOpp.StageName != CLOSED_WON) {
                closedWonOpps.add(opp);
                if (opp.AccountId != null) {
                    accountIds.add(opp.AccountId);
                }
            }
        }

        if (closedWonOpps.isEmpty()) {
            return;
        }

        // ── 2. Bulk-query Account owners (one SOQL, no loops) ─────────────────────
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, OwnerId, Owner.IsActive
            FROM   Account
            WHERE  Id IN :accountIds
        ]);

        // ── 3. Build Tasks ────────────────────────────────────────────────────────
        List<Task> followUpTasks = new List<Task>();

        for (Opportunity opp : closedWonOpps) {
            // Default to Opportunity owner; prefer active Account owner (AC #6)
            Id assigneeId = opp.OwnerId;
            if (opp.AccountId != null) {
                Account acc = accountMap.get(opp.AccountId);
                if (acc != null && acc.Owner.IsActive) {
                    assigneeId = acc.OwnerId;
                }
            }

            Date dueDate = opp.CloseDate != null
                ? opp.CloseDate.addDays(FOLLOW_UP_DAYS)
                : Date.today().addDays(FOLLOW_UP_DAYS);

            followUpTasks.add(new Task(
                Subject      = 'Follow up: ' + opp.Name,
                WhatId       = opp.Id,
                OwnerId      = assigneeId,
                Status       = 'Not Started',
                Priority     = 'Normal',
                ActivityDate = dueDate
            ));
        }

        if (!followUpTasks.isEmpty()) {
            insert followUpTasks;
        }
    }

    // ---------------------------------------------------------------------------
    // Large-Deal Custom Notifications  (KAN-5 AC #3, #4, #5, #7)
    // ---------------------------------------------------------------------------

    /**
     * @description Sends an in-app custom notification to the Sales Manager role user
     *              when an Opportunity over $50,000 is created (insert only — AC #5).
     *
     *              Notification body: "{Opportunity Name} ({Amount}) was just created
     *              by {Owner Name}"
     *
     *              Skip conditions (AC #7 — silent, no error):
     *                - Amount ≤ $50,000
     *                - No UserRole named "Sales Manager" exists
     *                - No active User holds the Sales Manager role
     *                - CustomNotificationType "Opportunity_Large_Deal" not deployed
     *
     *              Fully bulkified — all SOQL executed before any notification loop.
     *
     * @param newOpps Trigger.new list (after insert context).
     */
    public static void sendLargeDealNotifications(List<Opportunity> newOpps) {

        // ── 1. Filter to large deals ──────────────────────────────────────────────
        Set<Id> largeOppIds = new Set<Id>();
        for (Opportunity opp : newOpps) {
            if (opp.Amount != null && opp.Amount > NOTIFICATION_THRESHOLD) {
                largeOppIds.add(opp.Id);
            }
        }
        if (largeOppIds.isEmpty()) {
            return;
        }

        // ── 2. Enrich with relationship fields not available on Trigger.new ───────
        //       One SOQL covers all large deals in the batch.
        List<Opportunity> enrichedOpps = [
            SELECT Id, Name, Amount, AccountId,
                   OwnerId, Owner.Name,
                   Account.OwnerId,
                   Account.Owner.UserRoleId,
                   Account.Owner.UserRole.ParentRoleId
            FROM   Opportunity
            WHERE  Id IN :largeOppIds
        ];
        if (enrichedOpps.isEmpty()) {
            return;
        }

        // ── 3. Find the "Sales Manager" UserRole (single SOQL — AC #7) ───────────
        List<UserRole> salesMgrRoles = [
            SELECT Id
            FROM   UserRole
            WHERE  Name = :SALES_MANAGER_ROLE
            LIMIT  1
        ];
        if (salesMgrRoles.isEmpty()) {
            return; // AC #7: skip silently — no Sales Manager role in org
        }
        Id salesMgrRoleId = salesMgrRoles[0].Id;

        // ── 4. Find active users in the Sales Manager role ────────────────────────
        //       "The user in the Sales Manager role on the Account" (AC #3):
        //       We prefer the Sales Manager whose role is the direct parent of the
        //       Account owner's role in the hierarchy. If no hierarchy match is found
        //       we fall back to the first active Sales Manager in the org.
        List<User> salesManagers = [
            SELECT Id, UserRoleId
            FROM   User
            WHERE  UserRoleId = :salesMgrRoleId
            AND    IsActive   = true
        ];
        if (salesManagers.isEmpty()) {
            return; // AC #7: skip silently — no active Sales Manager user
        }

        // Build role-to-user map for hierarchy-aware lookup (one Sales Manager per role slot)
        Map<Id, Id> roleIdToSalesMgrUserId = new Map<Id, Id>();
        for (User mgr : salesManagers) {
            roleIdToSalesMgrUserId.put(mgr.UserRoleId, mgr.Id);
        }
        Id defaultSalesMgrId = salesManagers[0].Id; // fallback if hierarchy not matched

        // ── 5. Retrieve the Custom Notification Type (single SOQL) ───────────────
        List<CustomNotificationType> notifTypes = [
            SELECT Id
            FROM   CustomNotificationType
            WHERE  DeveloperName = :NOTIF_TYPE_DEV_NAME
            LIMIT  1
        ];
        if (notifTypes.isEmpty()) {
            return; // Skip silently — notification type not deployed
        }
        String notifTypeId = notifTypes[0].Id;

        // ── 6. Send one notification per large-deal Opportunity ───────────────────
        for (Opportunity opp : enrichedOpps) {
            Id targetMgrId = resolveSalesManager(opp, salesMgrRoleId, roleIdToSalesMgrUserId, defaultSalesMgrId);

            // Format notification body per AC #4
            String body = opp.Name + ' (' + formatCurrency(opp.Amount) + ') was just created by ' + opp.Owner.Name;

            try {
                Messaging.CustomNotification notif = new Messaging.CustomNotification();
                notif.setTitle('Large Deal Alert');
                notif.setBody(body);
                notif.setNotificationTypeId(notifTypeId);
                notif.setTargetId(opp.Id);
                notif.send(new Set<String>{ targetMgrId });
            } catch (Exception e) {
                // Notification failures must not abort the insert transaction
                System.debug(
                    LoggingLevel.WARN,
                    'KAN-5: Custom notification failed for Opportunity ' + opp.Id + ': ' + e.getMessage()
                );
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Private Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Determines the Sales Manager to notify for a given Opportunity.
     *              Prefers the Sales Manager whose role is the direct parent of the
     *              Account owner's role. Falls back to defaultSalesMgrId.
     */
    private static Id resolveSalesManager(
        Opportunity opp,
        Id salesMgrRoleId,
        Map<Id, Id> roleIdToSalesMgrUserId,
        Id defaultSalesMgrId
    ) {
        if (opp.Account != null && opp.Account.Owner != null && opp.Account.Owner.UserRole != null) {
            Id parentRoleId = opp.Account.Owner.UserRole.ParentRoleId;
            // If the Account owner's parent role IS the Sales Manager role,
            // we have an unambiguous match.
            if (parentRoleId != null && parentRoleId == salesMgrRoleId
                    && roleIdToSalesMgrUserId.containsKey(parentRoleId)) {
                return roleIdToSalesMgrUserId.get(parentRoleId);
            }
        }
        return defaultSalesMgrId;
    }

    /**
     * @description Formats a Decimal amount as a currency string (e.g. $75,000).
     */
    @TestVisible
    private static String formatCurrency(Decimal amount) {
        if (amount == null) {
            return '$0';
        }
        // Round to nearest whole dollar and format with comma separators
        Long   wholeDollars = amount.setScale(0, RoundingMode.HALF_UP).longValue();
        String raw          = String.valueOf(wholeDollars);
        String formatted    = '';
        Integer len         = raw.length();
        for (Integer i = 0; i < len; i++) {
            if (i > 0 && Math.mod(len - i, 3) == 0) {
                formatted += ',';
            }
            formatted += raw.substring(i, i + 1);
        }
        return '$' + formatted;
    }
}
