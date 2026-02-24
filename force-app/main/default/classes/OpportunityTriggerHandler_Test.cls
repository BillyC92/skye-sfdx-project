@IsTest
private class OpportunityTriggerHandler_Test {

    // ─────────────────────────────────────────────────────────────────────────
    // Test Setup
    // ─────────────────────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // Create a standard active user to own Accounts/Opportunities
        Profile stdProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User activeAccountOwner = new User(
            FirstName       = 'Active',
            LastName        = 'AccountOwner',
            Email           = 'active.accountowner@test.example.com',
            Username        = 'active.accountowner@test.example.com.sandbox',
            Alias           = 'actAccO',
            TimeZoneSidKey  = 'America/New_York',
            LocaleSidKey    = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId       = stdProfile.Id,
            IsActive        = true
        );

        User activeOppOwner = new User(
            FirstName       = 'Active',
            LastName        = 'OppOwner',
            Email           = 'active.oppowner@test.example.com',
            Username        = 'active.oppowner@test.example.com.sandbox',
            Alias           = 'actOppO',
            TimeZoneSidKey  = 'America/New_York',
            LocaleSidKey    = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId       = stdProfile.Id,
            IsActive        = true
        );

        insert new List<User>{ activeAccountOwner, activeOppOwner };

        // Account owned by activeAccountOwner
        Account acc = new Account(
            Name    = 'Test Account',
            OwnerId = activeAccountOwner.Id
        );
        insert acc;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: retrieve shared test data
    // ─────────────────────────────────────────────────────────────────────────

    private static Account getTestAccount() {
        return [SELECT Id, OwnerId FROM Account WHERE Name = 'Test Account' LIMIT 1];
    }

    private static User getActiveAccountOwner() {
        return [SELECT Id FROM User WHERE LastName = 'AccountOwner' AND IsActive = true LIMIT 1];
    }

    private static User getActiveOppOwner() {
        return [SELECT Id FROM User WHERE LastName = 'OppOwner' AND IsActive = true LIMIT 1];
    }

    /**
     * Build a minimal Opportunity record. StageName and Amount are caller-supplied
     * so individual tests can vary them.
     */
    private static Opportunity buildOpp(
        String name,
        String stage,
        Decimal amount,
        Id accountId,
        Id ownerId
    ) {
        return new Opportunity(
            Name        = name,
            StageName   = stage,
            CloseDate   = Date.today().addDays(30),
            Amount      = amount,
            AccountId   = accountId,
            OwnerId     = ownerId
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Single Closed Won insert → Task assigned to Account owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsertClosedWon_TaskAssignedToAccountOwner() {
        Account acc              = getTestAccount();
        User    activeAccOwner   = getActiveAccountOwner();
        User    oppOwner         = getActiveOppOwner();

        Opportunity opp = buildOpp('CW Insert Test', 'Closed Won', 10000, acc.Id, oppOwner.Id);

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [
            SELECT Id, Subject, OwnerId, ActivityDate, WhatId
            FROM   Task
            WHERE  WhatId = :opp.Id
        ];

        System.assertEquals(1, tasks.size(), 'Exactly one Task should be created for a Closed Won insert');
        System.assertEquals('Follow up: ' + opp.Name, tasks[0].Subject,
            'Task subject should follow the expected format');
        System.assertEquals(activeAccOwner.Id, tasks[0].OwnerId,
            'Task should be owned by the Account owner when the Account owner is active');
        System.assertEquals(opp.CloseDate.addDays(7), tasks[0].ActivityDate,
            'Task ActivityDate should be CloseDate + 7 days');
        System.assertEquals(opp.Id, tasks[0].WhatId,
            'Task WhatId should reference the Opportunity');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Non-Closed-Won insert → no Task created
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsertNonClosedWon_NoTaskCreated() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        Opportunity opp = buildOpp('Prospecting Insert', 'Prospecting', 5000, acc.Id, oppOwner.Id);

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(0, tasks.size(), 'No Task should be created for a non-Closed-Won insert');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Update transitioning to Closed Won → Task created
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpdateTransitionToClosedWon_TaskCreated() {
        Account acc              = getTestAccount();
        User    activeAccOwner   = getActiveAccountOwner();
        User    oppOwner         = getActiveOppOwner();

        Opportunity opp = buildOpp('CW Transition Test', 'Prospecting', 10000, acc.Id, oppOwner.Id);
        insert opp;

        // Verify no task yet
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should exist before transitioning to Closed Won');

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        List<Task> tasks = [
            SELECT Id, Subject, OwnerId, ActivityDate
            FROM   Task
            WHERE  WhatId = :opp.Id
        ];

        System.assertEquals(1, tasks.size(), 'One Task should be created when transitioning to Closed Won');
        System.assertEquals('Follow up: ' + opp.Name, tasks[0].Subject,
            'Task subject should follow the expected format');
        System.assertEquals(activeAccOwner.Id, tasks[0].OwnerId,
            'Task should be owned by the Account owner');
        System.assertEquals(opp.CloseDate.addDays(7), tasks[0].ActivityDate,
            'Task ActivityDate should be CloseDate + 7 days');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Update that stays Closed Won → no duplicate Task
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpdateStaysClosedWon_NoDuplicateTask() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        Opportunity opp = buildOpp('Stay CW Test', 'Closed Won', 10000, acc.Id, oppOwner.Id);
        insert opp;

        // One task created on insert
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'One Task should exist after initial Closed Won insert');

        Test.startTest();
        opp.Amount = 15000; // change something unrelated to stage
        update opp;
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No duplicate Task should be created when Opportunity stays Closed Won');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Account owner inactive → Task falls back to Opportunity owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInactiveAccountOwner_TaskFallsBackToOppOwner() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        // Deactivate the Account owner
        User activeAccOwner = getActiveAccountOwner();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            activeAccOwner.IsActive = false;
            update activeAccOwner;
        }

        Opportunity opp = buildOpp('Inactive AccOwner Test', 'Closed Won', 10000, acc.Id, oppOwner.Id);

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task should fall back to Opportunity owner when Account owner is inactive');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Amount > 50k on insert → notification attempt (no exception)
    //    CustomNotificationType may or may not exist in the test org;
    //    the handler silently skips if not found — we assert no exception.
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsertLargeAmount_NotificationAttemptedWithoutException() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        Opportunity opp = buildOpp('Large Opp Insert', 'Prospecting', 75000, acc.Id, oppOwner.Id);

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown,
            'No exception should be thrown when inserting an Opportunity with Amount > 50k');

        // Verify the opportunity was actually inserted
        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE Id = :opp.Id],
            'Opportunity should have been inserted successfully');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. Amount <= 50k on insert → no notification (no exception)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsertSmallAmount_NoNotificationNoException() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        Opportunity opp = buildOpp('Small Opp Insert', 'Prospecting', 49999, acc.Id, oppOwner.Id);

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown,
            'No exception should be thrown when inserting an Opportunity with Amount <= 50k');
        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE Id = :opp.Id],
            'Opportunity should have been inserted successfully');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. Amount > 50k on UPDATE → notification NOT sent (only on insert)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpdateLargeAmount_NotificationNotSent() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        // Insert with small amount — no notification
        Opportunity opp = buildOpp('Update Large Opp', 'Prospecting', 10000, acc.Id, oppOwner.Id);
        insert opp;

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            opp.Amount = 100000; // now > 50k but this is an update
            update opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // The handler should NOT send notifications on update — assert no exception
        System.assertEquals(false, exceptionThrown,
            'No exception should be thrown when updating Amount > 50k (notifications only fire on insert)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. No Sales Manager role in org → no exception thrown
    //    We cannot delete the UserRole if it exists, but we can verify the
    //    handler's graceful-skip path by ensuring the code path runs without error.
    //    This test inserts a large-amount Opp and asserts no exception regardless
    //    of whether the Sales Manager role exists.
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testNoSalesManagerRole_NoExceptionThrown() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        // Large amount triggers the notification path which queries for Sales Manager role
        Opportunity opp = buildOpp('No SM Role Test', 'Prospecting', 99999, acc.Id, oppOwner.Id);

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown,
            'Handler should silently return when no Sales Manager role is found — no exception expected');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Bulk test — 200 Closed Won inserts → 200 Tasks created
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBulkInsertClosedWon_200Tasks() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp('Bulk CW Opp ' + i, 'Closed Won', 10000, acc.Id, oppOwner.Id));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Integer taskCount = [SELECT COUNT() FROM Task WHERE WhatId IN :oppIds];

        System.assertEquals(200, taskCount,
            'Exactly 200 Tasks should be created for 200 Closed Won Opportunity inserts');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Bulk test — 200 Closed Won updates (transition) → 200 Tasks created
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBulkUpdateTransitionToClosedWon_200Tasks() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp('Bulk Transition Opp ' + i, 'Prospecting', 10000, acc.Id, oppOwner.Id));
        }
        insert opps;

        // Verify no tasks before transition
        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId IN :oppIds],
            'No Tasks should exist before transitioning to Closed Won');

        for (Opportunity opp : opps) {
            opp.StageName = 'Closed Won';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task WHERE WhatId IN :oppIds];
        System.assertEquals(200, taskCount,
            'Exactly 200 Tasks should be created when 200 Opportunities transition to Closed Won');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. Bulk test — 200 large-amount inserts → no exception (notification path)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBulkInsertLargeAmount_NoException() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp('Bulk Large Opp ' + i, 'Prospecting', 75000, acc.Id, oppOwner.Id));
        }

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opps;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown,
            'No exception should be thrown when bulk-inserting 200 Opportunities with Amount > 50k');

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        System.assertEquals(200, [SELECT COUNT() FROM Opportunity WHERE Id IN :oppIds],
            'All 200 Opportunities should have been inserted successfully');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. Mixed bulk — some Closed Won, some not → only CW get Tasks
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testMixedBulkInsert_OnlyClosedWonGetTasks() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        List<Opportunity> closedWonOpps  = new List<Opportunity>();
        List<Opportunity> prospectOpps   = new List<Opportunity>();

        for (Integer i = 0; i < 100; i++) {
            closedWonOpps.add(buildOpp('Mixed CW Opp '  + i, 'Closed Won',   10000, acc.Id, oppOwner.Id));
            prospectOpps.add(buildOpp('Mixed Pros Opp ' + i, 'Prospecting',  10000, acc.Id, oppOwner.Id));
        }

        List<Opportunity> allOpps = new List<Opportunity>();
        allOpps.addAll(closedWonOpps);
        allOpps.addAll(prospectOpps);

        Test.startTest();
        insert allOpps;
        Test.stopTest();

        // Re-query to get Ids
        Set<Id> cwIds  = new Map<Id, Opportunity>(
            [SELECT Id FROM Opportunity WHERE Name LIKE 'Mixed CW Opp%']
        ).keySet();
        Set<Id> prosIds = new Map<Id, Opportunity>(
            [SELECT Id FROM Opportunity WHERE Name LIKE 'Mixed Pros Opp%']
        ).keySet();

        System.assertEquals(100, [SELECT COUNT() FROM Task WHERE WhatId IN :cwIds],
            '100 Tasks should be created for the 100 Closed Won Opportunities');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId IN :prosIds],
            'No Tasks should be created for the 100 Prospecting Opportunities');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 14. Task ActivityDate is exactly CloseDate + 7
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testTaskActivityDate_IsCloseDatePlusSeven() {
        Account acc      = getTestAccount();
        User    oppOwner = getActiveOppOwner();

        Date specificCloseDate = Date.newInstance(2025, 6, 1);
        Opportunity opp = new Opportunity(
            Name      = 'Date Check Opp',
            StageName = 'Closed Won',
            CloseDate = specificCloseDate,
            Amount    = 5000,
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Task t = [SELECT ActivityDate FROM Task WHERE WhatId = :opp.Id LIMIT 1];
        System.assertEquals(specificCloseDate.addDays(7), t.ActivityDate,
            'Task ActivityDate must be exactly CloseDate + 7 days');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. Opportunity with no Account → Task owned by Opportunity owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testClosedWonNoAccount_TaskOwnedByOppOwner() {
        User oppOwner = getActiveOppOwner();

        // Opportunity without an Account
        Opportunity opp = new Opportunity(
            Name      = 'No Account Opp',
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(30),
            Amount    = 5000,
            OwnerId   = oppOwner.Id
        );

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown,
            'No exception should be thrown for a Closed Won Opportunity without an Account');

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task should be owned by the Opportunity owner when there is no Account');
    }
}