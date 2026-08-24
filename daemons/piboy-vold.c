/*
 * piboy-vold - map the PiBoy DMG volume wheel onto the ALSA mixer.
 *
 * The driver reports the wheel as ABS_VOLUME on its own input device, with the
 * jitter deadband applied in-kernel via the axis fuzz. Blocking on that fd means
 * no polling, no userspace deadband, and no amixer fork per change - which is
 * what the bash daemon was doing four times a second, forever.
 *
 * The PCM control spans about -102dB..+4dB linearly in dB, so the bottom of its
 * range is inaudible on this speaker: wheel 0 mutes, 1..100 maps onto
 * MIXER_FLOOR..100% of the raw volume range (see apply()).
 *
 * cc -O2 -o piboy-vold piboy-vold.c -lasound
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <signal.h>
#include <linux/input.h>
#include <alsa/asoundlib.h>

#define WHEEL_NAME   "PiBoy DMG Volume Wheel"
#define MIXER_CARD   "default"
#define MIXER_CTL    "PCM"
#define MIXER_FLOOR  55          /* raw scale; below this the PCM control is inaudible */
#define MUTE_BELOW   3           /* wheel positions at or under this mute outright */

static volatile sig_atomic_t running = 1;
static void on_signal(int sig) { (void)sig; running = 0; }

/* Find the event node whose EVIOCGNAME matches, so we never hardcode eventN. */
static int open_wheel(void)
{
    DIR *d = opendir("/dev/input");
    struct dirent *e;
    char path[320], name[256];
    int fd = -1;

    if (!d)
        return -1;

    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "event", 5) != 0)
            continue;
        snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
        fd = open(path, O_RDONLY);
        if (fd < 0)
            continue;
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
            strcmp(name, WHEEL_NAME) == 0) {
            fprintf(stderr, "piboy-vold: wheel on %s\n", path);
            closedir(d);
            return fd;
        }
        close(fd);
        fd = -1;
    }
    closedir(d);
    return -1;
}

static snd_mixer_t *mixer;
static snd_mixer_elem_t *elem;

static int mixer_open(void)
{
    snd_mixer_selem_id_t *sid;

    if (snd_mixer_open(&mixer, 0) < 0 ||
        snd_mixer_attach(mixer, MIXER_CARD) < 0 ||
        snd_mixer_selem_register(mixer, NULL, NULL) < 0 ||
        snd_mixer_load(mixer) < 0)
        return -1;

    snd_mixer_selem_id_alloca(&sid);
    snd_mixer_selem_id_set_index(sid, 0);
    snd_mixer_selem_id_set_name(sid, MIXER_CTL);
    elem = snd_mixer_find_selem(mixer, sid);
    return elem ? 0 : -1;
}

/* Wheel 0..100 -> mixer percent on the RAW volume range.
 *
 * Deliberately not the dB API: this control reports its dB minimum as the mute
 * sentinel (a huge negative), so interpolating from it lands below the audible
 * floor and snaps to mute. The raw range is already linear in dB on this card
 * (measured: 30% = -70.47dB, 60% = -38.56dB, 100% = +4.00dB), which is also
 * perceptually linear, so a plain percentage is the right mapping. */
static void apply(int wheel)
{
    static int last = -1;
    long min, max;
    int pct;

    if (wheel < 0) wheel = 0;
    if (wheel > 100) wheel = 100;

    /* Mute a little above zero, not only at it. The kernel axis fuzz drops
     * changes smaller than fuzz/2, so the final 1 -> 0 step never arrives and the
     * wheel would otherwise rest at MIXER_FLOOR - quietly audible forever. */
    pct = wheel > MUTE_BELOW ? MIXER_FLOOR + wheel * (100 - MIXER_FLOOR) / 100 : 0;
    if (pct == last)
        return;                          /* distinct wheel steps can map alike */

    if (snd_mixer_selem_get_playback_volume_range(elem, &min, &max) < 0)
        return;                          /* note: `last` NOT updated - retry next event */
    if (snd_mixer_selem_set_playback_volume_all(elem, min + (max - min) * pct / 100) < 0)
        return;

    /* Use the element's real mute switch as well: setting the volume to its
     * minimum is not necessarily silent on this card. */
    if (snd_mixer_selem_has_playback_switch(elem))
        snd_mixer_selem_set_playback_switch_all(elem, pct != 0);

    /* Only now is the cache truthful. Committing it before the write would
     * strand this wheel position forever if the write failed. */
    last = pct;
}

int main(void)
{
    struct input_absinfo abs;
    struct input_event ev;
    int fd;

    /* sigaction without SA_RESTART: glibc's signal() sets SA_RESTART, which
     * restarts the blocking read() after the handler and makes the process
     * ignore SIGTERM entirely. We want read() to fail with EINTR so the loop
     * can observe `running` and exit. */
    {
        struct sigaction sa = { .sa_handler = on_signal };
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;                 /* explicitly NOT SA_RESTART */
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT,  &sa, NULL);
    }
    setvbuf(stderr, NULL, _IOLBF, 0);

    fd = open_wheel();
    if (fd < 0) {
        fprintf(stderr, "piboy-vold: '%s' not found\n", WHEEL_NAME);
        return 1;
    }
    if (mixer_open() < 0) {
        fprintf(stderr, "piboy-vold: mixer '%s' on '%s' unavailable\n",
                MIXER_CTL, MIXER_CARD);
        return 1;
    }

    /* Seed from the current wheel position rather than waiting for a turn. */
    if (ioctl(fd, EVIOCGABS(ABS_VOLUME), &abs) >= 0)
        apply(abs.value);

    while (running) {
        ssize_t n = read(fd, &ev, sizeof(ev));   /* blocks; kernel fuzz filters */

        if (n < 0) {
            if (errno == EINTR)
                continue;              /* signal arrived; loop re-checks running */
            fprintf(stderr, "piboy-vold: read failed: %s\n", strerror(errno));
            break;
        }
        if (n != sizeof(ev)) {         /* short/zero read: errno is NOT meaningful here */
            fprintf(stderr, "piboy-vold: short read (%zd bytes)\n", n);
            break;                     /* never `continue` - that is a 100%% CPU spin */
        }
        snd_mixer_handle_events(mixer);   /* pick up changes made by others */
        if (ev.type == EV_ABS && ev.code == ABS_VOLUME)
            apply(ev.value);
    }

    snd_mixer_close(mixer);
    close(fd);
    return 0;
}
