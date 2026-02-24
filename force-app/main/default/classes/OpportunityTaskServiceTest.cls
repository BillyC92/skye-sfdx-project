/**
 * OpportunityTaskServiceTest
 *
 * Comprehensive test coverage for OpportunityTaskService.
 *
 * Each test method targets a specific acceptance criterion or edge case so
 * that failures are immediately actionable — not just coverage numbers.
 */
@IsTest
private class OpportunityTaskServiceTest {

    // -----------------------------------------------------------------------
    // Test data helpers
    // -----------------------------------------------------------------------

    /**
     * Creates and inserts a standard User for use as Account / Opp owner.
     * profileName should be an existing profile in the org (e.g. 'Standard User').
     */
    private static User createUser(String lastName, Boolean isActive) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            LastName           = lastName,
            FirstName          = 'Test',
            Email              = lastName.toLowerCase().replaceAll(' ', '') + '@example.test.com',
            Username           = lastName.toLowerCase().replaceAll(' ', '') + System.currentTimeMillis() + '@example.test.com',
            Alias              = lastName.left(5).toLowerCase(),
            TimeZoneSidKey     = 'America/New_York',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id,
            IsActive           = isActive
        );
        insert u;
        return u;
    }

    /**
     * Builds an Account owned by the given user (not inserted — caller decides).
     */
    private static Account buildAccount(String name, Id ownerId) {
        return new Account(Name = name, OwnerId = ownerId);
    }

    /**
     * Builds an Opportunity (not inserted — caller decides).
     */
    private static Opportunity buildOpportunity(
        String name,
        String stage,
        Date closeDate,
        Id accountId,
        Id ownerId
    ) {
        return new Opportunity(
            Name      = name,
            StageName = stage,
            CloseDate = closeDate,
            AccountId = accountId,
            OwnerId   = ownerId
        );
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /**
     * SCENARIO 1 — Closed Won Opp with active Account owner:
     * Task should be assigned to the Account owner.
     */
    @IsTest
    static void testClosedWon_activeAccountOwner_taskAssignedToAccountOwner() {
        User accOwner = createUser('AccOwnerActive', true);
        User oppOwner = createUser('OppOwnerActive', true);

        Account acc = buildAccount('Test Account', accOwner.Id);
        insert acc;

        // Re-query Account with Owner sub-object (mirrors what the handler does).
        Map<Id, Account> accountMap = new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id = :acc.Id]
        );

        Opportunity opp = buildOpportunity(
            'Deal Alpha', 'Closed Won', Date.today().addDays(10), acc.Id, oppOwner.Id
        );
        insert opp;

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT Id, Subject, OwnerId, ActivityDate, Status, Priority, WhatId
                            FROM Task WHERE WhatId = :opp.Id];

        System.assertEquals(1, tasks.size(), 'Exactly one Task should be created');
        Task t = tasks[0];
        System.assertEquals(
            OpportunityTaskService.TASK_SUBJECT_PREFIX + opp.Name,
            t.Subject,
            'Task Subject should be prefixed with Follow up:'
        );
        System.assertEquals(
            opp.CloseDate.addDays(OpportunityTaskService.FOLLOW_UP_DAYS),
            t.ActivityDate,
            'ActivityDate should be CloseDate + 7'
        );
        System.assertEquals(accOwner.Id, t.OwnerId, 'Task should be owned by the active Account owner');
        System.assertEquals(OpportunityTaskService.TASK_STATUS,   t.Status,   'Status should be Not Started');
        System.assertEquals(OpportunityTaskService.TASK_PRIORITY, t.Priority, 'Priority should be Normal');
        System.assertEquals(opp.Id, t.WhatId, 'WhatId should reference the Opportunity');
    }

    /**
     * SCENARIO 2 — Closed Won Opp with INACTIVE Account owner:
     * Task should fall back to the Opportunity owner.
     */
    @IsTest
    static void testClosedWon_inactiveAccountOwner_taskAssignedToOppOwner() {
        User inactiveAccOwner = createUser('AccOwnerInactive', true); // create active first
        User oppOwner         = createUser('OppOwnerFallback', true);

        Account acc = buildAccount('Inactive Owner Account', inactiveAccOwner.Id);
        insert acc;

        // Deactivate the account owner after account creation.
        inactiveAccOwner.IsActive = false;
        update inactiveAccOwner;

        Map<Id, Account> accountMap = new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id = :acc.Id]
        );

        Opportunity opp = buildOpportunity(
            'Deal Beta', 'Closed Won', Date.today().addDays(5), acc.Id, oppOwner.Id
        );
        insert opp;

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created');
        System.assertEquals(
            oppOwner.Id,
            tasks[0].OwnerId,
            'Task should fall back to Opportunity owner when Account owner is inactive'
        );
    }

    /**
     * SCENARIO 3 — Opportunity NOT in Closed Won stage:
     * No Task should be created.
     */
    @IsTest
    static void testNonClosedWon_noTaskCreated() {
        User oppOwner = createUser('OppOwnerOpen', true);

        Account acc = buildAccount('Open Deal Account', oppOwner.Id);
        insert acc;

        Map<Id, Account> accountMap = new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id = :acc.Id]
        );

        Opportunity opp = buildOpportunity(
            'Deal Gamma', 'Prospecting', Date.today().addDays(30), acc.Id, oppOwner.Id
        );
        insert opp;

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(0, tasks.size(), 'No Task should be created for a non-Closed-Won Opportunity');
    }

    /**
     * SCENARIO 4 — Opportunity with no Account (AccountId is null):
     * Should not throw a NullPointerException; Task assigned to Opp owner.
     */
    @IsTest
    static void testNoAccount_noNullPointer_taskAssignedToOppOwner() {
        User oppOwner = createUser('OppOwnerNoAcc', true);

        // Opportunity with no Account.
        Opportunity opp = buildOpportunity(
            'Deal Delta', 'Closed Won', Date.today().addDays(3), null, oppOwner.Id
        );
        insert opp;

        Test.startTest();
        // Empty accountMap — simulates no Account on the Opp.
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            new Map<Id, Account>()
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Task should still be created when Opp has no Account');
        System.assertEquals(
            oppOwner.Id,
            tasks[0].OwnerId,
            'Task should be owned by the Opportunity owner when no Account exists'
        );
    }

    /**
     * SCENARIO 5 — Null / empty inputs:
     * Method should return gracefully without exceptions.
     */
    @IsTest
    static void testNullAndEmptyInputs_noException() {
        Test.startTest();
        // Null list
        try {
            OpportunityTaskService.createFollowUpTasks(null, new Map<Id, Account>());
            System.assert(true, 'Null list should not throw');
        } catch (Exception e) {
            System.assert(false, 'Null list threw an unexpected exception: ' + e.getMessage());
        }
        // Empty list
        try {
            OpportunityTaskService.createFollowUpTasks(
                new List<Opportunity>(),
                new Map<Id, Account>()
            );
            System.assert(true, 'Empty list should not throw');
        } catch (Exception e) {
            System.assert(false, 'Empty list threw an unexpected exception: ' + e.getMessage());
        }
        Test.stopTest();
    }

    /**
     * SCENARIO 6 — Bulk test with 200 Opportunities:
     * All Closed Won records should produce Tasks; governor limits must not be hit.
     */
    @IsTest
    static void testBulk_200ClosedWonOpportunities_allTasksCreated() {
        User accOwner = createUser('BulkAccOwner', true);
        User oppOwner = createUser('BulkOppOwner', true);

        Account acc = buildAccount('Bulk Account', accOwner.Id);
        insert acc;

        Map<Id, Account> accountMap = new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id = :acc.Id]
        );

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpportunity(
                'Bulk Deal ' + i,
                'Closed Won',
                Date.today().addDays(i + 1),
                acc.Id,
                oppOwner.Id
            ));
        }
        insert opps;

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(opps, accountMap);
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task WHERE WhatId IN :opps];
        System.assertEquals(200, taskCount, '200 Tasks should be created for 200 Closed Won Opportunities');
    }

    /**
     * SCENARIO 7 — Mixed stages in a single bulk call:
     * Only Closed Won records should produce Tasks.
     */
    @IsTest
    static void testBulk_mixedStages_onlyClosedWonGetTasks() {
        User owner = createUser('MixedOwner', true);

        Account acc = buildAccount('Mixed Stage Account', owner.Id);
        insert acc;

        Map<Id, Account> accountMap = new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id = :acc.Id]
        );

        List<Opportunity> opps = new List<Opportunity>();
        // 5 Closed Won
        for (Integer i = 0; i < 5; i++) {
            opps.add(buildOpportunity('CW Deal ' + i, 'Closed Won', Date.today().addDays(i + 1), acc.Id, owner.Id));
        }
        // 5 Prospecting
        for (Integer i = 0; i < 5; i++) {
            opps.add(buildOpportunity('Prospect Deal ' + i, 'Prospecting', Date.today().addDays(i + 1), acc.Id, owner.Id));
        }
        insert opps;

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(opps, accountMap);
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task WHERE WhatId IN :opps];
        System.assertEquals(5, taskCount, 'Only 5 Tasks should be created — one per Closed Won Opportunity');
    }

    /**
     * SCENARIO 8 — CloseDate is null (defensive edge case):
     * ActivityDate should default to today + 7 without throwing.
     */
    @IsTest
    static void testNullCloseDate_activityDateDefaultsToTodayPlus7() {
        User owner = createUser('NullDateOwner', true);

        // Opportunity without CloseDate — requires a workaround since CloseDate
        // is required on Opportunity. We simulate this by directly constructing
        // the object without inserting (unit-style test of the service logic).
        // Because CloseDate is required by the DB, we test the branch by calling
        // the service with a manually constructed Opportunity that has a null CloseDate.
        // We use a real inserted Opp for the WhatId but override CloseDate in memory.
        Opportunity realOpp = buildOpportunity(
            'Null Date Deal', 'Closed Won', Date.today(), null, owner.Id
        );
        insert realOpp;

        // Simulate null CloseDate in memory (service receives this from trigger context).
        Opportunity oppWithNullDate = new Opportunity(
            Id        = realOpp.Id,
            Name      = realOpp.Name,
            StageName = 'Closed Won',
            CloseDate = null,
            OwnerId   = owner.Id,
            AccountId = null
        );

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ oppWithNullDate },
            new Map<Id, Account>()
        );
        Test.stopTest();

        List<Task> tasks = [SELECT ActivityDate FROM Task WHERE WhatId = :realOpp.Id];
        System.assertEquals(1, tasks.size(), 'Task should be created even with null CloseDate');
        System.assertEquals(
            Date.today().addDays(OpportunityTaskService.FOLLOW_UP_DAYS),
            tasks[0].ActivityDate,
            'ActivityDate should default to today + 7 when CloseDate is null'
        );
    }
}
