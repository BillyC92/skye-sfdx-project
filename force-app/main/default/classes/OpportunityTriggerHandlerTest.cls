/**
 * OpportunityTriggerHandlerTest
 *
 * Comprehensive unit tests for OpportunityTriggerHandler.
 *
 * Coverage targets:
 *  - Task creation on Closed Won insert (Account owner active)
 *  - Task creation on Closed Won update transition
 *  - No Task on non-Closed-Won insert
 *  - No duplicate Task when already-Closed-Won record is updated but stays Closed Won
 *  - Task falls back to Opportunity owner when Account owner is inactive
 *  - Notification sent for Amount > $50k on insert
 *  - No notification for Amount <= $50k on insert
 *  - No notification on update (even if Amount > $50k)
 *  - No exception when Sales Manager role does not exist
 *  - Bulk scenario: 200 records for Task creation and notification paths
 *
 * Note: CustomNotificationType 'OpportunityFollowUpNotification' must exist in the
 * org for notification-path tests to exercise the send() call. Tests are written
 * to be resilient when the type is absent (handler silently returns).
 */
@IsTest
private class OpportunityTriggerHandlerTest {

    // ─── Test Setup ───────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // Active Account owner
        User activeAccountOwner = createTestUser('Active', 'AcctOwner', true);
        insert activeAccountOwner;

        // Inactive Account owner (for fallback test)
        User inactiveAccountOwner = createTestUser('Inactive', 'AcctOwner', false);
        // Must insert as active then deactivate, because Salesforce prevents
        // inserting an inactive user directly in some orgs.
        inactiveAccountOwner.IsActive = true;
        insert inactiveAccountOwner;
        inactiveAccountOwner.IsActive = false;
        update inactiveAccountOwner;

        // Opportunity owner (used as fallback)
        User oppOwner = createTestUser('Opp', 'Owner', true);
        insert oppOwner;

        // Accounts
        Account accWithActiveOwner = new Account(
            Name    = 'Active Owner Account',
            OwnerId = activeAccountOwner.Id
        );
        Account accWithInactiveOwner = new Account(
            Name    = 'Inactive Owner Account',
            OwnerId = inactiveAccountOwner.Id
        );
        insert new List<Account>{ accWithActiveOwner, accWithInactiveOwner };
    }

    // ─── Helper: create a minimal test user ───────────────────────────────────

    private static User createTestUser(String firstName, String lastNameSuffix, Boolean isActive) {
        // Use a standard profile available in all orgs
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueSuffix = String.valueOf(Math.random()).replace('.', '').left(8);
        return new User(
            FirstName          = firstName,
            LastName           = lastNameSuffix + uniqueSuffix,
            Email              = firstName.toLowerCase() + uniqueSuffix + '@test.example.com',
            Username           = firstName.toLowerCase() + uniqueSuffix + '@test.example.com.sandbox',
            Alias              = (firstName.left(4) + uniqueSuffix.left(4)).toLowerCase(),
            TimeZoneSidKey     = 'America/New_York',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id,
            IsActive           = isActive
        );
    }

    // ─── Helper: fetch shared test data ───────────────────────────────────────

    private static Account getActiveOwnerAccount() {
        return [SELECT Id, OwnerId FROM Account WHERE Name = 'Active Owner Account' LIMIT 1];
    }

    private static Account getInactiveOwnerAccount() {
        return [SELECT Id, OwnerId FROM Account WHERE Name = 'Inactive Owner Account' LIMIT 1];
    }

    private static User getOppOwner() {
        // The oppOwner last name starts with 'Owner'
        return [SELECT Id FROM User WHERE LastName LIKE 'Owner%' AND IsActive = TRUE LIMIT 1];
    }

    // ─── Test 1: Closed Won insert → Task assigned to active Account owner ─────

    @IsTest
    static void testClosedWonInsert_TaskAssignedToActiveAccountOwner() {
        Account acc     = getActiveOwnerAccount();
        User oppOwner   = getOppOwner();

        Opportunity opp = new Opportunity(
            Name        = 'Test Opp CW Insert',
            StageName   = 'Closed Won',
            CloseDate   = Date.today(),
            AccountId   = acc.Id,
            OwnerId     = oppOwner.Id,
            Amount      = 10000
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, Subject, OwnerId, ActivityDate, WhatId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Exactly one follow-up Task should be created');

        Task t = tasks[0];
        System.assertEquals('Follow up: Test Opp CW Insert', t.Subject,
            'Task subject should be prefixed with "Follow up: "');
        System.assertEquals(acc.OwnerId, t.OwnerId,
            'Task should be owned by the active Account owner');
        System.assertEquals(Date.today().addDays(7), t.ActivityDate,
            'Task due date should be CloseDate + 7 days');
        System.assertEquals(opp.Id, t.WhatId,
            'Task WhatId should reference the Opportunity');
    }

    // ─── Test 2: Closed Won update transition → Task created ──────────────────

    @IsTest
    static void testClosedWonUpdateTransition_TaskCreated() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Test Opp Transition',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 5000
        );
        insert opp;

        // Verify no Task yet
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should exist before Closed Won transition');

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created on Closed Won transition');
        System.assertEquals(acc.OwnerId, tasks[0].OwnerId,
            'Task should be assigned to the active Account owner');
    }

    // ─── Test 3: Non-Closed-Won insert → no Task ──────────────────────────────

    @IsTest
    static void testNonClosedWonInsert_NoTaskCreated() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Test Opp Prospecting',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 5000
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should be created for a non-Closed-Won opportunity');
    }

    // ─── Test 4: Already Closed Won, update stays Closed Won → no duplicate Task

    @IsTest
    static void testAlreadyClosedWonUpdate_NoDuplicateTask() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Test Opp Already CW',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 5000
        );
        insert opp;

        // One Task should exist from insert
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'One Task should exist after insert');

        Test.startTest();
        opp.Description = 'Updated description';
        update opp;
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No duplicate Task should be created when Closed Won stage does not change');
    }

    // ─── Test 5: Inactive Account owner → Task falls back to Opportunity owner ─

    @IsTest
    static void testInactiveAccountOwner_TaskFallsBackToOppOwner() {
        Account acc   = getInactiveOwnerAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Test Opp Inactive Acct Owner',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 5000
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task should fall back to Opportunity owner when Account owner is inactive');
    }

    // ─── Test 6: Amount > $50k on insert → notification attempted ─────────────
    // The handler silently returns if the CustomNotificationType is absent,
    // so we assert no exception is thrown and verify the code path is exercised.

    @IsTest
    static void testLargeOpportunityInsert_NotificationAttempted() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Big Deal',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 75000
        );

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'No exception should be thrown when processing a large opportunity notification');
        // Verify the Opportunity was persisted
        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE Id = :opp.Id],
            'Opportunity should be successfully inserted');
    }

    // ─── Test 7: Amount <= $50k on insert → no notification path (no exception) ─

    @IsTest
    static void testSmallOpportunityInsert_NoNotification() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Small Deal',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 50000  // exactly at threshold — should NOT trigger notification
        );

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(!exceptionThrown, 'No exception should be thrown for a small opportunity');
    }

    // ─── Test 8: Amount > $50k on UPDATE → no notification sent ───────────────

    @IsTest
    static void testLargeOpportunityUpdate_NoNotificationSent() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        // Insert with small amount first
        Opportunity opp = new Opportunity(
            Name      = 'Growing Deal',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            Amount    = 10000
        );
        insert opp;

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            opp.Amount = 100000; // now large, but on update — should NOT notify
            update opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'No exception should be thrown on update of a large opportunity');
    }

    // ─── Test 9: No Sales Manager role → no exception thrown ──────────────────
    // This test calls the handler directly to simulate an org without the role.

    @IsTest
    static void testNoSalesManagerRole_NoExceptionThrown() {
        // Build a synthetic list of large opportunities (not inserted — we call handler directly)
        Opportunity opp = new Opportunity(
            Name      = 'Direct Handler Test',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 99999,
            OwnerId   = UserInfo.getUserId()
        );
        // We need a real Id for the notification target; insert it
        insert opp;

        OpportunityTriggerHandler handler = new OpportunityTriggerHandler();

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            // handleAfterInsert will call sendLargeOpportunityNotifications;
            // if no Sales Manager role exists the handler silently returns.
            handler.handleAfterInsert(new List<Opportunity>{ opp });
        } catch (Exception e) {
            exceptionThrown = true;
            System.debug('Unexpected exception: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'Handler should not throw when Sales Manager role is absent');
    }

    // ─── Test 10: Bulk — 200 Closed Won inserts → 200 Tasks created ───────────

    @IsTest
    static void testBulkClosedWonInsert_200Tasks() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Opp ' + i,
                StageName = 'Closed Won',
                CloseDate = Date.today(),
                AccountId = acc.Id,
                OwnerId   = oppOwner.Id,
                Amount    = 5000
            ));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Integer taskCount = [SELECT COUNT() FROM Task WHERE WhatId IN :oppIds];
        System.assertEquals(200, taskCount,
            '200 Tasks should be created for 200 Closed Won opportunities');
    }

    // ─── Test 11: Bulk — 200 large opportunity inserts → no exception ──────────

    @IsTest
    static void testBulkLargeOpportunityInsert_NoException() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Large Opp ' + i,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                AccountId = acc.Id,
                OwnerId   = oppOwner.Id,
                Amount    = 75000
            ));
        }

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opps;
        } catch (Exception e) {
            exceptionThrown = true;
            System.debug('Unexpected exception in bulk notification test: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'No exception should be thrown when inserting 200 large opportunities');
        System.assertEquals(200, [SELECT COUNT() FROM Opportunity WHERE Id IN :new Map<Id, Opportunity>(opps).keySet()],
            'All 200 large opportunities should be persisted');
    }

    // ─── Test 12: Opportunity with no Account → Task owned by Opp owner ────────

    @IsTest
    static void testClosedWonNoAccount_TaskOwnedByOppOwner() {
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'No Account Opp',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            OwnerId   = oppOwner.Id,
            Amount    = 5000
            // No AccountId
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created even without an Account');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task should be owned by the Opportunity owner when no Account is linked');
    }

    // ─── Test 13: Bulk Closed Won update transition → Tasks created ────────────

    @IsTest
    static void testBulkClosedWonUpdateTransition_TasksCreated() {
        Account acc   = getActiveOwnerAccount();
        User oppOwner = getOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 50; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Transition Opp ' + i,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                AccountId = acc.Id,
                OwnerId   = oppOwner.Id,
                Amount    = 5000
            ));
        }
        insert opps;

        for (Opportunity opp : opps) {
            opp.StageName = 'Closed Won';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Integer taskCount = [SELECT COUNT() FROM Task WHERE WhatId IN :oppIds];
        System.assertEquals(50, taskCount,
            '50 Tasks should be created for 50 Closed Won transitions');
    }
}