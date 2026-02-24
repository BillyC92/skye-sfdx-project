import { LightningElement, api, wire } from "lwc";
import { getRecord, getFieldValue } from "lightning/uiRecordApi";

// In a real implementation these would reference custom fields:
// import LEAD_SCORE_FIELD from '@salesforce/schema/Lead.Lead_Score__c';
// import LEAD_TIER_FIELD  from '@salesforce/schema/Lead.Lead_Score_Tier__c';

const LEAD_FIELDS = [
  "Lead.Industry",
  "Lead.NumberOfEmployees",
  "Lead.AnnualRevenue",
  "Lead.LeadSource",
  "Lead.Rating",
  "Lead.Email",
  "Lead.Phone",
  "Lead.Description",
];

/**
 * @description Lightning Web Component that displays a lead's computed score
 *              with a visual breakdown by dimension. Designed for the Lead
 *              record page in the Acme Corp Salesforce org.
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 */
export default class LeadScoreCard extends LightningElement {
  @api recordId;

  score = null;
  tierLabel = "";
  companyFitPercent = 0;
  industryFitPercent = 0;
  engagementPercent = 0;
  budgetPercent = 0;
  recommendation = "";
  isLoading = true;

  // -----------------------------------------------------------------------
  // Wire — fetch lead data reactively
  // -----------------------------------------------------------------------

  @wire(getRecord, { recordId: "$recordId", fields: LEAD_FIELDS })
  wiredLead({ error, data }) {
    if (data) {
      this.calculateScore(data);
      this.isLoading = false;
    } else if (error) {
      console.error("Error loading lead record:", JSON.stringify(error));
      this.isLoading = false;
    }
  }

  // -----------------------------------------------------------------------
  // Score Calculation (client-side mirror of Apex LeadScoringService)
  // -----------------------------------------------------------------------

  calculateScore(record) {
    const industry = getFieldValue(record, "Lead.Industry");
    const employees = getFieldValue(record, "Lead.NumberOfEmployees");
    const revenue = getFieldValue(record, "Lead.AnnualRevenue");
    const source = getFieldValue(record, "Lead.LeadSource");
    const rating = getFieldValue(record, "Lead.Rating");
    const email = getFieldValue(record, "Lead.Email");
    const phone = getFieldValue(record, "Lead.Phone");
    const description = getFieldValue(record, "Lead.Description");

    // Company size (0–25)
    let companyScore = 0;
    if (employees > 1000) companyScore = 25;
    else if (employees > 200) companyScore = 20;
    else if (employees > 50) companyScore = 12;
    else if (employees > 0) companyScore = 8;

    // Industry fit (0–25)
    const industryScores = {
      Technology: 25,
      "Financial Services": 22,
      Healthcare: 20,
      Manufacturing: 18,
      Retail: 15,
      Education: 12,
      Government: 10,
    };
    let industryScore = industry
      ? industryScores[industry] || 5
      : 0;

    // Engagement (0–25)
    let engagementScore = 0;
    const sourceScores = {
      "Partner Referral": 10,
      "Employee Referral": 10,
      "Phone Inquiry": 9,
      "External Referral": 9,
      Web: 8,
      "Trade Show": 7,
      Advertisement: 5,
      "Purchased List": 3,
    };
    if (source) engagementScore += sourceScores[source] || 4;
    if (email) {
      engagementScore += 4;
      if (
        !email.includes("@gmail.") &&
        !email.includes("@yahoo.") &&
        !email.includes("@hotmail.")
      ) {
        engagementScore += 2;
      }
    }
    if (phone) engagementScore += 2;
    if (description && description.length > 50) engagementScore += 5;
    else if (description) engagementScore += 2;
    engagementScore = Math.min(engagementScore, 25);

    // Budget (0–25)
    let budgetScore = 0;
    if (revenue >= 50000000) budgetScore += 15;
    else if (revenue >= 10000000) budgetScore += 12;
    else if (revenue >= 1000000) budgetScore += 8;
    else if (revenue > 0) budgetScore += 4;
    if (rating === "Hot") budgetScore += 10;
    else if (rating === "Warm") budgetScore += 6;
    else if (rating === "Cold") budgetScore += 2;
    budgetScore = Math.min(budgetScore, 25);

    // Total
    this.score = Math.min(
      companyScore + industryScore + engagementScore + budgetScore,
      100
    );
    this.companyFitPercent = (companyScore / 25) * 100;
    this.industryFitPercent = (industryScore / 25) * 100;
    this.engagementPercent = (engagementScore / 25) * 100;
    this.budgetPercent = (budgetScore / 25) * 100;

    // Tier
    if (this.score >= 80) this.tierLabel = "Hot";
    else if (this.score >= 55) this.tierLabel = "Warm";
    else if (this.score >= 30) this.tierLabel = "Cool";
    else this.tierLabel = "Cold";

    // Recommendation
    this.recommendation = this.deriveRecommendation(
      companyScore,
      industryScore,
      engagementScore,
      budgetScore
    );
  }

  deriveRecommendation(company, industry, engagement, budget) {
    const tips = [];
    if (company < 12)
      tips.push("Company size is small — verify decision-making authority.");
    if (industry < 10)
      tips.push("Industry is outside our ideal profile — assess strategic fit.");
    if (engagement < 12)
      tips.push("Engagement is low — prioritize outreach to build relationship.");
    if (budget < 12)
      tips.push("Budget signals are weak — qualify funding early in discovery.");

    return tips.length > 0
      ? tips.join(" ")
      : "Strong lead — move to qualification promptly.";
  }

  // -----------------------------------------------------------------------
  // Getters
  // -----------------------------------------------------------------------

  get hasScore() {
    return this.score !== null;
  }

  get scoreContainerClass() {
    const base = "score-container slds-align_absolute-center ";
    if (this.score >= 80) return base + "score-hot";
    if (this.score >= 55) return base + "score-warm";
    if (this.score >= 30) return base + "score-cool";
    return base + "score-cold";
  }

  get tierBadgeClass() {
    if (this.tierLabel === "Hot") return "slds-theme_success";
    if (this.tierLabel === "Warm") return "slds-theme_warning";
    return "slds-theme_info";
  }

  get companyFitVariant() {
    return this.companyFitPercent >= 60 ? "circular" : "base";
  }

  get industryFitVariant() {
    return this.industryFitPercent >= 60 ? "circular" : "base";
  }

  get engagementVariant() {
    return this.engagementPercent >= 60 ? "circular" : "base";
  }

  get budgetVariant() {
    return this.budgetPercent >= 60 ? "circular" : "base";
  }

  // -----------------------------------------------------------------------
  // Actions
  // -----------------------------------------------------------------------

  handleRefresh() {
    this.isLoading = true;
    // Force re-wire by briefly clearing recordId
    const currentId = this.recordId;
    this.recordId = undefined;
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      this.recordId = currentId;
    }, 100);
  }
}
