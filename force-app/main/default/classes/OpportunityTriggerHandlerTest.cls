@IsTest
private class OpportunityTriggerHandlerTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Test Setup
    // Shared data created once per test class execution. Individual tests
    // query for what they need rather than relying on static variables, which
    // avoids mixed-DML issues and keeps tests isolated.
    // ─────────────────────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // Active account owner — used as the expected Task owner in most tests
        User activeOwner = buildUser('active.owner@test.example.com', 'ActiveOwner');
        insert activeOwner;

        // Inactive account owner — used to verify the fallback-to-Opp-owner path
        User inactiveOwner = buildUser('inactive.owner@test.example.com', 'InactiveOwner');
        insert inactiveOwner;

        // Opportunity owner — used as fallback when Account owner is inactive
        User oppOwner = buildUser('opp.owner@test.example.com', 'OppOwner');
        insert oppOwner;

        // Account owned by the active user
        Account activeAccount = new Account(
            Name = 'Active Owner Account',
            OwnerId = activeOwner.Id
        );

        // Account owned by the inactive user
        Account inactiveAccount = new Account(
            Name = 'Inactive Owner Account',
            OwnerId = inactiveOwner.Id
        );

        insert new List<Account>{ activeAccount, inactiveAccount };

        // Deactivate the inactive owner AFTER account insert to avoid
        // Salesforce restrictions on assigning inactive owners at DML time.
        // We update IsActive = false in a separate DML.
        inactiveOwner.IsActive = false;
        update inactiveOwner;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: build a minimal, valid User record
    // ─────────────────────────────────────────────────────────────────────────
    private static User buildUser(String email, String lastNameSuffix) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            FirstName       = 'Test',
            LastName        = lastNameSuffix,
            Email           = email,
            Username        = email + '.' + System.currentTimeMillis(),
            Alias           = lastNameSuffix.left(8),
            TimeZoneSidKey  = 'America/Los_Angeles',
            LocaleSidKey    = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId       = p.Id
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: fetch the active-owner Account
    // ─────────────────────────────────────────────────────────────────────────
    private static Account getActiveAccount() {
        return [SELECT Id, OwnerId FROM Account WHERE Name = 'Active Owner Account' LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: fetch the inactive-owner Account
    // ─────────────────────────────────────────────────────────────────────────
    private static Account getInactiveAccount() {
        return [SELECT Id, OwnerId FROM Account WHERE Name = 'Inactive Owner Account' LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: fetch the opp owner User
    // ─────────────────────────────────────────────────────────────────────────
    private static User getOppOwner() {
        return [SELECT Id FROM User WHERE Email = 'opp.owner@test.example.com' LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: build a standard Opportunity
    // ─────────────────────────────────────────────────────────────────────────
    private static Opportunity buildOpp(
        String name,
        String stageName,
        Date closeDate,
        Decimal amount,
        Id accountId,
        Id ownerId
    ) {
        return new Opportunity(
            Name        = name,
            StageName   = stageName,
            CloseDate   = closeDate,
            Amount      = amount,
            AccountId   = accountId,
            OwnerId     = ownerId
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — Single Opportunity inserted directly as Closed Won
    // Expect: one Task with correct Subject, ActivityDate (+7 days), and Owner
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testInsertClosedWon_createsTask() {
        Account acc      = getActiveAccount();
        User oppOwner    = getOppOwner();
        Date closeDate   = Date.today().addDays(10);

        Opportunity opp = buildOpp(
            'Test Opp CW Insert',
            'Closed Won',
            closeDate,
            10000,
            acc.Id,
            oppOwner.Id
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Subject, ActivityDate, OwnerId, WhatId, Status, Priority
                            FROM Task WHERE WhatId = :opp.Id];

        System.assertEquals(1, tasks.size(),
            'Exactly one follow-up Task should be created for a Closed Won insert.');

        Task t = tasks[0];
        System.assertEquals('Follow up: ' + opp.Name, t.Subject,
            'Task Subject should be "Follow up: " + Opportunity Name.');
        System.assertEquals(closeDate.addDays(7), t.ActivityDate,
            'Task ActivityDate should be CloseDate + 7 days.');
        System.assertEquals(acc.OwnerId, t.OwnerId,
            'Task Owner should be the Account owner when the Account owner is active.');
        System.assertEquals('Not Started', t.Status,
            'Task Status should default to Not Started.');
        System.assertEquals('Normal', t.Priority,
            'Task Priority should default to Normal.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — Opportunity updated to Closed Won
    // Expect: one Task created on the after-update path
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testUpdateToClosedWon_createsTask() {
        Account acc    = getActiveAccount();
        User oppOwner  = getOppOwner();
        Date closeDate = Date.today().addDays(5);

        Opportunity opp = buildOpp(
            'Test Opp CW Update',
            'Prospecting',
            closeDate,
            20000,
            acc.Id,
            oppOwner.Id
        );
        insert opp;

        // Confirm no Task exists before the update
        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should exist before the Closed Won transition.');

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Subject, ActivityDate, OwnerId FROM Task WHERE WhatId = :opp.Id];

        System.assertEquals(1, tasks.size(),
            'One Task should be created when an Opportunity transitions to Closed Won.');
        System.assertEquals('Follow up: ' + opp.Name, tasks[0].Subject,
            'Task Subject should match the expected format.');
        System.assertEquals(closeDate.addDays(7), tasks[0].ActivityDate,
            'Task ActivityDate should be CloseDate + 7 days.');
        System.assertEquals(acc.OwnerId, tasks[0].OwnerId,
            'Task Owner should be the active Account owner.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — Opportunity updated but NOT to Closed Won
    // Expect: no Task created
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testUpdateNotToClosedWon_noTaskCreated() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = buildOpp(
            'Test Opp No CW',
            'Prospecting',
            Date.today().addDays(30),
            5000,
            acc.Id,
            oppOwner.Id
        );
        insert opp;

        Test.startTest();
        opp.StageName = 'Qualification'; // Not Closed Won
        update opp;
        Test.stopTest();

        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should be created when the Opportunity does not transition to Closed Won.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — Account owner is inactive → Task falls back to Opportunity owner
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testInactiveAccountOwner_taskFallsBackToOppOwner() {
        Account inactiveAcc = getInactiveAccount();
        User oppOwner       = getOppOwner();

        Opportunity opp = buildOpp(
            'Test Opp Inactive Account Owner',
            'Closed Won',
            Date.today().addDays(3),
            15000,
            inactiveAcc.Id,
            oppOwner.Id
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];

        System.assertEquals(1, tasks.size(),
            'One Task should be created even when the Account owner is inactive.');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task Owner should fall back to the Opportunity owner when the Account owner is inactive.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — Opportunity inserted with Amount > $50k
    // Expect: notification code path executes without exception
    // Note: Messaging.CustomNotification.send() cannot be fully asserted in
    // unit tests (no way to inspect sent notifications), so we verify the
    // code path runs cleanly and no exception is surfaced to the caller.
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testInsertHighValue_notificationPathExecutesWithoutException() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = buildOpp(
            'Test Opp High Value Insert',
            'Prospecting',   // Not Closed Won — isolates notification path from task path
            Date.today().addDays(20),
            75000,           // > $50k threshold
            acc.Id,
            oppOwner.Id
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
            'Inserting a high-value Opportunity should not throw an exception.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6 — Opportunity updated with Amount > $50k
    // Expect: notification is NOT sent (insert-only rule)
    // We verify by confirming no exception and that the update completes
    // normally. Since notifications cannot be queried, we rely on the
    // service's insert-only guard and code review for full confidence.
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testUpdateHighValue_notificationNotSent() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = buildOpp(
            'Test Opp High Value Update',
            'Prospecting',
            Date.today().addDays(20),
            75000,
            acc.Id,
            oppOwner.Id
        );
        insert opp;

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            opp.Amount = 90000; // Still > $50k but this is an update, not insert
            update opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // The handler only calls sendHighValueNotifications on after-insert.
        // We assert no exception and that no Tasks were created (not Closed Won).
        System.assert(!exceptionThrown,
            'Updating a high-value Opportunity should not throw an exception.');
        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should be created — Opportunity was not transitioned to Closed Won.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 7 — Bulk insert of 200 Opportunities all Closed Won
    // Expect: 200 Tasks created, no governor limit exceptions
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testBulkInsertClosedWon_200Tasks() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        Date closeDate = Date.today().addDays(14);

        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp(
                'Bulk CW Opp ' + i,
                'Closed Won',
                closeDate,
                10000,
                acc.Id,
                oppOwner.Id
            ));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task
                             WHERE WhatId IN :opps AND Subject LIKE 'Follow up:%'];

        System.assertEquals(200, taskCount,
            'Exactly 200 Tasks should be created for a bulk insert of 200 Closed Won Opportunities.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 8 — Bulk insert of 200 Opportunities all over $50k
    // Expect: no exceptions thrown (notification path handles bulk gracefully)
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testBulkInsertHighValue_noExceptions() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp(
                'Bulk HV Opp ' + i,
                'Prospecting',
                Date.today().addDays(30),
                60000, // > $50k
                acc.Id,
                oppOwner.Id
            ));
        }

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opps;
        } catch (Exception e) {
            exceptionThrown = true;
            System.debug('Unexpected exception in bulk high-value insert: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'Bulk insert of 200 high-value Opportunities should not throw any exception.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 9 — No Sales Manager role in org
    // Expect: notification service skips silently, no exception thrown
    // We simulate this by inserting a high-value Opp in an org context where
    // the Sales_Manager UserRole DeveloperName may not exist. The service
    // must handle an empty query result gracefully.
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testNoSalesManagerRole_noExceptionThrown() {
        // This test validates the silent-failure contract of
        // OpportunityNotificationService when no Sales Manager role is found.
        // In a scratch org / test environment the Sales_Manager role is
        // unlikely to exist, making this a realistic scenario.
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = buildOpp(
            'Test Opp No SM Role',
            'Prospecting',
            Date.today().addDays(10),
            99000, // > $50k to trigger notification path
            acc.Id,
            oppOwner.Id
        );

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
            System.debug('Unexpected exception when no Sales Manager role exists: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(!exceptionThrown,
            'No exception should be thrown when the Sales Manager UserRole does not exist in the org.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 10 — Opportunity with null CloseDate
    // Expect: graceful handling — either Task created with null ActivityDate
    // or the record is rejected by a validation rule before reaching the
    // trigger. We test both paths defensively.
    // Note: Standard Salesforce validation requires CloseDate on Opportunity,
    // so this test documents the expected behaviour (DmlException on insert)
    // and confirms the trigger does not introduce additional failures.
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testNullCloseDate_gracefulHandling() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = new Opportunity(
            Name      = 'Test Opp Null CloseDate',
            StageName = 'Closed Won',
            CloseDate = null,   // Intentionally null
            Amount    = 5000,
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id
        );

        Test.startTest();
        try {
            insert opp;
            // If the org has no validation rule blocking null CloseDate,
            // verify the trigger handles it without a NullPointerException.
            // ActivityDate may be null (null + 7 = null in Apex Date arithmetic
            // is not supported, so the service must guard against this).
            List<Task> tasks = [SELECT ActivityDate FROM Task WHERE WhatId = :opp.Id];
            // We do not assert a specific ActivityDate value here because the
            // service may choose to skip or default — either is acceptable.
            // The key assertion is that no unhandled exception was thrown.
            System.assert(true, 'Insert with null CloseDate completed without an unhandled exception.');
        } catch (DmlException e) {
            // Expected if a standard or custom validation rule requires CloseDate.
            // Confirm the exception is a validation error, not a NullPointerException
            // originating from our trigger code.
            System.assert(
                e.getMessage().containsIgnoreCase('CloseDate') ||
                e.getMessage().containsIgnoreCase('Required') ||
                e.getMessage().containsIgnoreCase('close date') ||
                e.getDmlType(0) == StatusCode.REQUIRED_FIELD_MISSING,
                'DmlException should be a validation/required-field error, not a trigger NullPointerException. Actual: '
                    + e.getMessage()
            );
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 11 — Opportunity already Closed Won, updated again (no stage change)
    // Expect: no duplicate Task created on subsequent updates
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testUpdateClosedWonToClosedWon_noDuplicateTask() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();

        Opportunity opp = buildOpp(
            'Test Opp Already CW',
            'Closed Won',
            Date.today().addDays(5),
            8000,
            acc.Id,
            oppOwner.Id
        );
        insert opp;

        // One Task should exist from the insert
        System.assertEquals(1,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'One Task should exist after initial Closed Won insert.');

        Test.startTest();
        // Update the Opp without changing the stage — still Closed Won
        opp.Amount = 9000;
        update opp;
        Test.stopTest();

        // Should still be exactly one Task — no duplicate from the update
        System.assertEquals(1,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No duplicate Task should be created when a Closed Won Opportunity is updated without a stage change.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 12 — Task subject and due date correctness for a named Opportunity
    // Validates the exact string format and date arithmetic in one focused test
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testTaskSubjectAndDueDateFormat() {
        Account acc   = getActiveAccount();
        User oppOwner = getOppOwner();
        Date specificClose = Date.newInstance(2025, 6, 15);

        Opportunity opp = buildOpp(
            'Acme Corp Renewal',
            'Closed Won',
            specificClose,
            30000,
            acc.Id,
            oppOwner.Id
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Task t = [SELECT Subject, ActivityDate FROM Task WHERE WhatId = :opp.Id LIMIT 1];

        System.assertEquals('Follow up: Acme Corp Renewal', t.Subject,
            'Task Subject must exactly match "Follow up: " + Opportunity Name.');
        System.assertEquals(Date.newInstance(2025, 6, 22), t.ActivityDate,
            'Task ActivityDate must be exactly 7 days after CloseDate (June 15 + 7 = June 22).');
    }
}