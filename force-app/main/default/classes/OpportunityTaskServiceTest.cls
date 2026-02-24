/**
 * OpportunityTaskServiceTest
 *
 * Unit tests for OpportunityTaskService.
 *
 * Coverage targets:
 *   - Task created with correct Subject, ActivityDate, WhatId, OwnerId.
 *   - Account owner assigned when active.
 *   - Opportunity owner used as fallback when Account owner is inactive.
 *   - Opportunity owner used when Opportunity has no AccountId.
 *   - Opportunity owner used when Account is absent from the map.
 *   - Bulk operation (200 records) completes within governor limits.
 *   - Null / empty input returns without error.
 *   - Null CloseDate falls back to today + 7.
 */
@IsTest
private class OpportunityTaskServiceTest {

    // -----------------------------------------------------------------------
    // Test data helpers
    // -----------------------------------------------------------------------

    /**
     * Creates and inserts a minimal active User for use as an Account or
     * Opportunity owner. Each call generates a unique username.
     */
    private static User createActiveUser(String lastName) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            LastName           = lastName,
            Email              = lastName.toLowerCase().replaceAll(' ', '_') + '@test.example.com',
            Username           = lastName.toLowerCase().replaceAll(' ', '_')
                                     + System.currentTimeMillis()
                                     + '@test.example.com',
            Alias              = lastName.left(8),
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id,
            IsActive           = true
        );
        insert u;
        return u;
    }

    /**
     * Creates and inserts an inactive User.
     */
    private static User createInactiveUser(String lastName) {
        // Insert as active first (Salesforce does not allow inserting inactive users directly).
        User u = createActiveUser(lastName + 'Inactive');
        u.IsActive = false;
        update u;
        return u;
    }

    /**
     * Builds an in-memory Account (not inserted) owned by the given user.
     * The Owner sub-object is populated to mirror what the handler SOQL returns.
     */
    private static Account buildAccountWithOwner(Id accountId, User owner) {
        Account acc = new Account(
            Id      = accountId,
            OwnerId = owner.Id
        );
        // Simulate the queried Owner relationship used by resolveAssignee.
        // We use JSON deserialisation to set the read-only relationship field.
        String json =
            '{"attributes":{"type":"Account"},' +
            '"Id":"' + accountId + '",' +
            '"OwnerId":"' + owner.Id + '",' +
            '"Owner":{"attributes":{"type":"User"},' +
            '"Id":"' + owner.Id + '",' +
            '"IsActive":' + owner.IsActive + '}}' ;
        return (Account) JSON.deserialize(json, Account.class);
    }

    /**
     * Builds a minimal Opportunity in memory (not inserted) with the supplied
     * owner and optional AccountId.
     */
    private static Opportunity buildOpportunity(
        String name,
        Id ownerId,
        Id accountId,
        Date closeDate
    ) {
        Opportunity opp = new Opportunity(
            Name        = name,
            OwnerId     = ownerId,
            AccountId   = accountId,
            CloseDate   = closeDate,
            StageName   = 'Closed Won',
            Amount      = 10000
        );
        return opp;
    }

    // -----------------------------------------------------------------------
    // Tests: resolveAssignee (via @TestVisible)
    // -----------------------------------------------------------------------

    @IsTest
    static void resolveAssignee_activeAccountOwner_returnsAccountOwner() {
        User accOwner  = createActiveUser('AccOwner');
        User oppOwner  = createActiveUser('OppOwner');

        // We need a real Account Id to use as a map key.
        Account acc = new Account(Name = 'Test Account', OwnerId = accOwner.Id);
        insert acc;

        Account accWithOwner = buildAccountWithOwner(acc.Id, accOwner);
        Map<Id, Account> accountMap = new Map<Id, Account>{ acc.Id => accWithOwner };

        Opportunity opp = buildOpportunity('Test Opp', oppOwner.Id, acc.Id, Date.today());

        Test.startTest();
        Id assignee = OpportunityTaskService.resolveAssignee(opp, accountMap);
        Test.stopTest();

        System.assertEquals(
            accOwner.Id,
            assignee,
            'Active Account owner should be assigned the Task.'
        );
    }

    @IsTest
    static void resolveAssignee_inactiveAccountOwner_returnsOppOwner() {
        User inactiveOwner = createInactiveUser('InactiveAcc');
        User oppOwner      = createActiveUser('OppOwnerFallback');

        Account acc = new Account(Name = 'Test Account', OwnerId = inactiveOwner.Id);
        insert acc;

        Account accWithOwner = buildAccountWithOwner(acc.Id, inactiveOwner);
        Map<Id, Account> accountMap = new Map<Id, Account>{ acc.Id => accWithOwner };

        Opportunity opp = buildOpportunity('Test Opp', oppOwner.Id, acc.Id, Date.today());

        Test.startTest();
        Id assignee = OpportunityTaskService.resolveAssignee(opp, accountMap);
        Test.stopTest();

        System.assertEquals(
            oppOwner.Id,
            assignee,
            'Inactive Account owner should fall back to Opportunity owner.'
        );
    }

    @IsTest
    static void resolveAssignee_noAccountId_returnsOppOwner() {
        User oppOwner = createActiveUser('OppOwnerNoAcc');

        Opportunity opp = buildOpportunity('Test Opp', oppOwner.Id, null, Date.today());

        Test.startTest();
        Id assignee = OpportunityTaskService.resolveAssignee(opp, new Map<Id, Account>());
        Test.stopTest();

        System.assertEquals(
            oppOwner.Id,
            assignee,
            'Opportunity with no AccountId should fall back to Opportunity owner.'
        );
    }

    @IsTest
    static void resolveAssignee_accountNotInMap_returnsOppOwner() {
        User accOwner = createActiveUser('AccOwnerMissing');
        User oppOwner = createActiveUser('OppOwnerMapMiss');

        Account acc = new Account(Name = 'Test Account', OwnerId = accOwner.Id);
        insert acc;

        // Intentionally empty map — Account not present.
        Map<Id, Account> accountMap = new Map<Id, Account>();

        Opportunity opp = buildOpportunity('Test Opp', oppOwner.Id, acc.Id, Date.today());

        Test.startTest();
        Id assignee = OpportunityTaskService.resolveAssignee(opp, accountMap);
        Test.stopTest();

        System.assertEquals(
            oppOwner.Id,
            assignee,
            'Account absent from map should fall back to Opportunity owner.'
        );
    }

    // -----------------------------------------------------------------------
    // Tests: buildTasks (via @TestVisible)
    // -----------------------------------------------------------------------

    @IsTest
    static void buildTasks_correctFieldValues() {
        User oppOwner = createActiveUser('BuildTaskOwner');

        Date closeDate = Date.today();
        Opportunity opp = buildOpportunity('Deal Alpha', oppOwner.Id, null, closeDate);
        // Assign a fake Id so the WhatId assertion is meaningful.
        // We use JSON to set the read-only Id field.
        opp = (Opportunity) JSON.deserialize(
            '{"attributes":{"type":"Opportunity"},' +
            '"Id":"006000000000001AAA",' +
            '"Name":"Deal Alpha",' +
            '"OwnerId":"' + oppOwner.Id + '",' +
            '"CloseDate":"' + String.valueOf(closeDate) + '",' +
            '"StageName":"Closed Won",' +
            '"Amount":10000}',
            Opportunity.class
        );

        Test.startTest();
        List<Task> tasks = OpportunityTaskService.buildTasks(
            new List<Opportunity>{ opp },
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assertEquals(1, tasks.size(), 'Exactly one Task should be built.');

        Task t = tasks[0];
        System.assertEquals('Follow up: Deal Alpha', t.Subject,
            'Subject should be "Follow up: " + Opportunity Name.');
        System.assertEquals(closeDate.addDays(7), t.ActivityDate,
            'ActivityDate should be CloseDate + 7 days.');
        System.assertEquals('006000000000001AAA', t.WhatId,
            'WhatId should be the Opportunity Id.');
        System.assertEquals(oppOwner.Id, t.OwnerId,
            'OwnerId should be the resolved assignee.');
        System.assertEquals('Not Started', t.Status,
            'Status should default to Not Started.');
        System.assertEquals('Normal', t.Priority,
            'Priority should default to Normal.');
    }

    @IsTest
    static void buildTasks_nullCloseDate_usesTodayPlusSeven() {
        User oppOwner = createActiveUser('NullCloseDateOwner');

        Opportunity opp = (Opportunity) JSON.deserialize(
            '{"attributes":{"type":"Opportunity"},' +
            '"Id":"006000000000002AAA",' +
            '"Name":"No Close Date Deal",' +
            '"OwnerId":"' + oppOwner.Id + '",' +
            '"StageName":"Closed Won",' +
            '"Amount":10000}',
            Opportunity.class
        );

        Test.startTest();
        List<Task> tasks = OpportunityTaskService.buildTasks(
            new List<Opportunity>{ opp },
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assertEquals(1, tasks.size());
        System.assertEquals(
            Date.today().addDays(7),
            tasks[0].ActivityDate,
            'Null CloseDate should fall back to today + 7 days.'
        );
    }

    @IsTest
    static void buildTasks_emptyList_returnsEmptyList() {
        Test.startTest();
        List<Task> tasks = OpportunityTaskService.buildTasks(
            new List<Opportunity>(),
            new Map<Id, Account>()
        );
        Test.stopTest();

        System.assertNotEquals(null, tasks, 'Result should not be null.');
        System.assertEquals(0, tasks.size(), 'Empty input should produce empty output.');
    }

    // -----------------------------------------------------------------------
    // Tests: createFollowUpTasks (integration — real DML)
    // -----------------------------------------------------------------------

    @IsTest
    static void createFollowUpTasks_singleRecord_taskInserted() {
        User accOwner = createActiveUser('SingleAccOwner');
        User oppOwner = createActiveUser('SingleOppOwner');

        Account acc = new Account(Name = 'Single Test Account', OwnerId = accOwner.Id);
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'Single Closed Won',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            OwnerId   = oppOwner.Id,
            AccountId = acc.Id,
            Amount    = 75000
        );
        insert opp;

        Account accWithOwner = buildAccountWithOwner(acc.Id, accOwner);
        Map<Id, Account> accountMap = new Map<Id, Account>{ acc.Id => accWithOwner };

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountMap
        );
        Test.stopTest();

        List<Task> tasks = [
            SELECT Subject, ActivityDate, WhatId, OwnerId
            FROM Task
            WHERE WhatId = :opp.Id
        ];

        System.assertEquals(1, tasks.size(), 'One Task should be created.');
        System.assertEquals('Follow up: Single Closed Won', tasks[0].Subject);
        System.assertEquals(Date.today().addDays(7), tasks[0].ActivityDate);
        System.assertEquals(opp.Id, tasks[0].WhatId);
        System.assertEquals(accOwner.Id, tasks[0].OwnerId,
            'Active Account owner should be assigned.');
    }

    @IsTest
    static void createFollowUpTasks_inactiveAccountOwner_taskAssignedToOppOwner() {
        User inactiveOwner = createInactiveUser('InactiveIntegration');
        User oppOwner      = createActiveUser('OppOwnerIntegration');

        Account acc = new Account(Name = 'Inactive Owner Account', OwnerId = inactiveOwner.Id);
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'Fallback Opp',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            OwnerId   = oppOwner.Id,
            AccountId = acc.Id,
            Amount    = 20000
        );
        insert opp;

        Account accWithOwner = buildAccountWithOwner(acc.Id, inactiveOwner);
        Map<Id, Account> accountMap = new Map<Id, Account>{ acc.Id => accWithOwner };

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            accountMap
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size());
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId,
            'Inactive Account owner should fall back to Opportunity owner.');
    }

    @IsTest
    static void createFollowUpTasks_bulkTwoHundredRecords_allTasksInserted() {
        User oppOwner = createActiveUser('BulkOppOwner');
        User accOwner = createActiveUser('BulkAccOwner');

        Account acc = new Account(Name = 'Bulk Account', OwnerId = accOwner.Id);
        insert acc;

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Opp ' + i,
                StageName = 'Closed Won',
                CloseDate = Date.today(),
                OwnerId   = oppOwner.Id,
                AccountId = acc.Id,
                Amount    = 10000
            ));
        }
        insert opps;

        Account accWithOwner = buildAccountWithOwner(acc.Id, accOwner);
        Map<Id, Account> accountMap = new Map<Id, Account>{ acc.Id => accWithOwner };

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(opps, accountMap);
        Test.stopTest();

        Integer taskCount = [
            SELECT COUNT()
            FROM Task
            WHERE WhatId IN :opps
        ];
        System.assertEquals(200, taskCount,
            'All 200 Opportunities should have a corresponding Task.');
    }

    @IsTest
    static void createFollowUpTasks_nullInput_noException() {
        Test.startTest();
        try {
            OpportunityTaskService.createFollowUpTasks(null, null);
            System.assert(true, 'Null input should not throw an exception.');
        } catch (Exception ex) {
            System.assert(false, 'Null input threw an unexpected exception: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void createFollowUpTasks_emptyList_noException() {
        Test.startTest();
        try {
            OpportunityTaskService.createFollowUpTasks(
                new List<Opportunity>(),
                new Map<Id, Account>()
            );
            System.assert(true, 'Empty list should not throw an exception.');
        } catch (Exception ex) {
            System.assert(false, 'Empty list threw an unexpected exception: ' + ex.getMessage());
        }
        Test.stopTest();
    }
}
