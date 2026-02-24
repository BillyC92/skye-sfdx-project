/**
 * OpportunityTaskServiceTest
 *
 * Unit tests for OpportunityTaskService. Each test method covers a distinct
 * scenario and includes meaningful assertions — not just coverage lines.
 *
 * Test data is created inline (no @TestSetup) so each test is fully
 * self-contained and failures are easy to isolate.
 */
@IsTest
private class OpportunityTaskServiceTest {

    // -------------------------------------------------------------------------
    // Helper factories
    // -------------------------------------------------------------------------

    /**
     * Creates a minimal active User for use as an Account or Opportunity owner.
     * Inserts the user and returns it.
     */
    private static User createActiveUser(String lastName) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            LastName           = lastName,
            Email              = lastName.toLowerCase() + '@example.invalid',
            Username           = lastName.toLowerCase() + System.currentTimeMillis() + '@example.invalid',
            Alias              = lastName.left(8),
            TimeZoneSidKey     = 'America/New_York',
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
     * Creates an Account owned by the given user and returns it.
     */
    private static Account createAccount(String name, Id ownerId) {
        Account a = new Account(Name = name, OwnerId = ownerId);
        insert a;
        return a;
    }

    /**
     * Creates an Opportunity with the given stage and amount.
     */
    private static Opportunity createOpportunity(
        String name,
        String stage,
        Decimal amount,
        Id accountId,
        Id ownerId,
        Date closeDate
    ) {
        Opportunity opp = new Opportunity(
            Name        = name,
            StageName   = stage,
            Amount      = amount,
            AccountId   = accountId,
            OwnerId     = ownerId,
            CloseDate   = closeDate
        );
        insert opp;
        return opp;
    }

    /**
     * Builds an accountMap (Id → Account with Owner) for the given accounts.
     * Mirrors what OpportunityTriggerHandler would supply.
     */
    private static Map<Id, Account> buildAccountMap(List<Account> accounts) {
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();
        Map<Id, Account> result = new Map<Id, Account>(
            [SELECT Id, OwnerId, Owner.IsActive FROM Account WHERE Id IN :accountIds]
        );
        return result;
    }

    // =========================================================================
    // Test: single Closed Won insert creates a Task
    // =========================================================================
    @IsTest
    static void testInsert_ClosedWon_CreatesTask() {
        User oppOwner = createActiveUser('OppOwner');
        User acctOwner = createActiveUser('AcctOwner');

        Account acct;
        Opportunity opp;

        System.runAs(oppOwner) {
            acct = createAccount('Test Account', acctOwner.Id);
            opp  = createOpportunity(
                'Deal Alpha', 'Closed Won', 10000,
                acct.Id, oppOwner.Id, Date.today().addDays(10)
            );
        }

        Map<Id, Account> accountMap = buildAccountMap(new List<Account>{ acct });

        // Re-query opp to get a clean record as the trigger would see it.
        List<Opportunity> newOpps = [SELECT Id, Name, StageName, OwnerId, AccountId, CloseDate FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, null, accountMap);
        Test.stopTest();

        List<Task> tasks = [SELECT Subject, ActivityDate, Status, WhatId, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Exactly one follow-up Task should be created for a Closed Won insert');

        Task t = tasks[0];
        System.assertEquals('Follow up: Deal Alpha', t.Subject, 'Task subject should match the Opportunity name');
        System.assertEquals(Date.today().addDays(10 + 7), t.ActivityDate, 'ActivityDate should be CloseDate + 7 days');
        System.assertEquals('Not Started', t.Status, 'Task status should be Not Started');
        System.assertEquals(opp.Id, t.WhatId, 'Task WhatId should reference the Opportunity');
        // Account owner is active — Task should be assigned to account owner.
        System.assertEquals(acctOwner.Id, t.OwnerId, 'Task owner should be the active Account owner');
    }

    // =========================================================================
    // Test: update to Closed Won creates a Task
    // =========================================================================
    @IsTest
    static void testUpdate_TransitionToClosedWon_CreatesTask() {
        User oppOwner = createActiveUser('OppOwner2');
        User acctOwner = createActiveUser('AcctOwner2');

        Account acct;
        Opportunity opp;

        System.runAs(oppOwner) {
            acct = createAccount('Account B', acctOwner.Id);
            opp  = createOpportunity(
                'Deal Beta', 'Prospecting', 20000,
                acct.Id, oppOwner.Id, Date.today().addDays(30)
            );
        }

        Map<Id, Account> accountMap = buildAccountMap(new List<Account>{ acct });

        // Simulate the old record (stage = Prospecting)
        Opportunity oldOpp = new Opportunity(Id = opp.Id, StageName = 'Prospecting');
        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ opp.Id => oldOpp };

        // Simulate the new record (stage = Closed Won)
        Opportunity newOpp = opp.clone(true, true, false, false);
        newOpp.StageName = 'Closed Won';
        List<Opportunity> newOpps = new List<Opportunity>{ newOpp };

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, oldMap, accountMap);
        Test.stopTest();

        List<Task> tasks = [SELECT Subject, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'One Task should be created when transitioning to Closed Won');
        System.assertEquals('Follow up: Deal Beta', tasks[0].Subject, 'Subject should reference the Opportunity name');
    }

    // =========================================================================
    // Test: update where stage was already Closed Won does NOT create a Task
    // =========================================================================
    @IsTest
    static void testUpdate_AlreadyClosedWon_NoTaskCreated() {
        User oppOwner = createActiveUser('OppOwner3');

        Opportunity opp;
        System.runAs(oppOwner) {
            opp = createOpportunity(
                'Deal Gamma', 'Closed Won', 5000,
                null, oppOwner.Id, Date.today()
            );
        }

        // Both old and new are Closed Won — no transition.
        Opportunity oldOpp = new Opportunity(Id = opp.Id, StageName = 'Closed Won');
        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ opp.Id => oldOpp };

        Opportunity newOpp = opp.clone(true, true, false, false);
        newOpp.StageName = 'Closed Won';
        newOpp.Amount = 9999; // some unrelated field change
        List<Opportunity> newOpps = new List<Opportunity>{ newOpp };

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, oldMap, new Map<Id, Account>());
        Test.stopTest();

        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(0, tasks.size(), 'No Task should be created when the stage was already Closed Won');
    }

    // =========================================================================
    // Test: inactive Account owner falls back to Opportunity owner
    // =========================================================================
    @IsTest
    static void testInsert_InactiveAccountOwner_FallsBackToOppOwner() {
        User oppOwner    = createActiveUser('OppOwner4');
        User acctOwner   = createActiveUser('AcctOwner4');

        Account acct;
        Opportunity opp;

        System.runAs(oppOwner) {
            acct = createAccount('Account D', acctOwner.Id);
            opp  = createOpportunity(
                'Deal Delta', 'Closed Won', 15000,
                acct.Id, oppOwner.Id, Date.today().addDays(5)
            );
        }

        // Deactivate the account owner.
        acctOwner.IsActive = false;
        update acctOwner;

        Map<Id, Account> accountMap = buildAccountMap(new List<Account>{ acct });

        List<Opportunity> newOpps = [SELECT Id, Name, StageName, OwnerId, AccountId, CloseDate FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, null, accountMap);
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'A Task should still be created when the Account owner is inactive');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId, 'Task should fall back to the Opportunity owner when Account owner is inactive');
    }

    // =========================================================================
    // Test: bulk insert of 200 Opportunities with mixed stages
    // =========================================================================
    @IsTest
    static void testBulkInsert_MixedStages_OnlyClosedWonGetTasks() {
        User oppOwner = createActiveUser('BulkOwner');

        List<Opportunity> opps = new List<Opportunity>();
        Integer closedWonCount = 0;

        for (Integer i = 0; i < 200; i++) {
            String stage = Math.mod(i, 2) == 0 ? 'Closed Won' : 'Prospecting';
            if (stage == 'Closed Won') {
                closedWonCount++;
            }
            opps.add(new Opportunity(
                Name      = 'Bulk Opp ' + i,
                StageName = stage,
                Amount    = 1000,
                OwnerId   = oppOwner.Id,
                CloseDate = Date.today().addDays(i)
            ));
        }

        System.runAs(oppOwner) {
            insert opps;
        }

        List<Opportunity> newOpps = [
            SELECT Id, Name, StageName, OwnerId, AccountId, CloseDate
            FROM Opportunity
            WHERE Id IN :opps
        ];

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, null, new Map<Id, Account>());
        Test.stopTest();

        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId IN :oppIds];
        System.assertEquals(
            closedWonCount,
            tasks.size(),
            'Exactly one Task per Closed Won Opportunity should be created in a bulk scenario'
        );
    }

    // =========================================================================
    // Test: null CloseDate — Task is still created with null ActivityDate
    // =========================================================================
    @IsTest
    static void testInsert_NullCloseDate_TaskCreatedWithNullActivityDate() {
        User oppOwner = createActiveUser('NullDateOwner');

        Opportunity opp;
        System.runAs(oppOwner) {
            // CloseDate is required by standard validation but we test the
            // service layer in isolation using a cloned/constructed record.
            opp = new Opportunity(
                Id        = null,
                Name      = 'No Close Date Deal',
                StageName = 'Closed Won',
                OwnerId   = oppOwner.Id,
                CloseDate = Date.today() // required for DML; we override below
            );
            insert opp;
        }

        // Construct a synthetic record with null CloseDate to test the service
        // directly without triggering standard field validation.
        Opportunity syntheticOpp = new Opportunity(
            Id        = opp.Id,
            Name      = 'No Close Date Deal',
            StageName = 'Closed Won',
            OwnerId   = oppOwner.Id,
            CloseDate = null
        );

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(
            new List<Opportunity>{ syntheticOpp },
            null,
            new Map<Id, Account>()
        );
        Test.stopTest();

        List<Task> tasks = [SELECT ActivityDate FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Task should be created even when CloseDate is null');
        System.assertNull(tasks[0].ActivityDate, 'ActivityDate should be null when CloseDate is null');
    }

    // =========================================================================
    // Test: null Amount — no impact on Task creation (Amount not used here)
    // =========================================================================
    @IsTest
    static void testInsert_NullAmount_TaskCreatedNormally() {
        User oppOwner = createActiveUser('NullAmtOwner');

        Opportunity opp;
        System.runAs(oppOwner) {
            opp = createOpportunity(
                'No Amount Deal', 'Closed Won', null,
                null, oppOwner.Id, Date.today().addDays(3)
            );
        }

        List<Opportunity> newOpps = [
            SELECT Id, Name, StageName, OwnerId, AccountId, CloseDate
            FROM Opportunity WHERE Id = :opp.Id
        ];

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, null, new Map<Id, Account>());
        Test.stopTest();

        List<Task> tasks = [SELECT Subject FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Task should be created regardless of null Amount');
        System.assertEquals('Follow up: No Amount Deal', tasks[0].Subject, 'Subject should still be set correctly');
    }

    // =========================================================================
    // Test: non-Closed Won insert does NOT create a Task
    // =========================================================================
    @IsTest
    static void testInsert_NonClosedWon_NoTaskCreated() {
        User oppOwner = createActiveUser('ProspectOwner');

        Opportunity opp;
        System.runAs(oppOwner) {
            opp = createOpportunity(
                'Prospect Deal', 'Prospecting', 5000,
                null, oppOwner.Id, Date.today().addDays(60)
            );
        }

        List<Opportunity> newOpps = [
            SELECT Id, Name, StageName, OwnerId, AccountId, CloseDate
            FROM Opportunity WHERE Id = :opp.Id
        ];

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, null, new Map<Id, Account>());
        Test.stopTest();

        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(0, tasks.size(), 'No Task should be created for a non-Closed Won Opportunity');
    }

    // =========================================================================
    // Test: empty list input — no error thrown, no DML
    // =========================================================================
    @IsTest
    static void testEmptyList_NoErrorThrown() {
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            OpportunityTaskService.createFollowUpTasks(
                new List<Opportunity>(),
                null,
                new Map<Id, Account>()
            );
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertFalse(exceptionThrown, 'No exception should be thrown for an empty Opportunity list');
    }

    // =========================================================================
    // Test: null list input — no error thrown
    // =========================================================================
    @IsTest
    static void testNullList_NoErrorThrown() {
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            OpportunityTaskService.createFollowUpTasks(null, null, null);
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertFalse(exceptionThrown, 'No exception should be thrown for a null Opportunity list');
    }

    // =========================================================================
    // Test: Opportunity with no Account — falls back to Opportunity owner
    // =========================================================================
    @IsTest
    static void testInsert_NoAccount_UsesOppOwner() {
        User oppOwner = createActiveUser('NoAcctOwner');

        Opportunity opp;
        System.runAs(oppOwner) {
            opp = createOpportunity(
                'No Account Deal', 'Closed Won', 8000,
                null, oppOwner.Id, Date.today().addDays(14)
            );
        }

        List<Opportunity> newOpps = [
            SELECT Id, Name, StageName, OwnerId, AccountId, CloseDate
            FROM Opportunity WHERE Id = :opp.Id
        ];

        Test.startTest();
        OpportunityTaskService.createFollowUpTasks(newOpps, null, new Map<Id, Account>());
        Test.stopTest();

        List<Task> tasks = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(1, tasks.size(), 'Task should be created for Opportunity with no Account');
        System.assertEquals(oppOwner.Id, tasks[0].OwnerId, 'Task owner should be the Opportunity owner when no Account is present');
    }

    // =========================================================================
    // Test: private helper isTransitioningToClosedWon — direct unit coverage
    // =========================================================================
    @IsTest
    static void testIsTransitioningToClosedWon_DirectCoverage() {
        Opportunity opp = new Opportunity(
            Id        = null,
            StageName = 'Closed Won'
        );

        // Insert context (null oldMap) — should return true.
        System.assert(
            OpportunityTaskService.isTransitioningToClosedWon(opp, null),
            'Should return true for Closed Won on insert'
        );

        // Update context — was Prospecting, now Closed Won — should return true.
        Opportunity oldOpp = new Opportunity(StageName = 'Prospecting');
        // We need an Id to key the map; use a fake one.
        Id fakeId = '0060000000000001AAA';
        opp.Id = fakeId;
        oldOpp.Id = fakeId;
        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ fakeId => oldOpp };
        System.assert(
            OpportunityTaskService.isTransitioningToClosedWon(opp, oldMap),
            'Should return true when transitioning from Prospecting to Closed Won'
        );

        // Update context — was already Closed Won — should return false.
        oldOpp.StageName = 'Closed Won';
        System.assert(
            !OpportunityTaskService.isTransitioningToClosedWon(opp, oldMap),
            'Should return false when stage was already Closed Won'
        );

        // Non-Closed Won stage — should return false regardless.
        opp.StageName = 'Negotiation/Review';
        System.assert(
            !OpportunityTaskService.isTransitioningToClosedWon(opp, null),
            'Should return false for a non-Closed Won stage'
        );
    }
}
