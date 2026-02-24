/**
 * OpportunityTriggerLogger
 *
 * Lightweight logging utility for the Opportunity trigger framework.
 * Writes to a Platform Event or falls back to System.debug to avoid
 * DML complications inside trigger contexts.
 *
 * This is intentionally minimal — replace with your org's logging
 * framework (e.g., a custom Log__c object, Platform Events, etc.)
 * if one exists.
 *
 * @author Skye
 * @ticket KAN-5
 */
public with sharing class OpportunityTriggerLogger {

    /**
     * Logs a message. Currently writes to the debug log.
     * Extend this method to persist logs to a custom object or platform event
     * as needed by the org's logging strategy.
     *
     * @param className   The class where the log originated.
     * @param methodName  The method where the log originated.
     * @param message     The log message.
     */
    public static void log(String className, String methodName, String message) {
        System.debug(
            LoggingLevel.ERROR,
            '[' + className + '.' + methodName + '] ' + message
        );
    }
}
