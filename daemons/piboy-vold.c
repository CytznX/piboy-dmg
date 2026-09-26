/*
 * piboy-vold - map the PiBoy DMG volume wheel onto the ALSA mixer.
 *
 * The driver reports the wheel as ABS_VOLUME on its own input device, with the
 * jitter deadband applied in-kernel via the axis fuzz. Blocking on that fd means
 * no polling, no userspace deadband, and no amixer fork per change - which is
 * what the bash daemon was doing four times a second, forever.
 *
 * The PCM control spans about -102dB..+4dB linearly in dB, so a 1:1 wheel-to-
 * percent mapping is audible only over the top of the travel. The wheel is
 * instead put through Experimental Pi's own logarithmic curve, recovered from
 * their osd binary; the bottom of the travel mutes outright (see apply()).
 *
 * Turning the wheel publishes the position to VOL_FILE, which RetroArch's
 * patched status bar reads and displays - the modern stand-in for what
 * Experimental Pi's osd.cfg called "volumeicon" (see osd_show()).
 *
 * cc -O2 -o piboy-vold piboy-vold.c -lasound -lm
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
#include <math.h>
#include <poll.h>
#include <time.h>
#include <linux/input.h>
#include <alsa/asoundlib.h>

#define WHEEL_NAME   "PiBoy DMG Volume Wheel"
#define MIXER_CARD   "default"
#define MIXER_CTL    "PCM"
#define MUTE_BELOW   3           /* wheel positions at or under this mute outright */
/* Must match network_cmd_port in retroarch.cfg, which is the real authority.
 * piboy-fand carries the same constant for its battery warnings. A stale value
 * here fails SILENTLY - both senders ignore every error - so change all three. */
/* The volume readout now lives in RetroArch's status bar rather than a
 * notification, so the wheel position is published here and the bar picks it
 * up. A notification was the wrong vehicle: menu_enable_widgets (which the
 * status bar requires) renders them as pop-up cards, and a control that moves
 * 25 times a second should not be firing pop-ups.
 *
 * tmpfs, so this costs no card writes. Mode 0644 because RetroArch runs as the
 * desktop user and only needs to read it. */
#define VOL_FILE     "/run/piboy-volume"
#define OSD_CELLS    16          /* slider width, in cells */

/* Slider glyphs, as explicit UTF-8 bytes rather than \u escapes so the encoding
 * does not depend on the compiler's execution charset.
 *
 * These MUST be equal width or the bar changes length as it fills. RetroArch's
 * bundled OSD font is proportional - '=' is 642 units and '-' is 460, so a full
 * bar rendered 40% wider than an empty one. retroarch.cfg therefore points
 * video_font_path at DejaVuSansMono, where every glyph is 602 units, and that
 * font also carries these block characters (the bundled one does not - they
 * would render as tofu). Both facts were measured from the hmtx tables.
 *
 * If the font ever goes missing RetroArch falls back to its bundled one and
 * these become boxes, which is a loud failure rather than a silent one. */
#define OSD_FILL     "\xE2\x96\x88"   /* U+2588 FULL BLOCK  */
#define OSD_EMPTY    "\xE2\x96\x91"   /* U+2591 LIGHT SHADE */
/* OSD pacing, milliseconds.
 *
 * These defaults assume RetroArch carries patches/retroarch-showmsg-flush.patch,
 * which makes SHOW_MSG replace the pending notification instead of queueing
 * behind it. With that patch a redraw costs nothing, so the slider tracks the
 * wheel live: QUIET is only the settling delay for the final frame, and MIN=0
 * means draw on every event (~25/s while turning).
 *
 * WITHOUT that patch these values are wrong and the display will lag by many
 * seconds. Stock RetroArch holds each message 180 frames - three seconds - and
 * shows them strictly in turn, with no duration setting, so anything above one
 * push per three seconds builds a backlog. Coalescing to 8/s was tried and was
 * still far too fast. On stock RetroArch use QUIET=150 MIN=3500, which draws a
 * single frame once the wheel settles.
 *
 * Both are overridable at runtime via PIBOY_OSD_QUIET_MS and PIBOY_OSD_MS. */
#define OSD_QUIET_MS_DEFAULT  50
#define OSD_MIN_MS_DEFAULT     0
static long osd_quiet_ms = OSD_QUIET_MS_DEFAULT;
static long osd_min_ms   = OSD_MIN_MS_DEFAULT;

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

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

/* Draw the wheel position as a slider inside the running game.
 *
 * Experimental Pi's osd.cfg called this "volumeicon" and drew a real slider on
 * a dispmanx overlay plane. That is not reachable here: under KMS only the DRM
 * master may commit to a plane, and RetroArch (or EmulationStation) holds it.
 * The nearest equivalent is to ask the process that DOES own the display to
 * draw for us, via RetroArch's UDP command port.
 *
 * Fire-and-forget by design: the socket is non-blocking, nothing is read back,
 * and every error is ignored - a volume wheel must never stall waiting on an
 * OSD. Only RetroArch listens, so this silently draws nothing under
 * EmulationStation and under the standalone ports; the wheel still works there,
 * it just gives no feedback. That is the limit of the mechanism, not a bug.
 *
 * The socket is deliberately left UNCONNECTED. connect() would let this use
 * send() and drop the address global, but a connected UDP socket latches the
 * ICMP port-unreachable that a closed loopback port returns and then fails
 * every OTHER send with ECONNREFUSED (measured). That would blank half the
 * slider updates in the moment RetroArch starts listening. */
static void osd_show(int wheel)
{
    char  buf[8];
    int   fd, n;
    ssize_t w;

    if (wheel < 0)   wheel = 0;
    if (wheel > 100) wheel = 100;

    n = snprintf(buf, sizeof buf, "%d\n", wheel);
    if (n <= 0)
        return;

    /* O_TRUNC, not append: only the latest position matters, and the reader
     * keys on this file's mtime to decide whether the wheel is being turned
     * right now. Failure is silent by design - a missing status bar must never
     * interfere with actually setting the volume. */
    fd = open(VOL_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    w = write(fd, buf, (size_t)n);
    (void)w;
    close(fd);
}

/* Wheel 0..100 -> mixer percent on the RAW volume range.
 *
 * Deliberately not the dB API: this control reports its dB minimum as the mute
 * sentinel (a huge negative), so interpolating from it lands below the audible
 * floor and snaps to mute. The raw range is already linear in dB on this card
 * (measured: 30% = -70.47dB, 60% = -38.56dB, 100% = +4.00dB) - which is exactly
 * why a 1:1 wheel-to-percent map is audible only near the top of the travel,
 * and why a curve is needed at all.
 *
 * The curve is Experimental Pi's, lifted from the osd binary they shipped:
 * a log10 call against literal-pool constants 9.0, 100.0 and 1.0, scaled by
 * 100, which their code handed to `amixer -q sset 'PCM' %d%%`.
 *
 *     percent = (int)(100 * log10(wheel * 9/100 + 1))
 *
 * It is an exact identity at both ends - log10(1) = 0 and log10(10) = 1 - and
 * bows upward in between (wheel 25 -> 51%, wheel 50 -> 74%), which is what
 * makes a dB-linear control feel even across the travel. Truncated, not
 * rounded, to match the original's (int) cast. */
static void apply(int wheel)
{
    static int last = -1;
    long min, max;
    int pct;

    if (wheel < 0) wheel = 0;
    if (wheel > 100) wheel = 100;

    /* Mute a little above zero, not only at it, and keep it a TRUE mute.
     * The kernel axis fuzz drops changes smaller than fuzz/2, so the final
     * 1 -> 0 step never arrives; without this the wheel would rest on the
     * curve's bottom step (wheel 1 -> 3%) forever. Experimental Pi's curve
     * reaches 0% at wheel 0 on its own, but 0% on this control is -102.39dB,
     * which is not silence - hence the switch below rather than a low level. */
    pct = wheel > MUTE_BELOW ? (int)(100.0 * log10(wheel * 9.0 / 100.0 + 1.0)) : 0;
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

    {
        static const struct { const char *name; long *slot; } knobs[] = {
            { "PIBOY_OSD_QUIET_MS", &osd_quiet_ms },
            { "PIBOY_OSD_MS",       &osd_min_ms   },
        };
        for (size_t i = 0; i < sizeof knobs / sizeof knobs[0]; i++) {
            const char *e = getenv(knobs[i].name);
            char *end;
            long v;
            if (!e || !*e)
                continue;
            v = strtol(e, &end, 10);
            if (*end == '\0' && v >= 0 && v <= 60000)
                *knobs[i].slot = v;
            else
                fprintf(stderr, "piboy-vold: ignoring %s='%s'\n", knobs[i].name, e);
        }
    }


    /* Seed from the current wheel position rather than waiting for a turn.
     * Nothing is drawn: nobody asked for the volume, so nothing should appear
     * on screen. Only the event loop below draws. */
    if (ioctl(fd, EVIOCGABS(ABS_VOLUME), &abs) >= 0)
        apply(abs.value);

    {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        long last_draw = 0;            /* monotonic ms of the last OSD frame */
        int  pending = 0, pending_val = 0;

        while (running) {
            /* Wait only while a frame is owed; otherwise block indefinitely,
             * so an idle wheel costs exactly nothing. */
            int timeout = pending ? (int)osd_quiet_ms : -1;

            int pr = poll(&pfd, 1, timeout);
            if (pr < 0) {
                if (errno == EINTR)
                    continue;          /* signal arrived; loop re-checks running */
                fprintf(stderr, "piboy-vold: poll failed: %s\n", strerror(errno));
                break;
            }
            if (pr == 0) {
                /* The wheel has been still for osd_quiet_ms: this is the
                 * single frame for this adjustment, showing the value it
                 * actually came to rest on. */
                if (pending) {
                    osd_show(pending_val);
                    last_draw = now_ms();
                    pending = 0;
                }
                continue;
            }

            ssize_t n = read(fd, &ev, sizeof(ev));
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN)
                    continue;
                fprintf(stderr, "piboy-vold: read failed: %s\n", strerror(errno));
                break;
            }
            if (n != sizeof(ev)) {     /* short/zero read: errno is NOT meaningful here */
                fprintf(stderr, "piboy-vold: short read (%zd bytes)\n", n);
                break;                 /* never `continue` - that is a 100%% CPU spin */
            }
            snd_mixer_handle_events(mixer);   /* pick up changes made by others */
            if (ev.type == EV_ABS && ev.code == ABS_VOLUME) {
                /* Volume on EVERY event - the audio must track the hand. */
                apply(ev.value);

                /* Hold the frame. The poll timeout below restarts on every
                 * event, so it only expires once the wheel has actually been
                 * still for osd_quiet_ms - that is the moment worth drawing. */
                pending     = 1;
                pending_val = ev.value;

                /* Backstop for a turn so slow it never falls quiet. */
                if (now_ms() - last_draw >= osd_min_ms) {
                    osd_show(ev.value);
                    last_draw = now_ms();
                    pending   = 0;
                }
            }
        }
    }

    snd_mixer_close(mixer);
    close(fd);
    return 0;
}
