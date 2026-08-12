/* ac-term-recorder.c - the SA_SIGINFO half of ac-term-recorder.sh.
 *
 * The contract (why it exists, how it is armed, the record format, the reap,
 * what it can and cannot catch) lives in the docs/examples/ac-term-recorder.sh
 * header, which is authoritative. This file owns the one thing a bash `trap` can never
 * express: si_pid, the pid of the process that sent the signal. It is
 * delivered only through sigaction/SA_SIGINFO.
 *
 * HANDLER RULES. on_signal() and on_alarm() call nothing but clock_gettime(),
 * getpid(), write() and fsync() - all async-signal-safe - over a line rendered
 * by hand-rolled digit writing. No printf, no malloc, no strftime, no locale.
 * The record is written AND fsynced inside the handler, before the process
 * does anything else, so a follow-up KILL a millisecond later still leaves the
 * evidence on disk. Everything expensive (ISO time, resolving the sender)
 * happens back in main() after the handler returns.
 *
 * Build: docs/examples/ac-term-recorder.sh builds this on demand; the binary is a
 * runtime artifact under the fleet home's gitignored state/, never committed.
 */

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define REC_LINE 256
#define CHAIN_MAX 32

static int rec_fd = -1; /* opened before any handler is armed */

static volatile sig_atomic_t got_signo = 0;
static volatile sig_atomic_t got_pid = 0;
static volatile sig_atomic_t got_uid = 0;
static volatile sig_atomic_t got_code = 0;
static volatile sig_atomic_t got_sec = 0;
static volatile sig_atomic_t got_ms = 0;
static volatile sig_atomic_t got_expired = 0;

/* --- handler-safe rendering ------------------------------------------------ */

static void put_str(char *b, size_t *o, const char *s)
{
	while (*s)
		b[(*o)++] = *s++;
}

static void put_num(char *b, size_t *o, long v)
{
	char t[24];
	int n = 0;

	if (v < 0) {
		b[(*o)++] = '-';
		v = -v;
	}
	do {
		t[n++] = (char)('0' + (int)(v % 10));
		v /= 10;
	} while (v > 0);
	while (n > 0)
		b[(*o)++] = t[--n];
}

static void put_ms3(char *b, size_t *o, long ns)
{
	long ms = ns / 1000000L;

	b[(*o)++] = (char)('0' + (int)((ms / 100) % 10));
	b[(*o)++] = (char)('0' + (int)((ms / 10) % 10));
	b[(*o)++] = (char)('0' + (int)(ms % 10));
}

/* --- handlers -------------------------------------------------------------- */

static void on_signal(int signo, siginfo_t *si, void *uap)
{
	char line[REC_LINE];
	size_t o = 0;
	struct timespec ts;

	(void)uap;
	ts.tv_sec = 0;
	ts.tv_nsec = 0;
	clock_gettime(CLOCK_REALTIME, &ts);

	put_str(line, &o, "signal epoch=");
	put_num(line, &o, (long)ts.tv_sec);
	put_str(line, &o, ".");
	put_ms3(line, &o, (long)ts.tv_nsec);
	put_str(line, &o, " signo=");
	put_num(line, &o, (long)signo);
	put_str(line, &o, " si_pid=");
	put_num(line, &o, si ? (long)si->si_pid : -1L);
	put_str(line, &o, " si_uid=");
	put_num(line, &o, si ? (long)si->si_uid : -1L);
	put_str(line, &o, " si_code=");
	put_num(line, &o, si ? (long)si->si_code : -1L);
	put_str(line, &o, " self_pid=");
	put_num(line, &o, (long)getpid());
	put_str(line, &o, "\n");

	if (write(rec_fd, line, o) < 0)
		_exit(3); /* nothing safe left to say; the exit code is the say */
	fsync(rec_fd);

	got_sec = (sig_atomic_t)ts.tv_sec;
	got_ms = (sig_atomic_t)(ts.tv_nsec / 1000000L);
	got_pid = si ? (sig_atomic_t)si->si_pid : -1;
	got_uid = si ? (sig_atomic_t)si->si_uid : -1;
	got_code = si ? (sig_atomic_t)si->si_code : -1;
	got_signo = signo; /* last: this is the flag main() waits on */
}

static void on_alarm(int signo)
{
	char line[REC_LINE];
	size_t o = 0;
	struct timespec ts;

	(void)signo;
	ts.tv_sec = 0;
	ts.tv_nsec = 0;
	clock_gettime(CLOCK_REALTIME, &ts);

	put_str(line, &o, "expired epoch=");
	put_num(line, &o, (long)ts.tv_sec);
	put_str(line, &o, " self_pid=");
	put_num(line, &o, (long)getpid());
	put_str(line, &o, "\n");

	if (write(rec_fd, line, o) < 0)
		_exit(3);
	fsync(rec_fd);
	got_expired = 1;
}

/* --- resolution (main loop only) ------------------------------------------- */

static const char *signame(int s)
{
	switch (s) {
	case SIGTERM:
		return "TERM";
	case SIGHUP:
		return "HUP";
	case SIGINT:
		return "INT";
	default:
		return "?";
	}
}

static void iso_now(char *buf, size_t n, time_t t)
{
	struct tm tm;

	gmtime_r(&t, &tm);
	strftime(buf, n, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

/* One hop of the ppid walk: records this pid's own ps line and returns its
 * ppid, or -1 when the pid is gone. A gone pid is EVIDENCE, not a failed
 * lookup - it excludes every long-lived parent - so it is recorded as such. */
static int resolve_step(int pid, int depth)
{
	char cmd[160];
	char line[4096];
	FILE *p;
	int self = 0;
	int ppid = 0;

	snprintf(cmd, sizeof cmd,
		 "/bin/ps -o pid=,ppid=,uid=,command= -p %d 2>/dev/null", pid);
	p = popen(cmd, "r");
	if (!p || !fgets(line, sizeof line, p)) {
		if (p)
			pclose(p);
		dprintf(rec_fd,
			"chain depth=%d pid=%d GONE - exited before resolution\n",
			depth, pid);
		return -1;
	}
	pclose(p);
	line[strcspn(line, "\n")] = '\0';
	dprintf(rec_fd, "chain depth=%d %s\n", depth, line);
	if (sscanf(line, "%d %d", &self, &ppid) != 2)
		return -1;
	return ppid;
}

int main(int argc, char **argv)
{
	static const int watched[] = { SIGTERM, SIGHUP, SIGINT };
	const char *rec = NULL;
	long ttl = 7200;
	char armed[64] = "";
	char skipped[64] = "";
	char iso[32];
	sigset_t block, empty;
	struct sigaction sa, old;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--record") && i + 1 < argc)
			rec = argv[++i];
		else if (!strcmp(argv[i], "--ttl") && i + 1 < argc)
			ttl = strtol(argv[++i], NULL, 10);
		/* Any other argument is ignored ON PURPOSE: the wrapper appends
		 * command-line bait so a kill aimed at watchers BY PATTERN
		 * reaches this recorder too. */
	}
	if (!rec || ttl <= 0) {
		fprintf(stderr,
			"usage: ac-term-recorder --record <file> --ttl <secs>\n");
		return 2;
	}

	rec_fd = open(rec, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (rec_fd < 0) {
		perror("open record");
		return 2;
	}

	/* Block first, install second, sigsuspend third: without the block a
	 * signal landing between the flag check and the wait would be lost. */
	sigemptyset(&block);
	for (i = 0; i < (int)(sizeof watched / sizeof watched[0]); i++)
		sigaddset(&block, watched[i]);
	sigaddset(&block, SIGALRM);
	sigprocmask(SIG_BLOCK, &block, NULL);

	for (i = 0; i < (int)(sizeof watched / sizeof watched[0]); i++) {
		/* A signal IGNORED on entry is left ignored, so the recorder's
		 * exposure is identical to that of the watcher it stands beside
		 * (a shell backgrounding a job without job control sets SIGINT
		 * to SIG_IGN in it, and bash cannot trap what it inherited
		 * ignored either). Overriding it would manufacture catches a
		 * real watcher would never have seen. */
		memset(&old, 0, sizeof old);
		sigaction(watched[i], NULL, &old);
		if (old.sa_handler == SIG_IGN) {
			if (*skipped)
				strlcat(skipped, ",", sizeof skipped);
			strlcat(skipped, signame(watched[i]), sizeof skipped);
			continue;
		}
		memset(&sa, 0, sizeof sa);
		sa.sa_sigaction = on_signal;
		sa.sa_flags = SA_SIGINFO;
		sigfillset(&sa.sa_mask);
		sigaction(watched[i], &sa, NULL);
		if (*armed)
			strlcat(armed, ",", sizeof armed);
		strlcat(armed, signame(watched[i]), sizeof armed);
	}

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_alarm;
	sigfillset(&sa.sa_mask);
	sigaction(SIGALRM, &sa, NULL);
	alarm((unsigned int)ttl);

	/* The arm line is written only here, AFTER the handlers are installed:
	 * it is the readiness marker anything waiting on this recorder must
	 * poll for. */
	iso_now(iso, sizeof iso, time(NULL));
	dprintf(rec_fd, "arm epoch=%ld iso=%s self_pid=%d ttl=%ld armed=%s skipped=%s\n",
		(long)time(NULL), iso, (int)getpid(), ttl, armed,
		*skipped ? skipped : "-");
	fsync(rec_fd);
	printf("term-recorder: armed pid=%d ttl=%lds armed=%s record=%s\n",
	       (int)getpid(), ttl, armed, rec);
	fflush(stdout);

	sigemptyset(&empty);
	while (!got_signo && !got_expired)
		sigsuspend(&empty);

	if (got_expired && !got_signo) {
		printf("term-recorder: expired after %lds with no signal\n", ttl);
		return 0;
	}

	{
		struct timespec now;
		long lag_ms;
		int cur = (int)got_pid;
		int depth = 0;

		now.tv_sec = 0;
		now.tv_nsec = 0;
		clock_gettime(CLOCK_REALTIME, &now);
		lag_ms = (long)(now.tv_sec - (time_t)got_sec) * 1000L +
			 (now.tv_nsec / 1000000L - (long)got_ms);
		iso_now(iso, sizeof iso, (time_t)got_sec);
		dprintf(rec_fd,
			"resolve iso=%s lag_ms=%ld signo=%d(%s) si_pid=%d si_uid=%d si_code=%d\n",
			iso, lag_ms, (int)got_signo, signame((int)got_signo),
			(int)got_pid, (int)got_uid, (int)got_code);

		if (cur <= 0) {
			dprintf(rec_fd,
				"chain none si_pid=%d - kernel-sent or not reported\n",
				cur);
		} else {
			while (depth < CHAIN_MAX) {
				int next = resolve_step(cur, depth);

				if (next < 0)
					break;
				if (next <= 1) {
					dprintf(rec_fd, "chain end pid=1 (init)\n");
					break;
				}
				cur = next;
				depth++;
			}
			if (depth >= CHAIN_MAX)
				dprintf(rec_fd, "chain truncated depth=%d\n", depth);
		}
		fsync(rec_fd);
		printf("term-recorder: caught SIG%s si_pid=%d si_uid=%d si_code=%d lag_ms=%ld record=%s\n",
		       signame((int)got_signo), (int)got_pid, (int)got_uid,
		       (int)got_code, lag_ms, rec);
	}
	return 0;
}
