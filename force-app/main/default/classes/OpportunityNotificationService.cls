/**
 * OpportunityNotificationService
 *
 * Sends custom notifications for newly created Opportunities with Amount > $50,000.
 * Notifications are sent to the user holding the 'Sales Manager' role.
 *
 * Design notes:
 * - Insert-only: this service should never be called for update events.
 * - If no Sales Manager role exists, or no active user holds that role, we skip
 *   silently — this is a soft-fail by design to avoid blocking Opportunity saves.
 * - Messaging.CustomNotification must be sent per-notification instance, so we
 *   loop, but we front-load all queries to stay within governor limits.
 * - The custom notification type 'OpportunityFollowUpNotification' must exist as
 *   a CustomNotificationType metadata record before this code can run.
 */
public with sharing class OpportunityNotificationService {

    // Developer name of the Custom Notification Type metadata record.
    // Must match the DeveloperName of the deployed CustomNotificationType.
    @TestVisible
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'OpportunityFollowUpNotification';

    // The exact Role Name to look up. Using a constant so it can be driven
    // by Custom Metadata in a future iteration without changing call sites.
    @TestVisible
    private static final String SALES_MANAGER_ROLE_NAME = 'Sales Manager';

    // Amount threshold — notifications fire for Amount strictly greater than this.
    @TestVisible
    private static final Decimal AMOUNT_THRESHOLD = 50000;

    /**
     * Sends notifications for qualifying new Opportunities.
     *
     * @param newOpportunities  List of newly inserted Opportunity records (Trigger.new).
     *                          Caller is responsible for passing insert-context records only.
     */
    public static void sendHighValueInsertNotifications(List<Opportunity> newOpportunities) {
        if (newOpportunities == null || newOpportunities.isEmpty()) {
            return;
        }

        // --- Step 1: Filter to qualifying Opportunities (Amount > $50k) ----------
        List<Opportunity> qualifying = new List<Opportunity>();
        for (Opportunity opp : newOpportunities) {
            if (opp.Amount != null && opp.Amount > AMOUNT_THRESHOLD) {
                qualifying.add(opp);
            }
        }

        if (qualifying.isEmpty()) {
            return;
        }

        // --- Step 2: Resolve the Sales Manager role ------------------------------
        // Query once; if the role doesn't exist we exit silently.
        List<UserRole> salesManagerRoles = [
            SELECT Id
            FROM UserRole
            WHERE Name = :SALES_MANAGER_ROLE_NAME
            LIMIT 1
        ];

        if (salesManagerRoles.isEmpty()) {
            // No Sales Manager role configured in this org — skip without error.
            return;
        }

        Id salesManagerRoleId = salesManagerRoles[0].Id;

        // --- Step 3: Find active users who hold the Sales Manager role -----------
        // We collect all users with this role in a single query.
        // The notification recipient strategy:
        //   - Prefer the Account owner if they hold the Sales Manager role.
        //   - Otherwise, fall back to any active user with the Sales Manager role.
        //   - If no such user exists, skip silently.
        //
        // NOTE: The exact "find the Sales Manager for an Account" lookup was flagged
        // as a clarification gap in the implementation plan. The current approach
        // sends the notification to ALL active users with the Sales Manager role,
        // which is a safe default until the business confirms the exact lookup
        // (e.g., Account team member, Account owner's role, a custom field, etc.).
        // Raise this on Slack before go-live if the org has multiple Sales Managers.
        List<User> salesManagers = [
            SELECT Id, Name
            FROM User
            WHERE UserRoleId = :salesManagerRoleId
            AND IsActive = TRUE
        ];

        if (salesManagers.isEmpty()) {
            // Role exists but no active user holds it — skip without error.
            return;
        }

        // Collect target user IDs once; reuse across all notifications.
        Set<Id> recipientIds = new Set<Id>();
        for (User u : salesManagers) {
            recipientIds.add(u.Id);
        }

        // --- Step 4: Resolve the Custom Notification Type -----------------------
        // Query by DeveloperName so we never hardcode a record ID.
        List<CustomNotificationType> notifTypes = [
            SELECT Id, DeveloperName
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT 1
        ];

        if (notifTypes.isEmpty()) {
            // Notification type not deployed — log and exit rather than throw,
            // so that Opportunity saves are not blocked.
            System.debug(
                LoggingLevel.WARN,
                'OpportunityNotificationService: CustomNotificationType "'
                + NOTIFICATION_TYPE_DEV_NAME
                + '" not found. Notifications will not be sent.'
            );
            return;
        }

        String notifTypeId = notifTypes[0].Id;

        // --- Step 5: Collect Opportunity owner names for message construction ---
        // Owner names are available via the Owner relationship; however, in a
        // trigger context Trigger.new does not include relationship fields.
        // We query Owner names in bulk here.
        Set<Id> ownerIds = new Set<Id>();
        for (Opportunity opp : qualifying) {
            ownerIds.add(opp.OwnerId);
        }

        Map<Id, User> ownerMap = new Map<Id, User>(
            [SELECT Id, Name FROM User WHERE Id IN :ownerIds]
        );

        // --- Step 6: Send one notification per qualifying Opportunity -----------
        // Messaging.CustomNotification must be instantiated and sent per record.
        // We keep construction efficient by reusing the type ID and recipient set.
        for (Opportunity opp : qualifying) {
            String ownerName = ownerMap.containsKey(opp.OwnerId)
                ? ownerMap.get(opp.OwnerId).Name
                : 'Unknown';

            String formattedAmount = formatCurrency(opp.Amount);

            String body = opp.Name
                + ' (' + formattedAmount + ')'
                + ' was just created by ' + ownerName;

            String title = 'New High-Value Opportunity';

            try {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(notifTypeId);
                notification.setTargetId(opp.Id);
                notification.setTitle(title);
                notification.setBody(body);
                notification.send(recipientIds);
            } catch (Exception ex) {
                // Log but do not rethrow — a notification failure must never
                // prevent the Opportunity record from being saved.
                System.debug(
                    LoggingLevel.ERROR,
                    'OpportunityNotificationService: Failed to send notification '
                    + 'for Opportunity ' + opp.Id + '. Error: ' + ex.getMessage()
                );
            }
        }
    }

    /**
     * Formats a Decimal as a currency string (e.g., 75000 → "$75,000.00").
     * Kept simple and self-contained to avoid locale dependencies in tests.
     *
     * @param amount  The numeric amount to format.
     * @return        A formatted currency string.
     */
    @TestVisible
    private static String formatCurrency(Decimal amount) {
        if (amount == null) {
            return '$0.00';
        }
        // Scale to 2 decimal places and delegate to standard formatting.
        // In a full implementation this could use UserInfo.getDefaultCurrency().
        return '$' + amount.setScale(2).toPlainString()
            .replaceAll('(\\d)(?=(\\d{3})+\\.)', '$1,');
    }
}
