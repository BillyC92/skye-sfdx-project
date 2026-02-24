/**
 * OpportunityTriggerHandler
 *
 * Central handler for all Opportunity trigger contexts.
 * Implements the one-trigger-per-object pattern — no business logic lives here.
 * This class is responsible for:
 *   1. Identifying Closed Won transitions (old vs new StageName comparison)
 *   2. Filtering new inserts with Amount > $50k for notification
 *   3. Bulk-fetching Account owner data to avoid per-record SOQL
 *   4. Delegating to OpportunityTaskService and OpportunityNotificationService
 *
 * Dependencies:
 *   - OpportunityTaskService
 *   - OpportunityNotificationService
 */
public with sharing class OpportunityTriggerHandler {

    // Injected via constructor to support mocking in tests
    @TestVisible
    private OpportunityTaskService taskService;

    @TestVisible
    private OpportunityNotificationService notificationService;

    // -----------------------------------------------------------------------
    // Constructors
    // -----------------------------------------------------------------------

    /**
     * Default constructor — uses real service implementations.
     */
    public OpportunityTriggerHandler() {
        this.taskService = new OpportunityTaskService();
        this.notificationService = new OpportunityNotificationService();
    }

    /**
     * Injectable constructor for unit testing with mock services.
     */
    @TestVisible
    private OpportunityTriggerHandler(
        OpportunityTaskService taskService,
        OpportunityNotificationService notificationService
    ) {
        this.taskService = taskService;
        this.notificationService = notificationService;
    }

    // -----------------------------------------------------------------------
    // Trigger Context Entry Points
    // -----------------------------------------------------------------------

    /**
     * Called from OpportunityTrigger on before insert.
     * Currently a no-op — reserved for future before-insert logic.
     *
     * @param newList  Trigger.new
     */
    public void onBeforeInsert(List<Opportunity> newList) {
        // Reserved for future before-insert logic (e.g., field defaulting)
    }

    /**
     * Called from OpportunityTrigger on before update.
     * Currently a no-op — reserved for future before-update logic.
     *
     * @param newList  Trigger.new
     * @param oldMap   Trigger.oldMap
     */
    public void onBeforeUpdate(
        List<Opportunity> newList,
        Map<Id, Opportunity> oldMap
    ) {
        // Reserved for future before-update logic (e.g., field validation)
    }

    /**
     * Called from OpportunityTrigger on after insert.
     * Handles:
     *   - Task creation for Closed Won inserts
     *   - $50k custom notification for qualifying new Opportunities
     *
     * @param newList  Trigger.new
     */
    public void onAfterInsert(List<Opportunity> newList) {
        // On insert there is no prior stage — treat all Closed Won records
        // as a "transition" for Task creation purposes.
        List<Opportunity> closedWonOpps = filterClosedWon(newList);

        if (!closedWonOpps.isEmpty()) {
            Map<Id, User> accountOwnerMap = fetchAccountOwners(closedWonOpps);
            taskService.createFollowUpTasks(closedWonOpps, accountOwnerMap);
        }

        // Notification fires on insert only — no old values to compare against.
        // Pass the full newList; the service applies its own Amount filter.
        notificationService.sendLargeOpportunityNotifications(newList);
    }

    /**
     * Called from OpportunityTrigger on after update.
     * Handles:
     *   - Task creation for Opportunities that just transitioned to Closed Won
     *   - Notifications are intentionally NOT sent on update (insert-only requirement)
     *
     * @param newList  Trigger.new
     * @param oldMap   Trigger.oldMap
     */
    public void onAfterUpdate(
        List<Opportunity> newList,
        Map<Id, Opportunity> oldMap
    ) {
        // Only create Tasks for records that JUST became Closed Won this update.
        // Records already in Closed Won before this DML are excluded to prevent
        // duplicate Task creation on subsequent edits.
        List<Opportunity> newlyClosedWon = filterNewlyClosedWon(newList, oldMap);

        if (!newlyClosedWon.isEmpty()) {
            Map<Id, User> accountOwnerMap = fetchAccountOwners(newlyClosedWon);
            taskService.createFollowUpTasks(newlyClosedWon, accountOwnerMap);
        }

        // Intentionally no notification call here — $50k notification is
        // insert-only per requirements.
    }

    // -----------------------------------------------------------------------
    // Private Helpers
    // -----------------------------------------------------------------------

    /**
     * Returns Opportunities whose StageName is 'Closed Won'.
     * Used for insert context where there is no prior stage to compare.
     *
     * @param opps  List of Opportunities to filter
     * @return      Subset with StageName == 'Closed Won'
     */
    private List<Opportunity> filterClosedWon(List<Opportunity> opps) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : opps) {
            if (opp.StageName == 'Closed Won') {
                result.add(opp);
            }
        }
        return result;
    }

    /**
     * Returns Opportunities that transitioned TO 'Closed Won' in this update.
     * Excludes records that were already Closed Won before this DML operation
     * to prevent duplicate Task creation on subsequent saves.
     *
     * @param newList  Trigger.new
     * @param oldMap   Trigger.oldMap
     * @return         Subset that just became Closed Won
     */
    private List<Opportunity> filterNewlyClosedWon(
        List<Opportunity> newList,
        Map<Id, Opportunity> oldMap
    ) {
        List<Opportunity> result = new List<Opportunity>();
        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            Boolean isNowClosedWon = (opp.StageName == 'Closed Won');
            Boolean wasAlreadyClosedWon = (oldOpp != null && oldOpp.StageName == 'Closed Won');

            if (isNowClosedWon && !wasAlreadyClosedWon) {
                result.add(opp);
            }
        }
        return result;
    }

    /**
     * Bulk-fetches the User records for Account owners associated with the
     * provided Opportunities. Performs a single SOQL query to retrieve
     * Id, IsActive, and Name for each distinct Account owner.
     *
     * Why we query Users separately rather than using a relationship query:
     * Trigger.new does not include related fields, so we must resolve
     * AccountId -> Account.OwnerId -> User in two steps. This method
     * handles both steps in bulk.
     *
     * @param opps  Opportunities whose Account owners we need
     * @return      Map of Account OwnerId -> User record
     */
    private Map<Id, User> fetchAccountOwners(List<Opportunity> opps) {
        // Step 1: Collect all AccountIds from the Opportunity list
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        if (accountIds.isEmpty()) {
            return new Map<Id, User>();
        }

        // Step 2: Query Accounts to get their OwnerId values
        Map<Id, Id> accountToOwnerIdMap = new Map<Id, Id>();
        for (Account acc : [
            SELECT Id, OwnerId
            FROM Account
            WHERE Id IN :accountIds
        ]) {
            accountToOwnerIdMap.put(acc.Id, acc.OwnerId);
        }

        // Step 3: Collect distinct Account owner User IDs
        Set<Id> ownerIds = new Set<Id>(accountToOwnerIdMap.values());

        if (ownerIds.isEmpty()) {
            return new Map<Id, User>();
        }

        // Step 4: Query User records for active status — keyed by User Id
        Map<Id, User> userMap = new Map<Id, User>([
            SELECT Id, IsActive, Name
            FROM User
            WHERE Id IN :ownerIds
        ]);

        // Step 5: Return a map keyed by AccountId -> User (the Account's owner)
        // This allows OpportunityTaskService to look up the owner by AccountId
        // without needing to repeat the Account query.
        Map<Id, User> accountOwnerMap = new Map<Id, User>();
        for (Id accountId : accountToOwnerIdMap.keySet()) {
            Id ownerId = accountToOwnerIdMap.get(accountId);
            if (userMap.containsKey(ownerId)) {
                accountOwnerMap.put(accountId, userMap.get(ownerId));
            }
        }

        return accountOwnerMap;
    }
}
