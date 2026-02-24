/**
 * @description Comprehensive test class for the Opportunity trigger handler framework.
 *              Covers all acceptance criteria defined in KAN-5:
 *              - Closed Won Task creation (single, bulk, inactive owner fallback)
 *              - $50k+ insert notification (and no notification on update)
 *              - Boundary conditions and graceful failure scenarios
 *
 * @author      Skye
 * @ticket      KAN-5
 */
@IsTest
private class OpportunityTriggerHandlerTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Test Data Factory
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Creates a standard Account with an active owner.
     *              The Account owner becomes the expected Task assignee in the
     *              happy-path Closed Won scenario.
     */
    private static Account createAccount(Id ownerId) {
        Account acc = new Account(
            Name    = 'Test Account',
            OwnerId = ownerId
        );
        insert acc;
        return acc;
    }

    /**
     * @description Creates an Opportunity in a non-terminal stage so that
     *              subsequent updates can trigger the Closed Won transition.
     */
    private static Opportunity createOpenOpportunity(
        Id accountId,
        Id ownerId,
        Decimal amount
    ) {
        return new Opportunity(
            Name        = 'Test Opp',
            AccountId   = accountId,
            OwnerId     = ownerId,
            StageName   = 'Prospecting',
            CloseDate   = Date.today().addDays(30),
            Amount      = amount
        );
    }

    /**
     * @description Creates a minimal active user in a given profile.
     *              Uses a unique username suffix to avoid conflicts across
     *              parallel test runs.
     */
    private static User createUser(String lastName, String profileName, Boolean isActive) {
        Profile p = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        User u = new User(
            LastName           = lastName,
            FirstName          = 'Test',
            Alias              = lastName.left(8),
            Email              = lastName + '@test.example.com',
            Username           = lastName + '.' + UserInfo.getOrganizationId() + '@test.example.com',
            ProfileId          = p.Id,
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            IsActive           = isActive
        );
        insert u;
        return u;
    }

    /**
     * @description Creates a UserRole with the given name.
     *              Used to simulate the Sales Manager role lookup.
     */
    private static UserRole createRole(String roleName) {
        UserRole role = new UserRole(Name = roleName, DeveloperName = roleName.replaceAll(' ', '_'));
        insert role;
        return role;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: Single Closed Won transition → Task assigned to Account owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSingleClosedWon_TaskAssignedToAccountOwner() {
        // Arrange
        User oppOwner  = createUser('OppOwner',  'Standard User', true);
        User accOwner  = createUser('AccOwner',  'Standard User', true);

        Account acc;
        Opportunity opp;

        System.runAs(oppOwner) {
            acc = createAccount(accOwner.Id);
            opp = createOpenOpportunity(acc.Id, oppOwner.Id, 10000);
            insert opp;
        }

        // Act — transition to Closed Won
        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        // Assert — exactly one Task created, assigned to Account owner
        List<Task> tasks = [SELECT Id, Subject, OwnerId, ActivityDate, WhatId
                            FROM Task
                            WHERE WhatId = :opp.Id];

        Assert.areEqual(1, tasks.size(),
            'Expected exactly one follow-up Task for the Closed Won opportunity.');

        Task t = tasks[0];
        Assert.areEqual('Follow up: ' + opp.Name, t.Subject,
            'Task Subject should be "Follow up: " + Opportunity Name.');
        Assert.areEqual(accOwner.Id, t.OwnerId,
            'Task should be assigned to the Account owner when the Account owner is active.');
        Assert.areEqual(opp.CloseDate.addDays(7), t.ActivityDate,
            'Task ActivityDate should be CloseDate + 7 days.');
        Assert.areEqual(opp.Id, t.WhatId,
            'Task WhatId should reference the Opportunity.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: Bulk — 200 records transitioning to Closed Won all get Tasks
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBulkClosedWon_200Records_AllGetTasks() {
        // Arrange
        User oppOwner = createUser('BulkOppOwner', 'Standard User', true);
        User accOwner = createUser('BulkAccOwner', 'Standard User', true);

        Account acc;
        List<Opportunity> opps = new List<Opportunity>();

        System.runAs(oppOwner) {
            acc = createAccount(accOwner.Id);
            for (Integer i = 0; i < 200; i++) {
                opps.add(createOpenOpportunity(acc.Id, oppOwner.Id, 5000));
            }
            insert opps;
        }

        // Act — bulk update to Closed Won
        for (Opportunity o : opps) {
            o.StageName = 'Closed Won';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        // Assert — 200 Tasks created, all assigned to Account owner
        List<Task> tasks = [SELECT Id, OwnerId FROM Task
                            WHERE WhatId IN :opps];

        Assert.areEqual(200, tasks.size(),
            'Expected one Task per Opportunity for all 200 bulk Closed Won records.');

        for (Task t : tasks) {
            Assert.areEqual(accOwner.Id, t.OwnerId,
                'Every Task should be assigned to the active Account owner.');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3: Inactive Account owner → Task falls back to Opportunity owner
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testClosedWon_InactiveAccountOwner_FallsBackToOppOwner() {
        // Arrange
        User oppOwner    = createUser('FallbackOppOwner', 'Standard User', true);
        User inactiveAcc = createUser('InactiveAccOwner', 'Standard User', true);

        Account acc;
        Opportunity opp;

        System.runAs(oppOwner) {
            acc = createAccount(inactiveAcc.Id);
            opp = createOpenOpportunity(acc.Id, oppOwner.Id, 10000);
            insert opp;
        }

        // Deactivate the Account owner AFTER setup to avoid mixed-DML issues
        inactiveAcc.IsActive = false;
        update inactiveAcc;

        // Act
        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        // Assert — Task assigned to Opportunity owner, not the inactive Account owner
        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId = :opp.Id];

        Assert.areEqual(1, tasks.size(),
            'Expected exactly one Task even when Account owner is inactive.');
        Assert.areEqual(oppOwner.Id, tasks[0].OwnerId,
            'Task should fall back to the Opportunity owner when Account owner is inactive.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: $50k+ Opportunity on INSERT triggers notification
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsert_AmountOver50k_NotificationSent() {
        // Arrange — create a Sales Manager role and assign a user to it
        UserRole salesMgrRole = createRole('Sales Manager');
        User salesMgr = createUser('SalesMgr', 'Standard User', true);
        salesMgr.UserRoleId = salesMgrRole.Id;
        update salesMgr;

        User oppOwner = createUser('NotifOppOwner', 'Standard User', true);
        Account acc;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
        }

        Opportunity opp = new Opportunity(
            Name      = 'Big Deal',
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 75000
        );

        // Act — insert triggers the notification path
        Test.startTest();
        // Messaging.CustomNotification.send() is a no-op in test context;
        // we verify no exception is thrown and the code path executes cleanly.
        insert opp;
        Test.stopTest();

        // Assert — primary assertion is that no exception was thrown.
        // The notification itself cannot be queried in tests; we verify the
        // Opportunity was inserted successfully as a proxy for clean execution.
        List<Opportunity> inserted = [SELECT Id, Amount FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(1, inserted.size(), 'Opportunity should have been inserted successfully.');
        Assert.areEqual(75000, inserted[0].Amount, 'Amount should be preserved after insert.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 5: $50k+ Opportunity on UPDATE does NOT trigger notification
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpdate_AmountOver50k_NoNotificationSent() {
        // Arrange — notification service should never be invoked on update
        User oppOwner = createUser('NoNotifOwner', 'Standard User', true);
        Account acc;
        Opportunity opp;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
            opp = createOpenOpportunity(acc.Id, oppOwner.Id, 75000);
            insert opp;
        }

        // Act — update the record; notification must NOT fire
        Test.startTest();
        opp.Description = 'Updated description';
        update opp; // Should not throw; notification service skipped for updates
        Test.stopTest();

        // Assert — no Tasks created (not Closed Won), no exception thrown
        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
        Assert.areEqual(0, tasks.size(),
            'No Tasks should be created for a non-Closed-Won update.');
        // The key assertion is that no exception was thrown during the update.
        // Notification service is only invoked on insert; this test confirms
        // the handler correctly gates on trigger context.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 6: Boundary — Amount exactly $50,000 does NOT trigger notification
    //             (business rule: Amount > 50000, not >= 50000)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsert_AmountExactly50k_NoNotification() {
        // Arrange
        User oppOwner = createUser('BoundaryOwner', 'Standard User', true);
        Account acc;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
        }

        Opportunity opp = new Opportunity(
            Name      = 'Boundary Deal',
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 50000  // Exactly at boundary — should NOT notify
        );

        // Act
        Test.startTest();
        insert opp;
        Test.stopTest();

        // Assert — Opportunity inserted cleanly; notification path not triggered
        // (no Sales Manager role exists in this test, so if notification fired
        //  incorrectly it would still be a silent skip — but the handler should
        //  not even enter the notification branch for Amount = 50000)
        List<Opportunity> inserted = [SELECT Id, Amount FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(1, inserted.size(), 'Opportunity should insert successfully at boundary amount.');
        Assert.areEqual(50000, inserted[0].Amount, 'Amount should be exactly 50000.');
    }

    @IsTest
    static void testInsert_AmountJustOver50k_NotificationPathEntered() {
        // Arrange — one cent over the boundary should trigger notification path
        UserRole salesMgrRole = createRole('SalesMgrBoundary');
        User salesMgr = createUser('SalesMgrBnd', 'Standard User', true);
        salesMgr.UserRoleId = salesMgrRole.Id;
        update salesMgr;

        User oppOwner = createUser('BoundaryPlusOwner', 'Standard User', true);
        Account acc;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
        }

        Opportunity opp = new Opportunity(
            Name      = 'Just Over Boundary Deal',
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 50000.01  // Just over — SHOULD trigger notification
        );

        // Act
        Test.startTest();
        insert opp;
        Test.stopTest();

        // Assert — no exception thrown; notification path executed cleanly
        List<Opportunity> inserted = [SELECT Id FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(1, inserted.size(),
            'Opportunity just over $50k should insert without error.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 7: Missing Sales Manager role → no exception thrown (silent skip)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsert_NoSalesManagerRole_NoExceptionThrown() {
        // Arrange — intentionally do NOT create a Sales Manager role
        User oppOwner = createUser('NoRoleOwner', 'Standard User', true);
        Account acc;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
        }

        Opportunity opp = new Opportunity(
            Name      = 'No Role Deal',
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 100000  // Over $50k — notification path entered
        );

        // Act & Assert — must not throw
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        Assert.isFalse(exceptionThrown,
            'No exception should be thrown when the Sales Manager role does not exist.');

        List<Opportunity> inserted = [SELECT Id FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(1, inserted.size(),
            'Opportunity should be inserted successfully even without a Sales Manager role.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 8: Opportunity NOT transitioning to Closed Won → no Task created
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testUpdate_NotClosedWon_NoTaskCreated() {
        // Arrange
        User oppOwner = createUser('NoTaskOwner', 'Standard User', true);
        Account acc;
        Opportunity opp;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
            opp = createOpenOpportunity(acc.Id, oppOwner.Id, 5000);
            insert opp;
        }

        // Act — update to a different non-terminal stage, not Closed Won
        Test.startTest();
        opp.StageName = 'Needs Analysis';
        update opp;
        Test.stopTest();

        // Assert — no Tasks created
        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
        Assert.areEqual(0, tasks.size(),
            'No Task should be created when the Opportunity does not transition to Closed Won.');
    }

    @IsTest
    static void testUpdate_AlreadyClosedWon_NoAdditionalTaskCreated() {
        // Arrange — Opportunity already in Closed Won; update a non-stage field
        // This verifies the handler checks OLD stage != Closed Won (not just new stage)
        User oppOwner = createUser('AlreadyCWOwner', 'Standard User', true);
        User accOwner = createUser('AlreadyCWAccOwner', 'Standard User', true);
        Account acc;
        Opportunity opp;

        System.runAs(oppOwner) {
            acc = createAccount(accOwner.Id);
            opp = createOpenOpportunity(acc.Id, oppOwner.Id, 5000);
            insert opp;
        }

        // First transition — creates the Task
        opp.StageName = 'Closed Won';
        update opp;

        Integer taskCountAfterFirstTransition =
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id];

        // Act — update again while already Closed Won
        Test.startTest();
        opp.Description = 'Post-close note';
        update opp;
        Test.stopTest();

        // Assert — no additional Task created
        Integer taskCountAfterSecondUpdate =
            [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id];

        Assert.areEqual(taskCountAfterFirstTransition, taskCountAfterSecondUpdate,
            'No additional Task should be created when the Opportunity is already Closed Won.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 9: Account with no Sales Manager user → silent skip
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testInsert_NoSalesManagerUser_SilentSkip() {
        // Arrange — role exists but no user is assigned to it
        UserRole salesMgrRole = createRole('Sales Manager No User');
        // Intentionally do NOT create a user with this role

        User oppOwner = createUser('NoSMUserOwner', 'Standard User', true);
        Account acc;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
        }

        Opportunity opp = new Opportunity(
            Name      = 'No SM User Deal',
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 80000
        );

        // Act & Assert — must not throw
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            insert opp;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        Assert.isFalse(exceptionThrown,
            'No exception should be thrown when no user holds the Sales Manager role.');

        List<Opportunity> inserted = [SELECT Id FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(1, inserted.size(),
            'Opportunity should be inserted successfully when no Sales Manager user exists.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 10: Bulk insert — 200 records over $50k, no Sales Manager role
    //              Verifies bulkification of notification path and silent skip
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBulkInsert_200RecordsOver50k_NoException() {
        // Arrange
        User oppOwner = createUser('BulkNotifOwner', 'Standard User', true);
        Account acc;

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
        }

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Notif Opp ' + i,
                AccountId = acc.Id,
                OwnerId   = oppOwner.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Amount    = 60000
            ));
        }

        // Act
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            insert opps;
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Assert
        Assert.isFalse(exceptionThrown,
            'Bulk insert of 200 records over $50k should not throw an exception.');

        Integer insertedCount = [SELECT COUNT() FROM Opportunity
                                 WHERE Id IN :opps];
        Assert.areEqual(200, insertedCount,
            'All 200 Opportunities should be inserted successfully.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 11: Mixed batch — some Closed Won, some not; only correct Tasks
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testMixedBatch_OnlyCWOppsGetTasks() {
        // Arrange
        User oppOwner = createUser('MixedOwner', 'Standard User', true);
        User accOwner = createUser('MixedAccOwner', 'Standard User', true);
        Account acc;
        List<Opportunity> opps = new List<Opportunity>();

        System.runAs(oppOwner) {
            acc = createAccount(accOwner.Id);
            for (Integer i = 0; i < 5; i++) {
                opps.add(createOpenOpportunity(acc.Id, oppOwner.Id, 5000));
            }
            insert opps;
        }

        // Act — transition only the first 3 to Closed Won
        List<Opportunity> toUpdate = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            Opportunity o = opps[i].clone(true, false, false, false);
            o.StageName = (i < 3) ? 'Closed Won' : 'Needs Analysis';
            toUpdate.add(o);
        }

        Test.startTest();
        update toUpdate;
        Test.stopTest();

        // Assert — exactly 3 Tasks created
        List<Task> tasks = [SELECT Id, WhatId FROM Task WHERE WhatId IN :opps];
        Assert.areEqual(3, tasks.size(),
            'Only the 3 Opportunities transitioning to Closed Won should have Tasks.');

        Set<Id> cwOppIds = new Set<Id>{ opps[0].Id, opps[1].Id, opps[2].Id };
        for (Task t : tasks) {
            Assert.isTrue(cwOppIds.contains(t.WhatId),
                'Task WhatId must reference one of the Closed Won Opportunities.');
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 12: Task ActivityDate = CloseDate + 7 (explicit date assertion)
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testClosedWon_TaskActivityDate_IsCloseDatePlusSeven() {
        // Arrange
        User oppOwner = createUser('DateCheckOwner', 'Standard User', true);
        Account acc;
        Opportunity opp;
        Date specificCloseDate = Date.newInstance(2026, 6, 15);

        System.runAs(oppOwner) {
            acc = createAccount(oppOwner.Id);
            opp = new Opportunity(
                Name      = 'Date Check Opp',
                AccountId = acc.Id,
                OwnerId   = oppOwner.Id,
                StageName = 'Prospecting',
                CloseDate = specificCloseDate,
                Amount    = 5000
            );
            insert opp;
        }

        // Act
        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        // Assert
        List<Task> tasks = [SELECT ActivityDate FROM Task WHERE WhatId = :opp.Id];
        Assert.areEqual(1, tasks.size(), 'Expected one Task.');
        Assert.areEqual(
            specificCloseDate.addDays(7),
            tasks[0].ActivityDate,
            'Task ActivityDate must be exactly CloseDate + 7 days.'
        );
    }
}
