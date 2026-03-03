/**
 * @description Single trigger for the Opportunity object. Delegates all logic to
 *              OpportunityTriggerHandler following Skieward's one-trigger-per-object pattern.
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
