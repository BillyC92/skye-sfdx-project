/**
 * OpportunityTrigger
 *
 * Single entry-point trigger for the Opportunity object.
 * Contains zero business logic — all logic is delegated to OpportunityTriggerHandler.
 *
 * Contexts enabled:
 *   - before insert  : reserved for future before-save field updates
 *   - before update  : reserved for future before-save field updates
 *   - after insert   : Task creation and large-opportunity notifications (requires record Id)
 *   - after update   : Task creation on Closed Won transition
 *
 * Why after insert/update for Tasks:
 *   Task.WhatId requires the Opportunity Id, which is only available post-insert.
 *   Notifications similarly need a persisted record to reference.
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
            handler.handleBeforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            handler.handleAfterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}