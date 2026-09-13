#include <linux/delay.h>
#include <linux/input.h>
#include <linux/of_device.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/of.h>
#include <linux/version.h>
#include <linux/timer.h>
#include <linux/power_supply.h>
#include <linux/leds.h>
#include <linux/hwmon.h>
#include <linux/reboot.h>
#include <linux/backlight.h>

/* Renamed in 6.11; the driver still has to build on the 5.10 it came from. */
#ifndef BACKLIGHT_POWER_ON
#define BACKLIGHT_POWER_ON  FB_BLANK_UNBLANK
#define BACKLIGHT_POWER_OFF FB_BLANK_POWERDOWN
#endif

/* flags is a bitfield the board reads as one byte. Bit 0 is panel power, bit 7
 * says a reboot is coming rather than a shutdown - without it the XPi cuts the
 * rail on halt and never re-asserts it, so `reboot` leaves the unit off until
 * somebody flips the switch. Userspace used to write the whole byte, which
 * meant every writer had to know the whole layout and could clobber the other
 * bit. Both live behind proper interfaces now: a backlight classdev and a
 * reboot notifier. */
#define XPI_FLAG_PANEL   0x01
#define XPI_FLAG_REBOOT  0x80

#include <asm/io.h>

/* --- kernel API compatibility shims (5.10 .. 6.18+) --- */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,15,0)
#define GC_DEL_TIMER_SYNC(t) timer_delete_sync(t)
#else
#define GC_DEL_TIMER_SYNC(t) del_timer_sync(t)
#endif

MODULE_AUTHOR("Nathan Scherdin");
MODULE_DESCRIPTION("PiBoy DMG Controls driver");
MODULE_LICENSE("GPL");

static struct gc *gc_base;
static const int gc_gpio_clk = 26;
static const int gc_gpio_data = 27;
static const int gc_clk_bit = 1<<26;
static const int gc_data_bit = 1<<27;

static unsigned long lastgood=0;
static bool xpi_psy_valid = false;	/* latched on first good packet; never cleared */
static struct input_dev *xpi_vol_dev;	/* ABS_VOLUME wheel, separate from the gamepad */
static struct input_dev *xpi_pwr_dev;	/* KEY_POWER only, so udev tags it power-switch */
static struct timer_list xpi_pwr_timer;	/* backstop if nothing handles the key */
static bool xpi_pwr_off_last;
static struct power_supply *xpi_psy;
static int xpi_psy_last_pct = -1;
static int xpi_psy_last_sign = -2;
static int xpi_psy_last_vbus = -1;	/* status depends on VBus now, so changes must notify */
static struct power_supply *xpi_usb;	/* the wall supply, so userspace knows it is plugged in */

#define XPI_STAT_SHUTDOWN	0x40	/* active-low in stat_val */
#define XPI_STAT_VBUS		0x80	/* wall power present */
/* Current arrives as a signed char scaled by 50mA, so one LSB is 50mA. A full
 * pack sitting on a charger dithers across zero by exactly that much; without a
 * deadband the status flaps Full/Discharging and every flip emits a uevent.
 * Treat anything inside one LSB as zero. */
#define XPI_CUR_DEADBAND	50
#define XPI_PWR_BACKSTOP_S	8	/* XPi cuts the rail at ~31s; act well before that */

/* Fan fail-safe. Nothing controls the fan between module load and multi-user,
 * and if the userspace governor dies the duty simply freezes. Rather than trust
 * a daemon with thermal management, hold a floor in the kernel whenever nobody
 * has written pwm1 recently. 64/255 is the same value the daemon uses on exit. */
#define XPI_FAN_SAFE		64
#define XPI_FAN_TIMEOUT		(30 * HZ)
static unsigned long xpi_fan_last_set;
static int xpi_fan_enable = 2;
static bool xpi_led_ok;		/* hwmon pwm1_enable: 0=full speed, 1=manual, 2=manual+floor */
static unsigned long lasterror=0;

static uint8_t index;

union {
	struct {
		int flags_val;
		int fan_val;
		int red_val;
		int green_val;
	};
	int data[4];
}volatile values;

volatile int version_val = 0;
volatile int cur_val = 0;
volatile int batt_val = 0;
volatile int percent_val = 0;
volatile int stat_val = 0;
volatile int vol_val = 0;

struct kobject *kobj_ref;

#define GC_LENGTH 12

#define GPIO_SET *(gpio+7)
#define GPIO_CLR *(gpio+10)
#define GPIO_STATUS (*(gpio+13))

#define GC_REFRESH_TIME	(HZ/120)

/* Half-period of the bit-banged clock, in microseconds. The timer busy-spins in
 * udelay() for 12 bytes x 8 bits x 2 edges x BITRATE, so this value directly sets
 * the driver's permanent CPU cost. Writable at runtime so it can be swept against
 * the CRC error counters below rather than guessed at.
 *   cost/tick ~= 192 * bitrate microseconds; at 125Hz that is 2.4% of a core per us.
 */
static int gc_bitrate = 7;
#define XPI_BITRATE_MIN 1
#define XPI_BITRATE_MAX 50
static int gc_bitrate_set(const char *val, const struct kernel_param *kp)
{
	int v, ret = kstrtoint(val, 0, &v);

	if (ret)
		return ret;
	if (v < XPI_BITRATE_MIN || v > XPI_BITRATE_MAX)
		return -EINVAL;
	WRITE_ONCE(gc_bitrate, v);
	return 0;
}
static const struct kernel_param_ops gc_bitrate_ops = {
	.set = gc_bitrate_set,
	.get = param_get_int,
};
module_param_cb(bitrate, &gc_bitrate_ops, &gc_bitrate, 0644);
MODULE_PARM_DESC(bitrate, "GPIO clock half-period in us (default 7)");

/* Cumulative, never reset - lastgood/lasterror are consecutive-run counters and
 * cannot express an error rate. */
static unsigned long gc_pkt_good;
static unsigned long gc_pkt_crc;
module_param_named(pkt_good, gc_pkt_good, ulong, 0444);
MODULE_PARM_DESC(pkt_good, "cumulative packets passing CRC");
module_param_named(pkt_crc, gc_pkt_crc, ulong, 0444);
MODULE_PARM_DESC(pkt_crc, "cumulative packets failing CRC");

/* Bounded hard. gc_timer() issues ~230 udelay(BITRATE) calls per tick at ~125Hz,
 * so an unbounded value busy-spins longer than the timer period and pins a core
 * in softirq; a large one soft-locks the machine outright (and udelay() itself
 * overflows above MAX_UDELAY_MS anyway). Read once so a concurrent write to the
 * module parameter cannot slip an out-of-range value past the check. */
static inline int gc_bitrate_get(void)
{
	return clamp(READ_ONCE(gc_bitrate), XPI_BITRATE_MIN, XPI_BITRATE_MAX);
}
#define BITRATE gc_bitrate_get()

static volatile unsigned *gpio;

static const short gc_btn[] = { BTN_A, //A
				BTN_B, //B
				BTN_C, //C
				BTN_X, //X
				BTN_Y, //Y
				BTN_Z, //Z
				BTN_SELECT, //Select
				BTN_START, //Start
				BTN_THUMBL, //Left Thumb
				BTN_DPAD_UP, //DPAD Up
				BTN_DPAD_DOWN, //DPAD Down
				BTN_DPAD_LEFT, //DPAD Left
				BTN_DPAD_RIGHT, //DPAD Right
				BTN_TL, //Left Trigger
				BTN_TR, //Right Trigger
			};
int gc_btn_size = ARRAY_SIZE(gc_btn);	/* was sizeof(): looped 15 elements OOB */

struct gc {
	struct input_dev *dev;
	struct timer_list timer;
	int used;
	struct mutex mutex;
};

static ssize_t version_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", version_val); }
static ssize_t version_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&version_val); return count; }

static ssize_t flags_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", values.flags_val); }
static ssize_t flags_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&values.flags_val); return count; }

static ssize_t red_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", values.red_val); }
static ssize_t red_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&values.red_val); return count; }

static ssize_t green_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", values.green_val); }
static ssize_t green_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&values.green_val); return count; }

static ssize_t fan_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", values.fan_val); }
/* Clamped, unlike Experimental Pi original. An unclamped value is worse than merely
 * wrong: the wire byte is (unsigned char)val, so writing 256 transmits 0 - fan
 * fully off - while values.fan_val reads 256, which makes the safety floor's
 * "values.fan_val < XPI_FAN_SAFE" test false AND stamps xpi_fan_last_set, so the
 * 30s watchdog meant to catch a dead governor believes one is alive. The fan then
 * stays off with its own backstop defeated. hwmon's pwm1_store already clamps;
 * this duplicate path did not. Only a valid write refreshes the watchdog. */
static ssize_t fan_store(struct kobject *kobj, struct kobj_attribute *attr,
			 const char *buf, size_t count)
{
	int v;

	if (kstrtoint(buf, 0, &v))
		return -EINVAL;
	values.fan_val = clamp(v, 0, 255);
	xpi_fan_last_set = jiffies;
	return count;
}

static ssize_t cur_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", cur_val); }
static ssize_t cur_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&cur_val); return count; }

static ssize_t batt_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", batt_val); }
static ssize_t batt_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&batt_val); return count; }

static ssize_t percent_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", percent_val); }
static ssize_t percent_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&percent_val); return count; }

static ssize_t stat_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", stat_val); }
static ssize_t stat_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&stat_val); return count; }

static ssize_t vol_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf){ return sprintf(buf, "%d", vol_val); }
static ssize_t vol_store(struct kobject *kobj, struct kobj_attribute *attr,const char *buf, size_t count) { sscanf(buf,"%d",&vol_val); return count; }

struct kobj_attribute version = __ATTR(version, 0440, version_show, version_store);
struct kobj_attribute flags = __ATTR(flags, 0660, flags_show, flags_store);
/* Read-only on purpose. The driver does transmit red_val - the protocol
 * round-robins flags/fan/red/green, one per packet, and red goes out as
 * selector 0xC2 every fourth packet. The XPi simply ignores it, because
 * that channel is firmware-owned: Experimental Pi documents the single
 * bi-colour LED going green -> yellow -> red as the pack drops below 25%,
 * and it lights even with no Pi communicating at all. A writable node that
 * silently does nothing sent two separate investigations down a dead end,
 * so expose the value, not the illusion of control. Green is ours and is
 * registered properly as a leds classdev. */
struct kobj_attribute red = __ATTR(red, 0440, red_show, red_store);
struct kobj_attribute green = __ATTR(green, 0660, green_show, green_store);
struct kobj_attribute fan = __ATTR(fan, 0660, fan_show, fan_store);
struct kobj_attribute cur = __ATTR(amps, 0660, cur_show, cur_store);
struct kobj_attribute batt = __ATTR(battery, 0660, batt_show, batt_store);
struct kobj_attribute per = __ATTR(percent, 0660, percent_show, percent_store);
struct kobj_attribute stat = __ATTR(status, 0660, stat_show, stat_store);
struct kobj_attribute vol = __ATTR(volume, 0660, vol_show, vol_store);

void gpio_func(int pin, int state)
{
	volatile unsigned *tgpio = gpio;
	tgpio += (pin/10);
	if(state){*tgpio &= ~(0x7<<(pin%10)*3);	}
	else{*tgpio |= (0x1<<(pin%10)*3);}
}

uint16_t check_crc16(uint8_t data[])
{
	int len = GC_LENGTH-2;
	uint16_t crc=0;
	uint16_t ccrc = (data[GC_LENGTH-1]<<8) | data[GC_LENGTH-2];
	int i,j;

	for(i = 0;i<len;i++){
		crc = (uint16_t)(crc ^ ((uint16_t)data[i] << 8));
		for (j=0; j<8; j++){
			if ((crc & 0x8000)!=0) crc = (uint16_t)((crc << 1) ^ 0x1021);
			else crc <<= 1;
		}
	}

	return crc==ccrc ? 0 : 1;
}

uint16_t crc=0;
void calc_crc16(uint8_t *data, uint8_t len)
{
	int i,j;

	crc=0;

	for(i = 0;i<len;i++){
		crc = (uint16_t)(crc ^ ((uint16_t)data[i] << 8));
		for (j=0; j<8; j++){
			if ((crc & 0x8000)!=0) crc = (uint16_t)((crc << 1) ^ 0x1021);
			else crc <<= 1;
		}
	}
	data[len] = crc>>8;
	data[len+1] = crc&0xFF;
}

/* If logind (or anything else) fails to act on KEY_POWER, halt anyway rather than
 * let the XPi yank the rail out from under a mounted filesystem. Re-checks the bit
 * so a switch flipped back on simply lets this expire harmlessly. */
static void xpi_pwr_backstop(struct timer_list *t)
{
	if (!(stat_val & XPI_STAT_SHUTDOWN) && system_state == SYSTEM_RUNNING) {
		printk(KERN_ERR "xpi_gamecon: power switch off and nothing halted us - forcing poweroff\n");
		orderly_poweroff(false);
	}
}

static void gc_timer(struct timer_list *t)
{
	struct gc *gc = container_of(t, struct gc, timer);

	unsigned char data[32];
	struct input_dev *dev = gc->dev;

	int byteindex;
	long bitindex;

	gpio_func(gc_gpio_data,1);	//input

	for(byteindex=0;byteindex<GC_LENGTH;byteindex++){
		data[byteindex]=0;
		for(bitindex=0;bitindex<8;bitindex++){
			data[byteindex]<<=1;

			//set clock pin
			GPIO_SET |= gc_clk_bit;
			udelay(BITRATE);
			GPIO_CLR |= gc_clk_bit;
			udelay(BITRATE);
			data[byteindex] |= GPIO_STATUS & gc_data_bit ? 1 : 0;
		}
	}

	gpio_func(gc_gpio_data,0);	//output

	GPIO_SET |= gc_clk_bit;
	udelay(BITRATE);
	GPIO_CLR |= gc_clk_bit;
	udelay(BITRATE);

	if(data[0] && !check_crc16(data)){
		uint8_t len = 0;
		if(data[0]==0xA5){
			unsigned char val;
			len = 2;
			version_val = 0x0100;
			val = values.fan_val | (values.flags_val&0x1 ? 0x00 : 0x80);
			data[GC_LENGTH] = val;
			data[GC_LENGTH+1] = ~val;
			data[GC_LENGTH+2] = 0;
			data[GC_LENGTH+3] = 0;
		}
		else
		if(data[0]==0x5A){
			len = 4;
			version_val = 0x0101;
			data[GC_LENGTH+0] = 0xC0 | (index&0x3);
			data[GC_LENGTH+1] = values.data[index&0x3];
			calc_crc16(&data[GC_LENGTH],2);
			index++;
		}
		else{
			len = 4;
			version_val = ((data[0]&0xC0)<<2) | (data[0]&0x3F);
			data[GC_LENGTH+0] = 0xC0 | (index&0x3);
			data[GC_LENGTH+1] = values.data[index&0x3];
			calc_crc16(&data[GC_LENGTH],2);
			index++;
		}

		for(byteindex=GC_LENGTH;byteindex<GC_LENGTH+len;byteindex++){
			for(bitindex=0;bitindex<8;bitindex++){
				if(data[byteindex]&(0x80>>bitindex))
					GPIO_SET |= gc_data_bit;
				else
					GPIO_CLR |= gc_data_bit;
				//set clock pin
				GPIO_SET |= gc_clk_bit;
				udelay(BITRATE);
				GPIO_CLR |= gc_clk_bit;
				udelay(BITRATE);
			}
		}

		lastgood++;
		gc_pkt_good++;

		input_report_abs(dev, ABS_X, (int16_t)data[1]);		//X Axis
		input_report_abs(dev, ABS_Y, (int16_t)data[2]);		//Y Axis

		input_report_key(dev, gc_btn[0], !(data[3]&0x01));	//A
		input_report_key(dev, gc_btn[1], !(data[3]&0x02));	//B
		input_report_key(dev, gc_btn[2], !(data[3]&0x04));	//C
		input_report_key(dev, gc_btn[3], !(data[3]&0x08));	//X
		input_report_key(dev, gc_btn[4], !(data[3]&0x10));	//Y
		input_report_key(dev, gc_btn[5], !(data[3]&0x20));	//Z
		input_report_key(dev, gc_btn[6], data[3]&0x40);		//Select
		input_report_key(dev, gc_btn[7], data[3]&0x80); 	//Start
		input_report_key(dev, gc_btn[8], data[4]&0x40);		//Left Thumb
		input_report_key(dev, gc_btn[9], data[4]&0x01);		//DPAD Up
		input_report_key(dev, gc_btn[10], data[4]&0x02);	//DPAD Down
		input_report_key(dev, gc_btn[11], data[4]&0x04);	//DPAD Left
		input_report_key(dev, gc_btn[12], data[4]&0x08);	//DPAD Right
		input_report_key(dev, gc_btn[13], data[4]&0x10);	//Left Shoulder
		input_report_key(dev, gc_btn[14], data[4]&0x20);	//Right Shoulder

		input_sync(dev);

		batt_val = (int)(data[7]*5)+2950;		//Battery Voltage
		cur_val = (int)((signed char)data[8])*50;	//Current
		percent_val = data[9];				//battery percentage
		stat_val = data[5]&0xC6;			//VBus,Shutdown,VSTAT2,VSTAT1

		/* Power switch -> KEY_POWER. udev tags a KEY_POWER-carrying device as
		 * power-switch and systemd-logind's HandlePowerKey runs an inhibitor-aware
		 * shutdown, so clean poweroff no longer depends on any daemon running. */
		{
			bool off = !(stat_val & XPI_STAT_SHUTDOWN);

			if (off != xpi_pwr_off_last) {
				xpi_pwr_off_last = off;
				if (xpi_pwr_dev) {
					input_report_key(xpi_pwr_dev, KEY_POWER, off);
					input_sync(xpi_pwr_dev);
				}
				if (off)
					mod_timer(&xpi_pwr_timer,
						  jiffies + XPI_PWR_BACKSTOP_S * HZ);
			}
		}
		vol_val = data[6];				//Volume

		/* Publish the values before the flag that advertises them. Without the
		 * barrier a reader on another core can see xpi_psy_valid == true while
		 * percent_val is still 0, i.e. report a present battery at 0% - exactly
		 * what this guard exists to prevent. */
		/* Fan fail-safe: if nobody has set pwm1 recently the governor is gone
		 * (not started yet, crashed, or stopped) - hold a safe floor. */
		if (xpi_fan_enable == 0) {
			/* Standard hwmon meaning of pwm1_enable=0: no speed control,
			 * i.e. full speed. fancontrol writes this on abort expecting
			 * exactly that, so it must not mean "hold a low floor". */
			values.fan_val = 255;
		} else if (xpi_fan_enable == 2 &&
			   time_after(jiffies, xpi_fan_last_set + XPI_FAN_TIMEOUT)) {
			if (values.fan_val < XPI_FAN_SAFE)
				values.fan_val = XPI_FAN_SAFE;
		}

		/* Tell power_supply consumers only when something they can observe
		 * actually changed. Unconditionally at 125Hz this would emit a uevent
		 * per tick - a netlink broadcast and udev wakeup 125 times a second. */
		{
			int sign = (cur_val > XPI_CUR_DEADBAND) - (cur_val < -XPI_CUR_DEADBAND);
			int vbus = !!(stat_val & XPI_STAT_VBUS);

			if (percent_val != xpi_psy_last_pct ||
			    sign != xpi_psy_last_sign || vbus != xpi_psy_last_vbus) {
				bool vbus_changed = (vbus != xpi_psy_last_vbus);

				xpi_psy_last_pct = percent_val;
				xpi_psy_last_sign = sign;
				xpi_psy_last_vbus = vbus;
				if (xpi_psy)
					power_supply_changed(xpi_psy);
				/* Only the wall supply's consumers care about this one. */
				if (vbus_changed && xpi_usb)
					power_supply_changed(xpi_usb);
			}
		}

		if (!READ_ONCE(xpi_psy_valid)) {
			smp_wmb();		/* publish values before the flag */
			WRITE_ONCE(xpi_psy_valid, true);
		}
		if (xpi_vol_dev) {
			/* fuzz on ABS_VOLUME filters ADC jitter in-kernel, so userspace
			 * needs no deadband and no polling. */
			input_report_abs(xpi_vol_dev, ABS_VOLUME, vol_val);
			input_sync(xpi_vol_dev);
		}

		lasterror = 0;
	}
	else{
		lasterror++;
		gc_pkt_crc++;
		printk_ratelimited(KERN_INFO "XPi Gamecon CRC Error: %4.4lu %4.4lu",lastgood,lasterror);
		//printk(KERN_INFO "XPi Gamecon CRC Error: %4.4lu %4.4lu %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x %2.2x",
		//	lastgood,lasterror, 
		//	data[0],data[1],data[2],data[3],
		//	data[4],data[5],data[6],data[7],
		//	data[8],data[9],data[10],data[11],
		//	data[12],data[13],data[14],data[15]);
		lastgood=0;
	}

	gpio_func(gc_gpio_data,1);	//input

	mod_timer(&gc->timer, jiffies + GC_REFRESH_TIME);
}

static int __init gc_setup_pad(struct gc *gc)
{
	struct input_dev *input_dev;
	int i;
	int err;

	gc->dev = input_dev = input_allocate_device();
	if (!input_dev) {
		printk(KERN_INFO "Not enough memory for input device\n");
		return -ENOMEM;
	}

	input_dev->name = "PiBoy DMG Controller";
	input_dev->phys = "input0";
	input_dev->id.bustype = BUS_PARPORT;
	input_dev->id.vendor = 0x0001;
	input_dev->id.product = 1;
	input_dev->id.version = 0x0100;

	input_set_drvdata(input_dev, gc);

	input_dev->evbit[0] = BIT_MASK(EV_KEY) | BIT_MASK(EV_ABS);

	for (i = 0; i < gc_btn_size; i++){
		__set_bit(gc_btn[i], input_dev->keybit);
	}

	input_set_abs_params(input_dev, ABS_X, 0, 255, 0, 0);
	input_set_abs_params(input_dev, ABS_Y, 0, 255, 0, 0);

	err = input_register_device(input_dev);
	if (err)
		goto err_free_dev;

	/* set data pin to input */
	gpio_func(gc_gpio_clk,0);	//output
	gpio_func(gc_gpio_data,1);	//input

	printk(KERN_INFO "GPIO%i and GPIO%i configured for Piboy DMG controller pins\n",gc_gpio_clk,gc_gpio_data);
	printk(KERN_INFO "PiBoy DMG Controls module loaded");

	return 0;

err_free_dev:
	input_free_device(gc->dev);
	gc->dev = NULL;
	return err;
}

static struct gc __init *gc_probe(void)
{
	struct gc *gc;
	int err;

	gc = kzalloc(sizeof(struct gc), GFP_KERNEL);
	if (!gc) {
		printk(KERN_INFO "Not enough memory\n");
		err = -ENOMEM;
		goto err_out;
	}

	mutex_init(&gc->mutex);

	timer_setup(&gc->timer, gc_timer, 0);

	err = gc_setup_pad(gc);
	if (err) goto err_unreg_devs;
	return gc;

 err_unreg_devs:
	if (gc->dev) input_unregister_device(gc->dev);
	kfree(gc);
 err_out:
	return ERR_PTR(err);
}

static void gc_remove(struct gc *gc)
{
	if (gc->dev)
		input_unregister_device(gc->dev);
	kfree(gc);
}

/**
 * gc_bcm_peri_base_probe - Find the peripherals address base for
 * the running Raspberry Pi model. It needs a kernel with runtime Device-Tree
 * overlay support.
 *
 * Based on the userland 'bcm_host' library code from
 * https://github.com/raspberrypi/userland/blob/2549c149d8aa7f18ff201a1c0429cb26f9e2535a/host_applications/linux/libs/bcm_host/bcm_host.c#L150
 *
 * Reference: https://www.raspberrypi.org/documentation/hardware/raspberrypi/peripheral_addresses.md
 *
 * If any error occurs reading the device tree nodes/properties, then return 0.
 */
static u32 __init gc_bcm_peri_base_probe(void) {

	char *path = "/soc";
	struct device_node *dt_node;
	u32 base_address = 1;

	dt_node = of_find_node_by_path(path);
	if (!dt_node) {
		printk(KERN_INFO "failed to find device-tree node: %s\n", path);
		return 0;
	}

	if (of_property_read_u32_index(dt_node, "ranges", 1, &base_address)) {
		printk(KERN_INFO "failed to read range index 1\n");
		return 0;
	}

	if (base_address == 0) {
		if (of_property_read_u32_index(dt_node, "ranges", 2, &base_address)) {
			printk(KERN_INFO "failed to read range index 2\n");
			return 0;
		}
	}

	return base_address == 1 ? 0x02000000 : base_address;
}

void osd(void)
{
	char *envp[] = {
	    "SHELL=/bin/bash",
	    "HOME=/",
	    "USER=root",
	    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
	    "DISPLAY=:0",
	    "PWD=/",
	    NULL
	};

	char *argv[] = { "/home/pi/osd/osd", NULL };
	int result = call_usermodehelper(argv[0], argv, envp, UMH_WAIT_EXEC);
	printk(KERN_INFO "Executing OSD: %i",result);
}


/* --- LED class device: lets the kernel's own triggers (timer, pattern, and the
 *     ones power_supply_register() creates) animate the LED, instead of a
 *     userspace loop writing brightness on a timer. Red is inert on this
 *     hardware, so only green is exposed. --- */
static struct led_classdev xpi_green_led;

static void xpi_green_set(struct led_classdev *cdev, enum led_brightness b)
{
	values.green_val = b;		/* pushed to the XPi by the existing timer */
}

/* --- hwmon: expose the fan as a standard pwm1 so `sensors`, fancontrol and
 *     anything else generic can drive it, rather than a private sysfs int. --- */
static struct device *xpi_hwmon;

static ssize_t pwm1_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", values.fan_val);
}

static ssize_t pwm1_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	unsigned long v;

	if (kstrtoul(buf, 10, &v))
		return -EINVAL;
	values.fan_val = min_t(unsigned long, v, 255);
	xpi_fan_last_set = jiffies;
	return count;
}
static DEVICE_ATTR_RW(pwm1);

static ssize_t pwm1_enable_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", xpi_fan_enable);
}

static ssize_t pwm1_enable_store(struct device *dev, struct device_attribute *attr,
				 const char *buf, size_t count)
{
	unsigned long v;

	if (kstrtoul(buf, 10, &v) || v > 2)
		return -EINVAL;
	xpi_fan_enable = v;
	xpi_fan_last_set = jiffies;
	return count;
}
static DEVICE_ATTR_RW(pwm1_enable);

static struct attribute *xpi_hwmon_attrs[] = {
	&dev_attr_pwm1.attr,
	&dev_attr_pwm1_enable.attr,
	NULL
};
ATTRIBUTE_GROUPS(xpi_hwmon);

/* --- standard power_supply device, so EmulationStation / RetroArch / anything
 *     else sees the XPi battery through the normal kernel interface --- */

static enum power_supply_property xpi_psy_props[] = {
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_SCOPE,
};

static int xpi_psy_get_prop(struct power_supply *psy,
			    enum power_supply_property psp,
			    union power_supply_propval *val)
{
	bool valid = READ_ONCE(xpi_psy_valid);
	int pct, cur;

	/* Pairs with the smp_wmb() in gc_timer(): if we observed the flag set,
	 * we must also observe the values stored before it. */
	if (valid)
		smp_rmb();

	pct = percent_val;
	cur = cur_val;

	/* Until the first valid packet arrives, percent_val is 0. Advertising a 0%
	 * battery even briefly can trigger an emergency shutdown on any system
	 * running upower/logind battery policy, so report the pack absent with a
	 * safe capacity until there is real data. (voltage/current read 0 anyway.) */
	switch (psp) {
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = valid;
		break;
	case POWER_SUPPLY_PROP_STATUS:
		/* Derive from VBus first. Inferring direction from the sign of the
		 * current alone made a full pack on a charger oscillate between Full
		 * and Discharging on a single LSB of dither - the hardware was
		 * reporting VBus the whole time and nothing looked at it. */
		if (!valid)
			val->intval = POWER_SUPPLY_STATUS_UNKNOWN;
		else if (!(stat_val & XPI_STAT_VBUS))
			val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
		else if (pct >= 100)
			val->intval = POWER_SUPPLY_STATUS_FULL;
		else if (cur < -XPI_CUR_DEADBAND)
			/* Plugged in and still net-draining: the load exceeds what the
			 * supply delivers. Genuinely discharging, and worth surfacing. */
			val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
		else
			val->intval = POWER_SUPPLY_STATUS_CHARGING;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		val->intval = valid ? clamp(pct, 0, 100) : 100;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		val->intval = batt_val * 1000;	/* mV -> uV */
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		val->intval = cur * 1000;	/* mA -> uA */
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		break;
	case POWER_SUPPLY_PROP_SCOPE:
		val->intval = POWER_SUPPLY_SCOPE_SYSTEM;
		break;
	default:
		return -EINVAL;
	}
	return 0;
}

static const struct power_supply_desc xpi_psy_desc = {
	.name		= "xpi-battery",
	.type		= POWER_SUPPLY_TYPE_BATTERY,
	.properties	= xpi_psy_props,
	.num_properties	= ARRAY_SIZE(xpi_psy_props),
	.get_property	= xpi_psy_get_prop,
};

/* Nothing on the system could tell wall power from battery, because only a
 * battery was registered. upower, logind and anything with a power policy look
 * for a supply of type MAINS/USB carrying an "online" property - so provide one. */
static enum power_supply_property xpi_usb_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
};

static int xpi_usb_get_prop(struct power_supply *psy,
			    enum power_supply_property psp,
			    union power_supply_propval *val)
{
	bool valid = READ_ONCE(xpi_psy_valid);

	if (psp != POWER_SUPPLY_PROP_ONLINE)
		return -EINVAL;

	/* Pairs with the smp_wmb() in gc_timer(), exactly as xpi_psy_get_prop()
	 * does. && sequences evaluation, not memory: without this the stat_val
	 * load may be observed ahead of the flag load on a weakly-ordered arm64,
	 * so a read racing the first good packet can see valid == true with a
	 * stale stat_val == 0 and report offline while on wall power. */
	if (valid)
		smp_rmb();

	/* Before the first good packet stat_val is 0, which would read as
	 * unplugged. Report offline rather than guess, matching the way capacity
	 * is faked to a safe value over the same window. */
	val->intval = valid && (stat_val & XPI_STAT_VBUS) ? 1 : 0;
	return 0;
}

static const struct power_supply_desc xpi_usb_desc = {
	.name		= "xpi-usb",
	.type		= POWER_SUPPLY_TYPE_USB,
	.properties	= xpi_usb_props,
	.num_properties	= ARRAY_SIZE(xpi_usb_props),
	.get_property	= xpi_usb_get_prop,
};

/* Read-modify-write, because the two bits have different owners. */
static void xpi_flag_set(int mask, bool on)
{
	if (on)
		values.flags_val |= mask;
	else
		values.flags_val &= ~mask;
}

static struct backlight_device *xpi_bl;

static int xpi_bl_update(struct backlight_device *bd)
{
	bool on = bd->props.power == BACKLIGHT_POWER_ON && bd->props.brightness > 0;

	xpi_flag_set(XPI_FLAG_PANEL, on);
	return 0;
}

static int xpi_bl_get(struct backlight_device *bd)
{
	return values.flags_val & XPI_FLAG_PANEL ? 1 : 0;
}

static const struct backlight_ops xpi_bl_ops = {
	.update_status  = xpi_bl_update,
	.get_brightness = xpi_bl_get,
};

/* The board needs telling BEFORE the rail drops, and setting the value is not
 * telling it. The outbound protocol round-robins four values one per packet, so
 * the flags byte only goes out when its turn comes round - about every 33ms at
 * 120Hz. Anything that merely assigns and returns is racing the shutdown, and
 * loses intermittently: that is exactly how the userspace version of this
 * failed, writing 129 at final.target and then having the rail drop before the
 * packet was clocked out. Observed: the unit logged that it ran, and the unit
 * still did not come back.
 *
 * So wait for proof of transmission. `index` advances once per outbound packet,
 * so eight of them is two full round-robins - the flags byte has demonstrably
 * gone out at least twice. Bounded, because a board that has stopped answering
 * must not hang the reboot.
 *
 * SYS_RESTART only: on SYS_POWER_OFF the rail SHOULD drop, which is the entire
 * point of the power switch. */
static int xpi_reboot_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	uint8_t start;
	int i;

	if (action != SYS_RESTART)
		return NOTIFY_DONE;

	xpi_flag_set(XPI_FLAG_REBOOT, true);
	xpi_flag_set(XPI_FLAG_PANEL, true);   /* never hand back a dark panel */

	start = READ_ONCE(index);
	for (i = 0; i < 250; i++) {
		if ((uint8_t)(READ_ONCE(index) - start) >= 8)
			break;
		mdelay(1);
	}

	if (i == 250)
		printk(KERN_INFO "xpi_gamecon: reboot flag may not have reached the "
		                 "board; it may not resume\n");
	return NOTIFY_DONE;
}

static struct notifier_block xpi_reboot_nb = {
	.notifier_call = xpi_reboot_notify,
};

static bool xpi_reboot_ok;

static int __init gc_init(void)
{
	/* BCM board peripherals address base */
	static u32 gc_bcm2708_peri_base;

	values.flags_val = 1;
	values.fan_val = 10;
	values.red_val = 100;
	values.green_val = 100;
	/* Seed the fan watchdog stamp as already-expired. Left at 0 it is compared
	 * against jiffies, which starts at INITIAL_JIFFIES (a large value near
	 * wraparound), so time_after() stays false for ~300s on 32-bit - exactly the
	 * boot window the floor exists to cover. */
	xpi_fan_last_set = jiffies - XPI_FAN_TIMEOUT;

	osd();

	/* Get the BCM2708 peripheral address */
	gc_bcm2708_peri_base = gc_bcm_peri_base_probe();
	if (!gc_bcm2708_peri_base) {
		printk(KERN_INFO "failed to find peripherals address base via device-tree\n");
		return -ENODEV;
	}

	printk(KERN_INFO "peripherals address base at 0x%08x\n", gc_bcm2708_peri_base);

	/* Set up gpio pointer for direct register access */
   	if ((gpio = ioremap((gc_bcm2708_peri_base + 0x200000), 0xB0)) == NULL) {
   	   	printk(KERN_INFO "io remap failed\n");
   	   	return -EBUSY;
   	}

	gc_base = gc_probe();
	if (IS_ERR(gc_base))
		return -ENODEV;

	/*Creating a directory in /sys/kernel/ */
	kobj_ref = kobject_create_and_add("xpi_gamecon",kernel_kobj);

	if(sysfs_create_file(kobj_ref,&version.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&flags.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&red.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&green.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&fan.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&cur.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&batt.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&per.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&stat.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}
	if(sysfs_create_file(kobj_ref,&vol.attr)){
		printk(KERN_INFO "Cannot create sysfs file......\n");
		goto r_sysfs;
	}

	xpi_vol_dev = input_allocate_device();
	if (xpi_vol_dev) {
		xpi_vol_dev->name = "PiBoy DMG Volume Wheel";
		xpi_vol_dev->phys = "xpi/input1";
		xpi_vol_dev->id.bustype = BUS_HOST;
		__set_bit(EV_ABS, xpi_vol_dev->evbit);
				/* input_defuzz_abs_event() hard-drops only |delta| < fuzz/2 and averages
		 * the rest, so this damps the ADC dither rather than eliminating it.
		 * Consumers should still treat near-zero as mute. */
		input_set_abs_params(xpi_vol_dev, ABS_VOLUME, 0, 100, 5, 0);
		if (input_register_device(xpi_vol_dev)) {
			input_free_device(xpi_vol_dev);
			xpi_vol_dev = NULL;
			printk(KERN_INFO "xpi_gamecon: volume input device failed\n");
		}
	}

	xpi_pwr_dev = input_allocate_device();
	if (xpi_pwr_dev) {
		xpi_pwr_dev->name = "PiBoy DMG Power Switch";
		xpi_pwr_dev->phys = "xpi/input2";
		xpi_pwr_dev->id.bustype = BUS_HOST;
		/* KEY_POWER only: a device also carrying joystick axes would be
		 * enumerated by SDL and show up as a phantom button in emulators. */
		__set_bit(EV_KEY, xpi_pwr_dev->evbit);
		__set_bit(KEY_POWER, xpi_pwr_dev->keybit);
		if (input_register_device(xpi_pwr_dev)) {
			input_free_device(xpi_pwr_dev);
			xpi_pwr_dev = NULL;
			printk(KERN_INFO "xpi_gamecon: power-switch input device failed\n");
		}
	}
	timer_setup(&xpi_pwr_timer, xpi_pwr_backstop, 0);

	xpi_green_led.name = "piboy:green:status";
	xpi_green_led.max_brightness = 255;
	xpi_green_led.brightness = values.green_val;
	xpi_green_led.brightness_set = xpi_green_set;
	{
		struct backlight_properties props = {
			.type           = BACKLIGHT_RAW,
			.max_brightness = 1,          /* the panel is on or off, nothing between */
			.brightness     = 1,
			.power          = BACKLIGHT_POWER_ON,
		};

		xpi_bl = backlight_device_register("piboy", NULL, NULL, &xpi_bl_ops, &props);
		if (IS_ERR(xpi_bl)) {
			printk(KERN_INFO "xpi_gamecon: backlight_device_register failed (%ld)\n",
			       PTR_ERR(xpi_bl));
			xpi_bl = NULL;
		}
	}

	xpi_reboot_ok = register_reboot_notifier(&xpi_reboot_nb) == 0;
	if (!xpi_reboot_ok)
		printk(KERN_INFO "xpi_gamecon: register_reboot_notifier failed; "
		                 "soft reboot will not resume\n");

	if (led_classdev_register(NULL, &xpi_green_led))
		printk(KERN_INFO "xpi_gamecon: green LED classdev failed\n");
	else
		xpi_led_ok = true;

	xpi_hwmon = hwmon_device_register_with_groups(NULL, "piboy", NULL,
						      xpi_hwmon_groups);
	if (IS_ERR(xpi_hwmon)) {
		printk(KERN_INFO "xpi_gamecon: hwmon register failed\n");
		xpi_hwmon = NULL;
	}

	xpi_psy = power_supply_register(NULL, &xpi_psy_desc, NULL);
	if (IS_ERR(xpi_psy)) {
		printk(KERN_INFO "xpi_gamecon: power_supply_register failed (%ld)\n", PTR_ERR(xpi_psy));
		xpi_psy = NULL;
	} else {
		printk(KERN_INFO "xpi_gamecon: registered /sys/class/power_supply/xpi-battery\n");
	}

	xpi_usb = power_supply_register(NULL, &xpi_usb_desc, NULL);
	if (IS_ERR(xpi_usb)) {
		printk(KERN_INFO "xpi_gamecon: xpi-usb register failed (%ld)\n", PTR_ERR(xpi_usb));
		xpi_usb = NULL;
	} else {
		printk(KERN_INFO "xpi_gamecon: registered /sys/class/power_supply/xpi-usb\n");
	}

	printk(KERN_INFO "Device Driver Insert...Done!!!\n");

	mod_timer(&gc_base->timer, jiffies + GC_REFRESH_TIME);

	return 0;

r_sysfs:
	kobject_put(kobj_ref);

	if (gc_base)
		gc_remove(gc_base);

	iounmap(gpio);

        return -1;
}

static void __exit gc_exit(void)
{
	if (gc_base){
		GC_DEL_TIMER_SYNC(&gc_base->timer);
		gc_remove(gc_base);
	}

	if (xpi_reboot_ok)
		unregister_reboot_notifier(&xpi_reboot_nb);

	if (xpi_bl)
		backlight_device_unregister(xpi_bl);

	if (xpi_usb)
		power_supply_unregister(xpi_usb);

	if (xpi_psy)
		power_supply_unregister(xpi_psy);

	if (xpi_hwmon)
		hwmon_device_unregister(xpi_hwmon);

	if (xpi_led_ok)
		led_classdev_unregister(&xpi_green_led);

	GC_DEL_TIMER_SYNC(&xpi_pwr_timer);

	if (xpi_pwr_dev)
		input_unregister_device(xpi_pwr_dev);

	if (xpi_vol_dev)
		input_unregister_device(xpi_vol_dev);

	iounmap(gpio);

	kobject_put(kobj_ref);

	printk(KERN_INFO "PiBoy DMG Controls module unloaded");
}

module_init(gc_init);
module_exit(gc_exit);
