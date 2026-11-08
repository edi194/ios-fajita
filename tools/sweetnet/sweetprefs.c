/*
 * sweetprefs: set or read a user default on the phone through cfprefsd
 * (iOS has no `defaults` tool). Run as root over SSH:
 *   sweetprefs USER DOMAIN KEY bool|int|string VALUE   set
 *   sweetprefs USER DOMAIN KEY                         read
 *   sweetprefs USER DOMAIN KEY delete -                remove the key
 * DOMAIN "-g" is the global domain (every app, e.g. WebKit settings).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFStringRef
str(const char *s)
{
	return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

int
main(int argc, char **argv)
{
	if (argc != 4 && argc != 6) {
		fprintf(stderr, "usage: sweetprefs USER DOMAIN KEY [bool|int|string VALUE | delete -]\n");
		return 2;
	}
	CFStringRef user = str(argv[1]);
	CFStringRef app = strcmp(argv[2], "-g") == 0 ? kCFPreferencesAnyApplication : str(argv[2]);
	CFStringRef key = str(argv[3]);
	if (argc == 6) {
		CFPropertyListRef v;
		if (strcmp(argv[4], "delete") == 0) {
			v = NULL;
		} else if (strcmp(argv[4], "bool") == 0) {
			v = (strcmp(argv[5], "1") == 0 || strcmp(argv[5], "true") == 0 || strcmp(argv[5], "YES") == 0) ?
			    kCFBooleanTrue : kCFBooleanFalse;
		} else if (strcmp(argv[4], "int") == 0) {
			long n = strtol(argv[5], NULL, 0);
			v = CFNumberCreate(NULL, kCFNumberLongType, &n);
		} else {
			v = str(argv[5]);
		}
		CFPreferencesSetValue(key, v, app, user, kCFPreferencesAnyHost);
		if (!CFPreferencesSynchronize(app, user, kCFPreferencesAnyHost)) {
			fprintf(stderr, "sweetprefs: synchronize failed\n");
			return 1;
		}
	}
	CFPropertyListRef cur = CFPreferencesCopyValue(key, app, user, kCFPreferencesAnyHost);
	if (cur == NULL) {
		printf("%s = (unset)\n", argv[3]);
	} else {
		CFStringRef d = CFCopyDescription(cur);
		char buf[512];
		CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8);
		printf("%s = %s\n", argv[3], buf);
	}
	return 0;
}
