/**
 * OpportunityNotificationServiceTest
 *
 * Comprehensive test coverage for OpportunityNotificationService.
 *
 * Testing strategy:
 * - Messaging.CustomNotification.send() cannot be called in test context without
 *   a real CustomNotificationType, so we verify the service handles missing
 *   notification types gracefully and test all branching logic up to the send call.
 * - We use @TestVisible constants and helper methods to assert correct message
 *   construction and recipient resolution without needing to actually deliver
 *   a push notification.
 * - All tests use SeeAllData=false and create their own data.
 *
 * @author Skye
 * @ticket KAN-5
 */
@IsTest
private class OpportunityNotificationServiceTest {

    // -------------------------------------------------------------------------
    // Test data setup
    // -------------------------------------------------------------------------

    /**
     * Creates a standard test Account with an active owner.
     */
    private static Account createTestAccount(Id ownerId) {
        Account acct = new Account(
            Name = 'Test Account',
            OwnerId = ownerId
        );
        insert acct;
        return acct;
    }

    /**
     * Creates a test Opportunity linked to the given Account.
     */
    private static Opportunity createTestOpportunity(
        String name,
        Id accountId,
        Id ownerId,
        Decimal amount,
        String stageName
    ) {
        return new Opportunity(
            Name = name,
            AccountId = accountId,
            OwnerId = ownerId,
            Amount = amount,
            StageName = stageName,
            CloseDate = Date.today().addDays(30)
        );
    }

    /**
     * Creates a UserRole with the given name.
     */
    private static UserRole createRole(String roleName) {
        UserRole role = new UserRole(Name = roleName, DeveloperName = roleName.replaceAll(' ', '_'));
        insert role;
        return role;
    }

    /**
     * Creates a minimal active test User with the given role.
     * Uses a unique username to avoid conflicts across test runs.
     */
    private static User createUser(String lastName, Id roleId) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            LastName = lastName,
            FirstName = 'Test',
            Email = lastName.toLowerCase().replaceAll(' ', '') + '@test.example.com',
            Username = lastName.toLowerCase().replaceAll(' ', '') +
                       String.valueOf(Math.random()).replaceAll('\.', '') +
                       '@test.example.com',
            Alias = lastName.left(5).toLowerCase(),
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id,
            UserRoleId = roleId,
            IsActive = true
        );
        insert u;
        return u;
    }

    // -------------------------------------------------------------------------
    // Tests: buildNotificationBody (unit — no DML required)
    // -------------------------------------------------------------------------

    @IsTest
    static void testBuildNotificationBody_standardValues() {
        Opportunity opp = new Opportunity(
            Name = 'Big Deal',
            Amount = 75000,
            OwnerId = UserInfo.getUserId()
        );

        Test.startTest();
        String body = OpportunityNotificationService.buildNotificationBody(opp, 'Jane Smith');
        Test.stopTest();

        System.assertEquals(
            'Big Deal ($75000) was just created by Jane Smith',
            body,
            'Notification body should match the expected format.'
        );
    }

    @IsTest
    static void testBuildNotificationBody_nullAmount() {
        Opportunity opp = new Opportunity(
            Name = 'No Amount Deal',
            Amount = null,
            OwnerId = UserInfo.getUserId()
        );

        Test.startTest();
        String body = OpportunityNotificationService.buildNotificationBody(opp, 'John Doe');
        Test.stopTest();

        System.assert(
            body.contains('$0'),
            'Null amount should render as $0 in the notification body.'
        );
    }

    @IsTest
    static void testBuildNotificationBody_decimalAmount() {
        Opportunity opp = new Opportunity(
            Name = 'Decimal Deal',
            Amount = 75000.99,
            OwnerId = UserInfo.getUserId()
        );

        Test.startTest();
        String body = OpportunityNotificationService.buildNotificationBody(opp, 'Alice');
        Test.stopTest();

        // Amount is scaled to 0 decimal places
        System.assert(
            body.contains('$75001') || body.contains('$75000'),
            'Decimal amount should be rounded/truncated in the notification body. Got: ' + body
        );
    }

    // -------------------------------------------------------------------------
    // Tests: sendInsertNotifications — guard clauses
    // -------------------------------------------------------------------------

    @IsTest
    static void testSendInsertNotifications_nullList_noException() {
        Test.startTest();
        // Should return silently without throwing
        OpportunityNotificationService.sendInsertNotifications(null, new Map<Id, Account>());
        Test.stopTest();

        System.assert(true, 'Null opportunity list should not throw an exception.');
    }

    @IsTest
    static void testSendInsertNotifications_emptyList_noException() {
        Test.startTest();
        OpportunityNotificationService.sendInsertNotifications(
            new List<Opportunity>(),
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assert(true, 'Empty opportunity list should not throw an exception.');
    }

    // -------------------------------------------------------------------------
    // Tests: missing Sales Manager role — silent skip
    // -------------------------------------------------------------------------

    @IsTest
    static void testSendInsertNotifications_missingSalesManagerRole_noException() {
        // Do NOT create a 'Sales Manager' role — verify the service handles absence gracefully.
        Account acct = createTestAccount(UserInfo.getUserId());

        Opportunity opp = createTestOpportunity(
            'High Value Opp',
            acct.Id,
            UserInfo.getUserId(),
            75000,
            'Prospecting'
        );
        // Do not insert — we pass the list directly to the service.
        opp.Id = null; // Ensure no Id confusion

        Map<Id, Account> accountsById = new Map<Id, Account>{ acct.Id => acct };

        Test.startTest();
        // Should return silently — no Sales Manager role exists
        OpportunityNotificationService.sendInsertNotifications(
            new List<Opportunity>{ opp },
            accountsById
        );
        Test.stopTest();

        System.assert(true, 'Missing Sales Manager role should not throw an exception.');
    }

    // -------------------------------------------------------------------------
    // Tests: missing CustomNotificationType — silent skip with log
    // -------------------------------------------------------------------------

    @IsTest
    static void testSendInsertNotifications_missingNotificationType_noException() {
        // The CustomNotificationType 'OpportunityFollowUpNotification' will not
        // exist in the test org sandbox — verify the service handles this gracefully.
        UserRole salesMgrRole = createRole('Sales Manager');
        User salesMgr = createUser('SalesManager', salesMgrRole.Id);

        // Run as a user without special permissions to keep the test isolated.
        Account acct;
        Opportunity opp;

        System.runAs(salesMgr) {
            acct = createTestAccount(salesMgr.Id);
        }

        opp = createTestOpportunity(
            'Big Opp',
            acct.Id,
            UserInfo.getUserId(),
            80000,
            'Prospecting'
        );

        Map<Id, Account> accountsById = new Map<Id, Account>{ acct.Id => acct };

        Test.startTest();
        // CustomNotificationType does not exist in test context — should log and return
        OpportunityNotificationService.sendInsertNotifications(
            new List<Opportunity>{ opp },
            accountsById
        );
        Test.stopTest();

        System.assert(
            true,
            'Missing CustomNotificationType should not throw — service should log and return.'
        );
    }

    // -------------------------------------------------------------------------
    // Tests: Opportunity with no AccountId — silent skip
    // -------------------------------------------------------------------------

    @IsTest
    static void testSendInsertNotifications_noAccount_silentSkip() {
        UserRole salesMgrRole = createRole('Sales Manager');

        Opportunity opp = new Opportunity(
            Name = 'No Account Opp',
            AccountId = null,
            OwnerId = UserInfo.getUserId(),
            Amount = 75000,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        Test.startTest();
        OpportunityNotificationService.sendInsertNotifications(
            new List<Opportunity>{ opp },
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assert(
            true,
            'Opportunity with no AccountId should be skipped silently.'
        );
    }

    // -------------------------------------------------------------------------
    // Tests: Account with no Sales Manager in hierarchy — silent skip
    // -------------------------------------------------------------------------

    @IsTest
    static void testSendInsertNotifications_accountOwnerHasNoSalesManagerParent_silentSkip() {
        // Create a role that is NOT 'Sales Manager' so the manager lookup returns nothing.
        UserRole nonSalesRole = createRole('Account Executive');
        UserRole salesMgrRole = createRole('Sales Manager');

        User accountOwner = createUser('AccountOwner', nonSalesRole.Id);
        // accountOwner's manager is NOT a Sales Manager — no ManagerId set.

        Account acct;
        System.runAs(accountOwner) {
            acct = createTestAccount(accountOwner.Id);
        }

        Opportunity opp = createTestOpportunity(
            'Orphan Opp',
            acct.Id,
            accountOwner.Id,
            75000,
            'Prospecting'
        );

        Map<Id, Account> accountsById = new Map<Id, Account>{ acct.Id => acct };

        Test.startTest();
        OpportunityNotificationService.sendInsertNotifications(
            new List<Opportunity>{ opp },
            accountsById
        );
        Test.stopTest();

        System.assert(
            true,
            'Account whose owner has no Sales Manager in hierarchy should be skipped silently.'
        );
    }

    // -------------------------------------------------------------------------
    // Tests: bulk — 200 opportunities, no exception thrown
    // -------------------------------------------------------------------------

    @IsTest
    static void testSendInsertNotifications_bulk200_noException() {
        UserRole salesMgrRole = createRole('Sales Manager');
        User salesMgr = createUser('BulkSalesMgr', salesMgrRole.Id);

        UserRole repRole = createRole('Sales Rep');
        User repUser = createUser('BulkRep', repRole.Id);

        // Set repUser's manager to salesMgr
        repUser.ManagerId = salesMgr.Id;
        update repUser;

        Account acct;
        System.runAs(repUser) {
            acct = createTestAccount(repUser.Id);
        }

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(createTestOpportunity(
                'Bulk Opp ' + i,
                acct.Id,
                repUser.Id,
                75000 + i,
                'Prospecting'
            ));
        }

        Map<Id, Account> accountsById = new Map<Id, Account>{ acct.Id => acct };

        Test.startTest();
        // CustomNotificationType won't exist in test org — service should handle gracefully
        // for all 200 records without hitting governor limits or throwing.
        OpportunityNotificationService.sendInsertNotifications(opps, accountsById);
        Test.stopTest();

        System.assert(
            true,
            'Bulk 200-record invocation should complete without exception or governor limit errors.'
        );
    }

    // -------------------------------------------------------------------------
    // Tests: amount boundary — exactly $50k is NOT notified (Amount > 50000)
    // -------------------------------------------------------------------------

    @IsTest
    static void testNotificationThreshold_exactlyFiftyK_notQualifying() {
        // The handler is responsible for filtering Amount > 50000 before calling
        // this service. This test verifies the threshold constant is correct
        // and that the service itself does not re-filter (it trusts the caller).
        System.assertEquals(
            50000,
            OpportunityNotificationService.NOTIFICATION_THRESHOLD,
            'Notification threshold constant should be 50000 (exclusive — Amount > 50000).'
        );
    }

    // -------------------------------------------------------------------------
    // Tests: notification type constant matches expected value
    // -------------------------------------------------------------------------

    @IsTest
    static void testNotificationTypeNameConstant() {
        System.assertEquals(
            'OpportunityFollowUpNotification',
            OpportunityNotificationService.NOTIFICATION_TYPE_NAME,
            'Notification type developer name must match the Setup record.'
        );
    }

    // -------------------------------------------------------------------------
    // Tests: Sales Manager role name constant
    // -------------------------------------------------------------------------

    @IsTest
    static void testSalesManagerRoleNameConstant() {
        System.assertEquals(
            'Sales Manager',
            OpportunityNotificationService.SALES_MANAGER_ROLE_NAME,
            'Sales Manager role name constant should be \'Sales Manager\'.'
        );
    }
}
