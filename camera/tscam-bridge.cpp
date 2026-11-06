// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * tscam-bridge: feed the first libcamera camera into a v4l2loopback device
 * as a plain YUYV webcam, so any V4L2 application (browsers, video calls)
 * can use the ThinkSmart View front camera.
 *
 *   tscam-bridge [-d /dev/video10] [-s 1280x720] [-f 30]
 */

#include <algorithm>
#include <array>
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <libcamera/libcamera.h>

using namespace libcamera;

static std::atomic<bool> g_stop{ false };
static void on_signal(int) { g_stop = true; }

struct MappedPlane {
	uint8_t *data;
	size_t length;
};

class Bridge
{
public:
	Bridge(std::shared_ptr<Camera> cam, int outFd, unsigned w, unsigned h)
		: cam_(cam), outFd_(outFd), w_(w), h_(h)
	{
		yuyv_.resize(size_t(w) * h * 2);
	}

	int start(unsigned fps)
	{
		config_ = cam_->generateConfiguration({ StreamRole::VideoRecording });
		if (!config_)
			return -EINVAL;

		StreamConfiguration &sc = config_->at(0);
		sc.size = { w_, h_ };
		sc.pixelFormat = formats::BGR888; /* memory order R,G,B */
		sc.bufferCount = 4;
		config_->orientation = Orientation::Rotate0;

		if (config_->validate() == CameraConfiguration::Invalid) {
			fprintf(stderr, "configuration invalid\n");
			return -EINVAL;
		}
		fprintf(stderr, "stream: %s\n", sc.toString().c_str());
		if (sc.pixelFormat != formats::BGR888 && sc.pixelFormat != formats::RGB888 &&
		    sc.pixelFormat != formats::XBGR8888 && sc.pixelFormat != formats::XRGB8888) {
			fprintf(stderr, "unsupported output format %s\n",
				sc.pixelFormat.toString().c_str());
			return -EINVAL;
		}

		if (cam_->configure(config_.get()) < 0)
			return -EIO;

		unsigned reqW = w_, reqH = h_;
		w_ = sc.size.width;
		h_ = sc.size.height;
		stride_ = sc.stride;
		fmt_ = sc.pixelFormat;
		stream_ = sc.stream();
		yuyv_.resize(size_t(w_) * h_ * 2);

		/* The loopback was primed with the requested size already; a
		 * repeated S_FMT may be refused while an app is streaming. */
		if (setupLoopback() < 0 && (w_ != reqW || h_ != reqH))
			return -EIO;

		alloc_ = std::make_unique<FrameBufferAllocator>(cam_);
		if (alloc_->allocate(stream_) < 0)
			return -ENOMEM;

		for (const auto &buf : alloc_->buffers(stream_)) {
			const FrameBuffer::Plane &p = buf->planes()[0];
			void *m = mmap(nullptr, p.offset + p.length, PROT_READ, MAP_SHARED,
				       p.fd.get(), 0);
			if (m == MAP_FAILED)
				return -errno;
			maps_[buf.get()] = { static_cast<uint8_t *>(m) + p.offset, p.length };

			std::unique_ptr<Request> req = cam_->createRequest();
			req->addBuffer(stream_, buf.get());
			requests_.push_back(std::move(req));
		}

		ControlList ctrls(cam_->controls());
		int64_t frameUs = 1000000 / fps;
		ctrls.set(controls::FrameDurationLimits,
			  std::array<int64_t, 2>{ frameUs, frameUs });
		if (cam_->controls().count(&controls::AeEnable))
			ctrls.set(controls::AeEnable, true);
		if (cam_->controls().count(&controls::AwbEnable))
			ctrls.set(controls::AwbEnable, true);

		cam_->requestCompleted.connect(this, &Bridge::onComplete);
		running_ = true;
		if (cam_->start(&ctrls) < 0) {
			running_ = false;
			return -EIO;
		}
		for (auto &r : requests_)
			cam_->queueRequest(r.get());
		return 0;
	}

	void stop()
	{
		running_ = false;
		cam_->stop();
		cam_->requestCompleted.disconnect(this);
		for (auto &[buf, m] : maps_)
			munmap(m.data, m.length);
		requests_.clear();
		alloc_.reset();
	}

	unsigned frames() const { return frames_; }

private:
	int setupLoopback()
	{
		struct v4l2_format f = {};
		f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		f.fmt.pix.width = w_;
		f.fmt.pix.height = h_;
		f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
		f.fmt.pix.field = V4L2_FIELD_NONE;
		f.fmt.pix.bytesperline = w_ * 2;
		f.fmt.pix.sizeimage = w_ * h_ * 2;
		f.fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
		if (ioctl(outFd_, VIDIOC_S_FMT, &f) < 0) {
			perror("VIDIOC_S_FMT on loopback");
			return -1;
		}
		fprintf(stderr, "loopback: %ux%u YUYV\n", w_, h_);
		return 0;
	}

	static inline uint8_t clip(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

	void convert(const uint8_t *src)
	{
		/* Byte offsets of R, G, B within a source pixel. */
		int bpp, ro, go, bo;
		if (fmt_ == formats::BGR888) { bpp = 3; ro = 0; go = 1; bo = 2; }
		else if (fmt_ == formats::RGB888) { bpp = 3; ro = 2; go = 1; bo = 0; }
		else if (fmt_ == formats::XBGR8888) { bpp = 4; ro = 0; go = 1; bo = 2; }
		else { bpp = 4; ro = 2; go = 1; bo = 0; }

		uint8_t *dst = yuyv_.data();
		for (unsigned y = 0; y < h_; y++) {
			const uint8_t *s = src + size_t(y) * stride_;
			for (unsigned x = 0; x < w_; x += 2, s += 2 * bpp) {
				int r0 = s[ro], g0 = s[go], b0 = s[bo];
				int r1 = s[bpp + ro], g1 = s[bpp + go], b1 = s[bpp + bo];
				/* BT.601 limited range */
				int y0 = (66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8;
				int y1 = (66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8;
				int r = (r0 + r1) >> 1, g = (g0 + g1) >> 1, b = (b0 + b1) >> 1;
				int u = (-38 * r - 74 * g + 112 * b + 128) >> 8;
				int v = (112 * r - 94 * g - 18 * b + 128) >> 8;
				*dst++ = clip(y0 + 16);
				*dst++ = clip(u + 128);
				*dst++ = clip(y1 + 16);
				*dst++ = clip(v + 128);
			}
		}
	}

	void onComplete(Request *req)
	{
		if (req->status() == Request::RequestCancelled)
			return;

		FrameBuffer *buf = req->buffers().begin()->second;
		if (buf->metadata().status == FrameMetadata::FrameSuccess) {
			convert(maps_[buf].data);
			ssize_t n = write(outFd_, yuyv_.data(), yuyv_.size());
			if (n < 0 && errno != EAGAIN)
				perror("write loopback");
			frames_++;
		}

		req->reuse(Request::ReuseBuffers);
		if (running_)
			cam_->queueRequest(req);
	}

	std::shared_ptr<Camera> cam_;
	int outFd_;
	unsigned w_, h_, stride_ = 0;
	PixelFormat fmt_;
	Stream *stream_ = nullptr;
	std::unique_ptr<CameraConfiguration> config_;
	std::unique_ptr<FrameBufferAllocator> alloc_;
	std::vector<std::unique_ptr<Request>> requests_;
	std::map<FrameBuffer *, MappedPlane> maps_;
	std::vector<uint8_t> yuyv_;
	std::atomic<unsigned> frames_{ 0 };
	std::atomic<bool> running_{ false };
};

/* v4l2loopback private event: number of active capture clients changed */
#define V4L2_EVENT_PRI_CLIENT_USAGE (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)

static int prime_loopback(int fd, unsigned w, unsigned h)
{
	struct v4l2_format f = {};
	f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	f.fmt.pix.width = w;
	f.fmt.pix.height = h;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	f.fmt.pix.bytesperline = w * 2;
	f.fmt.pix.sizeimage = w * h * 2;
	f.fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
	if (ioctl(fd, VIDIOC_S_FMT, &f) < 0) {
		perror("VIDIOC_S_FMT on loopback");
		return -1;
	}
	/* One black frame makes the device show up as a capture device. */
	std::vector<uint8_t> black(size_t(w) * h * 2);
	for (size_t i = 0; i < black.size(); i += 2) {
		black[i] = 16;
		black[i + 1] = 128;
	}
	if (write(fd, black.data(), black.size()) < 0)
		perror("write loopback");
	return 0;
}

static int wait_usage(int fd, int timeout_ms)
{
	struct pollfd p = { fd, POLLPRI, 0 };
	int r = poll(&p, 1, timeout_ms);
	if (r <= 0 || !(p.revents & POLLPRI))
		return -1;

	/* drain everything queued, keep the latest count */
	int count = -1;
	for (;;) {
		struct v4l2_event ev = {};
		if (ioctl(fd, VIDIOC_DQEVENT, &ev) < 0) {
			if (count < 0)
				perror("VIDIOC_DQEVENT");
			break;
		}
		if (ev.type == V4L2_EVENT_PRI_CLIENT_USAGE) {
			uint32_t c;
			memcpy(&c, ev.u.data, sizeof(c));
			count = c;
		}
		fprintf(stderr, "event type=0x%x seq=%u pending=%u count=%d\n",
			ev.type, ev.sequence, ev.pending, count);
		if (!ev.pending)
			break;
	}
	return count;
}

int main(int argc, char **argv)
{
	std::string dev = "/dev/video10";
	unsigned w = 1280, h = 720, fps = 30;
	bool always = false;
	int c;

	while ((c = getopt(argc, argv, "d:s:f:ah")) != -1) {
		switch (c) {
		case 'd': dev = optarg; break;
		case 's': sscanf(optarg, "%ux%u", &w, &h); break;
		case 'f': fps = std::max(1, atoi(optarg)); break;
		case 'a': always = true; break;
		default:
			fprintf(stderr, "usage: %s [-d /dev/video10] [-s 1280x720] [-f 30] [-a]\n"
				"  -a  keep the camera running (default: only while an app reads)\n",
				argv[0]);
			return c == 'h' ? 0 : 1;
		}
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	int fd = open(dev.c_str(), O_RDWR);
	if (fd < 0) {
		perror(dev.c_str());
		return 1;
	}
	if (prime_loopback(fd, w, h) < 0)
		return 1;

	struct v4l2_event_subscription sub = {};
	sub.type = V4L2_EVENT_PRI_CLIENT_USAGE;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	bool onDemand = !always;
	if (onDemand && ioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0) {
		perror("client usage events unavailable, running continuously");
		onDemand = false;
	}

	auto cm = std::make_unique<CameraManager>();
	if (cm->start() < 0 || cm->cameras().empty()) {
		fprintf(stderr, "no camera found\n");
		return 1;
	}
	std::shared_ptr<Camera> cam = cm->cameras()[0];
	fprintf(stderr, "camera: %s, mode: %s\n", cam->id().c_str(),
		onDemand ? "on demand" : "always on");

	std::unique_ptr<Bridge> b;
	unsigned clients = onDemand ? 0 : 1;
	unsigned last = 0;
	int idleTicks = 0;

	while (!g_stop) {
		if (onDemand) {
			int n = wait_usage(fd, 1000);
			if (n >= 0) {
				clients = n;
				fprintf(stderr, "capture clients: %u\n", clients);
			}
		} else {
			sleep(1);
		}

		if (clients)
			idleTicks = 0;

		if (clients && !b) {
			if (cam->acquire() < 0) {
				fprintf(stderr, "camera busy, retrying\n");
				sleep(1);
				continue;
			}
			b = std::make_unique<Bridge>(cam, fd, w, h);
			int ret = b->start(fps);
			if (ret) {
				fprintf(stderr, "start failed: %d\n", ret);
				b.reset();
				cam->release();
				sleep(1);
				continue;
			}
			fprintf(stderr, "camera started\n");
			last = 0;
			idleTicks = 0;
		} else if (!clients && b) {
			/* short grace period so apps that reopen quickly don't restart the sensor */
			if (++idleTicks < 3)
				continue;
			b->stop();
			b.reset();
			cam->release();
			fprintf(stderr, "camera stopped\n");
		}

		if (b) {
			static int tick;
			if (++tick % 10 == 0) {
				unsigned now = b->frames();
				fprintf(stderr, "%.1f fps\n", (now - last) / 10.0);
				last = now;
			}
		}
	}

	if (b) {
		b->stop();
		b.reset();
		cam->release();
	}
	cam.reset();
	cm->stop();
	close(fd);
	return 0;
}
