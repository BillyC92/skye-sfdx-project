/**
 * OpportunityNotificationService
 *
 * Responsible for sending in-app/mobile custom notifications to Sales Manager users
 * when a new Opportunity is created with an Amount greater than $50,000.
 *
 * Design decisions:
 * - Accepts pre-queried data (Opportunities + Account map) so this class is
 *   stateless and independently testable without needing live DML in tests.
 * - Sales Manager role is looked up by UserRole.DeveloperName to avoid
 *   hardcoding any Salesforce IDs.
 * - All notification exceptions are caught and logged rather than re-thrown,
 *   so a notification failure never causes the originating trigger to roll back.
 * - The CustomNotificationType is referenced by DeveloperName ('Follow_Up_Notification')
 *   and must exist in the org before this class is invoked in production.
 */
public with sharing class OpportunityNotificationService {

    // DeveloperName of the CustomNotificationType metadata record.
    // Must match the record deployed under customNotifications/Follow_Up_Notification.customNotification
    @TestVisible
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'Follow_Up_Notification';

    // DeveloperName of the UserRole representing Sales Managers.
    // Using a constant keeps the value configurable in one place and avoids magic strings.
    @TestVisible
    private static final String SALES_MANAGER_ROLE_DEV_NAME = 'Sales_Manager';

    /**
     * Sends a custom notification to all active Sales Manager users for every
     * newly inserted Opportunity whose Amount exceeds $50,000.
     *
     * @param newOpportunities  List of newly inserted Opportunity records (Trigger.new).
     *                          Expected to include: Id, Name, Amount, OwnerId, Owner.Name, AccountId.
     * @param accountById       Map of Account.Id -> Account (with owner data) pre-queried
     *                          by the handler to avoid SOQL inside this service.
     */
    public static void sendHighValueOpportunityNotifications(
        List<Opportunity> newOpportunities,
        Map<Id, Account> accountById
    ) {
        if (newOpportunities == null || newOpportunities.isEmpty()) {
            return;
        }

        // --- 1. Filter qualifying Opportunities up front ---
        // Only process records with Amount > 50,000 to avoid unnecessary work.
        List<Opportunity> qualifyingOpps = new List<Opportunity>();
        for (Opportunity opp : newOpportunities) {
            if (opp.Amount != null && opp.Amount > 50000) {
                qualifyingOpps.add(opp);
            }
        }

        if (qualifyingOpps.isEmpty()) {
            return;
        }

        // --- 2. Resolve the CustomNotificationType Id ---
        // We look this up at runtime so the class works across sandboxes and production
        // without hardcoding an org-specific Id.
        Id notificationTypeId = resolveNotificationTypeId();
        if (notificationTypeId == null) {
            // The CustomNotificationType hasn't been deployed yet — log and exit gracefully.
            System.debug(
                LoggingLevel.WARN,
                'OpportunityNotificationService: CustomNotificationType "' +
                NOTIFICATION_TYPE_DEV_NAME +
                '" not found. Notifications will not be sent.'
            );
            return;
        }

        // --- 3. Resolve Sales Manager user Ids ---
        // Query users whose role DeveloperName matches. If none exist, exit silently.
        Set<Id> salesManagerUserIds = resolveSalesManagerUserIds();
        if (salesManagerUserIds.isEmpty()) {
            System.debug(
                LoggingLevel.INFO,
                'OpportunityNotificationService: No active users found with role "' +
                SALES_MANAGER_ROLE_DEV_NAME +
                '". Skipping notifications.'
            );
            return;
        }

        // --- 4. Send one notification per qualifying Opportunity ---
        for (Opportunity opp : qualifyingOpps) {
            String ownerName = opp.Owner != null ? opp.Owner.Name : 'Unknown';
            String formattedAmount = formatCurrency(opp.Amount);

            String notificationBody =
                opp.Name + ' (' + formattedAmount + ') was just created by ' + ownerName;

            // PageReference target: the Opportunity record page.
            // Using a string page reference keeps this compatible with both Classic and LEX.
            String targetPageRef =
                '{"type":"standard__recordPage","attributes":{"recordId":"' +
                opp.Id +
                '","actionName":"view"}}';

            try {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(notificationTypeId);
                notification.setTargetPageRef(targetPageRef);
                notification.setTitle('High-Value Opportunity Created');
                notification.setBody(notificationBody);
                notification.send(salesManagerUserIds);
            } catch (Exception ex) {
                // Catching broadly here is intentional: a notification failure must never
                // roll back the Opportunity insert that triggered this service.
                System.debug(
                    LoggingLevel.ERROR,
                    'OpportunityNotificationService: Failed to send notification for Opportunity "' +
                    opp.Name + '" (Id: ' + opp.Id + '). Error: ' + ex.getMessage()
                );
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------

    /**
     * Looks up the Id of the Follow_Up_Notification CustomNotificationType.
     * Returns null if the record does not exist in the org.
     */
    private static Id resolveNotificationTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0].Id;
    }

    /**
     * Returns the Ids of all active users whose UserRole has the Sales Manager
     * DeveloperName. Returns an empty set if no matching users exist.
     *
     * Why query User directly (not UserRole then User)?
     * A single query with a relationship filter is more governor-limit-friendly
     * than two separate queries and avoids an in-memory join.
     */
    private static Set<Id> resolveSalesManagerUserIds() {
        Set<Id> userIds = new Set<Id>();
        for (User u : [
            SELECT Id
            FROM User
            WHERE IsActive = TRUE
              AND UserRole.DeveloperName = :SALES_MANAGER_ROLE_DEV_NAME
        ]) {
            userIds.add(u.Id);
        }
        return userIds;
    }

    /**
     * Formats a Decimal as a USD currency string (e.g. 75000 -> '$75,000.00').
     * Keeps the notification body human-readable without pulling in heavy
     * formatting libraries.
     */
    private static String formatCurrency(Decimal amount) {
        if (amount == null) {
            return '$0.00';
        }
        // setScale ensures two decimal places; format() adds locale-aware grouping separators.
        return '$' + amount.setScale(2).format();
    }
}
