/**
 * OpportunityTrigger
 *
 * Single trigger for the Opportunity object. Contains zero logic — all behaviour
 * is delegated to OpportunityTriggerHandler so that logic remains testable,
 * maintainable, and easy to extend without touching the trigger itself.
 *
 * Contexts registered:
 *   - before insert  : reserved for future use (e.g. field defaulting)
 *   - after insert   : Task creation + $50k notification (KAN-5)
 *   - before update  : reserved for future use (e.g. field validation)
 *   - after update   : Task creation on Closed Won transition (KAN-5)
 *
 * DO NOT add logic directly to this file. Add a new method to
 * OpportunityTriggerHandler and call it from the appropriate context block.
 */
trigger OpportunityTrigger on Opportunity (
    before insert,
    after insert,
    before update,
    after update
) {
    OpportunityTriggerHandler handler = new OpportunityTriggerHandler(
        Trigger.new,
        Trigger.newMap,
        Trigger.old,
        Trigger.oldMap
    );

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.onBeforeInsert();
        } else if (Trigger.isUpdate) {
            handler.onBeforeUpdate();
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            handler.onAfterInsert();
        } else if (Trigger.isUpdate) {
            handler.onAfterUpdate();
        }
    }
}