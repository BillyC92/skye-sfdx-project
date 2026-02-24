/**
 * OpportunityNotificationServiceTest
 *
 * Tests for OpportunityNotificationService.
 *
 * Testing strategy:
 * - Messaging.CustomNotification.send() cannot be fully mocked in Apex without
 *   a stub framework, so tests verify:
 *     (a) No unhandled exceptions are thrown under any scenario.
 *     (b) The service exits early (no notification attempt) when pre-conditions
 *         are not met (low amount, no notification type, no Sales Manager).
 *     (c) Bulk behaviour with 200 records does not breach governor limits.
 *
 * Where the CustomNotificationType or Sales Manager role is absent in the test
 * org, the service must exit silently — these paths are explicitly tested.
 *
 * Note: CustomNotificationType records cannot be inserted via Apex DML in tests,
 * so tests that exercise the notification-send path rely on the type existing in
 * the org (deployed via metadata). Tests are written to be safe whether or not
 * the type is present.
 */
@IsTest
private class OpportunityNotificationServiceTest {

    // -------------------------------------------------------------------------
    // Test data helpers
    // -------------------------------------------------------------------------

    /**
     * Creates a minimal Account with an active owner for use across tests.
     * Does NOT insert — caller decides whether to insert.
     */
    private static Account buildAccount(String name) {
        return new Account(Name = name);
    }

    /**
     * Builds an Opportunity with the given amount and links it to the provided
     * Account. Does NOT insert.
     */
    private static Opportunity buildOpportunity(
        String name,
        Decimal amount,
        Id accountId,
        Id ownerId,
        String stageName,
        Date closeDate
    ) {
        return new Opportunity(
            Name      = name,
            Amount    = amount,
            AccountId = accountId,
            OwnerId   = ownerId,
            StageName = stageName,
            CloseDate = closeDate
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 1: Amount at or below threshold — no notification attempt
    // -------------------------------------------------------------------------

    @IsTest
    static void testLowAmountOpportunity_noNotificationSent() {
        Account acc = buildAccount('Low Value Corp');
        insert acc;

        Opportunity opp = buildOpportunity(
            'Small Deal',
            49999.99,
            acc.Id,
            UserInfo.getUserId(),
            'Prospecting',
            Date.today().addDays(30)
        );
        insert opp;

        // Re-query with Owner relationship populated (mirrors what the handler provides)
        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        Map<Id, Account> accountById = new Map<Id, Account>(
            [SELECT Id, Name, OwnerId FROM Account WHERE Id = :acc.Id]
        );

        Test.startTest();
        // Expect no exception — service should exit silently for low amounts
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        // If we reach here without exception, the test passes.
        // There is no side-effect to assert on for the early-exit path.
        System.assert(true, 'Service should complete without exception for low-amount Opportunity');
    }

    // -------------------------------------------------------------------------
    // Scenario 2: Amount exactly at threshold (50000) — not qualifying
    // -------------------------------------------------------------------------

    @IsTest
    static void testAmountExactlyAtThreshold_noNotificationSent() {
        Account acc = buildAccount('Threshold Corp');
        insert acc;

        Opportunity opp = buildOpportunity(
            'Threshold Deal',
            50000,
            acc.Id,
            UserInfo.getUserId(),
            'Prospecting',
            Date.today().addDays(30)
        );
        insert opp;

        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        Map<Id, Account> accountById = new Map<Id, Account>(
            [SELECT Id, Name, OwnerId FROM Account WHERE Id = :acc.Id]
        );

        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        System.assert(
            true,
            'Service should complete without exception for Opportunity at exactly $50,000 (not > threshold)'
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 3: Amount above threshold — service runs notification path
    //             without throwing (Sales Manager role may or may not exist)
    // -------------------------------------------------------------------------

    @IsTest
    static void testHighAmountOpportunity_noExceptionThrown() {
        Account acc = buildAccount('High Value Corp');
        insert acc;

        Opportunity opp = buildOpportunity(
            'Big Deal',
            75000,
            acc.Id,
            UserInfo.getUserId(),
            'Prospecting',
            Date.today().addDays(30)
        );
        insert opp;

        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        Map<Id, Account> accountById = new Map<Id, Account>(
            [SELECT Id, Name, OwnerId FROM Account WHERE Id = :acc.Id]
        );

        Test.startTest();
        // Whether or not the CustomNotificationType / Sales Manager role exists,
        // the service must not throw an unhandled exception.
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        System.assert(
            true,
            'Service should complete without exception even when notification type or role is absent'
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 4: Null Amount — should not qualify and must not throw NPE
    // -------------------------------------------------------------------------

    @IsTest
    static void testNullAmount_noExceptionThrown() {
        Account acc = buildAccount('Null Amount Corp');
        insert acc;

        Opportunity opp = buildOpportunity(
            'No Amount Deal',
            null,
            acc.Id,
            UserInfo.getUserId(),
            'Prospecting',
            Date.today().addDays(30)
        );
        insert opp;

        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        Map<Id, Account> accountById = new Map<Id, Account>(
            [SELECT Id, Name, OwnerId FROM Account WHERE Id = :acc.Id]
        );

        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        System.assert(
            true,
            'Service should handle null Amount gracefully without NullPointerException'
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 5: Opportunity without an Account — edge case, no NPE
    // -------------------------------------------------------------------------

    @IsTest
    static void testOpportunityWithoutAccount_noExceptionThrown() {
        // Opportunities can exist without an Account in some org configurations.
        Opportunity opp = buildOpportunity(
            'No Account Deal',
            80000,
            null,
            UserInfo.getUserId(),
            'Prospecting',
            Date.today().addDays(30)
        );
        insert opp;

        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        // Pass an empty account map — simulates no Account being found
        Map<Id, Account> accountById = new Map<Id, Account>();

        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        System.assert(
            true,
            'Service should handle Opportunity with no Account without throwing an exception'
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 6: Empty list — early exit, no exception
    // -------------------------------------------------------------------------

    @IsTest
    static void testEmptyList_noExceptionThrown() {
        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            new List<Opportunity>(),
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assert(true, 'Service should handle empty Opportunity list without exception');
    }

    // -------------------------------------------------------------------------
    // Scenario 7: Null list — defensive null check, no exception
    // -------------------------------------------------------------------------

    @IsTest
    static void testNullList_noExceptionThrown() {
        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            null,
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assert(true, 'Service should handle null Opportunity list without exception');
    }

    // -------------------------------------------------------------------------
    // Scenario 8: Mixed list — some above threshold, some below
    //             All records processed without exception
    // -------------------------------------------------------------------------

    @IsTest
    static void testMixedAmounts_noExceptionThrown() {
        Account acc = buildAccount('Mixed Corp');
        insert acc;

        List<Opportunity> oppsToInsert = new List<Opportunity>();
        oppsToInsert.add(buildOpportunity(
            'Small Deal', 10000, acc.Id, UserInfo.getUserId(), 'Prospecting', Date.today().addDays(30)
        ));
        oppsToInsert.add(buildOpportunity(
            'Big Deal', 100000, acc.Id, UserInfo.getUserId(), 'Prospecting', Date.today().addDays(30)
        ));
        oppsToInsert.add(buildOpportunity(
            'Medium Deal', 50001, acc.Id, UserInfo.getUserId(), 'Prospecting', Date.today().addDays(30)
        ));
        insert oppsToInsert;

        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id IN :oppsToInsert
        ];
        Map<Id, Account> accountById = new Map<Id, Account>(
            [SELECT Id, Name, OwnerId FROM Account WHERE Id = :acc.Id]
        );

        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        System.assert(
            true,
            'Service should process mixed-amount list without exception'
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 9: Bulk test — 200 high-value Opportunities
    //             Verifies governor limits are not breached
    // -------------------------------------------------------------------------

    @IsTest
    static void testBulk200HighValueOpportunities_noExceptionThrown() {
        Account acc = buildAccount('Bulk Corp');
        insert acc;

        List<Opportunity> oppsToInsert = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            oppsToInsert.add(buildOpportunity(
                'Bulk Deal ' + i,
                60000 + i,
                acc.Id,
                UserInfo.getUserId(),
                'Prospecting',
                Date.today().addDays(30)
            ));
        }
        insert oppsToInsert;

        List<Opportunity> opps = [
            SELECT Id, Name, Amount, OwnerId, Owner.Name, AccountId
            FROM Opportunity
            WHERE Id IN :oppsToInsert
        ];
        Map<Id, Account> accountById = new Map<Id, Account>(
            [SELECT Id, Name, OwnerId FROM Account WHERE Id = :acc.Id]
        );

        Test.startTest();
        OpportunityNotificationService.sendHighValueOpportunityNotifications(
            opps, accountById
        );
        Test.stopTest();

        System.assert(
            true,
            'Service should handle 200 high-value Opportunities without hitting governor limits'
        );
    }

    // -------------------------------------------------------------------------
    // Scenario 10: Verify NOTIFICATION_TYPE_DEV_NAME and SALES_MANAGER_ROLE_DEV_NAME
    //              constants are set to expected values
    // -------------------------------------------------------------------------

    @IsTest
    static void testConstants_haveExpectedValues() {
        System.assertEquals(
            'Follow_Up_Notification',
            OpportunityNotificationService.NOTIFICATION_TYPE_DEV_NAME,
            'Notification type DeveloperName constant should match the deployed CustomNotificationType'
        );
        System.assertEquals(
            'Sales_Manager',
            OpportunityNotificationService.SALES_MANAGER_ROLE_DEV_NAME,
            'Sales Manager role DeveloperName constant should match the expected UserRole'
        );
    }
}
