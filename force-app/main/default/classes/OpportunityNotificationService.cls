/**
 * OpportunityNotificationService
 *
 * Responsible for sending custom push notifications when a new Opportunity
 * with Amount > $50,000 is inserted.
 *
 * Design decisions:
 * - Queries UserRole once per transaction (bulkified).
 * - Identifies the Sales Manager user via the Account's Owner's Role.
 *   If the Account Owner holds the 'Sales Manager' role, they receive the
 *   notification. This is the most direct declarative relationship available
 *   without a custom field. If the requirement changes (e.g., a dedicated
 *   lookup field for Sales Manager on Account), update getSalesManagerUserIds().
 * - Exits silently when no Sales Manager role or no qualifying users are found
 *   to avoid surfacing internal errors to end users on insert.
 * - Uses Messaging.CustomNotification with the Opportunity_Follow_Up_Notification
 *   custom notification type (DeveloperName). This type must exist in the org
 *   before deployment (see CustomNotification metadata).
 *
 * @author Skye
 * @ticket KAN-5
 */
public with sharing class OpportunityNotificationService {

    // DeveloperName of the Custom Notification Type created for this feature.
    // Stored here as a constant so it is easy to locate; consider moving to
    // Custom Metadata if the org needs to support multiple environments with
    // different DeveloperNames.
    @TestVisible
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'Opportunity_Follow_Up_Notification';

    private static final Decimal AMOUNT_THRESHOLD = 50000;

    /**
     * Entry point called by OpportunityTriggerHandler on after-insert.
     *
     * @param newOpportunities  List of newly inserted Opportunity records.
     *                          Assumed to be non-null; caller is responsible
     *                          for passing Trigger.new.
     */
    public static void sendHighValueInsertNotifications(List<Opportunity> newOpportunities) {
        if (newOpportunities == null || newOpportunities.isEmpty()) {
            return;
        }

        // --- Step 1: Filter to qualifying opportunities (Amount > $50k) ---
        List<Opportunity> qualifying = filterQualifyingOpportunities(newOpportunities);
        if (qualifying.isEmpty()) {
            return;
        }

        // --- Step 2: Resolve the Custom Notification Type ---
        CustomNotificationType notificationType = getNotificationType();
        if (notificationType == null) {
            // Notification type not deployed — log and exit silently.
            logWarning('OpportunityNotificationService: CustomNotificationType ' +
                       NOTIFICATION_TYPE_DEV_NAME + ' not found. Notifications skipped.');
            return;
        }

        // --- Step 3: Resolve Sales Manager role ---
        UserRole salesManagerRole = getSalesManagerRole();
        if (salesManagerRole == null) {
            // No Sales Manager role in org — nothing to notify.
            return;
        }

        // --- Step 4: Collect Account IDs to look up Account owners ---
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : qualifying) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        // Map of AccountId -> Account Owner User (only those with Sales Manager role)
        Map<Id, User> salesManagerByAccountId = getSalesManagersByAccount(
            accountIds, salesManagerRole.Id
        );

        // --- Step 5: Collect Opportunity owner IDs for display name resolution ---
        Set<Id> ownerIds = new Set<Id>();
        for (Opportunity opp : qualifying) {
            ownerIds.add(opp.OwnerId);
        }
        Map<Id, User> ownerById = getUsers(ownerIds);

        // --- Step 6: Send a notification per qualifying opportunity ---
        for (Opportunity opp : qualifying) {
            Id targetUserId = resolveTargetUser(opp, salesManagerByAccountId);
            if (targetUserId == null) {
                // No Sales Manager associated with this opportunity's account — skip.
                continue;
            }

            String ownerName = ownerById.containsKey(opp.OwnerId)
                ? ownerById.get(opp.OwnerId).Name
                : 'Unknown';

            String body = buildNotificationBody(opp, ownerName);

            sendNotification(notificationType.Id, opp.Id, targetUserId, body);
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Returns only opportunities with Amount strictly greater than the threshold.
     * Null Amount is treated as zero (does not qualify).
     */
    private static List<Opportunity> filterQualifyingOpportunities(
        List<Opportunity> opportunities
    ) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : opportunities) {
            if (opp.Amount != null && opp.Amount > AMOUNT_THRESHOLD) {
                result.add(opp);
            }
        }
        return result;
    }

    /**
     * Fetches the CustomNotificationType by DeveloperName.
     * Returns null if not found so the caller can exit gracefully.
     */
    private static CustomNotificationType getNotificationType() {
        List<CustomNotificationType> types = [
            SELECT Id, DeveloperName
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0];
    }

    /**
     * Fetches the UserRole with Name = 'Sales Manager'.
     * Returns null if not found.
     *
     * Why query by Name rather than Id: avoids hardcoding an org-specific Id.
     * If the role name differs across sandboxes, consider a Custom Metadata
     * record to store the role name.
     */
    private static UserRole getSalesManagerRole() {
        List<UserRole> roles = [
            SELECT Id, Name
            FROM UserRole
            WHERE Name = 'Sales Manager'
            LIMIT 1
        ];
        return roles.isEmpty() ? null : roles[0];
    }

    /**
     * For the given set of Account IDs, returns a map of AccountId -> User
     * where the User is the Account Owner AND holds the Sales Manager role.
     *
     * Relationship: Account.OwnerId -> User.UserRoleId -> UserRole.
     * This is the standard out-of-the-box relationship. If a custom lookup
     * (e.g., Account.Sales_Manager__c) is later added, replace this query.
     */
    private static Map<Id, User> getSalesManagersByAccount(
        Set<Id> accountIds,
        Id salesManagerRoleId
    ) {
        Map<Id, User> result = new Map<Id, User>();
        if (accountIds.isEmpty()) {
            return result;
        }

        List<Account> accounts = [
            SELECT Id, OwnerId, Owner.Id, Owner.Name, Owner.UserRoleId, Owner.IsActive
            FROM Account
            WHERE Id IN :accountIds
            AND Owner.UserRoleId = :salesManagerRoleId
            AND Owner.IsActive = TRUE
        ];

        for (Account acc : accounts) {
            result.put(acc.Id, acc.Owner);
        }
        return result;
    }

    /**
     * Fetches User records by a set of IDs.
     * Used to resolve Opportunity owner display names.
     */
    private static Map<Id, User> getUsers(Set<Id> userIds) {
        if (userIds.isEmpty()) {
            return new Map<Id, User>();
        }
        return new Map<Id, User>([
            SELECT Id, Name
            FROM User
            WHERE Id IN :userIds
        ]);
    }

    /**
     * Determines the notification target user for a given opportunity.
     * Returns the Sales Manager (Account Owner with Sales Manager role) if found,
     * otherwise returns null so the caller can skip gracefully.
     */
    private static Id resolveTargetUser(
        Opportunity opp,
        Map<Id, User> salesManagerByAccountId
    ) {
        if (opp.AccountId != null && salesManagerByAccountId.containsKey(opp.AccountId)) {
            return salesManagerByAccountId.get(opp.AccountId).Id;
        }
        return null;
    }

    /**
     * Builds the notification body string.
     * Format: '{Opportunity Name} ({Amount}) was just created by {Owner Name}'
     * Amount is formatted as currency with two decimal places.
     */
    @TestVisible
    private static String buildNotificationBody(Opportunity opp, String ownerName) {
        String formattedAmount = opp.Amount != null
            ? '$' + opp.Amount.setScale(2).toPlainString()
            : '$0.00';
        return opp.Name + ' (' + formattedAmount + ') was just created by ' + ownerName;
    }

    /**
     * Sends a single custom notification.
     * Wrapped in try/catch so a failure for one opportunity does not
     * prevent others from being processed or the insert from completing.
     */
    private static void sendNotification(
        Id notificationTypeId,
        Id opportunityId,
        Id targetUserId,
        String body
    ) {
        try {
            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notificationTypeId);
            notification.setTargetId(opportunityId);
            notification.setTitle('High-Value Opportunity Created');
            notification.setBody(body);
            notification.send(new Set<String>{ targetUserId });
        } catch (Exception ex) {
            // Log but do not rethrow — notification failure must not roll back
            // the Opportunity insert.
            logWarning('OpportunityNotificationService.sendNotification failed for ' +
                       'Opportunity ' + opportunityId + ': ' + ex.getMessage());
        }
    }

    /**
     * Centralised warning logger.
     * Uses System.debug at WARN level. Replace with a custom logging framework
     * (e.g., Platform Events, custom object) if the org adopts one.
     */
    private static void logWarning(String message) {
        System.debug(LoggingLevel.WARN, message);
    }
}
