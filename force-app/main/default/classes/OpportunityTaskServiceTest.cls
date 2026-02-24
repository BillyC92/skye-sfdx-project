/**
 * OpportunityTaskServiceTest
 *
 * Covers OpportunityTaskService in isolation. The handler and trigger are tested
 * separately in OpportunityTriggerHandlerTest.
 *
 * Test strategy:
 * - All tests use @TestSetup data where possible to reduce DML overhead.
 * - Each test method has a clear "Arrange / Act / Assert" structure.
 * - Assertions verify business outcomes, not just code coverage.
 */
@IsTest
private class OpportunityTaskServiceTest {

    // -------------------------------------------------------------------------
    // Test data setup
    // -------------------------------------------------------------------------

    @TestSetup
    static void makeData() {
        // Active user to act as Account owner
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User activeAccountOwner = new User(
            FirstName          = 'Active',
            LastName           = 'AccountOwner',
            Email              = 'active.accountowner@test.example.com',
            Username           = 'active.accountowner@test.example.com.sandbox',
            Alias              = 'actAccO',
            TimeZoneSidKey     = 'America/New_York',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = standardProfile.Id,
            IsActive           = true
        );

        User inactiveAccountOwner = new User(
            FirstName          = 'Inactive',
            LastName           = 'AccountOwner',
            Email              = 'inactive.accountowner@test.example.com',
            Username           = 'inactive.accountowner@test.example.com.sandbox',
            Alias              = 'inAccO',
            TimeZoneSidKey     = 'America/New_York',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = standardProfile.Id,
            IsActive           = true  // Must be active to insert; deactivated below
        );

        insert new List<User>{ activeAccountOwner, inactiveAccountOwner };

        // Deactivate the second user after insert
        inactiveAccountOwner.IsActive = false;
        update inactiveAccountOwner;

        // Accounts owned by each user
        Account accWithActiveOwner = new Account(
            Name    = 'Active Owner Account',
            OwnerId = activeAccountOwner.Id
        );
        Account accWithInactiveOwner = new Account(
            Name    = 'Inactive Owner Account',
            OwnerId = inactiveAccountOwner.Id
        );
        Account accWithNoOwnerInMap = new Account(
            Name = 'No Map Entry Account'
        );
        insert new List<Account>{ accWithActiveOwner, accWithInactiveOwner, accWithNoOwnerInMap };
    }

    // -------------------------------------------------------------------------
    // Helper: build a minimal Closed Won Opportunity
    // -------------------------------------------------------------------------
    private static Opportunity buildOpp(String name, Id accountId, Id ownerId, Date closeDate) {
        return new Opportunity(
            Name        = name,
            StageName   = 'Closed Won',
            CloseDate   = closeDate,
            AccountId   = accountId,
            OwnerId     = ownerId,
            Amount      = 10000
        );
    }

    // -------------------------------------------------------------------------
    // Test: active Account owner is assigned to the Task
    // -------------------------------------------------------------------------
    @IsTest
    static void testActiveAccountOwnerAssignedToTask() {
        User activeOwner = [SELECT Id FROM User WHERE LastName = 'AccountOwner' AND IsActive = true LIMIT 1];
        Account acc      = [SELECT Id FROM Account WHERE Name = 'Active Owner Account' LIMIT 1];

        Opportunity opp = buildOpp('Test Opp Active', acc.Id, UserInfo.getUserId(), Date.today().addDays(30));
        insert opp;

        // Build the accountOwnerMap as the handler would
        Map<Id, User> accountOwnerMap = new Map<Id, User>();
        accountOwnerMap.put(acc.Id, new User(Id = activeOwner.Id, IsActive = true));

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountOwnerMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT Id, Subject, OwnerId, ActivityDate, Status, WhatId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Exactly one Task should be created');

        Task t = tasks[0];
        System.assertEquals(
            OpportunityTaskService.TASK_SUBJECT_PREFIX + opp.Name,
            t.Subject,
            'Subject should be prefixed with Follow up:'
        );
        System.assertEquals(activeOwner.Id, t.OwnerId, 'Task should be assigned to the active Account owner');
        System.assertEquals(opp.Id, t.WhatId, 'WhatId should reference the Opportunity');
        System.assertEquals(OpportunityTaskService.TASK_STATUS, t.Status, 'Status should be Not Started');
        System.assertEquals(
            opp.CloseDate.addDays(OpportunityTaskService.FOLLOW_UP_DAYS),
            t.ActivityDate,
            'ActivityDate should be CloseDate + 7 days'
        );
    }

    // -------------------------------------------------------------------------
    // Test: inactive Account owner causes fallback to Opportunity owner
    // -------------------------------------------------------------------------
    @IsTest
    static void testInactiveAccountOwnerFallsBackToOppOwner() {
        User inactiveOwner = [SELECT Id FROM User WHERE LastName = 'AccountOwner' AND IsActive = false LIMIT 1];
        Account acc        = [SELECT Id FROM Account WHERE Name = 'Inactive Owner Account' LIMIT 1];

        Opportunity opp = buildOpp('Test Opp Inactive', acc.Id, UserInfo.getUserId(), Date.today().addDays(30));
        insert opp;

        Map<Id, User> accountOwnerMap = new Map<Id, User>();
        accountOwnerMap.put(acc.Id, new User(Id = inactiveOwner.Id, IsActive = false));

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountOwnerMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created even with inactive Account owner');
        System.assertEquals(
            UserInfo.getUserId(),
            tasks[0].OwnerId,
            'Task should fall back to the Opportunity owner when Account owner is inactive'
        );
    }

    // -------------------------------------------------------------------------
    // Test: no Account on Opportunity — Task assigned to Opportunity owner
    // -------------------------------------------------------------------------
    @IsTest
    static void testNoAccountFallsBackToOppOwner() {
        Opportunity opp = buildOpp('Test Opp No Account', null, UserInfo.getUserId(), Date.today().addDays(30));
        insert opp;

        // Empty map — no Account data available
        Map<Id, User> accountOwnerMap = new Map<Id, User>();

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountOwnerMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created for Opp without Account');
        System.assertEquals(
            UserInfo.getUserId(),
            tasks[0].OwnerId,
            'Task should be assigned to Opportunity owner when no Account is present'
        );
    }

    // -------------------------------------------------------------------------
    // Test: null CloseDate falls back to today + 7
    // -------------------------------------------------------------------------
    @IsTest
    static void testNullCloseDateFallsBackToToday() {
        // Build the Opp in memory only — we cannot insert with null CloseDate
        // so we test the service directly with a fabricated record.
        Opportunity opp = new Opportunity(
            Id        = null,
            Name      = 'No Close Date Opp',
            OwnerId   = UserInfo.getUserId(),
            AccountId = null,
            CloseDate = null
        );

        // We need a real Id for WhatId — insert a throwaway opp
        Opportunity realOpp = buildOpp('Real Opp For Id', null, UserInfo.getUserId(), Date.today());
        insert realOpp;
        opp.Id = realOpp.Id; // Borrow the Id so WhatId is valid

        Map<Id, User> accountOwnerMap = new Map<Id, User>();

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountOwnerMap
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

    // -------------------------------------------------------------------------
    // Test: empty list — no DML, no error
    // -------------------------------------------------------------------------
    @IsTest
    static void testEmptyListDoesNothing() {
        Test.startTest();
        // Should complete silently with no exception
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>(),
            new Map<Id, User>()
        );
        Test.stopTest();

        // No tasks created
        List<Task> tasks = [SELECT Id FROM Task];
        System.assertEquals(0, tasks.size(), 'No Tasks should be created for an empty list');
    }

    // -------------------------------------------------------------------------
    // Test: null list — no DML, no error
    // -------------------------------------------------------------------------
    @IsTest
    static void testNullListDoesNothing() {
        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(null, null);
        Test.stopTest();

        List<Task> tasks = [SELECT Id FROM Task];
        System.assertEquals(0, tasks.size(), 'No Tasks should be created for a null list');
    }

    // -------------------------------------------------------------------------
    // Test: bulk — 200 Opportunities all get Tasks
    // -------------------------------------------------------------------------
    @IsTest
    static void testBulk200OpportunitiesCreateTasks() {
        Account acc      = [SELECT Id FROM Account WHERE Name = 'Active Owner Account' LIMIT 1];
        User activeOwner = [SELECT Id FROM User WHERE LastName = 'AccountOwner' AND IsActive = true LIMIT 1];

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp('Bulk Opp ' + i, acc.Id, UserInfo.getUserId(), Date.today().addDays(30)));
        }
        insert opps;

        Map<Id, User> accountOwnerMap = new Map<Id, User>();
        accountOwnerMap.put(acc.Id, new User(Id = activeOwner.Id, IsActive = true));

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(opps, accountOwnerMap);
        Test.stopTest();

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        List<Task> tasks = [SELECT Id, OwnerId FROM Task WHERE WhatId IN :oppIds];
        System.assertEquals(200, tasks.size(), '200 Tasks should be created for 200 Opportunities');

        for (Task t : tasks) {
            System.assertEquals(
                activeOwner.Id,
                t.OwnerId,
                'Each Task should be assigned to the active Account owner'
            );
        }
    }

    // -------------------------------------------------------------------------
    // Test: Account not in map — falls back to Opportunity owner
    // -------------------------------------------------------------------------
    @IsTest
    static void testAccountNotInMapFallsBackToOppOwner() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'No Map Entry Account' LIMIT 1];

        Opportunity opp = buildOpp('Test Opp Missing Map Entry', acc.Id, UserInfo.getUserId(), Date.today().addDays(30));
        insert opp;

        // Intentionally empty map — Account exists but has no entry
        Map<Id, User> accountOwnerMap = new Map<Id, User>();

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountOwnerMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created');
        System.assertEquals(
            UserInfo.getUserId(),
            tasks[0].OwnerId,
            'Task should fall back to Opportunity owner when Account has no map entry'
        );
    }
}
