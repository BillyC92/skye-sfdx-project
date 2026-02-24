/**
 * @description Calculates a composite health score for Account records based on
 *              three dimensions: opportunity pipeline strength, support case trends,
 *              and recent activity volume. Designed for the Acme Corp customer
 *              success dashboard.
 *
 *              Health Score Range: 0–100
 *                  85–100  Thriving
 *                  65–84   Healthy
 *                  40–64   Needs Attention
 *                  0–39    At Risk
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 * @group   Account Management
 */
public with sharing class AccountHealthCalculator {

    // ---------------------------------------------------------------------------
    // Inner Types
    // ---------------------------------------------------------------------------

    /**
     * @description Value object encapsulating the health score breakdown for an Account.
     */
    public class HealthResult {
        @AuraEnabled public Id      accountId;
        @AuraEnabled public Integer overallScore;
        @AuraEnabled public Integer opportunityScore;
        @AuraEnabled public Integer caseScore;
        @AuraEnabled public Integer activityScore;
        @AuraEnabled public String  tier;
        @AuraEnabled public String  recommendation;

        public HealthResult(Id accountId) {
            this.accountId = accountId;
            this.overallScore     = 0;
            this.opportunityScore = 0;
            this.caseScore        = 0;
            this.activityScore    = 0;
            this.tier             = 'Unknown';
            this.recommendation   = '';
        }
    }

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    private static final Integer LOOKBACK_DAYS = 365;
    private static final Date    CUTOFF_DATE   = Date.today().addDays(-LOOKBACK_DAYS);

    private static final Integer OPP_WEIGHT      = 40; // max 40 pts
    private static final Integer CASE_WEIGHT     = 30; // max 30 pts
    private static final Integer ACTIVITY_WEIGHT = 30; // max 30 pts

    // ---------------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------------

    /**
     * @description Computes health scores for a set of Account Ids.
     * @param  accountIds Set of Account Ids to evaluate.
     * @return Map<Id, HealthResult> — one HealthResult per Account.
     */
    public static Map<Id, HealthResult> calculateHealth(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new Map<Id, HealthResult>();
        }

        Map<Id, HealthResult> results = new Map<Id, HealthResult>();
        for (Id acctId : accountIds) {
            results.put(acctId, new HealthResult(acctId));
        }

        // Gather data in bulk (three SOQL queries)
        Map<Id, List<Opportunity>> oppsByAccount   = queryOpportunities(accountIds);
        Map<Id, List<Case>>        casesByAccount  = queryCases(accountIds);
        Map<Id, Integer>           activityCounts  = queryActivityCounts(accountIds);

        // Score each Account
        for (Id acctId : accountIds) {
            HealthResult hr = results.get(acctId);

            hr.opportunityScore = scoreOpportunities(
                oppsByAccount.containsKey(acctId) ? oppsByAccount.get(acctId) : new List<Opportunity>()
            );

            hr.caseScore = scoreCases(
                casesByAccount.containsKey(acctId) ? casesByAccount.get(acctId) : new List<Case>()
            );

            hr.activityScore = scoreActivity(
                activityCounts.containsKey(acctId) ? activityCounts.get(acctId) : 0
            );

            hr.overallScore = Math.min(
                hr.opportunityScore + hr.caseScore + hr.activityScore,
                100
            );

            hr.tier           = deriveTier(hr.overallScore);
            hr.recommendation = deriveRecommendation(hr);
        }

        return results;
    }

    /**
     * @description Convenience overload for a single Account.
     */
    public static HealthResult calculateHealth(Id accountId) {
        Map<Id, HealthResult> results = calculateHealth(new Set<Id>{ accountId });
        return results.get(accountId);
    }

    // ---------------------------------------------------------------------------
    // Data Queries
    // ---------------------------------------------------------------------------

    private static Map<Id, List<Opportunity>> queryOpportunities(Set<Id> accountIds) {
        Map<Id, List<Opportunity>> result = new Map<Id, List<Opportunity>>();

        for (Opportunity opp : [
            SELECT Id, AccountId, StageName, Amount, CloseDate, IsClosed, IsWon, Probability
            FROM   Opportunity
            WHERE  AccountId IN :accountIds
            AND    CloseDate >= :CUTOFF_DATE
            ORDER BY CloseDate DESC
        ]) {
            if (!result.containsKey(opp.AccountId)) {
                result.put(opp.AccountId, new List<Opportunity>());
            }
            result.get(opp.AccountId).add(opp);
        }

        return result;
    }

    private static Map<Id, List<Case>> queryCases(Set<Id> accountIds) {
        Map<Id, List<Case>> result = new Map<Id, List<Case>>();

        for (Case c : [
            SELECT Id, AccountId, Status, Priority, CreatedDate, ClosedDate, IsClosed
            FROM   Case
            WHERE  AccountId IN :accountIds
            AND    CreatedDate >= :CUTOFF_DATE
            ORDER BY CreatedDate DESC
        ]) {
            if (!result.containsKey(c.AccountId)) {
                result.put(c.AccountId, new List<Case>());
            }
            result.get(c.AccountId).add(c);
        }

        return result;
    }

    private static Map<Id, Integer> queryActivityCounts(Set<Id> accountIds) {
        Map<Id, Integer> result = new Map<Id, Integer>();

        for (AggregateResult ar : [
            SELECT WhatId, COUNT(Id) cnt
            FROM   Task
            WHERE  WhatId IN :accountIds
            AND    CreatedDate >= :CUTOFF_DATE
            GROUP BY WhatId
        ]) {
            result.put((Id) ar.get('WhatId'), (Integer) ar.get('cnt'));
        }

        return result;
    }

    // ---------------------------------------------------------------------------
    // Scoring Logic
    // ---------------------------------------------------------------------------

    /**
     * @description Scores the opportunity dimension (max 40 pts).
     *              Factors: win rate, pipeline coverage, average deal size.
     */
    @TestVisible
    private static Integer scoreOpportunities(List<Opportunity> opps) {
        if (opps.isEmpty()) {
            return 0;
        }

        Integer totalOpps = opps.size();
        Integer wonCount  = 0;
        Integer lostCount = 0;
        Decimal totalWonAmount = 0;
        Integer openCount = 0;

        for (Opportunity opp : opps) {
            if (opp.IsWon) {
                wonCount++;
                totalWonAmount += (opp.Amount != null ? opp.Amount : 0);
            } else if (opp.IsClosed) {
                lostCount++;
            } else {
                openCount++;
            }
        }

        // Win-rate component (0–20 pts)
        Integer closedCount = wonCount + lostCount;
        Decimal winRate = closedCount > 0 ? (Decimal) wonCount / closedCount : 0;
        Integer winRatePts = (Integer) Math.round(winRate * 20);

        // Pipeline component — having open opportunities is positive (0��10 pts)
        Integer pipelinePts = Math.min(openCount * 3, 10);

        // Revenue component (0–10 pts)
        Integer revenuePts = 0;
        if (totalWonAmount >= 500000) {
            revenuePts = 10;
        } else if (totalWonAmount >= 100000) {
            revenuePts = 7;
        } else if (totalWonAmount >= 25000) {
            revenuePts = 4;
        } else if (totalWonAmount > 0) {
            revenuePts = 2;
        }

        return Math.min(winRatePts + pipelinePts + revenuePts, OPP_WEIGHT);
    }

    /**
     * @description Scores the support case dimension (max 30 pts).
     *              Fewer and faster-resolved cases = better health.
     */
    @TestVisible
    private static Integer scoreCases(List<Case> cases) {
        if (cases.isEmpty()) {
            // No cases at all — neutral / slightly positive
            return 20;
        }

        Integer totalCases      = cases.size();
        Integer closedCount     = 0;
        Integer highPriority    = 0;
        Integer escalatedOrOpen = 0;

        for (Case c : cases) {
            if (c.IsClosed) {
                closedCount++;
            } else {
                escalatedOrOpen++;
            }
            if (c.Priority == 'High' || c.Priority == 'Critical') {
                highPriority++;
            }
        }

        // Resolution rate component (0–15 pts)
        Decimal resolutionRate = (Decimal) closedCount / totalCases;
        Integer resolutionPts  = (Integer) Math.round(resolutionRate * 15);

        // Volume penalty — high case volume is a negative signal (0–10 pts, inverted)
        Integer volumePts = 10;
        if (totalCases > 20) {
            volumePts = 0;
        } else if (totalCases > 10) {
            volumePts = 3;
        } else if (totalCases > 5) {
            volumePts = 6;
        }

        // Severity penalty (0–5 pts, inverted)
        Integer severityPts = 5;
        if (highPriority > 5) {
            severityPts = 0;
        } else if (highPriority > 2) {
            severityPts = 2;
        }

        return Math.min(resolutionPts + volumePts + severityPts, CASE_WEIGHT);
    }

    /**
     * @description Scores the activity dimension (max 30 pts).
     *              More recent engagement = healthier account.
     */
    @TestVisible
    private static Integer scoreActivity(Integer activityCount) {
        if (activityCount >= 50) {
            return ACTIVITY_WEIGHT;
        } else if (activityCount >= 25) {
            return 22;
        } else if (activityCount >= 10) {
            return 15;
        } else if (activityCount >= 3) {
            return 8;
        } else if (activityCount >= 1) {
            return 3;
        }
        return 0;
    }

    // ---------------------------------------------------------------------------
    // Tier & Recommendation Logic
    // ---------------------------------------------------------------------------

    @TestVisible
    private static String deriveTier(Integer score) {
        if (score >= 85) return 'Thriving';
        if (score >= 65) return 'Healthy';
        if (score >= 40) return 'Needs Attention';
        return 'At Risk';
    }

    private static String deriveRecommendation(HealthResult hr) {
        List<String> actions = new List<String>();

        if (hr.opportunityScore < OPP_WEIGHT / 2) {
            actions.add('Schedule a pipeline review meeting to identify expansion opportunities.');
        }
        if (hr.caseScore < CASE_WEIGHT / 2) {
            actions.add('Escalate open support cases and conduct a customer satisfaction check-in.');
        }
        if (hr.activityScore < ACTIVITY_WEIGHT / 2) {
            actions.add('Increase engagement cadence — consider a QBR or executive sponsor touch-point.');
        }

        if (actions.isEmpty()) {
            actions.add('Account is in good standing. Continue current engagement cadence.');
        }

        return String.join(actions, ' ');
    }
}
