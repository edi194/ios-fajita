/*
 * BlueTool stand-in for the Poco F1 (docs/BT_IOS_TRANSPORT.md section 2.3).
 *
 * bluetoothd asks the Mach service com.apple.BlueTool to boot and initialise the chip
 * (messages kMsgId = RunBuiltinScript / RunExternalScript / RunCommand, kMsgArgs.script =
 * boot | init | deepsleep, reply key "result" 0 = ok, optionally firmware / output /
 * manufacturer / btaddress). The real BlueTool only knows Broadcom controllers; here the
 * kernel (bsd/dev/beryllium_wlan.c, sweetbt=1) already powered the WCN3990, downloaded its
 * firmware and set the BD_ADDR, so every request just succeeds.
 *
 * Installed as /usr/sbin/BlueTool (the launchd job runs it as "BlueTool -R", user mobile);
 * the original stays as /usr/sbin/BlueTool.orig. tools/sweet-bt-install.sh does that.
 *
 * The exact message shape is read from disassembly, not observed, so the stub does not depend
 * on it: whatever dictionary arrives is answered with result = 0 plus the optional keys, and
 * every message is described in /private/var/tmp/bluetool-stub.log (mobile can write there)
 * so the first boot shows the real shape.
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SERVICE "com.apple.BlueTool"
#define LOGFILE "/private/var/tmp/bluetool-stub.log"

static FILE *logf;

static void
logline(const char *fmt, const char *arg)
{
	if (logf == NULL) {
		logf = fopen(LOGFILE, "a");
		if (logf == NULL) {
			return;
		}
		setvbuf(logf, NULL, _IOLBF, 0);
	}
	fprintf(logf, "%ld pid %d: ", (long)time(NULL), (int)getpid());
	fprintf(logf, fmt, arg ? arg : "");
	fputc('\n', logf);
}

static void
describe(const char *what, xpc_object_t o)
{
	char *d = xpc_copy_description(o);
	if (d != NULL) {
		logline("%s", what);
		logline("%s", d);
		free(d);
	}
}

/* the btaddress the caller sent (any of the plausible places), echoed back with the same type */
static xpc_object_t
find_btaddress(xpc_object_t msg)
{
	xpc_object_t v = xpc_dictionary_get_value(msg, "btaddress");
	if (v != NULL) {
		return v;
	}
	xpc_object_t args = xpc_dictionary_get_value(msg, "kMsgArgs");
	if (args != NULL && xpc_get_type(args) == XPC_TYPE_DICTIONARY) {
		return xpc_dictionary_get_value(args, "btaddress");
	}
	return NULL;
}

static void
handle_message(xpc_connection_t peer, xpc_object_t msg)
{
	if (xpc_get_type(msg) == XPC_TYPE_ERROR) {
		if (msg == XPC_ERROR_CONNECTION_INVALID) {
			logline("peer gone%s", "");
		}
		return;
	}
	if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) {
		return;
	}
	describe("request:", msg);
	xpc_object_t reply = xpc_dictionary_create_reply(msg);
	if (reply == NULL) {
		logline("no reply expected%s", "");
		return;
	}
	xpc_dictionary_set_int64(reply, "result", 0);
	xpc_dictionary_set_string(reply, "firmware", "qca/crbtfw21.tlv");
	xpc_dictionary_set_string(reply, "output", "");
	xpc_dictionary_set_string(reply, "manufacturer", "Qualcomm");
	xpc_object_t addr = find_btaddress(msg);
	if (addr != NULL) {
		xpc_dictionary_set_value(reply, "btaddress", addr);
	}
	describe("reply:", reply);
	xpc_connection_send_message(peer, reply);
	xpc_release(reply);
}

int
main(int argc, char **argv)
{
	/* "BlueTool -R" from launchd serves; anything else (a person typing BlueTool -c ...) is a no-op */
	int serve = argc == 1;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-R") == 0) {
			serve = 1;
		}
	}
	if (!serve) {
		fprintf(stderr, "BlueTool stub: the kernel owns the controller; the real tool is /usr/sbin/BlueTool.orig\n");
		return 0;
	}
	logline("stub starts, serving " SERVICE "%s", "");
	/* the SDK marks xpc_connection_create_mach_service unavailable on iOS; libxpc has it (the real BlueTool uses it) */
	xpc_connection_t (*create)(const char *, dispatch_queue_t, uint64_t) =
	    (xpc_connection_t (*)(const char *, dispatch_queue_t, uint64_t))dlsym(RTLD_DEFAULT,
	    "xpc_connection_create_mach_service");
	if (create == NULL) {
		logline("xpc_connection_create_mach_service not found%s", "");
		return 1;
	}
	xpc_connection_t listener = create(SERVICE, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
	if (listener == NULL) {
		logline("cannot create the mach service listener%s", "");
		return 1;
	}
	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
			return;
		}
		logline("connection%s", "");
		xpc_connection_t c = (xpc_connection_t)peer;
		xpc_connection_set_event_handler(c, ^(xpc_object_t msg) {
			handle_message(c, msg);
		});
		xpc_connection_resume(c);
	});
	xpc_connection_resume(listener);
	dispatch_main();
}
