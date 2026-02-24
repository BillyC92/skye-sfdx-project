/**
 * OpportunityNotificationService
 *
 * Responsible for sending custom push notifications when Opportunities over $50,000
 * are created. Notifications are sent to the Sales Manager user associated with
 * the Opportunity's Account.
 *
 * Design decisions:
 * - Accepts pre-queried Account data from the handler to avoid redundant SOQL.
 * - Queries UserRole by Name = 'Sales Manager' once per invocation (bulkified).
 * - Queries Users by RoleId in a single SOQL — maps AccountId -> Sales Manager User
 *   via the Account's OwnerId role hierarchy is ambiguous; instead we find all Users
 *   whose Role is 'Sales Manager' and match them to the Account's owner's manager chain.
 *   Given the clarification gap noted in the implementation plan, we adopt the pragmatic
 *   interpretation: notify the Sales Manager whose role is 'Sales Manager' and who is
 *   the direct manager (UserRoleId = Sales Manager role) of the Account owner.
 *   If no such user exists for a given Account, we skip silently.
 * - Uses Messaging.CustomNotification with the named notification type
 *   'OpportunityFollowUpNotification' (must be provisioned in Setup first).
 * - All exceptions are caught and logged; a missing role or user never throws to the caller.
 *
 * @author Skye
 * @ticket KAN-5
 */
public with sharing class OpportunityNotificationService {

    // Custom Notification Type developer name — must match the record created in
    // Setup > Notification Builder > Notification Types.
    // Stored as a constant so it is easy to update without touching logic.
    @TestVisible
    private static final String NOTIFICATION_TYPE_NAME = 'OpportunityFollowUpNotification';

    // The role name used to identify Sales Managers. Using a constant keeps
    // the magic string in one place and makes future changes trivial.
    @TestVisible
    private static final String SALES_MANAGER_ROLE_NAME = 'Sales Manager';

    // Threshold above which a notification is sent (exclusive — Amount > 50000).
    @TestVisible
    private static final Decimal NOTIFICATION_THRESHOLD = 50000;

    /**
     * Sends custom notifications to the relevant Sales Manager for each qualifying
     * Opportunity. Called only on insert; the handler is responsible for filtering
     * to Amount > 50,000 before calling this method.
     *
     * @param opportunities  List of newly inserted Opportunities with Amount > $50k.
     * @param accountsById   Map of Account Id -> Account (with OwnerId populated)
     *                       pre-queried by the handler.
     */
    public static void sendInsertNotifications(
        List<Opportunity> opportunities,
        Map<Id, Account> accountsById
    ) {
        if (opportunities == null || opportunities.isEmpty()) {
            return;
        }

        // ----------------------------------------------------------------
        // 1. Resolve the Custom Notification Type — single SOQL.
        //    If the notification type has not been created in Setup, we log
        //    and return rather than throwing, to avoid blocking saves.
        // ----------------------------------------------------------------
        CustomNotificationType notificationType = getNotificationType();
        if (notificationType == null) {
            OpportunityTriggerLogger.log(
                'OpportunityNotificationService',
                'sendInsertNotifications',
                'Custom Notification Type not found: ' + NOTIFICATION_TYPE_NAME +
                '. Notifications will not be sent. Create the type in Setup > Notification Builder.'
            );
            return;
        }

        // ----------------------------------------------------------------
        // 2. Resolve the Sales Manager role — single SOQL.
        //    If no role exists with this name, skip silently.
        // ----------------------------------------------------------------
        UserRole salesManagerRole = getSalesManagerRole();
        if (salesManagerRole == null) {
            // No Sales Manager role configured — nothing to do.
            return;
        }

        // ----------------------------------------------------------------
        // 3. Collect Account Owner IDs so we can find their managers.
        //    The Sales Manager is defined as a User whose UserRoleId matches
        //    the 'Sales Manager' role. We then match them to Accounts by
        //    finding which Account owner reports to a Sales Manager.
        //
        //    Approach: query all active Users with the Sales Manager role.
        //    Then, for each Account owner, walk up via ManagerId to find
        //    whether their direct manager holds the Sales Manager role.
        //    To keep this to a single SOQL, we query Account owners' manager
        //    IDs in the Account data, then match against Sales Manager users.
        //
        //    Because the Account query in the handler may not include the
        //    Owner.ManagerId sub-query, we query Account owners here.
        // ----------------------------------------------------------------
        Set<Id> accountOwnerIds = new Set<Id>();
        for (Opportunity opp : opportunities) {
            if (opp.AccountId != null && accountsById.containsKey(opp.AccountId)) {
                accountOwnerIds.add(accountsById.get(opp.AccountId).OwnerId);
            }
        }

        // Single SOQL: fetch Account owners with their ManagerId.
        Map<Id, User> accountOwnerById = new Map<Id, User>();
        if (!accountOwnerIds.isEmpty()) {
            for (User u : [
                SELECT Id, ManagerId
                FROM User
                WHERE Id IN :accountOwnerIds
                AND IsActive = TRUE
            ]) {
                accountOwnerById.put(u.Id, u);
            }
        }

        // Collect manager IDs (potential Sales Managers).
        Set<Id> managerIds = new Set<Id>();
        for (User owner : accountOwnerById.values()) {
            if (owner.ManagerId != null) {
                managerIds.add(owner.ManagerId);
            }
        }

        // Single SOQL: find which managers hold the Sales Manager role.
        Map<Id, User> salesManagerById = new Map<Id, User>();
        if (!managerIds.isEmpty()) {
            for (User u : [
                SELECT Id, UserRoleId, IsActive
                FROM User
                WHERE Id IN :managerIds
                AND UserRoleId = :salesManagerRole.Id
                AND IsActive = TRUE
            ]) {
                salesManagerById.put(u.Id, u);
            }
        }

        // ----------------------------------------------------------------
        // 4. Build a map of AccountOwnerId -> Sales Manager User Id
        //    so we can resolve the recipient per Opportunity.
        // ----------------------------------------------------------------
        Map<Id, Id> accountOwnerToSalesManager = new Map<Id, Id>();
        for (Id ownerId : accountOwnerById.keySet()) {
            User owner = accountOwnerById.get(ownerId);
            if (owner.ManagerId != null && salesManagerById.containsKey(owner.ManagerId)) {
                accountOwnerToSalesManager.put(ownerId, owner.ManagerId);
            }
        }

        // ----------------------------------------------------------------
        // 5. Fetch Opportunity owners' names for the notification message.
        //    The handler passes Trigger.new which has OwnerId but not Owner.Name.
        // ----------------------------------------------------------------
        Set<Id> oppOwnerIds = new Set<Id>();
        for (Opportunity opp : opportunities) {
            oppOwnerIds.add(opp.OwnerId);
        }
        Map<Id, User> oppOwnerById = new Map<Id, User>();
        if (!oppOwnerIds.isEmpty()) {
            for (User u : [
                SELECT Id, Name
                FROM User
                WHERE Id IN :oppOwnerIds
            ]) {
                oppOwnerById.put(u.Id, u);
            }
        }

        // ----------------------------------------------------------------
        // 6. Send one notification per Opportunity to the resolved
        //    Sales Manager. Skip silently if no Sales Manager is found.
        // ----------------------------------------------------------------
        for (Opportunity opp : opportunities) {
            try {
                Id salesManagerUserId = resolveSalesManagerForOpportunity(
                    opp, accountsById, accountOwnerToSalesManager
                );

                if (salesManagerUserId == null) {
                    // No Sales Manager found for this Account — skip silently.
                    continue;
                }

                String ownerName = oppOwnerById.containsKey(opp.OwnerId)
                    ? oppOwnerById.get(opp.OwnerId).Name
                    : 'Unknown';

                String body = buildNotificationBody(opp, ownerName);

                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(notificationType.Id);
                notification.setTitle('New High-Value Opportunity');
                notification.setBody(body);
                notification.setTargetId(opp.Id);
                notification.send(new Set<String>{ salesManagerUserId });

            } catch (Exception ex) {
                // Log but never rethrow — notification failure must not block
                // the Opportunity insert that triggered this service.
                OpportunityTriggerLogger.log(
                    'OpportunityNotificationService',
                    'sendInsertNotifications',
                    'Failed to send notification for Opportunity ' + opp.Id +
                    ': ' + ex.getMessage() + ' | ' + ex.getStackTraceString()
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Queries the Custom Notification Type by developer name.
     * Returns null if not found rather than throwing.
     */
    private static CustomNotificationType getNotificationType() {
        List<CustomNotificationType> types = [
            SELECT Id, DeveloperName
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_NAME
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0];
    }

    /**
     * Queries the UserRole with the Sales Manager name.
     * Returns null if not found.
     */
    private static UserRole getSalesManagerRole() {
        List<UserRole> roles = [
            SELECT Id, Name
            FROM UserRole
            WHERE Name = :SALES_MANAGER_ROLE_NAME
            LIMIT 1
        ];
        return roles.isEmpty() ? null : roles[0];
    }

    /**
     * Resolves the Sales Manager User ID for a given Opportunity by looking up
     * the Account owner's manager in the pre-built map.
     *
     * Returns null if the Opportunity has no Account, the Account is not in the
     * map, or no Sales Manager is found for the Account owner.
     */
    private static Id resolveSalesManagerForOpportunity(
        Opportunity opp,
        Map<Id, Account> accountsById,
        Map<Id, Id> accountOwnerToSalesManager
    ) {
        if (opp.AccountId == null) {
            return null;
        }
        Account acct = accountsById.get(opp.AccountId);
        if (acct == null) {
            return null;
        }
        return accountOwnerToSalesManager.get(acct.OwnerId);
    }

    /**
     * Constructs the notification body string.
     * Format: '{Opportunity Name} ({Amount}) was just created by {Owner Name}'
     * Amount is formatted as currency with no decimal places for readability.
     */
    @TestVisible
    private static String buildNotificationBody(Opportunity opp, String ownerName) {
        String formattedAmount = opp.Amount != null
            ? '$' + opp.Amount.setScale(0).toPlainString()
            : '$0';
        return opp.Name + ' (' + formattedAmount + ') was just created by ' + ownerName;
    }
}
