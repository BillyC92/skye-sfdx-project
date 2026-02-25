/**
 * OpportunityTrigger
 *
 * Single entry-point trigger for the Opportunity object.
 * Enforces the one-trigger-per-object pattern — all business logic lives
 * in OpportunityTriggerHandler. This trigger is intentionally thin:
 * it only identifies the active context(s) and delegates immediately.
 *
 * Contexts handled:
 *   - before insert  : reserved for future field-defaulting / validation logic
 *   - before update  : reserved for future field-defaulting / validation logic
 *   - after insert   : Task creation for Opps inserted as Closed Won;
 *                      high-value ($50k+) notification dispatch
 *                      (both require record Ids, only available post-insert)
 *   - after update   : Task creation for Opps that transition TO Closed Won;
 *                      old/new comparison requires the after-update context
 *
 * KAN-5 | OpportunityTrigger
 */
trigger OpportunityTrigger on Opportunity (
    before insert,
    before update,
    after insert,
    after update
) {
    OpportunityTriggerHandler handler = new OpportunityTriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            // Reserved for future before-insert logic (e.g. field defaults, validation)
            handler.handleBeforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            // Reserved for future before-update logic (e.g. field defaults, validation)
            handler.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            // Task creation for Opps inserted directly as Closed Won
            // High-value notification for Opps with Amount > $50k
            handler.handleAfterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            // Task creation for Opps that transitioned to Closed Won in this DML
            // Old/new value comparison performed inside the handler
            handler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}