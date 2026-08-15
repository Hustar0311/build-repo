/*
 * gsmmux —— 把一个串口挂上内核的 GSM 07.10 线路规程（n_gsm）
 *
 * 背景：ImmortalWrt 25.12 的软件源里没有 ldattach，而内核 n_gsm 必须由
 *       用户态调用 ioctl 才能启用。本工具就是干这件事的最小实现。
 *
 * 关键点：线路规程在持有该 fd 的进程退出后会被自动摘除，
 *         所以本进程必须一直把 fd 开着（-d 进入后台常驻）。
 *
 * 用法： gsmmux [-d] [-b 波特率] [-n 通道数] <串口设备>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/gsmmux.h>

#ifndef N_GSM0710
#define N_GSM0710 21
#endif

static int g_fd = -1;
static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static speed_t baud_to_speed(int baud)
{
	switch (baud) {
	case 9600:   return B9600;
	case 19200:  return B19200;
	case 38400:  return B38400;
	case 57600:  return B57600;
	case 115200: return B115200;
	case 230400: return B230400;
	case 460800: return B460800;
	case 921600: return B921600;
	default:     return 0;
	}
}

/* 以原始模式打开串口并设置波特率 */
static int open_serial(const char *dev, int baud)
{
	struct termios tio;
	speed_t sp = baud_to_speed(baud);
	int fd;

	if (!sp) {
		fprintf(stderr, "gsmmux: 不支持的波特率 %d\n", baud);
		return -1;
	}

	fd = open(dev, O_RDWR | O_NOCTTY);
	if (fd < 0) {
		fprintf(stderr, "gsmmux: 打开 %s 失败: %s\n", dev, strerror(errno));
		return -1;
	}

	if (tcgetattr(fd, &tio) < 0) {
		fprintf(stderr, "gsmmux: tcgetattr 失败: %s\n", strerror(errno));
		close(fd);
		return -1;
	}

	cfmakeraw(&tio);
	tio.c_cflag |= CLOCAL | CREAD;
	tio.c_cflag &= ~CRTSCTS;
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 10;
	cfsetispeed(&tio, sp);
	cfsetospeed(&tio, sp);

	if (tcsetattr(fd, TCSANOW, &tio) < 0) {
		fprintf(stderr, "gsmmux: tcsetattr 失败: %s\n", strerror(errno));
		close(fd);
		return -1;
	}
	tcflush(fd, TCIOFLUSH);
	return fd;
}

/* 发一条 AT 命令并等待包含 OK 的应答 */
static int at_expect_ok(int fd, const char *cmd, int timeout_s)
{
	char buf[512];
	int total = 0, i;
	ssize_t n;

	tcflush(fd, TCIOFLUSH);
	if (write(fd, cmd, strlen(cmd)) < 0)
		return -1;

	for (i = 0; i < timeout_s * 10; i++) {
		n = read(fd, buf + total, sizeof(buf) - 1 - total);
		if (n > 0) {
			total += (int)n;
			buf[total] = '\0';
			if (strstr(buf, "OK"))
				return 0;
			if (strstr(buf, "ERROR"))
				return -1;
			if (total >= (int)sizeof(buf) - 1)
				return -1;
		}
		usleep(100000);
	}
	return -1;
}

static void usage(const char *p)
{
	fprintf(stderr,
		"用法: %s [-d] [-b 波特率] [-n 通道数] [-m mtu] <串口设备>\n"
		"  -d  后台常驻（线路规程会在本进程退出时被摘除，因此必须常驻）\n"
		"  -b  波特率，默认 115200\n"
		"  -n  逻辑通道数，默认 4\n"
		"  -m  MRU/MTU，默认 512\n", p);
}

int main(int argc, char **argv)
{
	const char *dev = NULL;
	int baud = 115200, nchan = 4, mtu = 512, daemonize = 0;
	int ldisc = N_GSM0710;
	struct gsm_config cfg;
	int opt;

	while ((opt = getopt(argc, argv, "db:n:m:h")) != -1) {
		switch (opt) {
		case 'd': daemonize = 1; break;
		case 'b': baud = atoi(optarg); break;
		case 'n': nchan = atoi(optarg); break;
		case 'm': mtu = atoi(optarg); break;
		default:  usage(argv[0]); return 1;
		}
	}
	if (optind >= argc) { usage(argv[0]); return 1; }
	dev = argv[optind];

	g_fd = open_serial(dev, baud);
	if (g_fd < 0)
		return 1;

	/* 让模组进入 CMUX 基本模式。参数含义：
	 * 0=basic 模式, 0=无差错纠正, 波特率档位省略由模组沿用当前速率,
	 * N1=帧长。这里用最兼容的写法。 */
	{
		char cmd[64];
		snprintf(cmd, sizeof(cmd), "AT+CMUX=0,0,,%d\r", mtu);
		if (at_expect_ok(g_fd, "AT\r", 3) < 0)
			fprintf(stderr, "gsmmux: 警告——模组对 AT 无应答，仍继续尝试\n");
		if (at_expect_ok(g_fd, cmd, 5) < 0) {
			fprintf(stderr, "gsmmux: AT+CMUX 失败，改用最简形式重试\n");
			if (at_expect_ok(g_fd, "AT+CMUX=0\r", 5) < 0) {
				fprintf(stderr, "gsmmux: 模组拒绝进入 CMUX 模式\n");
				close(g_fd);
				return 1;
			}
		}
	}

	/* 挂上 n_gsm 线路规程 */
	if (ioctl(g_fd, TIOCSETD, &ldisc) < 0) {
		fprintf(stderr, "gsmmux: 挂载 n_gsm 线路规程失败: %s\n"
				"        （内核是否启用了 CONFIG_N_GSM？）\n",
			strerror(errno));
		close(g_fd);
		return 1;
	}

	memset(&cfg, 0, sizeof(cfg));
	if (ioctl(g_fd, GSMIOC_GETCONF, &cfg) < 0) {
		fprintf(stderr, "gsmmux: GSMIOC_GETCONF 失败: %s\n", strerror(errno));
		close(g_fd);
		return 1;
	}
	cfg.initiator     = 1;
	cfg.encapsulation = 0;   /* basic 模式 */
	cfg.mru           = mtu;
	cfg.mtu           = mtu;
	cfg.t1            = 10;
	cfg.t2            = 30;
	cfg.t3            = 10;
	cfg.n2            = 3;
	if (ioctl(g_fd, GSMIOC_SETCONF, &cfg) < 0) {
		fprintf(stderr, "gsmmux: GSMIOC_SETCONF 失败: %s\n", strerror(errno));
		close(g_fd);
		return 1;
	}

	fprintf(stderr, "gsmmux: %s 已进入 CMUX，%d 条通道，设备为 /dev/gsmtty1..%d\n",
		dev, nchan, nchan);

	if (daemonize) {
		if (daemon(0, 0) < 0) {
			fprintf(stderr, "gsmmux: daemon() 失败: %s\n", strerror(errno));
			close(g_fd);
			return 1;
		}
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT,  on_signal);

	/* 必须常驻：一旦本进程退出，内核会摘除线路规程，
	 * /dev/gsmtty* 随之失效。 */
	while (!g_stop)
		sleep(3600);

	close(g_fd);
	return 0;
}
