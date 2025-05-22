#include "fpicker.h"

// --- Definitions from AFL++ (types.h) ---

// Versioning
#define FS_NEW_VERSION_MAX 1
#define FS_NEW_MAGIC (0x41464c00 + FS_NEW_VERSION_MAX)
#define FS_NEW_MAGIC_REPLY (FS_NEW_MAGIC ^ 0xffffffff)

// Options
#define FS_OPT_ENABLED 0x80000001U
#define FS_OPT_MAPSIZE 0x40000000U
#define FS_OPT_SHDMEM_FUZZ 0x01000000U
#define FS_OPT_AUTODICT 0x10000000U

// Error codes
#define FS_OPT_ERROR 0xf800008f
#define FS_OPT_SET_ERROR(x) ((x & 0x0000ffff) << 8)

// --- Forkserver logic (based on AFL++'s afl-proxy.c example, afl-forkserver.c) ---

// Custom error codes
#define FS_ERROR_TARGET_CRASHED 101
#define FS_ERROR_TARGET_NO_ATTACH 102

static bool _start_forkserver() {
    uint32_t afl_msg;
    uint32_t proxy_version_msg = FS_NEW_MAGIC;
    uint32_t proxy_reply_msg = FS_NEW_MAGIC_REPLY;
    uint32_t proxy_options_msg = FS_OPT_ENABLED | FS_OPT_MAPSIZE;
    uint32_t proxy_map_size_msg = COVERAGE_BITMAP_SIZE;

    plog("[PROXY] Starting forkserver handshake on FDs: read=%d, write=%d\n", 
         FORKSRV_FD, FORKSRV_FD + 1);

    // 1. Proxy sends its version to AFL++
    if (write(FORKSRV_FD + 1, &proxy_version_msg, 4) != 4) {
        plog("[PROXY] Error writing version.\n");
        return false;
    }
    plog("[PROXY] Sent version: 0x%08x\n", proxy_version_msg);

    // 2. Proxy reads AFL++'s XORed reply
    if (read(FORKSRV_FD, &afl_msg, 4) != 4) {
        plog("[PROXY] Error reading XORed reply.\n");
        return false;
    }
    plog("[PROXY] Received XORed reply: 0x%08x\n", afl_msg);

    if (afl_msg != proxy_reply_msg) {
        plog("[PROXY] AFL++ reply mismatch: got 0x%08x, expected 0x%08x.\n",
             afl_msg, proxy_reply_msg);
        return false;
    }

    // 3. Send our options
    if (write(FORKSRV_FD + 1, &proxy_options_msg, 4) != 4) {
        plog("[PROXY] Error writing options.\n");
        return false;
    }
    plog("[PROXY] Sent options: 0x%08x\n", proxy_options_msg);

    // 4. Send map size (since we set FS_OPT_MAPSIZE)
    if (write(FORKSRV_FD + 1, &proxy_map_size_msg, 4) != 4) {
        plog("[PROXY] Error writing map size.\n");
        return false;
    }
    plog("[PROXY] Sent map size: 0x%08x (%u)\n", proxy_map_size_msg, proxy_map_size_msg);

    // 5. FS_OPT_AUTODICT
    // 6. FS_OPT_SHDMEM_FUZZ

    // 7. Send version again as final confirmation
    if (write(FORKSRV_FD + 1, &proxy_version_msg, 4) != 4) {
        plog("[PROXY] Error writing final version.\n");
        return false;
    }
    plog("[PROXY] Sent final version: 0x%08x\n", proxy_version_msg);

    plog("[PROXY] New forkserver handshake with AFL++ successful.\n");
    return true;
}

static uint32_t _next_testcase(uint8_t *buf, uint32_t max_len) {
    int32_t status_from_afl = 0;
    int32_t dummy_child_pid = 1;
    ssize_t testcase_len;

    // Abort if read fails.
    if (read(FORKSRV_FD, &status_from_afl, 4) != 4) {
        plog("[PROXY] Error reading status from AFL++.\n");
        return 0;
    }

    // Read the test case from stdin (fd 0).
    testcase_len = read(0, buf, max_len);
    if (testcase_len < 0) {
        plog("[PROXY] Error reading test case from stdin.\n");
        return 0;
    }

    // Report that we are starting the target.
    if (write(FORKSRV_FD + 1, &dummy_child_pid, 4) != 4) {
        plog("[PROXY] Error writing dummy PID to AFL++.\n");
        return 0;
    }

    return (uint32_t)testcase_len;
}

static bool _end_testcase(int32_t status) {
    if (write(FORKSRV_FD + 1, &status, 4) != 4) {
        plog("[PROXY] Error writing execution status to AFL++.\n");
        return false;
    }
    return true;
}

void _forkserver_send_error(int error_code) {
    uint32_t status = FS_OPT_ERROR | FS_OPT_SET_ERROR(error_code);
    ssize_t written = write(FORKSRV_FD + 1, &status, 4);
    if (written < 0) { // Use < 0 to check for write errors
        plog("[PROXY] Error while sending error to forkserver: %s\n", strerror(errno));
    }
}

void run_forkserver(fuzzer_state_t *fstate) {
    uint32_t len;
    uint8_t buf[FUZZING_PAYLOAD_SIZE];

    if (!_start_forkserver()) {
        plog("[PROXY] Unable to start forkserver, handshake failed.\n");
        return;
    }

    struct timeval *mut_timer = _start_measure();

    plog("[PROXY] Everything ready, starting to fuzz!\n");

    while ((len = _next_testcase(buf, FUZZING_PAYLOAD_SIZE)) > 0) {
        fstate->mutation_time += _stop_measure(mut_timer);
        struct timeval *iteration_timer = _start_measure();

        // Call frida to fuzz the target.
        do_fuzz_iteration(fstate, buf, len);

        // Check if the fuzzed process is still running
        if (kill(fstate->target_pid, 0) == -1) { 
            plog("[PROXY] Target process (PID: %d) is not there anymore. Crash?\n", fstate->target_pid);

            fstate->exec_ret_status = SIGSEGV;

            if (fstate->config->exec_mode == EXEC_MODE_SPAWN) {
                if (!spawn_or_attach(fstate)) {
                     plog("[PROXY] Failed to respawn/attach target after crash. Exiting.\n");
                    _forkserver_send_error(FS_ERROR_TARGET_CRASHED);
                    do_exit(fstate);
                    break;
                }
            } else {
                plog("[PROXY] Target process died in attach mode. Proxy cannot continue.\n");
                _forkserver_send_error(FS_ERROR_TARGET_NO_ATTACH);
                do_exit(fstate);
                break;
            }
        }

        if (!_end_testcase(fstate->exec_ret_status)) {
            plog("[PROXY] Failed to send end_testcase status. Exiting forkserver loop.\n");
            break;
        }

        fstate->exec_ret_status = 0;
        bzero(buf, len);

        fstate->total_payload_count++;

        if (fstate->config->metrics) {
            uint64_t itime = _stop_measure(iteration_timer);

            int mut_avg = fstate->mutation_time / fstate->total_payload_count;
            int cov_avg = fstate->coverage_time / fstate->total_payload_count;

            plog("[METRICS]: [t=%lu] [fc=%llu] [cur_loop=%d] [mut_avg=%d] [cov_avg=%d]\n", 
                time(NULL), fstate->total_payload_count, itime, mut_avg, cov_avg);
        }
        mut_timer = _start_measure();
    }

    plog("[PROXY] Forkserver execution ended (testcase len <= 0 or read error).\n");
    _stop_measure(mut_timer);
}
