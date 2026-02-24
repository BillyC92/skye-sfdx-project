# Skieward — Acme Corp Salesforce Implementation

> Managed by **Skieward Consulting** | Salesforce Platform Partner

## Overview

This repository contains the Salesforce source for the **Acme Corp** CRM enhancement project. The implementation focuses on lead scoring automation, opportunity lifecycle management, and account health visibility.

## Key Components

| Component | Type | Description |
|---|---|---|
| `LeadScoringService` | Apex Class | Scores inbound leads based on company size, industry fit, and engagement signals |
| `OpportunityTriggerHandler` | Apex Class | Enforces business rules on opportunity stage transitions and amount thresholds |
| `AccountHealthCalculator` | Apex Class | Computes a composite health score for accounts using opportunities, cases, and activity data |
| `OpportunityTrigger` | Trigger | Before/after trigger delegating to `OpportunityTriggerHandler` |
| `leadScoreCard` | LWC | Lightning Web Component displaying a lead's computed score on the record page |

## Architecture

```
Lead Created/Updated
        │
        ▼
 LeadScoringService.scoreLead()
        │
        ├── evaluateCompanySize()
        ├── evaluateIndustryFit()
        ├── evaluateEngagement()
        └── evaluateBudgetIndicators()
                │
                ▼
        Lead.Lead_Score__c updated
                │
                ▼
        leadScoreCard LWC reflects score
```

## Development

```bash
# Authenticate to a sandbox
sf org login web --set-default --alias acme-sandbox

# Push source
sf project deploy start --target-org acme-sandbox

# Run tests
sf apex run test --target-org acme-sandbox --test-level RunLocalTests --wait 10
```

## Deployment

All deployments follow the Skieward CI/CD pipeline:

1. Feature branch → Pull Request → Code Review
2. Deploy to QA sandbox via GitHub Actions
3. UAT sign-off
4. Production deployment with `RunLocalTests`

---

*Built with care by the Skieward team.*
