/**
 * @description Trigger handler for Opportunity events. Implements stage-transition
 *              validation, amount-threshold enforcement, and notification dispatch
 *              for the Acme Corp sales process.
 *
 *              Follows the single-trigger-per-object pattern with a dedicated handler.
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 * @group   Opportunity Management
 */
public with sharing class OpportunityTriggerHandler {

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    private static final Decimal EXECUTIVE_APPROVAL_THRESHOLD = 500000.00;
    private static final Decimal LARGE_DEAL_THRESHOLD         = 100000.00;

    /** Allowed forward stage transitions (simplified Acme Corp sales process). */
    private static final Map<String, Set<String>> VALID_STAGE_TRANSITIONS = new Map<String, Set<String>>{
        'Prospecting'           => new Set<String>{ 'Qualification', 'Closed Lost' },
        'Qualification'         => new Set<String>{ 'Needs Analysis', 'Closed Lost' },
        'Needs Analysis'        => new Set<String>{ 'Value Proposition', 'Closed Lost' },
        'Value Proposition'     => new Set<String>{ 'Id. Decision Makers', 'Closed Lost' },
        'Id. Decision Makers'   => new Set<String>{ 'Perception Analysis', 'Closed Lost' },
        'Perception Analysis'   => new Set<String>{ 'Proposal/Price Quote', 'Closed Lost' },
        'Proposal/Price Quote'  => new Set<String>{ 'Negotiation/Review', 'Closed Lost' },
        'Negotiation/Review'    => new Set<String>{ 'Closed Won', 'Closed Lost' }
    };

    // ---------------------------------------------------------------------------
    // Trigger Entry Points
    // ---------------------------------------------------------------------------

    /**
     * @description Executes before-insert logic.
     * @param newOpps Trigger.new list.
     */
    public void handleBeforeInsert(List<Opportunity> newOpps) {
        stampDefaultFields(newOpps);
        validateAmountThresholds(newOpps);
    }

    /**
     * @description Executes before-update logic.
     * @param newOpps Trigger.new list.
     * @param oldMap  Trigger.oldMap.
     */
    public void handleBeforeUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        validateStageTransitions(newOpps, oldMap);
        validateAmountThresholds(newOpps);
        flagLargeDealChanges(newOpps, oldMap);
    }

    /**
     * @description Executes after-update logic (notifications, chatter posts).
     * @param newOpps Trigger.new list.
     * @param oldMap  Trigger.oldMap.
     */
    public void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        notifyOnClosedWon(newOpps, oldMap);
        createStageChangeHistoryTasks(newOpps, oldMap);
    }

    // ---------------------------------------------------------------------------
    // Before-Insert Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Sets sensible defaults on new Opportunity records when values
     *              are not provided by the user.
     */
    private void stampDefaultFields(List<Opportunity> newOpps) {
        for (Opportunity opp : newOpps) {
            if (opp.StageName == null) {
                opp.StageName = 'Prospecting';
            }

            if (opp.CloseDate == null) {
                opp.CloseDate = Date.today().addDays(90);
            }

            if (opp.LeadSource == null) {
                opp.LeadSource = 'Web';
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Before-Update Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Validates that stage transitions follow the allowed Acme Corp
     *              sales methodology. Prevents skipping stages or moving backwards
     *              unless the target is "Closed Lost".
     */
    @TestVisible
    private void validateStageTransitions(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.StageName == oldOpp.StageName) {
                continue;
            }

            // Allow admin overrides via custom permission (simplified: check profile)
            if (isAdminBypass()) {
                continue;
            }

            Set<String> allowedNextStages = VALID_STAGE_TRANSITIONS.get(oldOpp.StageName);

            if (allowedNextStages == null) {
                // Current stage is terminal (Closed Won / Closed Lost) — no transitions allowed
                opp.StageName.addError(
                    'Opportunity in stage "' + oldOpp.StageName + '" cannot be moved to another stage. ' +
                    'Please clone the record if you need a new opportunity.'
                );
                continue;
            }

            if (!allowedNextStages.contains(opp.StageName)) {
                opp.StageName.addError(
                    'Invalid stage transition from "' + oldOpp.StageName + '" to "' +
                    opp.StageName + '". Allowed next stages: ' +
                    String.join(new List<String>(allowedNextStages), ', ') + '.'
                );
            }
        }
    }

    /**
     * @description Enforces amount thresholds. Opportunities above the executive
     *              approval threshold require the Description field to be populated
     *              (as a proxy for justification notes).
     */
    private void validateAmountThresholds(List<Opportunity> opps) {
        for (Opportunity opp : opps) {
            if (opp.Amount != null && opp.Amount >= EXECUTIVE_APPROVAL_THRESHOLD) {
                if (String.isBlank(opp.Description)) {
                    opp.Description.addError(
                        'Opportunities of $' + EXECUTIVE_APPROVAL_THRESHOLD.setScale(0).toPlainString() +
                        ' or more require a justification in the Description field.'
                    );
                }
            }
        }
    }

    /**
     * @description Flags opportunities where the Amount increased by more than 20%
     *              in a single edit — adds a note to the Description for audit trail.
     */
    private void flagLargeDealChanges(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.Amount == null || oldOpp.Amount == null || oldOpp.Amount == 0) {
                continue;
            }

            Decimal percentChange = ((opp.Amount - oldOpp.Amount) / oldOpp.Amount) * 100;

            if (percentChange > 20) {
                String auditNote = '\n[Skieward Audit] Amount increased by ' +
                    percentChange.setScale(1) + '% on ' + String.valueOf(Date.today()) + '.';

                opp.Description = (String.isNotBlank(opp.Description) ? opp.Description : '') + auditNote;
            }
        }
    }

    // ---------------------------------------------------------------------------
    // After-Update Helpers
    // ---------------------------------------------------------------------------

    /**
     * @description Sends a platform event or email notification when an Opportunity
     *              moves to "Closed Won". In this implementation we create a Task
     *              assigned to the Opportunity Owner for follow-up.
     */
    private void notifyOnClosedWon(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        List<Task> followUpTasks = new List<Task>();

        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.StageName == 'Closed Won' && oldOpp.StageName != 'Closed Won') {
                followUpTasks.add(new Task(
                    Subject     = 'Closed Won Follow-Up: ' + opp.Name,
                    WhatId      = opp.Id,
                    OwnerId     = opp.OwnerId,
                    Status      = 'Not Started',
                    Priority    = opp.Amount >= LARGE_DEAL_THRESHOLD ? 'High' : 'Normal',
                    ActivityDate = Date.today().addDays(3),
                    Description = 'Congratulations on closing ' + opp.Name + '! ' +
                                  'Please initiate the onboarding process within 3 business days.'
                ));
            }
        }

        if (!followUpTasks.isEmpty()) {
            insert followUpTasks;
        }
    }

    /**
     * @description Creates a lightweight Task record to log every stage change,
     *              providing a queryable audit trail without custom objects.
     */
    private void createStageChangeHistoryTasks(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        List<Task> historyTasks = new List<Task>();

        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            if (opp.StageName != oldOpp.StageName) {
                historyTasks.add(new Task(
                    Subject     = 'Stage Change: ' + oldOpp.StageName + ' → ' + opp.StageName,
                    WhatId      = opp.Id,
                    OwnerId     = opp.OwnerId,
                    Status      = 'Completed',
                    Priority    = 'Low',
                    ActivityDate = Date.today(),
                    Description = 'Automated stage-change log by Skieward trigger framework.'
                ));
            }
        }

        if (!historyTasks.isEmpty()) {
            insert historyTasks;
        }
    }

    // ---------------------------------------------------------------------------
    // Utility
    // ---------------------------------------------------------------------------

    /**
     * @description Simplified admin bypass check. In production this would use
     *              Custom Permissions or a Custom Metadata Type.
     * @return Boolean true if the running user should bypass stage validation.
     */
    @TestVisible
    private Boolean isAdminBypass() {
        return FeatureManagement.checkPermission('Bypass_Opportunity_Stage_Validation');
    }
}
