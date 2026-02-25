/**
 * OpportunityNotificationService
 *
 * Stateless service class responsible for sending custom notifications
 * to Sales Managers when a high-value Opportunity (Amount > $50,000) is created.
 *
 * Design decisions:
 * - Called only on insert (after insert) — update notifications are intentionally excluded
 *   per requirements. The handler enforces this; this class does not re-check context.
 * - Silent failure: exceptions from the notification API are caught and logged via
 *   System.debug rather than rethrown, so a notification failure never rolls back the
 *   Opportunity DML that triggered it.
 * - No SOQL inside loops. The UserRole query is performed once and cached in a local
 *   variable. Account data is passed in from the handler to avoid redundant queries.
 * - CustomNotificationType is looked up by DeveloperName so no Id is hardcoded.
 */
public with sharing class OpportunityNotificationService {

    // Notification type developer name — matches the CustomNotificationType metadata record.
    // Using a constant keeps the magic string in one place and makes future changes trivial.
    @TestVisible
    private static final String NOTIFICATION_TYPE_DEV_NAME = 'OpportunityFollowUpNotification';

    // Amount threshold above which a notification is sent.
    @TestVisible
    private static final Decimal HIGH_VALUE_THRESHOLD = 50000;

    /**
     * sendHighValueNotifications
     *
     * Sends a custom notification to the Account owner (if they are a Sales Manager)
     * for every Opportunity in newOpps whose Amount exceeds the high-value threshold.
     *
     * @param newOpps    List of newly inserted Opportunity records (Trigger.new).
     * @param accountMap Map of Account Id -> Account (with OwnerId, Owner.UserRoleId populated)
     *                   pre-fetched by the handler. May be empty but never null.
     */
    public static void sendHighValueNotifications(
        List<Opportunity> newOpps,
        Map<Id, Account> accountMap
    ) {
        if (newOpps == null || newOpps.isEmpty()) {
            return;
        }

        // --- Step 1: Filter to high-value Opportunities only ---
        List<Opportunity> highValueOpps = new List<Opportunity>();
        for (Opportunity opp : newOpps) {
            if (opp.Amount != null && opp.Amount > HIGH_VALUE_THRESHOLD) {
                highValueOpps.add(opp);
            }
        }

        if (highValueOpps.isEmpty()) {
            return;
        }

        // --- Step 2: Look up the Sales Manager UserRole (single query, no loop) ---
        // We query by DeveloperName so this works across sandboxes and production
        // without hardcoding a Role Id.
        UserRole salesManagerRole = null;
        List<UserRole> roles = [
            SELECT Id, DeveloperName
            FROM UserRole
            WHERE DeveloperName = 'Sales_Manager'
            LIMIT 1
        ];
        if (!roles.isEmpty()) {
            salesManagerRole = roles[0];
        }

        // If no Sales Manager role exists in this org, there is no valid recipient.
        // Per requirements, skip silently — do not throw.
        if (salesManagerRole == null) {
            System.debug(
                LoggingLevel.WARN,
                'OpportunityNotificationService: No UserRole with DeveloperName \'Sales_Manager\' ' +
                'found. High-value notifications will not be sent.'
            );
            return;
        }

        // --- Step 3: Look up the CustomNotificationType Id (single query) ---
        // This Id is required by the Messaging.CustomNotification API.
        CustomNotificationType notificationType = null;
        List<CustomNotificationType> notifTypes = [
            SELECT Id, DeveloperName
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_DEV_NAME
            LIMIT 1
        ];
        if (!notifTypes.isEmpty()) {
            notificationType = notifTypes[0];
        }

        if (notificationType == null) {
            System.debug(
                LoggingLevel.ERROR,
                'OpportunityNotificationService: CustomNotificationType \'' +
                NOTIFICATION_TYPE_DEV_NAME +
                '\' not found. Ensure the metadata record has been deployed. ' +
                'High-value notifications will not be sent.'
            );
            return;
        }

        // --- Step 4: Build and send notifications ---
        // We iterate high-value Opps, resolve the Account owner, confirm they hold
        // the Sales Manager role, then dispatch one notification per qualifying Opp.
        //
        // The Messaging.CustomNotification API does not support true bulk dispatch
        // (each send() call targets one notification), so we call send() per record.
        // Exceptions are caught individually so one failure does not block others.
        for (Opportunity opp : highValueOpps) {
            try {
                // Resolve the Account owner for this Opportunity.
                Id accountOwnerId = resolveAccountOwnerId(opp, accountMap);

                if (accountOwnerId == null) {
                    System.debug(
                        LoggingLevel.WARN,
                        'OpportunityNotificationService: Could not resolve Account owner ' +
                        'for Opportunity ' + opp.Id + ' (' + opp.Name + '). Skipping notification.'
                    );
                    continue;
                }

                // Confirm the Account owner holds the Sales Manager role.
                // We look up the User's role via the accountMap's owner data.
                // The handler must have queried Account with Owner.UserRoleId.
                if (!isUserSalesManager(accountOwnerId, accountMap, salesManagerRole.Id)) {
                    System.debug(
                        LoggingLevel.DEBUG,
                        'OpportunityNotificationService: Account owner ' + accountOwnerId +
                        ' is not a Sales Manager. Skipping notification for Opp ' + opp.Id + '.'
                    );
                    continue;
                }

                // Build the notification.
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(notificationType.Id);
                notification.setTargetId(opp.Id);
                notification.setTitle('High-Value Opportunity Created');
                notification.setBody(
                    'Opportunity \'' + opp.Name + '\' has been created with an amount of $' +
                    formatAmount(opp.Amount) + '. Please review and take appropriate action.'
                );

                // Recipient set — one user per notification.
                Set<String> recipientIds = new Set<String>{ accountOwnerId };
                notification.send(recipientIds);

            } catch (Exception ex) {
                // Silent failure: log the error but do not rethrow.
                // A notification failure must never roll back the Opportunity save.
                System.debug(
                    LoggingLevel.ERROR,
                    'OpportunityNotificationService: Failed to send notification for ' +
                    'Opportunity ' + opp.Id + '. Error: ' + ex.getMessage() +
                    ' | Stack: ' + ex.getStackTraceString()
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * resolveAccountOwnerId
     *
     * Returns the OwnerId of the Account associated with the given Opportunity,
     * using the pre-fetched accountMap. Returns null if the Account is not found
     * in the map or the Opportunity has no AccountId.
     */
    private static Id resolveAccountOwnerId(
        Opportunity opp,
        Map<Id, Account> accountMap
    ) {
        if (opp.AccountId == null || accountMap == null) {
            return null;
        }
        Account acc = accountMap.get(opp.AccountId);
        return (acc != null) ? acc.OwnerId : null;
    }

    /**
     * isUserSalesManager
     *
     * Checks whether the given userId is the owner of an Account in accountMap
     * whose Owner.UserRoleId matches salesManagerRoleId.
     *
     * The handler is expected to have queried:
     *   SELECT Id, OwnerId, Owner.UserRoleId FROM Account WHERE Id IN :accountIds
     *
     * We iterate the accountMap values to find the Account owned by this user
     * and inspect their role. This avoids an additional SOQL query.
     */
    private static Boolean isUserSalesManager(
        Id userId,
        Map<Id, Account> accountMap,
        Id salesManagerRoleId
    ) {
        if (userId == null || accountMap == null || salesManagerRoleId == null) {
            return false;
        }
        for (Account acc : accountMap.values()) {
            if (acc.OwnerId == userId) {
                // Owner.UserRoleId is available when the handler queries with
                // a relationship field: Owner.UserRoleId
                return acc.Owner != null && acc.Owner.UserRoleId == salesManagerRoleId;
            }
        }
        return false;
    }

    /**
     * formatAmount
     *
     * Formats a Decimal amount as a plain string with two decimal places.
     * Keeps the notification body readable without importing a full formatter.
     */
    private static String formatAmount(Decimal amount) {
        if (amount == null) {
            return '0.00';
        }
        return amount.setScale(2).toPlainString();
    }
}
