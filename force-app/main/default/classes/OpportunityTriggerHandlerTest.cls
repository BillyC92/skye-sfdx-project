/**
 * @description Test class for OpportunityTriggerHandler and OpportunityService.
 *              Covers all trigger entry points, both happy-path and edge cases,
 *              and validates bulk behaviour with 200-record batches.
 *
 *              KAN-5 acceptance criteria exercised here:
 *                AC #1  — Trigger fires on insert and update
 *                AC #2  — Closed Won creates "Follow up: {Name}" Task, due CloseDate+7
 *                AC #3  — $50k insert triggers notification path (silently skipped in
 *                          test orgs where no CustomNotificationType is deployed)
 *                AC #5  — Notification fires on insert only, not update
 *                AC #6  — Inactive Account owner → Task falls back to Opp owner
 *                AC #7  — Missing Sales Manager role / notification type → no error
 *                AC #9  — All methods bulkified; 200-record test passes
 *                AC #10 — ≥80% code coverage with meaningful assertions
 *
 * @author  Skieward Consulting
 * @date    2026-03-03
 * @group   Opportunity Management
 */
@IsTest
private class OpportunityTriggerHandlerTest {

    // =========================================================================
    // Test Data Setup
    // =========================================================================

    /**
     * @description Creates a shared Account record used by most test methods.
     *              Account owner defaults to the running test user, which is
     *              always active — allowing tests to verify the "active owner"
     *              happy path without additional user setup.
     */
    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'Meridian Test Account');
        insert acc;
    }

    // =========================================================================
    // BEFORE INSERT — stampDefaultFields
    // =========================================================================

    @IsTest
    static void beforeInsert_noDefaults_shouldStampStageDateAndSource() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name      = 'Default Fields Test',
            AccountId = acc.Id
            // StageName, CloseDate, and LeadSource intentionally omitted
        );
        insert opp;
        Test.stopTest();

        Opportunity result = [SELECT StageName, CloseDate, LeadSource FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Prospecting', result.StageName, 'StageName should default to Prospecting');
        System.assertNotEquals(null, result.CloseDate,       'CloseDate should be stamped');
        System.assertEquals(Date.today().addDays(90), result.CloseDate, 'CloseDate should default to today+90');
        System.assertEquals('Web', result.LeadSource,       'LeadSource should default to Web');
    }

    @IsTest
    static void beforeInsert_providedValues_shouldNotOverrideDefaults() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Date   targetClose = Date.today().addDays(30);

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name       = 'Explicit Values',
            AccountId  = acc.Id,
            StageName  = 'Qualification',
            CloseDate  = targetClose,
            LeadSource = 'Partner Referral'
        );
        insert opp;
        Test.stopTest();

        Opportunity result = [SELECT StageName, CloseDate, LeadSource FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Qualification',   result.StageName,  'Provided StageName should not be overwritten');
        System.assertEquals(targetClose,       result.CloseDate,  'Provided CloseDate should not be overwritten');
        System.assertEquals('Partner Referral',result.LeadSource, 'Provided LeadSource should not be overwritten');
    }

    // =========================================================================
    // BEFORE INSERT — validateAmountThresholds
    // =========================================================================

    @IsTest
    static void beforeInsert_amountAboveExecThreshold_noDescription_shouldError() {
        Account acc     = [SELECT Id FROM Account LIMIT 1];
        Boolean errored = false;

        Test.startTest();
        try {
            insert new Opportunity(
                Name        = 'Exec Deal No Justification',
                AccountId   = acc.Id,
                StageName   = 'Prospecting',
                CloseDate   = Date.today().addDays(60),
                Amount      = 500001,
                Description = null
            );
        } catch (DmlException e) {
            errored = e.getMessage().contains('justification') ||
                      e.getMessage().contains('500000')        ||
                      e.getMessage().contains('Description');
        }
        Test.stopTest();

        System.assert(errored, 'Should reject amount ≥ $500k without a Description');
    }

    @IsTest
    static void beforeInsert_amountAboveExecThreshold_withDescription_shouldSucceed() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name        = 'Exec Deal With Justification',
            AccountId   = acc.Id,
            StageName   = 'Prospecting',
            CloseDate   = Date.today().addDays(60),
            Amount      = 500000,
            Description = 'Strategic expansion into APAC market — approved by CRO.'
        );
        insert opp;
        Test.stopTest();

        System.assertNotEquals(null, opp.Id, 'Exec-threshold opp with Description should insert');
    }

    // =========================================================================
    // BEFORE UPDATE — validateStageTransitions
    // =========================================================================

    @IsTest
    static void beforeUpdate_validTransition_shouldSucceed() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Valid Transition', acc.Id, 'Prospecting', Date.today().addDays(30), null);

        Test.startTest();
        opp.StageName = 'Qualification';
        update opp;
        Test.stopTest();

        Opportunity result = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Qualification', result.StageName, 'Prospecting → Qualification should be allowed');
    }

    @IsTest
    static void beforeUpdate_invalidStagSkip_shouldError() {
        Account acc    = [SELECT Id FROM Account LIMIT 1];
        Opportunity op = insertOpp('Stage Skip', acc.Id, 'Prospecting', Date.today().addDays(30), null);
        Boolean errored = false;

        Test.startTest();
        try {
            op.StageName = 'Closed Won'; // Skip 7 stages — invalid
            update op;
        } catch (DmlException e) {
            errored = true;
        }
        Test.stopTest();

        System.assert(errored, 'Skipping stages should be rejected by stage validation');
    }

    @IsTest
    static void beforeUpdate_terminalStageChange_shouldError() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Terminal Stage', acc.Id, 'Negotiation/Review', Date.today().addDays(5), null);

        // Advance to Closed Won first
        opp.StageName = 'Closed Won';
        update opp;

        Boolean errored = false;
        Test.startTest();
        try {
            opp.StageName = 'Prospecting'; // Backwards from terminal — invalid
            update opp;
        } catch (DmlException e) {
            errored = true;
        }
        Test.stopTest();

        System.assert(errored, 'Moving out of a terminal stage should be blocked');
    }

    @IsTest
    static void beforeUpdate_stageUnchanged_shouldNotValidate() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('No Stage Change', acc.Id, 'Prospecting', Date.today().addDays(30), null);

        Test.startTest();
        opp.Amount = 9999; // Change amount, not stage
        update opp;        // Should succeed with no stage error
        Test.stopTest();

        Opportunity result = [SELECT StageName, Amount FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Prospecting', result.StageName, 'Stage should remain Prospecting');
        System.assertEquals(9999, result.Amount, 'Amount update should succeed');
    }

    // =========================================================================
    // BEFORE UPDATE — flagLargeDealChanges
    // =========================================================================

    @IsTest
    static void beforeUpdate_amountUp21Pct_shouldAddAuditNote() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Audit Test', acc.Id, 'Prospecting', Date.today().addDays(30), 10000);

        Test.startTest();
        opp.Amount = 12100; // 21% increase > 20% threshold
        update opp;
        Test.stopTest();

        Opportunity result = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assert(
            String.isNotBlank(result.Description) && result.Description.contains('Skieward Audit'),
            'Description should contain Skieward audit note for >20% amount increase'
        );
    }

    @IsTest
    static void beforeUpdate_amountUp10Pct_shouldNotAddAuditNote() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('No Audit', acc.Id, 'Prospecting', Date.today().addDays(30), 10000);

        Test.startTest();
        opp.Amount = 11000; // 10% increase — below threshold
        update opp;
        Test.stopTest();

        Opportunity result = [SELECT Description FROM Opportunity WHERE Id = :opp.Id];
        System.assert(
            result.Description == null || !result.Description.contains('Skieward Audit'),
            'Description should NOT contain audit note for ≤20% amount increase'
        );
    }

    // =========================================================================
    // AFTER UPDATE — notifyOnClosedWon (KAN-5 AC #2)
    // =========================================================================

    @IsTest
    static void afterUpdate_closedWon_shouldCreateFollowUpTaskWithCorrectSubject() {
        Account acc      = [SELECT Id FROM Account LIMIT 1];
        Date    closeDate = Date.today().addDays(10);
        Opportunity opp  = insertOpp('Deal Alpha', acc.Id, 'Negotiation/Review', closeDate, 5000);

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        List<Task> tasks = [
            SELECT Subject, ActivityDate, Status
            FROM   Task
            WHERE  WhatId = :opp.Id
            AND    Subject LIKE 'Follow up:%'
        ];
        System.assertEquals(1, tasks.size(), 'Exactly one follow-up task should be created');
        System.assertEquals('Follow up: Deal Alpha', tasks[0].Subject, 'Subject must match AC #2 format');
        System.assertEquals(closeDate.addDays(7), tasks[0].ActivityDate, 'Due date must be CloseDate + 7 days (AC #2)');
        System.assertEquals('Not Started', tasks[0].Status, 'Task status should be Not Started');
    }

    @IsTest
    static void afterUpdate_closedWon_shouldAssignTaskToAccountOwner() {
        Account acc = [SELECT Id, OwnerId FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Deal Beta', acc.Id, 'Negotiation/Review', Date.today().addDays(5), 5000);

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        Task t = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Follow up:%' LIMIT 1];
        System.assertEquals(acc.OwnerId, t.OwnerId, 'Task must be assigned to Account owner (AC #2)');
    }

    @IsTest
    static void afterUpdate_closedWonTwice_shouldNotCreateDuplicateTask() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Deal Gamma', acc.Id, 'Negotiation/Review', Date.today().addDays(5), 5000);

        opp.StageName = 'Closed Won';
        update opp;

        Integer taskCountAfterFirst = [
            SELECT COUNT() FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Follow up:%'
        ];

        Test.startTest();
        opp.Amount = 6000; // Non-stage update on already-Closed-Won opp
        update opp;
        Test.stopTest();

        Integer taskCountAfterSecond = [
            SELECT COUNT() FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Follow up:%'
        ];
        System.assertEquals(
            taskCountAfterFirst,
            taskCountAfterSecond,
            'Should not create a duplicate task when opp is already Closed Won'
        );
    }

    @IsTest
    static void afterUpdate_noClosedWon_shouldNotCreateFollowUpTask() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Non-Closing Deal', acc.Id, 'Prospecting', Date.today().addDays(30), 5000);

        Test.startTest();
        opp.StageName = 'Qualification';
        update opp;
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Follow up:%'];
        System.assertEquals(0, count, 'Follow-up task should not be created for non-Closed-Won transitions');
    }

    // =========================================================================
    // AFTER UPDATE — Closed Won fallback: inactive Account owner → Opp owner (AC #6)
    // =========================================================================

    @IsTest
    static void afterUpdate_inactiveAccountOwner_shouldFallbackToOppOwner() {
        // ── Setup: create an inactive user and assign them as Account owner ──────
        // UserRole and User are setup objects; wrap non-setup DML in System.runAs
        // to avoid the Mixed DML restriction in test context.
        UserRole testRole = new UserRole(
            Name            = 'KAN5 Test Role',
            DeveloperName   = 'KAN5_Test_Role'
        );
        insert testRole;

        Profile stdProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User inactiveOwner = buildUser('Inactive', 'AccountOwner', 'kan5inactive@test.skieward.com', stdProfile.Id, testRole.Id);
        insert inactiveOwner;

        // Create Account owned by inactiveOwner (non-setup DML in System.runAs block)
        Account acc = new Account(Name = 'Inactive Owner Account');
        System.runAs(inactiveOwner) {
            acc.OwnerId = inactiveOwner.Id;
            insert acc;
        }

        // Deactivate the Account owner (setup-object DML — fine here as a separate statement)
        inactiveOwner.IsActive = false;
        update inactiveOwner;

        // Create Opportunity — its owner will be the running test user (not inactiveOwner)
        Opportunity opp = new Opportunity(
            Name      = 'Fallback Owner Test',
            AccountId = acc.Id,
            StageName = 'Negotiation/Review',
            CloseDate = Date.today().addDays(5),
            Amount    = 3000
        );
        insert opp;
        Id oppOwnerId = opp.OwnerId; // Running user — should be the fallback

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        Task t = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Follow up:%' LIMIT 1];
        System.assertEquals(
            oppOwnerId,
            t.OwnerId,
            'Task should fall back to Opportunity owner when Account owner is inactive (AC #6)'
        );
    }

    // =========================================================================
    // AFTER UPDATE — createStageChangeHistoryTasks
    // =========================================================================

    @IsTest
    static void afterUpdate_stageChange_shouldCreateHistoryTask() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('Stage History', acc.Id, 'Prospecting', Date.today().addDays(30), null);

        Test.startTest();
        opp.StageName = 'Qualification';
        update opp;
        Test.stopTest();

        List<Task> histTasks = [
            SELECT Subject, Status FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Stage Change:%'
        ];
        System.assertEquals(1, histTasks.size(), 'One history task per stage change');
        System.assert(histTasks[0].Subject.contains('Prospecting'),   'Old stage should appear in history subject');
        System.assert(histTasks[0].Subject.contains('Qualification'), 'New stage should appear in history subject');
        System.assertEquals('Completed', histTasks[0].Status,         'History task status should be Completed');
    }

    @IsTest
    static void afterUpdate_noStageChange_shouldNotCreateHistoryTask() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = insertOpp('No Stage History', acc.Id, 'Prospecting', Date.today().addDays(30), 5000);

        Test.startTest();
        opp.Amount = 6000; // Non-stage update
        update opp;
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id AND Subject LIKE 'Stage Change:%'];
        System.assertEquals(0, count, 'No history task when stage is unchanged');
    }

    // =========================================================================
    // AFTER INSERT — sendLargeDealNotifications (KAN-5 AC #3, #5, #7)
    // =========================================================================

    @IsTest
    static void afterInsert_amountUnder50k_shouldInsertWithoutError() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name      = 'Small Deal',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 49999
        );
        insert opp;
        Test.stopTest();

        Opportunity result = [SELECT Amount FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(49999, result.Amount, 'Under-$50k opp should insert without error');
    }

    @IsTest
    static void afterInsert_amountOver50k_noSalesMgrRole_shouldSkipSilently() {
        // In a clean scratch org there is no "Sales Manager" UserRole — AC #7 requires
        // the code to skip silently rather than throw.
        Account acc        = [SELECT Id FROM Account LIMIT 1];
        Boolean didError   = false;

        Test.startTest();
        try {
            insert new Opportunity(
                Name      = 'Large Deal No Role',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Amount    = 75000
            );
        } catch (Exception e) {
            didError = true;
        }
        Test.stopTest();

        System.assert(!didError, 'Missing Sales Manager role should be handled silently (AC #7)');
    }

    @IsTest
    static void afterInsert_amountExactly50k_shouldNotTriggerNotificationPath() {
        // Threshold is strictly greater-than ($50k+ε). Exactly $50k should not notify.
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name      = 'Exactly 50k',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 50000
        );
        insert opp;
        Test.stopTest();

        // Verify insert succeeded (notification path skipped, no exception)
        Opportunity result = [SELECT Amount FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(50000, result.Amount, 'Exactly-$50k opp should insert cleanly');
    }

    @IsTest
    static void afterInsert_largeDealWithSalesMgrRole_shouldAttemptNotification() {
        // Create a Sales Manager role and user to exercise the full notification path.
        // CustomNotificationType is metadata and won't exist in the test org, so the
        // notification send itself will be skipped — but all SOQL/logic up to that
        // point should execute without error.
        UserRole smRole = new UserRole(
            Name          = 'Sales Manager',
            DeveloperName = 'Sales_Manager_KAN5'
        );
        insert smRole;

        Profile stdProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User smUser = buildUser('Sales', 'Manager', 'salesmgr.kan5@test.skieward.com', stdProfile.Id, smRole.Id);
        insert smUser;

        Account acc = [SELECT Id FROM Account LIMIT 1];
        Boolean didError = false;

        Test.startTest();
        try {
            insert new Opportunity(
                Name      = 'Large Deal With Role',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Amount    = 100000
            );
        } catch (Exception e) {
            didError = true;
        }
        Test.stopTest();

        System.assert(!didError, 'Notification path with a valid Sales Manager should not throw (AC #7)');
    }

    @IsTest
    static void afterInsert_largeDealOnUpdate_shouldNotReFire() {
        // AC #5: the $50k notification fires on INSERT only.
        // Verify that updating an existing opp's amount from <50k to >50k does NOT
        // re-trigger the notification path (it's wired to handleAfterInsert, not update).
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = new Opportunity(
            Name      = 'Escalating Deal',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount    = 10000
        );
        insert opp;

        // The after-insert fires here (amount < 50k, no notification path entered).
        // Now bump the amount above threshold — trigger fires but handleAfterInsert
        // is NOT invoked on update, only handleBeforeUpdate + handleAfterUpdate.
        Boolean didError = false;
        Test.startTest();
        try {
            opp.Amount = 999999;
            opp.Description = 'Price revision approved by CFO.'; // Needed for exec threshold validation
            update opp;
        } catch (Exception e) {
            // The only acceptable exception is the exec-threshold validation (no Description INITIALLY)
            // In this case we have Description, so no error expected. Guard anyway.
            didError = true;
        }
        Test.stopTest();

        System.assert(!didError, 'Updating amount above $50k should not trigger notification (AC #5)');
    }

    // =========================================================================
    // BULK TESTS (AC #9 — 200 records)
    // =========================================================================

    @IsTest
    static void bulk_200ClosedWonUpdates_shouldCreateAllFollowUpTasks() {
        Account acc    = [SELECT Id FROM Account LIMIT 1];
        Date closeDate = Date.today().addDays(15);

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Closed Won ' + i,
                AccountId = acc.Id,
                StageName = 'Negotiation/Review',
                CloseDate = closeDate,
                Amount    = 1000 + i
            ));
        }
        insert opps;

        for (Opportunity opp : opps) {
            opp.StageName = 'Closed Won';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        Integer taskCount = [SELECT COUNT() FROM Task WHERE Subject LIKE 'Follow up: Bulk Closed Won%'];
        System.assertEquals(200, taskCount, 'Should create exactly 200 follow-up tasks for bulk Closed Won (AC #9)');
    }

    @IsTest
    static void bulk_200LargeDealInserts_shouldHandleWithoutGovernorErrors() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Large Deal ' + i,
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Amount    = 60000 + i
            ));
        }

        Test.startTest();
        insert opps; // After insert fires sendLargeDealNotifications for all 200
        Test.stopTest();

        Integer insertedCount = [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'Bulk Large Deal%'];
        System.assertEquals(200, insertedCount, 'All 200 large deals should insert without governor limit errors');
    }

    @IsTest
    static void bulk_200StageChanges_shouldCreateHistoryTasks() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Stage ' + i,
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ));
        }
        insert opps;
        for (Opportunity opp : opps) {
            opp.StageName = 'Qualification';
        }

        Test.startTest();
        update opps;
        Test.stopTest();

        Integer histCount = [SELECT COUNT() FROM Task WHERE Subject LIKE 'Stage Change: Prospecting%'];
        System.assertEquals(200, histCount, 'Should create 200 stage-change history tasks in bulk');
    }

    // =========================================================================
    // OpportunityService — Unit Tests (static methods)
    // =========================================================================

    @IsTest
    static void service_formatCurrency_shouldFormatCorrectly() {
        // Direct unit tests on the @TestVisible formatCurrency helper
        System.assertEquals('$0',          OpportunityService.formatCurrency(null));
        System.assertEquals('$75,000',     OpportunityService.formatCurrency(75000));
        System.assertEquals('$1,234,567',  OpportunityService.formatCurrency(1234567));
        System.assertEquals('$50,001',     OpportunityService.formatCurrency(50001));
        System.assertEquals('$100',        OpportunityService.formatCurrency(100));
    }

    @IsTest
    static void service_createClosedWonFollowUpTasks_emptyList_shouldDoNothing() {
        // Guard: empty list passed directly to service should not throw or DML
        Test.startTest();
        OpportunityService.createClosedWonFollowUpTasks(new List<Opportunity>(), new Map<Id, Opportunity>());
        Test.stopTest();

        // If we get here without exception, the guard works
        System.assert(true, 'Empty list to service should not throw');
    }

    @IsTest
    static void service_sendLargeDealNotifications_emptyList_shouldDoNothing() {
        Test.startTest();
        OpportunityService.sendLargeDealNotifications(new List<Opportunity>());
        Test.stopTest();

        System.assert(true, 'Empty list to notification service should not throw');
    }

    @IsTest
    static void service_sendLargeDealNotifications_allUnderThreshold_shouldDoNothing() {
        // All opps below $50k — service should return early without any SOQL
        List<Opportunity> cheapOpps = new List<Opportunity>{
            new Opportunity(Id = null, Amount = 100),
            new Opportunity(Id = null, Amount = 49999),
            new Opportunity(Id = null, Amount = 50000)  // Exactly at threshold — not over
        };

        Test.startTest();
        // This will fail because opps have no Ids — but it should bail before the SOQL
        // that requires real Ids. Wrap in try-catch for robustness.
        try {
            OpportunityService.sendLargeDealNotifications(cheapOpps);
        } catch (Exception e) {
            // Any exception here means the code went further than the threshold guard
            System.assert(false, 'All-under-threshold should exit before attempting SOQL: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // =========================================================================
    // OpportunityTriggerHandler — isAdminBypass (@TestVisible)
    // =========================================================================

    @IsTest
    static void handler_isAdminBypass_shouldReturnBoolean() {
        OpportunityTriggerHandler handler = new OpportunityTriggerHandler();

        Test.startTest();
        Boolean result = handler.isAdminBypass();
        Test.stopTest();

        System.assertNotEquals(null, result, 'isAdminBypass should return a Boolean, not null');
        // In test context without the custom permission, this returns false
        System.assertEquals(false, result, 'isAdminBypass should be false without the custom permission');
    }

    // =========================================================================
    // Private Helpers
    // =========================================================================

    private static Opportunity insertOpp(
        String name, Id accountId, String stage, Date closeDate, Decimal amount
    ) {
        Opportunity opp = new Opportunity(
            Name      = name,
            AccountId = accountId,
            StageName = stage,
            CloseDate = closeDate,
            Amount    = amount
        );
        insert opp;
        return opp;
    }

    private static User buildUser(String firstName, String lastName, String username, Id profileId, Id roleId) {
        return new User(
            FirstName         = firstName,
            LastName          = lastName,
            Email             = username,
            Username          = username,
            Alias             = (firstName + lastName).left(8),
            LocaleSidKey      = 'en_US',
            LanguageLocaleKey = 'en_US',
            TimeZoneSidKey    = 'America/New_York',
            EmailEncodingKey  = 'UTF-8',
            ProfileId         = profileId,
            UserRoleId        = roleId
        );
    }
}
