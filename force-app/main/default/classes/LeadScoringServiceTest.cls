/**
 * @description Test class for LeadScoringService. Covers all scoring dimensions,
 *              edge cases, and the bulk scoring API.
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 * @group   Lead Management
 */
@IsTest
private class LeadScoringServiceTest {

    // ---------------------------------------------------------------------------
    // scoreLead — Happy Path
    // ---------------------------------------------------------------------------

    @IsTest
    static void scoreLead_enterpriseTechLead_shouldReturnHighScore() {
        Lead testLead = buildLead(
            'Acme',
            'Technology',
            5000,
            150000000,
            'Partner Referral',
            'Hot',
            'cto@acmecorp.com',
            '+1-555-0100',
            'We are looking for an enterprise platform to consolidate our CRM and ERP systems across 12 regions.'
        );

        Test.startTest();
        Integer score = LeadScoringService.scoreLead(testLead);
        Test.stopTest();

        // Enterprise (25) + Technology (25) + strong engagement + hot budget → near max
        System.assert(score >= 80, 'Enterprise tech lead should score at least 80. Actual: ' + score);
        System.assert(score <= 100, 'Score should not exceed 100. Actual: ' + score);
    }

    @IsTest
    static void scoreLead_smallUnknownIndustry_shouldReturnLowScore() {
        Lead testLead = buildLead(
            'Corner Shop',
            'Agriculture',
            10,
            50000,
            null,
            'Cold',
            null,
            null,
            null
        );

        Test.startTest();
        Integer score = LeadScoringService.scoreLead(testLead);
        Test.stopTest();

        System.assert(score < 30, 'Small unknown-industry lead should score below 30. Actual: ' + score);
    }

    @IsTest
    static void scoreLead_midMarketHealthcare_shouldReturnModerateScore() {
        Lead testLead = buildLead(
            'MedTech Solutions',
            'Healthcare',
            350,
            25000000,
            'Web',
            'Warm',
            'buyer@medtech.com',
            '+1-555-0200',
            'Interested in patient management module.'
        );

        Test.startTest();
        Integer score = LeadScoringService.scoreLead(testLead);
        Test.stopTest();

        System.assert(score >= 50 && score <= 85,
            'Mid-market healthcare lead should score 50–85. Actual: ' + score);
    }

    // ---------------------------------------------------------------------------
    // scoreLead — Edge Cases
    // ---------------------------------------------------------------------------

    @IsTest
    static void scoreLead_nullLead_shouldThrowException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            LeadScoringService.scoreLead(null);
        } catch (LeadScoringService.LeadScoringException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('null'),
                'Exception message should mention null. Actual: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'LeadScoringException should be thrown for null input.');
    }

    @IsTest
    static void scoreLead_allNullFields_shouldReturnZero() {
        Lead testLead = new Lead(
            LastName  = 'Empty',
            Company   = 'None'
        );

        Test.startTest();
        Integer score = LeadScoringService.scoreLead(testLead);
        Test.stopTest();

        System.assertEquals(0, score, 'Lead with all null scoring fields should return 0.');
    }

    @IsTest
    static void scoreLead_freeEmailDomain_shouldScoreLower() {
        Lead corporateEmail = buildLead('Test', 'Technology', 100, null, null, null,
            'buyer@enterprise.com', null, null);
        Lead freeEmail = buildLead('Test', 'Technology', 100, null, null, null,
            'buyer@gmail.com', null, null);

        Test.startTest();
        Integer corpScore = LeadScoringService.scoreLead(corporateEmail);
        Integer freeScore = LeadScoringService.scoreLead(freeEmail);
        Test.stopTest();

        System.assert(corpScore > freeScore,
            'Corporate email should score higher than free email. Corp: ' + corpScore + ', Free: ' + freeScore);
    }

    // ---------------------------------------------------------------------------
    // scoreLeads — Bulk
    // ---------------------------------------------------------------------------

    @IsTest
    static void scoreLeads_bulkList_shouldReturnMapOfScores() {
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(buildLead(
                'Company ' + i,
                'Technology',
                100 * i,
                1000000,
                'Web',
                'Warm',
                'lead' + i + '@company.com',
                null,
                null
            ));
        }

        // Insert to get Ids
        insert leads;

        Test.startTest();
        Map<Id, Integer> scores = LeadScoringService.scoreLeads(leads);
        Test.stopTest();

        System.assertEquals(200, scores.size(), 'Should return a score for every lead.');

        for (Integer score : scores.values()) {
            System.assert(score >= 0 && score <= 100,
                'Every score should be 0–100. Found: ' + score);
        }
    }

    @IsTest
    static void scoreLeads_emptyList_shouldReturnEmptyMap() {
        Test.startTest();
        Map<Id, Integer> scores = LeadScoringService.scoreLeads(new List<Lead>());
        Test.stopTest();

        System.assertEquals(0, scores.size(), 'Empty input should produce empty output.');
    }

    // ---------------------------------------------------------------------------
    // getScoreTier
    // ---------------------------------------------------------------------------

    @IsTest
    static void getScoreTier_shouldReturnCorrectTiers() {
        System.assertEquals('Hot',      LeadScoringService.getScoreTier(95));
        System.assertEquals('Hot',      LeadScoringService.getScoreTier(80));
        System.assertEquals('Warm',     LeadScoringService.getScoreTier(55));
        System.assertEquals('Warm',     LeadScoringService.getScoreTier(79));
        System.assertEquals('Cool',     LeadScoringService.getScoreTier(30));
        System.assertEquals('Cool',     LeadScoringService.getScoreTier(54));
        System.assertEquals('Cold',     LeadScoringService.getScoreTier(0));
        System.assertEquals('Cold',     LeadScoringService.getScoreTier(29));
        System.assertEquals('Unscored', LeadScoringService.getScoreTier(null));
        System.assertEquals('Unscored', LeadScoringService.getScoreTier(-5));
    }

    // ---------------------------------------------------------------------------
    // Individual Dimension Tests
    // ---------------------------------------------------------------------------

    @IsTest
    static void evaluateCompanySize_shouldScaleWithEmployeeCount() {
        System.assertEquals(0,  LeadScoringService.evaluateCompanySize(null));
        System.assertEquals(0,  LeadScoringService.evaluateCompanySize(0));
        System.assertEquals(8,  LeadScoringService.evaluateCompanySize(25));
        System.assertEquals(12, LeadScoringService.evaluateCompanySize(100));
        System.assertEquals(20, LeadScoringService.evaluateCompanySize(500));
        System.assertEquals(25, LeadScoringService.evaluateCompanySize(5000));
    }

    @IsTest
    static void evaluateIndustryFit_shouldMatchConfiguredScores() {
        System.assertEquals(25, LeadScoringService.evaluateIndustryFit('Technology'));
        System.assertEquals(22, LeadScoringService.evaluateIndustryFit('Financial Services'));
        System.assertEquals(5,  LeadScoringService.evaluateIndustryFit('Unknown Industry'));
        System.assertEquals(0,  LeadScoringService.evaluateIndustryFit(null));
        System.assertEquals(0,  LeadScoringService.evaluateIndustryFit(''));
    }

    // ---------------------------------------------------------------------------
    // Helper
    // ---------------------------------------------------------------------------

    private static Lead buildLead(
        String company, String industry, Integer employees, Decimal revenue,
        String source, String rating, String email, String phone, String description
    ) {
        return new Lead(
            FirstName         = 'Test',
            LastName          = 'Lead',
            Company           = company,
            Industry          = industry,
            NumberOfEmployees = employees,
            AnnualRevenue     = revenue,
            LeadSource        = source,
            Rating            = rating,
            Email             = email,
            Phone             = phone,
            Description       = description
        );
    }
}
