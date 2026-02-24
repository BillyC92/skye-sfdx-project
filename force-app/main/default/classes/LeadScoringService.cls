/**
 * @description Service class for scoring inbound leads based on multiple criteria.
 *              Part of the Acme Corp lead qualification automation.
 *              Scores are computed on a 0–100 scale across four dimensions:
 *              company size, industry fit, engagement level, and budget indicators.
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 * @group   Lead Management
 */
public with sharing class LeadScoringService {

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    @TestVisible
    private static final Integer MAX_SCORE = 100;

    @TestVisible
    private static final Map<String, Integer> INDUSTRY_SCORE_MAP = new Map<String, Integer>{
        'Technology'        => 25,
        'Financial Services'=> 22,
        'Healthcare'        => 20,
        'Manufacturing'     => 18,
        'Retail'            => 15,
        'Education'         => 12,
        'Government'        => 10
    };

    private static final Integer DEFAULT_INDUSTRY_SCORE = 5;

    private static final Map<String, Integer> COMPANY_SIZE_THRESHOLDS = new Map<String, Integer>{
        'Enterprise'  => 25,   // > 1 000 employees
        'MidMarket'   => 20,   // 201 – 1 000
        'SMB'         => 12,   // 51 – 200
        'Startup'     => 8     // 1 – 50
    };

    // ---------------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------------

    /**
     * @description Computes a composite lead score for a single Lead record.
     *              The score is the sum of four weighted dimensions capped at MAX_SCORE.
     * @param  lead The Lead sObject (must include NumberOfEmployees, Industry, LeadSource,
     *              Email, Phone, AnnualRevenue, Rating, and Description).
     * @return Integer — the computed score (0–100).
     */
    public static Integer scoreLead(Lead lead) {
        if (lead == null) {
            throw new LeadScoringException('Cannot score a null Lead record.');
        }

        Integer companyScore    = evaluateCompanySize(lead.NumberOfEmployees);
        Integer industryScore   = evaluateIndustryFit(lead.Industry);
        Integer engagementScore = evaluateEngagement(lead);
        Integer budgetScore     = evaluateBudgetIndicators(lead);

        Integer totalScore = companyScore + industryScore + engagementScore + budgetScore;
        return Math.min(totalScore, MAX_SCORE);
    }

    /**
     * @description Bulk-scores a list of Leads and stamps the result onto Lead_Score__c.
     *              Designed to be called from a trigger or batch context.
     * @param  leads List of Lead records to score.
     * @return Map<Id, Integer> — map of Lead Id to computed score.
     */
    public static Map<Id, Integer> scoreLeads(List<Lead> leads) {
        Map<Id, Integer> scoreMap = new Map<Id, Integer>();

        if (leads == null || leads.isEmpty()) {
            return scoreMap;
        }

        for (Lead ld : leads) {
            Integer score = scoreLead(ld);
            scoreMap.put(ld.Id, score);
        }

        return scoreMap;
    }

    /**
     * @description Returns a human-readable tier label for a given numeric score.
     * @param  score Integer score (0–100).
     * @return String — 'Hot', 'Warm', 'Cool', or 'Cold'.
     */
    public static String getScoreTier(Integer score) {
        if (score == null || score < 0) {
            return 'Unscored';
        }
        if (score >= 80) {
            return 'Hot';
        } else if (score >= 55) {
            return 'Warm';
        } else if (score >= 30) {
            return 'Cool';
        }
        return 'Cold';
    }

    // ---------------------------------------------------------------------------
    // Scoring Dimensions (private)
    // ---------------------------------------------------------------------------

    /**
     * @description Evaluates company size based on NumberOfEmployees.
     *              Max contribution: 25 points.
     */
    @TestVisible
    private static Integer evaluateCompanySize(Integer numberOfEmployees) {
        if (numberOfEmployees == null || numberOfEmployees <= 0) {
            return 0;
        }

        if (numberOfEmployees > 1000) {
            return COMPANY_SIZE_THRESHOLDS.get('Enterprise');
        } else if (numberOfEmployees > 200) {
            return COMPANY_SIZE_THRESHOLDS.get('MidMarket');
        } else if (numberOfEmployees > 50) {
            return COMPANY_SIZE_THRESHOLDS.get('SMB');
        }
        return COMPANY_SIZE_THRESHOLDS.get('Startup');
    }

    /**
     * @description Evaluates industry alignment with Acme Corp's ideal customer profile.
     *              Max contribution: 25 points.
     */
    @TestVisible
    private static Integer evaluateIndustryFit(String industry) {
        if (String.isBlank(industry)) {
            return 0;
        }
        return INDUSTRY_SCORE_MAP.containsKey(industry)
            ? INDUSTRY_SCORE_MAP.get(industry)
            : DEFAULT_INDUSTRY_SCORE;
    }

    /**
     * @description Evaluates engagement signals: lead source quality, contact info
     *              completeness, and description richness.
     *              Max contribution: 25 points.
     */
    @TestVisible
    private static Integer evaluateEngagement(Lead lead) {
        Integer score = 0;

        // Lead source quality (0–10)
        if (lead.LeadSource != null) {
            Map<String, Integer> sourceScores = new Map<String, Integer>{
                'Web'                  => 8,
                'Partner Referral'     => 10,
                'Phone Inquiry'        => 9,
                'Purchased List'       => 3,
                'Trade Show'           => 7,
                'Advertisement'        => 5,
                'Employee Referral'    => 10,
                'External Referral'    => 9
            };
            score += sourceScores.containsKey(lead.LeadSource)
                ? sourceScores.get(lead.LeadSource)
                : 4;
        }

        // Contact completeness (0–8)
        if (String.isNotBlank(lead.Email)) {
            score += 4;
            // Bonus for corporate email domains
            if (!lead.Email.contains('@gmail.') &&
                !lead.Email.contains('@yahoo.') &&
                !lead.Email.contains('@hotmail.')) {
                score += 2;
            }
        }
        if (String.isNotBlank(lead.Phone)) {
            score += 2;
        }

        // Description richness — proxy for buying intent (0–5)
        if (String.isNotBlank(lead.Description) && lead.Description.length() > 50) {
            score += 5;
        } else if (String.isNotBlank(lead.Description)) {
            score += 2;
        }

        return Math.min(score, 25);
    }

    /**
     * @description Evaluates budget and purchase readiness indicators.
     *              Max contribution: 25 points.
     */
    @TestVisible
    private static Integer evaluateBudgetIndicators(Lead lead) {
        Integer score = 0;

        // Annual revenue signals (0–15)
        if (lead.AnnualRevenue != null) {
            if (lead.AnnualRevenue >= 50000000) {
                score += 15;
            } else if (lead.AnnualRevenue >= 10000000) {
                score += 12;
            } else if (lead.AnnualRevenue >= 1000000) {
                score += 8;
            } else if (lead.AnnualRevenue > 0) {
                score += 4;
            }
        }

        // Rating field (0–10)
        if (lead.Rating != null) {
            if (lead.Rating == 'Hot') {
                score += 10;
            } else if (lead.Rating == 'Warm') {
                score += 6;
            } else if (lead.Rating == 'Cold') {
                score += 2;
            }
        }

        return Math.min(score, 25);
    }

    // ---------------------------------------------------------------------------
    // Custom Exception
    // ---------------------------------------------------------------------------

    public class LeadScoringException extends Exception {}
}
