/*
 * Level C: the runtime bridge driving the real Inferno library.
 *
 *   test_real <libqemu-aarch64-softmmu> <qmp port> <qmp_probe.py>
 *
 * Boots QEMU's device-less `none` machine (no guest files needed), then walks
 * the bridge through pause, resume, input, metrics and stop, asking QEMU
 * itself over QMP after each step whether the run state really changed.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "vp_runtime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static void msleep(int ms)
{
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

static bool wait_for(vp_emulator *emu, vp_state want, int ms)
{
    for (int i = 0; i < ms / 5; i++) {
        if (vp_emulator_state(emu) == want)
            return true;
        msleep(5);
    }
    return vp_emulator_state(emu) == want;
}

static const char *probe_script;
static const char *qmp_port;

/* QEMU's own answer, retried briefly: vmstop is processed by the main loop. */
static bool qmp_status_is(const char *want)
{
    char cmd[1024];
    snprintf(cmd, sizeof cmd, "python3 '%s' %s %s > /dev/null", probe_script, qmp_port, want);
    for (int i = 0; i < 20; i++) {
        if (system(cmd) == 0)
            return true;
        msleep(100);
    }
    return false;
}

int main(int argc, char **argv)
{
    char err[512] = "";
    char qmp[128];

    if (argc < 4) {
        fprintf(stderr, "usage: %s <lib> <qmp port> <qmp_probe.py>\n", argv[0]);
        return 2;
    }
    qmp_port = argv[2];
    probe_script = argv[3];
    snprintf(qmp, sizeof qmp, "tcp:127.0.0.1:%s,server=on,wait=off", qmp_port);

    vp_emulator *emu = vp_emulator_create(argv[1], err, sizeof err);
    if (!emu) {
        fprintf(stderr, "create: %s\n", err);
        return 1;
    }
    uint32_t caps = vp_emulator_capabilities(emu);
    printf("capabilities 0x%x\n", caps);
    /* The real build must export everything the app relies on. */
    CHECK(caps & VP_CAP_DISPLAY);
    CHECK(caps & VP_CAP_TOUCH);
    CHECK(caps & VP_CAP_BUTTONS);
    CHECK(caps & VP_CAP_PAUSE);
    CHECK(caps & VP_CAP_RESET);
    CHECK(caps & VP_CAP_STOP);
    CHECK(caps & VP_CAP_STATS);
    CHECK(caps & VP_CAP_NET_STATUS);
    CHECK(caps & VP_CAP_BATTERY);

    const char *args[] = {"qemu-system-aarch64",
                          "-M",
                          "none",
                          "-nodefaults",
                          "-display",
                          "none",
                          "-monitor",
                          "none",
                          "-serial",
                          "none",
                          "-qmp",
                          qmp};
    CHECK(vp_emulator_start(emu, (int)(sizeof args / sizeof args[0]), args) == VP_OK);
    CHECK(wait_for(emu, VP_STATE_RUNNING, 20000));
    CHECK(qmp_status_is("running"));

    CHECK(vp_emulator_pause(emu) == VP_OK);
    CHECK(qmp_status_is("paused"));
    CHECK(vp_emulator_resume(emu) == VP_OK);
    CHECK(qmp_status_is("running"));

    /* The `none` machine has no panel or buttons; the calls must still be safe. */
    CHECK(vp_emulator_set_touch(emu, 10, 10, true) == VP_OK);
    CHECK(vp_emulator_set_touch(emu, 10, 10, false) == VP_OK);
    CHECK(vp_emulator_button_event(emu, VP_BUTTON_HOME, true) == VP_OK);
    CHECK(vp_emulator_button_event(emu, VP_BUTTON_HOME, false) == VP_OK);
    vp_frame_info info;
    vp_frame_result fr = vp_emulator_framebuffer(emu, NULL, 0, &info);
    printf("framebuffer on `none`: %d (%ux%u)\n", fr, info.width, info.height);
    CHECK(fr != VP_FRAME_OK); /* nothing to draw into a NULL buffer */

    vp_metrics m;
    msleep(200);
    vp_emulator_get_metrics(emu, &m);
    CHECK(m.state == VP_STATE_RUNNING);
    CHECK(m.uptime_ms >= 100);
    CHECK(m.touches_sent == 2 && m.buttons_sent == 2);
    CHECK(!m.net_link_up);

    CHECK(vp_emulator_stop(emu) == VP_OK);
    CHECK(vp_emulator_wait(emu, 20000));
    CHECK(vp_emulator_state(emu) == VP_STATE_STOPPED);
    vp_emulator_get_metrics(emu, &m);
    printf("exit status %d\n", m.exit_status);
    CHECK(vp_emulator_destroy(emu) == VP_OK);

    printf("%s real (%d failure%s)\n", failures ? "FAIL" : "PASS", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
