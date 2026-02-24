/**
 * OpportunityTrigger
 *
 * Single entry point for all Opportunity trigger events.
 * Contains zero business logic — all routing and processing is delegated
 * to OpportunityTriggerHandler to keep this file thin and maintainable.
 *
 * Contexts handled:
 *   - before insert  : field defaulting / validation before record is saved
 *   - before update  : field defaulting / validation before record is saved
 *   - after insert   : side-effects requiring committed record IDs (Tasks, notifications)
 *   - after update   : side-effects on record changes (Closed Won transition Tasks)
 *
 * One-trigger-per-object pattern: do NOT add a second Opportunity trigger.
 */
trigger OpportunityTrigger on Opportunity (
    before insert,
    before update,
    after insert,
    after update
) {
    OpportunityTriggerHandler handler = new OpportunityTriggerHandler(
        Trigger.new,
        Trigger.old,
        Trigger.newMap,
        Trigger.oldMap,
        Trigger.operationType
    );

    handler.run();
}