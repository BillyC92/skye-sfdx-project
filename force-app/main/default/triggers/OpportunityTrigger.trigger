/**
 * OpportunityTrigger
 *
 * Single entry-point trigger for the Opportunity object.
 * Contains NO business logic — all logic is delegated to OpportunityTriggerHandler.
 *
 * Contexts handled:
 *   - before insert  : field defaulting / validation before records are saved
 *   - before update  : field defaulting / validation before records are saved
 *   - after insert   : post-save logic (e.g. $50k notification on new records)
 *   - after update   : post-save logic (e.g. Closed Won task creation on stage transition)
 *
 * Why a handler class?
 *   Keeping logic out of the trigger body makes the code unit-testable in isolation,
 *   prevents the "logic buried in trigger" anti-pattern, and allows the handler to be
 *   called from other contexts (e.g. batch jobs) without re-entering trigger context.
 */
trigger OpportunityTrigger on Opportunity (
    before insert,
    before update,
    after insert,
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