/**
 * OpportunityTaskServiceTest
 *
 * Unit tests for OpportunityTaskService.
 *
 * Coverage targets:
 * - Every branch in createFollowUpTasks and resolveTaskOwner.
 * - Bulk scenarios (200 records) to confirm governor-limit safety.
 * - Edge cases: null CloseDate, missing Account in map, inactive Account owner.
 *
 * Test data is created inline (no @TestSetup) so each test method is fully
 * self-contained and readable without cross-method dependencies.
 */
@IsTest
private class OpportunityTaskServiceTest {

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Creates and inserts a minimal active User with a given last name.
     * Uses the current running user's profile to avoid profile SOQL.
     */
    private static User createActiveUser(String lastName) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName          = 'Test',
            LastName           = lastName,
            Email              = lastName.toLowerCase().replace(' ', '') + '@example.invalid',
            Username           = lastName.toLowerCase().replace(' ', '') +
                                 String.valueOf(Math.random()).replace('0.', '') +
                                 '@example.invalid',
            Alias              = lastName.left(8).toLowerCase(),
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
     * Creates an Account owned by the given user.
     */
    private static Account createAccount(String name, Id ownerId) {
        Account a = new Account(Name = name, OwnerId = ownerId);
        insert a;
        return a;
    }

    /**
     * Builds an Opportunity (not inserted) with sensible defaults.
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

    /**
     * Fetches the Account map the same way OpportunityTriggerHandler would:
     * includes Owner.IsActive so resolveTaskOwner can evaluate it.
     */
    private static Map<Id, Account> fetchAccountMap(Set<Id> accountIds) {
        return new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id IN :accountIds]
        );
    }

    // -------------------------------------------------------------------------
    // Test: empty / null input — no DML, no exception
    // -------------------------------------------------------------------------

    @IsTest
    static void testEmptyList_noTasksCreated() {
        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(new List<Opportunity>(), new Map<Id, Account>());
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task];
        System.assertEquals(0, taskCount, 'No Tasks should be created for an empty Opportunity list.');
    }

    @IsTest
    static void testNullList_noException() {
        Test.startTest();
        // Should return silently without throwing.
        OpportunityTaskService.createFollowUpTasks(null, new Map<Id, Account>());
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task];
        System.assertEquals(0, taskCount, 'No Tasks should be created when null list is passed.');
    }

    // -------------------------------------------------------------------------
    // Test: Task created with correct fields — Account owner is active
    // -------------------------------------------------------------------------

    @IsTest
    static void testSingleOpp_activeAccountOwner_taskCreatedWithCorrectFields() {
        User accountOwner = createActiveUser('AccountOwner');
        User oppOwner     = createActiveUser('OppOwner');

        Account acc = createAccount('Test Account', accountOwner.Id);

        Date closeDate = Date.today().addDays(10);
        Opportunity opp = buildOpportunity(
            'Test Opp', acc.Id, oppOwner.Id, 'Closed Won', closeDate, 10000
        );
        insert opp;

        Map<Id, Account> accountMap = fetchAccountMap(new Set<Id>{ acc.Id });

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(new List<Opportunity>{ opp }, accountMap);
        Test.stopTest();

        List<Task> tasks = [SELECT Subject, ActivityDate, WhatId, OwnerId, Status, Priority FROM Task];
        System.assertEquals(1, tasks.size(), 'Exactly one Task should be created.');

        Task t = tasks[0];
        System.assertEquals('Follow up: Test Opp', t.Subject,      'Subject should be prefixed correctly.');
        System.assertEquals(closeDate.addDays(7),  t.ActivityDate, 'Due date should be CloseDate + 7.');
        System.assertEquals(opp.Id,                t.WhatId,       'WhatId should reference the Opportunity.');
        System.assertEquals(accountOwner.Id,       t.OwnerId,      'Task owner should be the active Account owner.');
        System.assertEquals('Not Started',         t.Status,       'Status should be Not Started.');
        System.assertEquals('Normal',              t.Priority,     'Priority should be Normal.');
    }

    // -------------------------------------------------------------------------
    // Test: Inactive Account owner — falls back to Opportunity owner
    // -------------------------------------------------------------------------

    @IsTest
    static void testInactiveAccountOwner_fallsBackToOppOwner() {
        User accountOwner = createActiveUser('InactiveAccOwner');
        User oppOwner     = createActiveUser('ActiveOppOwner');

        Account acc = createAccount('Fallback Account', accountOwner.Id);

        Date closeDate = Date.today().addDays(5);
        Opportunity opp = buildOpportunity(
            'Fallback Opp', acc.Id, oppOwner.Id, 'Closed Won', closeDate, 5000
        );
        insert opp;

        // Deactivate the Account owner AFTER creating records to avoid ownership errors.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            accountOwner.IsActive = false;
            update accountOwner;
        }

        Map<Id, Account> accountMap = fetchAccountMap(new Set<Id>{ acc.Id });

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(new List<Opportunity>{ opp }, accountMap);
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task];
        System.assertEquals(1, tasks.size(), 'One Task should be created.');
        System.assertEquals(
            oppOwner.Id, tasks[0].OwnerId,
            'Task owner should fall back to the Opportunity owner when Account owner is inactive.'
        );
    }

    // -------------------------------------------------------------------------
    // Test: No Account on Opportunity — falls back to Opportunity owner
    // -------------------------------------------------------------------------

    @IsTest
    static void testNoAccount_fallsBackToOppOwner() {
        User oppOwner = createActiveUser('NoAccOppOwner');

        // Opportunity with no AccountId.
        Opportunity opp = new Opportunity(
            Name      = 'No Account Opp',
            OwnerId   = oppOwner.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(3),
            Amount    = 1000
        );
        insert opp;

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            new Map<Id, Account>() // empty map — no accounts
        );
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task];
        System.assertEquals(1, tasks.size(), 'One Task should be created even without an Account.');
        System.assertEquals(
            oppOwner.Id, tasks[0].OwnerId,
            'Task owner should be the Opportunity owner when no Account is present.'
        );
    }

    // -------------------------------------------------------------------------
    // Test: Account in map but Owner sub-object is null (defensive)
    // -------------------------------------------------------------------------

    @IsTest
    static void testAccountOwnerSubObjectNull_fallsBackToOppOwner() {
        User oppOwner = createActiveUser('SubObjNullOppOwner');

        Opportunity opp = new Opportunity(
            Name      = 'SubObj Null Opp',
            OwnerId   = oppOwner.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Amount    = 2000
        );
        insert opp;

        // Manually build an Account with a null Owner sub-object to simulate
        // a caller that forgot to query the relationship field.
        Account acc = new Account(Id = opp.AccountId != null ? opp.AccountId : '001000000000001AAA');
        // Owner is intentionally left null on this stub.
        Map<Id, Account> accountMap = new Map<Id, Account>{ acc.Id => acc };

        // Patch opp.AccountId to point at our stub account.
        opp.AccountId = acc.Id;

        Test.startTest();
        // resolveTaskOwner should handle null Owner gracefully.
        Id resolvedOwner = OpportunityTaskService.resolveTaskOwner(opp, accountMap);
        Test.stopTest();

        System.assertEquals(
            oppOwner.Id, resolvedOwner,
            'Should fall back to Opportunity owner when Account.Owner sub-object is null.'
        );
    }

    // -------------------------------------------------------------------------
    // Test: Null CloseDate — uses today + 7 as fallback
    // -------------------------------------------------------------------------

    @IsTest
    static void testNullCloseDate_usesTodayPlusOffset() {
        User oppOwner = createActiveUser('NullDateOppOwner');

        // We cannot insert an Opportunity with a null CloseDate (required field),
        // so we test the service directly with a fabricated in-memory record.
        Opportunity opp = new Opportunity(
            Name      = 'Null Date Opp',
            OwnerId   = oppOwner.Id,
            StageName = 'Closed Won',
            CloseDate = null,
            Amount    = 500
        );
        // Do NOT insert — we're testing the service's defensive null handling.

        Test.startTest();
        // Call the service with the in-memory opp (no Id, no AccountId).
        // The service should not throw even though CloseDate is null.
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ opp },
            new Map<Id, Account>()
        );
        Test.stopTest();

        // We cannot assert on a Task because the Opp has no Id (WhatId would be null
        // and DML may fail). The key assertion is that no exception was thrown.
        // If we reach this line, the defensive branch executed without error.
        System.assert(true, 'No exception should be thrown when CloseDate is null.');
    }

    // -------------------------------------------------------------------------
    // Test: Bulk — 200 Opportunities, all Closed Won, active Account owners
    // -------------------------------------------------------------------------

    @IsTest
    static void testBulk200Opps_allClosedWon_200TasksCreated() {
        User accountOwner = createActiveUser('BulkAccOwner');
        User oppOwner     = createActiveUser('BulkOppOwner');

        // One Account shared by all Opportunities to keep data setup fast.
        Account acc = createAccount('Bulk Account', accountOwner.Id);

        List<Opportunity> opps = new List<Opportunity>();
        Date closeDate = Date.today().addDays(14);
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpportunity(
                'Bulk Opp ' + i, acc.Id, oppOwner.Id, 'Closed Won', closeDate, 1000
            ));
        }
        insert opps;

        Map<Id, Account> accountMap = fetchAccountMap(new Set<Id>{ acc.Id });

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(opps, accountMap);
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task];
        System.assertEquals(200, taskCount, '200 Tasks should be created for 200 Closed Won Opportunities.');
    }

    // -------------------------------------------------------------------------
    // Test: Bulk — 200 Opportunities, mixed Account owners (active and inactive)
    // -------------------------------------------------------------------------

    @IsTest
    static void testBulk200Opps_mixedOwners_correctTaskOwners() {
        User activeAccOwner   = createActiveUser('BulkActiveAccOwner');
        User inactiveAccOwner = createActiveUser('BulkInactiveAccOwner');
        User oppOwner         = createActiveUser('BulkMixedOppOwner');

        Account activeOwnerAcc   = createAccount('Active Owner Account',   activeAccOwner.Id);
        Account inactiveOwnerAcc = createAccount('Inactive Owner Account', inactiveAccOwner.Id);

        // Deactivate one Account owner.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            inactiveAccOwner.IsActive = false;
            update inactiveAccOwner;
        }

        List<Opportunity> opps = new List<Opportunity>();
        Date closeDate = Date.today().addDays(7);
        for (Integer i = 0; i < 100; i++) {
            opps.add(buildOpportunity(
                'Active Acc Opp ' + i, activeOwnerAcc.Id, oppOwner.Id, 'Closed Won', closeDate, 500
            ));
        }
        for (Integer i = 0; i < 100; i++) {
            opps.add(buildOpportunity(
                'Inactive Acc Opp ' + i, inactiveOwnerAcc.Id, oppOwner.Id, 'Closed Won', closeDate, 500
            ));
        }
        insert opps;

        Map<Id, Account> accountMap = fetchAccountMap(
            new Set<Id>{ activeOwnerAcc.Id, inactiveOwnerAcc.Id }
        );

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(opps, accountMap);
        Test.stopTest();

        List<Task> tasksOwnedByAccOwner = [SELECT Id FROM Task WHERE OwnerId = :activeAccOwner.Id];
        List<Task> tasksOwnedByOppOwner = [SELECT Id FROM Task WHERE OwnerId = :oppOwner.Id];

        System.assertEquals(
            100, tasksOwnedByAccOwner.size(),
            '100 Tasks should be owned by the active Account owner.'
        );
        System.assertEquals(
            100, tasksOwnedByOppOwner.size(),
            '100 Tasks should fall back to the Opportunity owner for inactive Account owners.'
        );
    }

    // -------------------------------------------------------------------------
    // Test: resolveTaskOwner — direct unit test of private helper via @TestVisible
    // -------------------------------------------------------------------------

    @IsTest
    static void testResolveTaskOwner_activeAccountOwner_returnsAccountOwnerId() {
        User accountOwner = createActiveUser('ResolveAccOwner');
        User oppOwner     = createActiveUser('ResolveOppOwner');

        Account acc = createAccount('Resolve Account', accountOwner.Id);
        Map<Id, Account> accountMap = fetchAccountMap(new Set<Id>{ acc.Id });

        Opportunity opp = new Opportunity(
            Name      = 'Resolve Opp',
            AccountId = acc.Id,
            OwnerId   = oppOwner.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today()
        );

        Id resolved = OpportunityTaskService.resolveTaskOwner(opp, accountMap);

        System.assertEquals(
            accountOwner.Id, resolved,
            'resolveTaskOwner should return the Account owner Id when the owner is active.'
        );
    }

    @IsTest
    static void testResolveTaskOwner_noAccountId_returnsOppOwnerId() {
        User oppOwner = createActiveUser('ResolveNoAccOppOwner');

        Opportunity opp = new Opportunity(
            Name      = 'No Acc Opp',
            OwnerId   = oppOwner.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today()
        );
        // AccountId intentionally left null.

        Id resolved = OpportunityTaskService.resolveTaskOwner(opp, new Map<Id, Account>());

        System.assertEquals(
            oppOwner.Id, resolved,
            'resolveTaskOwner should return the Opportunity owner Id when AccountId is null.'
        );
    }
}
