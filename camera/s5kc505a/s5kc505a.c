// SPDX-License-Identifier: GPL-2.0-only
/*
 * V4L2 driver for the Samsung S5KC505A 5MP raw Bayer sensor, as used as the
 * front camera of the Lenovo ThinkSmart View (CD-18781Y).
 *
 * Register sequences, power sequencing and timing data were recovered from
 * the vendor mm-camera sensor library (libmmcamera_s5kc505a.so).
 *
 * Status: experimental bring-up driver.
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/units.h>

#include <media/v4l2-cci.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-mediabus.h>

#include "s5kc505a_regs.h"

#define S5KC505A_REG_CHIP_ID		CCI_REG16(0x0000)
#define S5KC505A_CHIP_ID		0x5034

#define S5KC505A_REG_MODE_SELECT	CCI_REG8(0x0100)
#define S5KC505A_MODE_STANDBY		0x00
#define S5KC505A_MODE_STREAMING		0x01

#define S5KC505A_REG_ORIENTATION	CCI_REG8(0x0101)
#define S5KC505A_REG_GROUP_HOLD		CCI_REG8(0x0104)

#define S5KC505A_REG_EXPOSURE		CCI_REG16(0x0202)
#define S5KC505A_EXPOSURE_MIN		4
#define S5KC505A_EXPOSURE_STEP		1
#define S5KC505A_EXPOSURE_MARGIN	8

#define S5KC505A_REG_ANALOG_GAIN	CCI_REG16(0x0204)
#define S5KC505A_AGAIN_MIN		0x20	/* 1.0x */
#define S5KC505A_AGAIN_MAX		0x1ff	/* ~16x, vendor limit 15.97x */
#define S5KC505A_AGAIN_DEFAULT		0x20

#define S5KC505A_REG_FRAME_LENGTH	CCI_REG16(0x0340)
#define S5KC505A_FLL_MAX		0xfffe

#define S5KC505A_REG_TEST_PATTERN	CCI_REG16(0x0600)

#define S5KC505A_NATIVE_WIDTH		2608
#define S5KC505A_NATIVE_HEIGHT		1960

#define S5KC505A_XCLK_FREQ		(24 * HZ_PER_MHZ)
#define S5KC505A_LANES			2

/* 960 Mbps/lane, and 1032 Mbps/lane for the 640x490 mode */
static const s64 s5kc505a_link_freqs[] = {
	480000000,
	516000000,
};

/*
 * Colour filter order of the unflipped readout, measured on the device:
 * GRBG. Both horizontal and vertical flips shift the order.
 * 0 = RGGB, 1 = GRBG, 2 = GBRG, 3 = BGGR
 */
static int bayer_order = 1;
module_param(bayer_order, int, 0444);
MODULE_PARM_DESC(bayer_order, "CFA order without flips: 0=RGGB 1=GRBG 2=GBRG 3=BGGR (default 1)");

/*
 * The module is mounted upside down in the ThinkSmart View. Start with both
 * flips enabled so plain V4L2 users get an upright image; libcamera sets the
 * flips itself from the "rotation" DT property.
 */
static bool default_flip = true;
module_param(default_flip, bool, 0444);
MODULE_PARM_DESC(default_flip, "Enable H+V flip by default (default Y)");

static const u32 s5kc505a_mbus_codes[4] = {
	MEDIA_BUS_FMT_SRGGB10_1X10,
	MEDIA_BUS_FMT_SGRBG10_1X10,
	MEDIA_BUS_FMT_SGBRG10_1X10,
	MEDIA_BUS_FMT_SBGGR10_1X10,
};

static const char * const s5kc505a_supply_names[] = {
	"vio",		/* 1.8V I/O, PM8953 L6 */
	"avdd",		/* 2.8V analog, PM8953 L17 + GPIO switch */
	"dvdd",		/* 1.2V core, PM8953 L2 + GPIO switch */
};

static const char * const s5kc505a_test_pattern_menu[] = {
	"Disabled",
	"Solid Colour",
	"Colour Bars",
	"Fade To Grey Colour Bars",
	"PN9",
};

struct s5kc505a_mode {
	u32 width;
	u32 height;
	struct v4l2_rect crop;
	u32 llp;		/* line length in pixel clocks */
	u32 fll_min;		/* vendor frame length = maximum frame rate */
	u32 fll;		/* default frame length, gives 30 fps */
	u64 pixel_rate;
	unsigned int link_freq_index;
	const struct cci_reg_sequence *regs;
	unsigned int num_regs;
};

#define MODE_REGS(r) .regs = r, .num_regs = ARRAY_SIZE(r)

static const struct s5kc505a_mode s5kc505a_modes[] = {
	{
		.width = 2608, .height = 1960,
		.crop = { 0, 0, 2608, 1960 },
		.llp = 3112, .fll_min = 2030, .fll = 2030,
		.pixel_rate = 190000000, .link_freq_index = 0,
		MODE_REGS(s5kc505a_mode_2608x1960_regs),
	}, {
		.width = 1936, .height = 1096,
		.crop = { 336, 432, 1936, 1096 },
		.llp = 2760, .fll_min = 1166, .fll = 2415,
		.pixel_rate = 200000000, .link_freq_index = 0,
		MODE_REGS(s5kc505a_mode_1936x1096_regs),
	}, {
		.width = 1304, .height = 980,
		.crop = { 0, 0, 2608, 1960 },
		.llp = 3112, .fll_min = 2030, .fll = 2030,
		.pixel_rate = 190000000, .link_freq_index = 0,
		MODE_REGS(s5kc505a_mode_1304x980_regs),
	}, {
		.width = 1296, .height = 736,
		.crop = { 8, 244, 2592, 1472 },
		.llp = 2760, .fll_min = 806, .fll = 2284,
		.pixel_rate = 189087600, .link_freq_index = 0,
		MODE_REGS(s5kc505a_mode_1296x736_regs),
	}, {
		.width = 640, .height = 490,
		.crop = { 24, 0, 2560, 1960 },
		.llp = 2800, .fll_min = 565, .fll = 2260,
		.pixel_rate = 189840000, .link_freq_index = 1,
		MODE_REGS(s5kc505a_mode_640x490_regs),
	},
};

struct s5kc505a {
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct regmap *regmap;
	struct clk *xclk;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *pwdn_gpio;
	struct regulator_bulk_data supplies[ARRAY_SIZE(s5kc505a_supply_names)];

	struct v4l2_ctrl_handler ctrls;
	struct v4l2_ctrl *link_freq;
	struct v4l2_ctrl *pixel_rate;
	struct v4l2_ctrl *exposure;
	struct v4l2_ctrl *vblank;
	struct v4l2_ctrl *hblank;
	struct v4l2_ctrl *hflip;
	struct v4l2_ctrl *vflip;

	const struct s5kc505a_mode *mode;
};

static inline struct s5kc505a *to_s5kc505a(struct v4l2_subdev *sd)
{
	return container_of(sd, struct s5kc505a, sd);
}

static u32 s5kc505a_get_format_code(struct s5kc505a *s)
{
	unsigned int idx = clamp(bayer_order, 0, 3);

	/* bit0 of the index swaps columns, bit1 swaps rows */
	if (s->hflip && s->hflip->val)
		idx ^= 1;
	if (s->vflip && s->vflip->val)
		idx ^= 2;

	return s5kc505a_mbus_codes[idx];
}

/* -------------------------------------------------------------------------- */

static int s5kc505a_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct s5kc505a *s = container_of(ctrl->handler, struct s5kc505a, ctrls);
	struct i2c_client *client = v4l2_get_subdevdata(&s->sd);
	int ret = 0;

	if (ctrl->id == V4L2_CID_VBLANK) {
		int exp_max = s->mode->height + ctrl->val - S5KC505A_EXPOSURE_MARGIN;

		ret = __v4l2_ctrl_modify_range(s->exposure, s->exposure->minimum,
					       exp_max, s->exposure->step,
					       min(s->exposure->default_value, exp_max));
		if (ret)
			return ret;
	}

	if (pm_runtime_get_if_in_use(&client->dev) == 0)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		cci_write(s->regmap, S5KC505A_REG_EXPOSURE, ctrl->val, &ret);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		cci_write(s->regmap, S5KC505A_REG_ANALOG_GAIN, ctrl->val, &ret);
		break;
	case V4L2_CID_VBLANK:
		cci_write(s->regmap, S5KC505A_REG_FRAME_LENGTH,
			  s->mode->height + ctrl->val, &ret);
		break;
	case V4L2_CID_HFLIP:
	case V4L2_CID_VFLIP:
		cci_write(s->regmap, S5KC505A_REG_ORIENTATION,
			  s->hflip->val | (s->vflip->val << 1), &ret);
		break;
	case V4L2_CID_TEST_PATTERN:
		cci_write(s->regmap, S5KC505A_REG_TEST_PATTERN, ctrl->val, &ret);
		break;
	default:
		ret = -EINVAL;
		break;
	}

	pm_runtime_put(&client->dev);
	return ret;
}

static const struct v4l2_ctrl_ops s5kc505a_ctrl_ops = {
	.s_ctrl = s5kc505a_set_ctrl,
};

static void s5kc505a_update_mode_ctrls(struct s5kc505a *s)
{
	const struct s5kc505a_mode *m = s->mode;
	int vblank_def = m->fll - m->height;
	int vblank_min = m->fll_min - m->height;
	int hblank = m->llp - m->width;
	int exp_max = m->fll - S5KC505A_EXPOSURE_MARGIN;

	__v4l2_ctrl_s_ctrl(s->link_freq, m->link_freq_index);
	__v4l2_ctrl_s_ctrl_int64(s->pixel_rate, m->pixel_rate);

	__v4l2_ctrl_modify_range(s->hblank, hblank, hblank, 1, hblank);
	__v4l2_ctrl_modify_range(s->vblank, vblank_min,
				 S5KC505A_FLL_MAX - m->height, 1, vblank_def);
	__v4l2_ctrl_s_ctrl(s->vblank, vblank_def);
	__v4l2_ctrl_modify_range(s->exposure, S5KC505A_EXPOSURE_MIN, exp_max,
				 S5KC505A_EXPOSURE_STEP, exp_max);
}

static int s5kc505a_init_controls(struct s5kc505a *s)
{
	struct i2c_client *client = v4l2_get_subdevdata(&s->sd);
	const struct s5kc505a_mode *m = s->mode;
	struct v4l2_ctrl_handler *h = &s->ctrls;
	struct v4l2_fwnode_device_properties props;
	int ret;

	v4l2_ctrl_handler_init(h, 12);

	s->link_freq = v4l2_ctrl_new_int_menu(h, &s5kc505a_ctrl_ops,
					      V4L2_CID_LINK_FREQ,
					      ARRAY_SIZE(s5kc505a_link_freqs) - 1,
					      m->link_freq_index,
					      s5kc505a_link_freqs);
	if (s->link_freq)
		s->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	s->pixel_rate = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops,
					  V4L2_CID_PIXEL_RATE,
					  1, 400000000, 1, m->pixel_rate);
	if (s->pixel_rate)
		s->pixel_rate->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	s->hblank = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_HBLANK,
				      m->llp - m->width, m->llp - m->width, 1,
				      m->llp - m->width);
	if (s->hblank)
		s->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	s->vblank = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_VBLANK,
				      m->fll_min - m->height,
				      S5KC505A_FLL_MAX - m->height, 1,
				      m->fll - m->height);

	s->exposure = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_EXPOSURE,
					S5KC505A_EXPOSURE_MIN,
					m->fll - S5KC505A_EXPOSURE_MARGIN,
					S5KC505A_EXPOSURE_STEP,
					m->fll - S5KC505A_EXPOSURE_MARGIN);

	v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_ANALOGUE_GAIN,
			  S5KC505A_AGAIN_MIN, S5KC505A_AGAIN_MAX, 1,
			  S5KC505A_AGAIN_DEFAULT);

	s->hflip = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_HFLIP, 0, 1, 1, default_flip);
	if (s->hflip)
		s->hflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;
	s->vflip = v4l2_ctrl_new_std(h, &s5kc505a_ctrl_ops, V4L2_CID_VFLIP, 0, 1, 1, default_flip);
	if (s->vflip)
		s->vflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;

	v4l2_ctrl_new_std_menu_items(h, &s5kc505a_ctrl_ops, V4L2_CID_TEST_PATTERN,
				     ARRAY_SIZE(s5kc505a_test_pattern_menu) - 1,
				     0, 0, s5kc505a_test_pattern_menu);

	if (h->error) {
		ret = h->error;
		dev_err(&client->dev, "control init failed: %d\n", ret);
		goto err;
	}

	ret = v4l2_fwnode_device_parse(&client->dev, &props);
	if (ret)
		goto err;

	ret = v4l2_ctrl_new_fwnode_properties(h, &s5kc505a_ctrl_ops, &props);
	if (ret)
		goto err;

	s->sd.ctrl_handler = h;
	return 0;

err:
	v4l2_ctrl_handler_free(h);
	return ret;
}

/* -------------------------------------------------------------------------- */

static int s5kc505a_write_init(struct s5kc505a *s)
{
	int ret;

	/* The vendor sequence waits 10 ms after the first (OTP page) write. */
	ret = cci_multi_reg_write(s->regmap, s5kc505a_init_regs, 1, NULL);
	if (ret)
		return ret;
	usleep_range(10000, 11000);

	return cci_multi_reg_write(s->regmap, s5kc505a_init_regs + 1,
				   ARRAY_SIZE(s5kc505a_init_regs) - 1, NULL);
}

static int s5kc505a_enable_streams(struct v4l2_subdev *sd,
				   struct v4l2_subdev_state *state, u32 pad,
				   u64 streams_mask)
{
	struct s5kc505a *s = to_s5kc505a(sd);
	struct i2c_client *client = v4l2_get_subdevdata(sd);
	int ret;

	ret = pm_runtime_resume_and_get(&client->dev);
	if (ret < 0)
		return ret;

	ret = s5kc505a_write_init(s);
	if (ret) {
		dev_err(&client->dev, "init sequence failed: %d\n", ret);
		goto err;
	}

	ret = cci_multi_reg_write(s->regmap, s->mode->regs, s->mode->num_regs, NULL);
	if (ret) {
		dev_err(&client->dev, "mode sequence failed: %d\n", ret);
		goto err;
	}

	ret = __v4l2_ctrl_handler_setup(sd->ctrl_handler);
	if (ret)
		goto err;

	ret = cci_write(s->regmap, S5KC505A_REG_MODE_SELECT,
			S5KC505A_MODE_STREAMING, NULL);
	if (ret)
		goto err;

	__v4l2_ctrl_grab(s->hflip, true);
	__v4l2_ctrl_grab(s->vflip, true);
	return 0;

err:
	pm_runtime_put_autosuspend(&client->dev);
	return ret;
}

static int s5kc505a_disable_streams(struct v4l2_subdev *sd,
				    struct v4l2_subdev_state *state, u32 pad,
				    u64 streams_mask)
{
	struct s5kc505a *s = to_s5kc505a(sd);
	struct i2c_client *client = v4l2_get_subdevdata(sd);
	int ret;

	ret = cci_write(s->regmap, S5KC505A_REG_MODE_SELECT,
			S5KC505A_MODE_STANDBY, NULL);
	if (ret)
		dev_err(&client->dev, "stream off failed: %d\n", ret);

	__v4l2_ctrl_grab(s->hflip, false);
	__v4l2_ctrl_grab(s->vflip, false);

	pm_runtime_put_autosuspend(&client->dev);
	return ret;
}

/* -------------------------------------------------------------------------- */

static void s5kc505a_fill_fmt(struct s5kc505a *s, const struct s5kc505a_mode *m,
			      struct v4l2_mbus_framefmt *fmt)
{
	fmt->width = m->width;
	fmt->height = m->height;
	fmt->code = s5kc505a_get_format_code(s);
	fmt->field = V4L2_FIELD_NONE;
	fmt->colorspace = V4L2_COLORSPACE_RAW;
	fmt->ycbcr_enc = V4L2_YCBCR_ENC_601;
	fmt->quantization = V4L2_QUANTIZATION_FULL_RANGE;
	fmt->xfer_func = V4L2_XFER_FUNC_NONE;
}

static int s5kc505a_enum_mbus_code(struct v4l2_subdev *sd,
				   struct v4l2_subdev_state *state,
				   struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index > 0)
		return -EINVAL;

	code->code = s5kc505a_get_format_code(to_s5kc505a(sd));
	return 0;
}

static int s5kc505a_enum_frame_size(struct v4l2_subdev *sd,
				    struct v4l2_subdev_state *state,
				    struct v4l2_subdev_frame_size_enum *fse)
{
	struct s5kc505a *s = to_s5kc505a(sd);

	if (fse->index >= ARRAY_SIZE(s5kc505a_modes))
		return -EINVAL;
	if (fse->code != s5kc505a_get_format_code(s))
		return -EINVAL;

	fse->min_width = fse->max_width = s5kc505a_modes[fse->index].width;
	fse->min_height = fse->max_height = s5kc505a_modes[fse->index].height;
	return 0;
}

static int s5kc505a_set_fmt(struct v4l2_subdev *sd,
			    struct v4l2_subdev_state *state,
			    struct v4l2_subdev_format *fmt)
{
	struct s5kc505a *s = to_s5kc505a(sd);
	const struct s5kc505a_mode *m;

	if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE && v4l2_subdev_is_streaming(sd))
		return -EBUSY;

	m = v4l2_find_nearest_size(s5kc505a_modes, ARRAY_SIZE(s5kc505a_modes),
				   width, height,
				   fmt->format.width, fmt->format.height);

	s5kc505a_fill_fmt(s, m, &fmt->format);
	*v4l2_subdev_state_get_format(state, 0) = fmt->format;
	*v4l2_subdev_state_get_crop(state, 0) = m->crop;

	if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE) {
		s->mode = m;
		s5kc505a_update_mode_ctrls(s);
	}

	return 0;
}

static int s5kc505a_get_selection(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_selection *sel)
{
	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
		sel->r = *v4l2_subdev_state_get_crop(state, 0);
		return 0;
	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = S5KC505A_NATIVE_WIDTH;
		sel->r.height = S5KC505A_NATIVE_HEIGHT;
		return 0;
	}

	return -EINVAL;
}

static int s5kc505a_init_state(struct v4l2_subdev *sd,
			       struct v4l2_subdev_state *state)
{
	struct v4l2_subdev_format fmt = {
		.which = V4L2_SUBDEV_FORMAT_TRY,
		.format = {
			.width = s5kc505a_modes[0].width,
			.height = s5kc505a_modes[0].height,
		},
	};

	return s5kc505a_set_fmt(sd, state, &fmt);
}

static const struct v4l2_subdev_video_ops s5kc505a_video_ops = {
	.s_stream = v4l2_subdev_s_stream_helper,
};

static const struct v4l2_subdev_pad_ops s5kc505a_pad_ops = {
	.enum_mbus_code = s5kc505a_enum_mbus_code,
	.enum_frame_size = s5kc505a_enum_frame_size,
	.get_fmt = v4l2_subdev_get_fmt,
	.set_fmt = s5kc505a_set_fmt,
	.get_selection = s5kc505a_get_selection,
	.enable_streams = s5kc505a_enable_streams,
	.disable_streams = s5kc505a_disable_streams,
};

static const struct v4l2_subdev_ops s5kc505a_subdev_ops = {
	.video = &s5kc505a_video_ops,
	.pad = &s5kc505a_pad_ops,
};

static const struct v4l2_subdev_internal_ops s5kc505a_internal_ops = {
	.init_state = s5kc505a_init_state,
};

/* -------------------------------------------------------------------------- */

/*
 * Vendor power-up order: AVDD -> DVDD -> VIO -> MCLK (24 MHz) -> 1 ms ->
 * RESET release, 10 ms -> STANDBY release, 10 ms.
 */
static int s5kc505a_power_on(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct s5kc505a *s = to_s5kc505a(sd);
	int ret;

	gpiod_set_value_cansleep(s->reset_gpio, 1);
	gpiod_set_value_cansleep(s->pwdn_gpio, 1);

	ret = regulator_enable(s->supplies[1].consumer);	/* avdd */
	if (ret)
		return ret;
	usleep_range(1000, 1100);

	ret = regulator_enable(s->supplies[2].consumer);	/* dvdd */
	if (ret)
		goto err_avdd;
	usleep_range(1000, 1100);

	ret = regulator_enable(s->supplies[0].consumer);	/* vio */
	if (ret)
		goto err_dvdd;

	ret = clk_prepare_enable(s->xclk);
	if (ret)
		goto err_vio;
	usleep_range(1000, 1100);

	gpiod_set_value_cansleep(s->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(s->pwdn_gpio, 0);
	usleep_range(10000, 11000);

	return 0;

err_vio:
	regulator_disable(s->supplies[0].consumer);
err_dvdd:
	regulator_disable(s->supplies[2].consumer);
err_avdd:
	regulator_disable(s->supplies[1].consumer);
	return ret;
}

static int s5kc505a_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct s5kc505a *s = to_s5kc505a(sd);

	gpiod_set_value_cansleep(s->pwdn_gpio, 1);
	gpiod_set_value_cansleep(s->reset_gpio, 1);
	clk_disable_unprepare(s->xclk);
	regulator_disable(s->supplies[0].consumer);
	regulator_disable(s->supplies[2].consumer);
	regulator_disable(s->supplies[1].consumer);

	return 0;
}

static int s5kc505a_identify(struct s5kc505a *s)
{
	struct i2c_client *client = v4l2_get_subdevdata(&s->sd);
	u64 id;
	int ret;

	ret = cci_read(s->regmap, S5KC505A_REG_CHIP_ID, &id, NULL);
	if (ret) {
		dev_err(&client->dev, "failed to read chip id: %d\n", ret);
		return ret;
	}

	if (id != S5KC505A_CHIP_ID)
		dev_warn(&client->dev,
			 "unexpected chip id 0x%04llx (expected 0x%04x), continuing\n",
			 id, S5KC505A_CHIP_ID);
	else
		dev_info(&client->dev, "detected S5KC505A (id 0x%04llx)\n", id);

	return 0;
}

static int s5kc505a_check_hwcfg(struct device *dev)
{
	struct v4l2_fwnode_endpoint ep = { .bus_type = V4L2_MBUS_CSI2_DPHY };
	struct fwnode_handle *epn;
	unsigned long bitmap;
	int ret;

	epn = fwnode_graph_get_next_endpoint(dev_fwnode(dev), NULL);
	if (!epn)
		return dev_err_probe(dev, -ENXIO, "endpoint node not found\n");

	ret = v4l2_fwnode_endpoint_alloc_parse(epn, &ep);
	fwnode_handle_put(epn);
	if (ret)
		return dev_err_probe(dev, ret, "failed to parse endpoint\n");

	if (ep.bus.mipi_csi2.num_data_lanes != S5KC505A_LANES) {
		ret = dev_err_probe(dev, -EINVAL, "only 2 data lanes supported\n");
		goto out;
	}

	ret = v4l2_link_freq_to_bitmap(dev, ep.link_frequencies,
				       ep.nr_of_link_frequencies,
				       s5kc505a_link_freqs,
				       ARRAY_SIZE(s5kc505a_link_freqs), &bitmap);
	if (!ret && !(bitmap & BIT(0)))
		ret = dev_err_probe(dev, -EINVAL, "480 MHz link frequency required\n");

out:
	v4l2_fwnode_endpoint_free(&ep);
	return ret;
}

static int s5kc505a_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct s5kc505a *s;
	unsigned int i;
	int ret;

	s = devm_kzalloc(dev, sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;

	v4l2_i2c_subdev_init(&s->sd, client, &s5kc505a_subdev_ops);
	s->sd.internal_ops = &s5kc505a_internal_ops;

	ret = s5kc505a_check_hwcfg(dev);
	if (ret)
		return ret;

	s->regmap = devm_cci_regmap_init_i2c(client, 16);
	if (IS_ERR(s->regmap))
		return dev_err_probe(dev, PTR_ERR(s->regmap), "regmap init failed\n");

	s->xclk = devm_v4l2_sensor_clk_get(dev, NULL);
	if (IS_ERR(s->xclk))
		return dev_err_probe(dev, PTR_ERR(s->xclk), "failed to get xclk\n");
	if (clk_get_rate(s->xclk) != S5KC505A_XCLK_FREQ)
		return dev_err_probe(dev, -EINVAL, "xclk must be 24 MHz, got %lu\n",
				     clk_get_rate(s->xclk));

	for (i = 0; i < ARRAY_SIZE(s5kc505a_supply_names); i++)
		s->supplies[i].supply = s5kc505a_supply_names[i];
	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(s->supplies), s->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "failed to get regulators\n");

	s->reset_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(s->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(s->reset_gpio), "reset gpio\n");
	s->pwdn_gpio = devm_gpiod_get_optional(dev, "powerdown", GPIOD_OUT_HIGH);
	if (IS_ERR(s->pwdn_gpio))
		return dev_err_probe(dev, PTR_ERR(s->pwdn_gpio), "powerdown gpio\n");

	ret = s5kc505a_power_on(dev);
	if (ret)
		return dev_err_probe(dev, ret, "power on failed\n");

	ret = s5kc505a_identify(s);
	if (ret)
		goto err_power;

	s->mode = &s5kc505a_modes[0];
	ret = s5kc505a_init_controls(s);
	if (ret)
		goto err_power;

	s->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	s->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	s->pad.flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&s->sd.entity, 1, &s->pad);
	if (ret)
		goto err_ctrls;

	s->sd.state_lock = s->ctrls.lock;
	ret = v4l2_subdev_init_finalize(&s->sd);
	if (ret)
		goto err_entity;

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);

	ret = v4l2_async_register_subdev_sensor(&s->sd);
	if (ret)
		goto err_pm;

	pm_runtime_set_autosuspend_delay(dev, 1000);
	pm_runtime_use_autosuspend(dev);
	pm_runtime_idle(dev);
	return 0;

err_pm:
	pm_runtime_disable(dev);
	pm_runtime_set_suspended(dev);
	v4l2_subdev_cleanup(&s->sd);
err_entity:
	media_entity_cleanup(&s->sd.entity);
err_ctrls:
	v4l2_ctrl_handler_free(&s->ctrls);
err_power:
	s5kc505a_power_off(dev);
	return ret;
}

static void s5kc505a_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct s5kc505a *s = to_s5kc505a(sd);

	v4l2_async_unregister_subdev(sd);
	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(&s->ctrls);

	pm_runtime_disable(&client->dev);
	if (!pm_runtime_status_suspended(&client->dev))
		s5kc505a_power_off(&client->dev);
	pm_runtime_set_suspended(&client->dev);
}

static DEFINE_RUNTIME_DEV_PM_OPS(s5kc505a_pm_ops, s5kc505a_power_off,
				 s5kc505a_power_on, NULL);

static const struct of_device_id s5kc505a_of_match[] = {
	{ .compatible = "samsung,s5kc505a" },
	{ }
};
MODULE_DEVICE_TABLE(of, s5kc505a_of_match);

static struct i2c_driver s5kc505a_driver = {
	.driver = {
		.name = "s5kc505a",
		.of_match_table = s5kc505a_of_match,
		.pm = pm_ptr(&s5kc505a_pm_ops),
	},
	.probe = s5kc505a_probe,
	.remove = s5kc505a_remove,
};
module_i2c_driver(s5kc505a_driver);

MODULE_DESCRIPTION("Samsung S5KC505A camera sensor driver");
MODULE_LICENSE("GPL");
