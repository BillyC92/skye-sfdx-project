/**
 * OpportunityTrigger
 *
 * Single, thin trigger on the Opportunity object.
 * Contains zero business logic — all logic lives in OpportunityTriggerHandler.
 *
 * Contexts handled:
 *   - before insert  : reserved for future before-save field defaulting
 *   - after insert   : task creation, notifications for new Closed Won / large opps
 *   - after update   : task creation, notifications on Closed Won transition / large opps
 *
 * Why a thin trigger?
 *   Keeping logic out of the trigger body makes the handler independently testable,
 *   easier to maintain, and avoids the "logic buried in trigger" anti-pattern.
 */
trigger OpportunityTrigger on Opportunity (before insert, after insert, before update, after update) {

    OpportunityTriggerHandler handler = new OpportunityTriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            // Reserved for future before-insert logic (e.g. field defaulting).
            // OpportunityTriggerHandler.handleBeforeInsert(Trigger.new);
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