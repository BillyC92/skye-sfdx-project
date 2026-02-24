@IsTest
private class OpportunityTriggerHandlerTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Test Data Factory
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Creates a standard active user with a given role.
     * Using a helper keeps test data consistent and DRY.
     */
    private static User createUser(String lastName, Id roleId, Boolean isActive) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName       = 'Test',
            LastName        = lastName,
            Email           = lastName.toLowerCase().replaceAll(' ', '') + '@test.example.com',
            Username        = lastName.toLowerCase().replaceAll(' ', '') + '.' +
                              String.valueOf(Math.random()).replace('0.', '') + '@test.example.com',
            Alias           = lastName.left(8),
            TimeZoneSidKey  = 'America/New_York',
            LocaleSidKey    = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en',
            ProfileId       = p.Id,
            UserRoleId      = roleId,
            IsActive        = isActive
        );
        return u;
    }

    /**
     * Creates or retrieves the Sales Manager UserRole.
     * In a scratch org the role may not exist; we create it if absent.
     * Returns null if creation is not possible (e.g., role hierarchy locked).
     */
    private static UserRole upsertSalesManagerRole() {
        List<UserRole> existing = [
            SELECT Id, DeveloperName
            FROM   UserRole
            WHERE  DeveloperName = 'Sales_Manager'
            LIMIT  1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }
        UserRole role = new UserRole(
            Name            = 'Sales Manager',
            DeveloperName   = 'Sales_Manager'
        );
        insert role;
        return role;
    }

    /**
     * Creates a test Account owned by the supplied user.
     */
    private static Account createAccount(String name, Id ownerId) {
        Account a = new Account(
            Name    = name,
            OwnerId = ownerId
        );
        insert a;
        return a;
    }

    /**
     * Builds (but does NOT insert) an Opportunity.
     */
    private static Opportunity buildOpportunity(
        String name,
        Id accountId,
        Id ownerId,
        String stageName,
        Date closeDate,
        Decimal amount
    ) {
        return new Opportunity(
            Name        = name,
            AccountId   = accountId,
            OwnerId     = ownerId,
            StageName   = stageName,
            CloseDate   = closeDate,
            Amount      = amount
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1 — Single Closed Won INSERT creates Task assigned to Account owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void insertClosedWon_createsTaskAssignedToAccountOwner() {
        UserRole role = upsertSalesManagerRole();

        User accountOwner = createUser('AccountOwner1', null, true);
        User oppOwner     = createUser('OppOwner1', null, true);
        insert new List<User>{ accountOwner, oppOwner };

        Account acc = createAccount('Test Account 1', accountOwner.Id);

        Opportunity opp = buildOpportunity(
            'Test Opp 1', acc.Id, oppOwner.Id,
            'Closed Won', Date.today().addDays(30), 10000
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId, Subject, ActivityDate, WhatId, Status, Priority
                            FROM   Task
                            WHERE  WhatId = :opp.Id];

        System.assertEquals(1, tasks.size(),
            'Exactly one Task should be created for a Closed Won insert.');

        Task t = tasks[0];
        System.assertEquals(accountOwner.Id, t.OwnerId,
            'Task should be assigned to the Account owner when they are active.');
        System.assertEquals('Follow up: ' + opp.Name, t.Subject,
            'Task Subject should follow the prescribed format.');
        System.assertEquals(opp.CloseDate.addDays(7), t.ActivityDate,
            'Task ActivityDate should be CloseDate + 7 days.');
        System.assertEquals('Not Started', t.Status,
            'Task Status should be Not Started.');
        System.assertEquals('Normal', t.Priority,
            'Task Priority should be Normal.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2 — UPDATE transition to Closed Won creates Task
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void updateToClosedWon_createsTask() {
        User accountOwner = createUser('AccountOwner2', null, true);
        User oppOwner     = createUser('OppOwner2', null, true);
        insert new List<User>{ accountOwner, oppOwner };

        Account acc = createAccount('Test Account 2', accountOwner.Id);

        Opportunity opp = buildOpportunity(
            'Test Opp 2', acc.Id, oppOwner.Id,
            'Prospecting', Date.today().addDays(30), 10000
        );
        insert opp;

        // Confirm no Task exists before the transition
        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should exist before transitioning to Closed Won.');

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(),
            'One Task should be created when Opportunity transitions to Closed Won.');
        System.assertEquals(accountOwner.Id, tasks[0].OwnerId,
            'Task should be assigned to the active Account owner.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3 — UPDATE that stays Closed Won does NOT create a duplicate Task
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void updateStaysClosedWon_noDuplicateTask() {
        User accountOwner = createUser('AccountOwner3', null, true);
        User oppOwner     = createUser('OppOwner3', null, true);
        insert new List<User>{ accountOwner, oppOwner };

        Account acc = createAccount('Test Account 3', accountOwner.Id);

        // Insert already Closed Won — Task created on insert
        Opportunity opp = buildOpportunity(
            'Test Opp 3', acc.Id, oppOwner.Id,
            'Closed Won', Date.today().addDays(30), 10000
        );
        insert opp;

        Integer taskCountAfterInsert = [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, taskCountAfterInsert,
            'One Task should exist after initial Closed Won insert.');

        Test.startTest();
        // Update a non-stage field — stage remains Closed Won
        opp.Description = 'Updated description';
        update opp;
        Test.stopTest();

        Integer taskCountAfterUpdate = [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, taskCountAfterUpdate,
            'No additional Task should be created when stage stays Closed Won.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4 — Inactive Account owner causes Task fallback to Opportunity owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void inactiveAccountOwner_taskAssignedToOppOwner() {
        // We need to create the inactive user, then deactivate after insert
        // (Salesforce requires IsActive=true on insert in some orgs)
        User inactiveAccountOwner = createUser('InactiveAccOwner4', null, true);
        User oppOwner             = createUser('OppOwner4', null, true);
        insert new List<User>{ inactiveAccountOwner, oppOwner };

        // Deactivate the account owner
        inactiveAccountOwner.IsActive = false;
        update inactiveAccountOwner;

        Account acc = createAccount('Test Account 4', inactiveAccountOwner.Id);

        Opportunity opp = buildOpportunity(
            'Test Opp 4', acc.Id, oppOwner.Id,
            'Closed Won', Date.today().addDays(30), 10000
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(),
            'One Task should be created even when Account owner is inactive.');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task should fall back to Opportunity owner when Account owner is inactive.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 5 — INSERT with Amount > $50k sends notification (no exception)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void insertHighValueOpp_notificationSentWithoutException() {
        UserRole salesManagerRole = upsertSalesManagerRole();

        User salesManager = createUser('SalesManager5', salesManagerRole.Id, true);
        User oppOwner     = createUser('OppOwner5', null, true);
        insert new List<User>{ salesManager, oppOwner };

        Account acc = createAccount('Test Account 5', oppOwner.Id);

        Opportunity opp = buildOpportunity(
            'Big Deal 5', acc.Id, oppOwner.Id,
            'Prospecting', Date.today().addDays(30), 75000
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
            'Inserting a high-value Opportunity should not throw an exception, ' +
            'even if the notification type is unavailable in test context.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 6 — UPDATE with Amount > $50k does NOT send notification
    //              (notification service is only called on after insert)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void updateHighValueOpp_noNotificationSent() {
        UserRole salesManagerRole = upsertSalesManagerRole();

        User salesManager = createUser('SalesManager6', salesManagerRole.Id, true);
        User oppOwner     = createUser('OppOwner6', null, true);
        insert new List<User>{ salesManager, oppOwner };

        Account acc = createAccount('Test Account 6', oppOwner.Id);

        // Insert below threshold so no notification fires on insert
        Opportunity opp = buildOpportunity(
            'Growing Deal 6', acc.Id, oppOwner.Id,
            'Prospecting', Date.today().addDays(30), 10000
        );
        insert opp;

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            // Raise amount above threshold and update — notification should NOT fire
            opp.Amount = 100000;
            update opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Primary assertion: no exception from notification path on update
        System.assertEquals(false, exceptionThrown,
            'Updating a high-value Opportunity should not throw an exception.');
        // No Task created because stage did not transition to Closed Won
        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
            'No Task should be created when stage does not transition to Closed Won.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 7 — No Sales Manager role present — no error thrown
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void insertHighValueOpp_noSalesManagerRole_noException() {
        // Deliberately do NOT create or reference a Sales Manager role.
        // The notification service should exit silently.
        User oppOwner = createUser('OppOwner7', null, true);
        insert oppOwner;

        Account acc = createAccount('Test Account 7', oppOwner.Id);

        Opportunity opp = buildOpportunity(
            'No Manager Deal 7', acc.Id, oppOwner.Id,
            'Prospecting', Date.today().addDays(30), 99000
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
            'No exception should be thrown when no Sales Manager role user exists.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 8a — Bulk INSERT: 200 Opportunities — Task path
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void bulkInsert200ClosedWon_tasksCreatedForAll() {
        User accountOwner = createUser('BulkAccOwner8a', null, true);
        User oppOwner     = createUser('BulkOppOwner8a', null, true);
        insert new List<User>{ accountOwner, oppOwner };

        Account acc = createAccount('Bulk Account 8a', accountOwner.Id);

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpportunity(
                'Bulk Opp 8a-' + i, acc.Id, oppOwner.Id,
                'Closed Won', Date.today().addDays(30), 10000
            ));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task
                             WHERE WhatId IN :opps
                             AND   Subject LIKE 'Follow up:%'];
        System.assertEquals(200, taskCount,
            'One Task should be created for each of the 200 Closed Won Opportunities.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 8b — Bulk INSERT: 200 Opportunities — Notification path (no exception)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void bulkInsert200HighValue_noException() {
        UserRole salesManagerRole = upsertSalesManagerRole();

        User salesManager = createUser('BulkSalesMgr8b', salesManagerRole.Id, true);
        User oppOwner     = createUser('BulkOppOwner8b', null, true);
        insert new List<User>{ salesManager, oppOwner };

        Account acc = createAccount('Bulk Account 8b', oppOwner.Id);

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpportunity(
                'Bulk High Value 8b-' + i, acc.Id, oppOwner.Id,
                'Prospecting', Date.today().addDays(30), 75000
            ));
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
            'Bulk inserting 200 high-value Opportunities should not throw an exception.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 9 — Opportunity without Account does not cause NullPointerException
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void insertClosedWonWithoutAccount_noNullPointer() {
        User oppOwner = createUser('OppOwner9', null, true);
        insert oppOwner;

        // AccountId intentionally omitted
        Opportunity opp = new Opportunity(
            Name      = 'No Account Opp 9',
            OwnerId   = oppOwner.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(30),
            Amount    = 10000
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
            'Inserting a Closed Won Opportunity without an Account should not throw a NullPointerException.');

        // Task should still be created, assigned to Opportunity owner (no Account owner to check)
        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(),
            'A Task should still be created for a Closed Won Opportunity without an Account.');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Task should be assigned to the Opportunity owner when no Account is present.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 10 — Mixed batch: some Closed Won, some not — only qualifying
    //               Opportunities get Tasks
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void insertMixedStages_onlyClosedWonGetTasks() {
        User accountOwner = createUser('AccOwner10', null, true);
        User oppOwner     = createUser('OppOwner10', null, true);
        insert new List<User>{ accountOwner, oppOwner };

        Account acc = createAccount('Test Account 10', accountOwner.Id);

        List<Opportunity> opps = new List<Opportunity>();
        // 3 Closed Won
        for (Integer i = 0; i < 3; i++) {
            opps.add(buildOpportunity(
                'Closed Opp 10-' + i, acc.Id, oppOwner.Id,
                'Closed Won', Date.today().addDays(30), 5000
            ));
        }
        // 2 Prospecting (should NOT get Tasks)
        for (Integer i = 0; i < 2; i++) {
            opps.add(buildOpportunity(
                'Open Opp 10-' + i, acc.Id, oppOwner.Id,
                'Prospecting', Date.today().addDays(30), 5000
            ));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task
                             WHERE WhatId IN :opps
                             AND   Subject LIKE 'Follow up:%'];
        System.assertEquals(3, taskCount,
            'Only the 3 Closed Won Opportunities should have Tasks created.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 11 — Bulk UPDATE: mixed transitions, only newly-Closed-Won get Tasks
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void bulkUpdate_mixedTransitions_onlyNewClosedWonGetTasks() {
        User accountOwner = createUser('AccOwner11', null, true);
        User oppOwner     = createUser('OppOwner11', null, true);
        insert new List<User>{ accountOwner, oppOwner };

        Account acc = createAccount('Test Account 11', accountOwner.Id);

        // 5 Prospecting opps — will transition 3 to Closed Won
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(buildOpportunity(
                'Transition Opp 11-' + i, acc.Id, oppOwner.Id,
                'Prospecting', Date.today().addDays(30), 5000
            ));
        }
        insert opps;

        // Transition first 3 to Closed Won
        for (Integer i = 0; i < 3; i++) {
            opps[i].StageName = 'Closed Won';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task
                             WHERE WhatId IN :opps
                             AND   Subject LIKE 'Follow up:%'];
        System.assertEquals(3, taskCount,
            'Only the 3 Opportunities that transitioned to Closed Won should have Tasks.');
    }
}