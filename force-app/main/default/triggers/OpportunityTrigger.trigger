/**
 * @description Single trigger for the Opportunity object. Delegates all logic to
 *              OpportunityTriggerHandler following Skieward's one-trigger-per-object pattern.
 *
 *              Contexts handled:
 *                - before insert : field defaulting (stampDefaultFields) + amount validation
 *                - after insert  : large-deal notifications for opps > $50k (KAN-5 AC #3–5)
 *                - before update : stage-transition validation, amount validation, audit flags
 *                - after update  : Closed Won follow-up tasks (KAN-5 AC #2), stage-history tasks
 *
 * @author  Skieward Consulting
 * @date    2024-11-15
 */
trigger OpportunityTrigger on Opportunity (before insert, after insert, before update, after update) {

    OpportunityTriggerHandler handler = new OpportunityTriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.handleBeforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
        }
    }

    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            handler.handleAfterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}