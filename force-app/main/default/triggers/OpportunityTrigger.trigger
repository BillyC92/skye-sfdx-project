/**
 * OpportunityTrigger
 *
 * Single, thin trigger on the Opportunity object.
 * Contains zero business logic — all logic is delegated to OpportunityTriggerHandler.
 *
 * Why: Enforcing the one-trigger-per-object pattern ensures a predictable execution
 * order and a single entry point for all Opportunity trigger logic. Adding logic
 * here directly would make it untestable in isolation and harder to maintain.
 *
 * Fires on:
 *   - before insert  : reserved for future before-save field defaulting
 *   - after insert   : new Opportunity creation logic (e.g. $50k notifications)
 *   - after update   : stage transition logic (e.g. Closed Won task creation)
 */
trigger OpportunityTrigger on Opportunity (before insert, after insert, after update) {
    OpportunityTriggerHandler handler = new OpportunityTriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.onBeforeInsert(Trigger.new);
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            handler.onAfterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.onAfterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}