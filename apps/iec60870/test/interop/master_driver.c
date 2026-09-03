/* Minimal CS104 master driver for iec60870_interop_SUITE, built against
 * lib60870-C (https://github.com/mz-automation/lib60870). Not part of the
 * iec60870 Erlang app -- a disposable test fixture the suite compiles on
 * demand (apps/iec60870/test/iec60870_interop_SUITE.erl).
 *
 * Drives one scripted scenario against a server at ca=1, then prints exactly
 * one line:
 *   RESULT: <scenario> ok
 *   RESULT: <scenario> fail: <reason>
 * and exits 0 / 1 accordingly -- the CT suite asserts on that line rather
 * than parsing a human-oriented transcript.
 *
 * Scenarios (argv[3]): interrogate, test_command, direct_command,
 * select_before_operate, clock_sync. See scenario functions below for what
 * each expects of the data model at COA 1 (IOA 100 = M_SP_NA_1, IOA 200 =
 * M_ME_NC_1) preloaded by the suite.
 */

#include "cs104_connection.h"
#include "hal_thread.h"
#include "hal_time.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CA 1
#define POLL_MS 20

static volatile bool g_startdtCon = false;
static volatile bool g_closed = false;

static volatile bool g_sawSp100 = false;
static volatile bool g_sawMe200 = false;

static volatile bool g_actCon = false;
static volatile bool g_actConNegative = false;
static volatile bool g_actTerm = false;
static volatile int g_actConTypeId = -1;

static void
resetActFlags(void)
{
    g_actCon = false;
    g_actConNegative = false;
    g_actTerm = false;
    g_actConTypeId = -1;
}

static void
connectionHandler(void* parameter, CS104_Connection connection, CS104_ConnectionEvent event)
{
    (void) parameter;
    (void) connection;
    switch (event) {
    case CS104_CONNECTION_STARTDT_CON_RECEIVED:
        g_startdtCon = true;
        break;
    case CS104_CONNECTION_CLOSED:
        g_closed = true;
        break;
    default:
        break;
    }
}

static bool
asduReceivedHandler(void* parameter, int address, CS101_ASDU asdu)
{
    (void) parameter;
    (void) address;

    TypeID type = CS101_ASDU_getTypeID(asdu);
    CS101_CauseOfTransmission cot = CS101_ASDU_getCOT(asdu);

    if (type == M_SP_NA_1) {
        int i;
        for (i = 0; i < CS101_ASDU_getNumberOfElements(asdu); i++) {
            InformationObject io = CS101_ASDU_getElement(asdu, i);
            if (InformationObject_getObjectAddress(io) == 100)
                g_sawSp100 = true;
            InformationObject_destroy(io);
        }
    } else if (type == M_ME_NC_1) {
        int i;
        for (i = 0; i < CS101_ASDU_getNumberOfElements(asdu); i++) {
            InformationObject io = CS101_ASDU_getElement(asdu, i);
            if (InformationObject_getObjectAddress(io) == 200)
                g_sawMe200 = true;
            InformationObject_destroy(io);
        }
    } else if (cot == CS101_COT_ACTIVATION_CON) {
        g_actCon = true;
        g_actConNegative = CS101_ASDU_isNegative(asdu);
        g_actConTypeId = (int) type;
    } else if (cot == CS101_COT_ACTIVATION_TERMINATION) {
        g_actTerm = true;
    }

    return true;
}

/* Poll a flag up to timeoutMs, sleeping POLL_MS between checks. */
static bool
waitUntil(volatile bool* flag, int timeoutMs)
{
    int waited = 0;
    while (!(*flag) && waited < timeoutMs) {
        Thread_sleep(POLL_MS);
        waited += POLL_MS;
    }
    return *flag;
}

static const char*
scenarioInterrogate(CS104_Connection con)
{
    CS104_Connection_sendInterrogationCommand(con, CS101_COT_ACTIVATION, CA, IEC60870_QOI_STATION);

    if (!waitUntil(&g_actCon, 3000))
        return "no activation confirmation for interrogation";
    if (g_actConNegative)
        return "interrogation activation confirmation was negative";
    if (!waitUntil(&g_actTerm, 3000))
        return "no activation termination for interrogation";
    if (!g_sawSp100)
        return "IOA 100 (M_SP_NA_1) missing from the dump";
    if (!g_sawMe200)
        return "IOA 200 (M_ME_NC_1) missing from the dump";

    return NULL;
}

static const char*
scenarioTestCommand(CS104_Connection con)
{
    struct sCP56Time2a ts;
    CP56Time2a_createFromMsTimestamp(&ts, Hal_getTimeInMs());
    CS104_Connection_sendTestCommandWithTimestamp(con, CA, 0x4938, &ts);

    if (!waitUntil(&g_actCon, 3000))
        return "no activation confirmation for test command";
    if (g_actConTypeId != C_TS_TA_1)
        return "reply was not C_TS_TA_1";
    if (g_actConNegative)
        return "test command activation confirmation was negative";

    return NULL;
}

static const char*
scenarioDirectCommand(CS104_Connection con)
{
    InformationObject sc = (InformationObject) SingleCommand_create(NULL, 100, true, false, 0);
    CS104_Connection_sendProcessCommandEx(con, CS101_COT_ACTIVATION, CA, sc);
    InformationObject_destroy(sc);

    if (!waitUntil(&g_actCon, 3000))
        return "no activation confirmation for direct command";
    if (g_actConNegative)
        return "direct command activation confirmation was negative";
    if (!waitUntil(&g_actTerm, 3000))
        return "no activation termination for direct command";

    return NULL;
}

static const char*
scenarioSelectBeforeOperate(CS104_Connection con)
{
    InformationObject select = (InformationObject) SingleCommand_create(NULL, 100, true, true, 0);
    CS104_Connection_sendProcessCommandEx(con, CS101_COT_ACTIVATION, CA, select);
    InformationObject_destroy(select);

    if (!waitUntil(&g_actCon, 3000))
        return "no activation confirmation for select";
    if (g_actConNegative)
        return "select activation confirmation was negative";

    resetActFlags();

    InformationObject operate = (InformationObject) SingleCommand_create(NULL, 100, true, false, 0);
    CS104_Connection_sendProcessCommandEx(con, CS101_COT_ACTIVATION, CA, operate);
    InformationObject_destroy(operate);

    if (!waitUntil(&g_actCon, 3000))
        return "no activation confirmation for operate";
    if (g_actConNegative)
        return "operate activation confirmation was negative";
    if (!waitUntil(&g_actTerm, 3000))
        return "no activation termination for operate";

    return NULL;
}

static const char*
scenarioClockSync(CS104_Connection con)
{
    struct sCP56Time2a ts;
    CP56Time2a_createFromMsTimestamp(&ts, Hal_getTimeInMs());
    CS104_Connection_sendClockSyncCommand(con, CA, &ts);

    if (!waitUntil(&g_actCon, 3000))
        return "no activation confirmation for clock sync";
    if (g_actConTypeId != C_CS_NA_1)
        return "reply was not C_CS_NA_1";
    if (g_actConNegative)
        return "clock sync activation confirmation was negative";

    return NULL;
}

int
main(int argc, char** argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <host> <port> <scenario>\n", argv[0]);
        return 2;
    }

    const char* host = argv[1];
    int port = atoi(argv[2]);
    const char* scenario = argv[3];

    CS104_Connection con = CS104_Connection_create(host, port);
    CS104_Connection_setConnectionHandler(con, connectionHandler, NULL);
    CS104_Connection_setASDUReceivedHandler(con, asduReceivedHandler, NULL);

    const char* failure = "could not connect";

    if (CS104_Connection_connect(con)) {
        CS104_Connection_sendStartDT(con);

        if (waitUntil(&g_startdtCon, 3000)) {
            resetActFlags();

            if (strcmp(scenario, "interrogate") == 0)
                failure = scenarioInterrogate(con);
            else if (strcmp(scenario, "test_command") == 0)
                failure = scenarioTestCommand(con);
            else if (strcmp(scenario, "direct_command") == 0)
                failure = scenarioDirectCommand(con);
            else if (strcmp(scenario, "select_before_operate") == 0)
                failure = scenarioSelectBeforeOperate(con);
            else if (strcmp(scenario, "clock_sync") == 0)
                failure = scenarioClockSync(con);
            else
                failure = "unknown scenario";
        } else {
            failure = "no STARTDT confirmation";
        }
    }

    CS104_Connection_destroy(con);

    if (failure == NULL) {
        printf("RESULT: %s ok\n", scenario);
        return 0;
    } else {
        printf("RESULT: %s fail: %s\n", scenario, failure);
        return 1;
    }
}
