/*
 * sweetlog [SECONDS] [WORD...]: the unified log over SSH (iOS has no `log` tool). Prints the entries of the last
 * SECONDS (default 30) whose process name or message contains any WORD (case-insensitive; no WORD = all), oldest first:
 *   HH:MM:SS.mmm process[pid] subsystem/category: message
 * Reads the system store through OSLogStore (+localStoreAndReturnError:, else the system scope, else a .logarchive of links
 * to /private/var/db/diagnostics and uuidtext; entitlements com.apple.logging.local-store, com.apple.private.logging.admin). iOS 18, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <Foundation/Foundation.h>
#import <OSLog/OSLog.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		double secs = argc > 1 ? atof(argv[1]) : 30;
		NSMutableArray<NSString *> *words = [NSMutableArray array];
		for (int i = 2; i < argc; i++)
			[words addObject:[@(argv[i]) lowercaseString]];

		NSError *err = nil;
		OSLogStore *store = nil;
		SEL sel = NSSelectorFromString(@"localStoreAndReturnError:");
		if ([OSLogStore respondsToSelector:sel]) {
			OSLogStore *(*local)(id, SEL, NSError **) = (void *)[OSLogStore methodForSelector:sel];
			store = local([OSLogStore class], sel, &err);
		}
		if (!store)     /* OSLogStoreSystem (0): in the iOS headers only as unavailable */
			store = [OSLogStore storeWithScope:(OSLogStoreScope)0 error:&err];
		if (!store) {   /* a .logarchive made of links: the diagnostics store, the uuidtext tree, an Info.plist */
			NSFileManager *fm = NSFileManager.defaultManager;
			NSString *arc = @"/private/var/tmp/sweetlog.logarchive";
			[fm removeItemAtPath:arc error:nil];
			[fm createDirectoryAtPath:arc withIntermediateDirectories:YES attributes:nil error:nil];
			for (NSString *dir in @[@"/private/var/db/diagnostics", @"/private/var/db/uuidtext"])
				for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil])
					[fm createSymbolicLinkAtPath:[arc stringByAppendingPathComponent:n]
					         withDestinationPath:[dir stringByAppendingPathComponent:n] error:nil];
			[@{@"OSArchiveVersion": @4} writeToFile:[arc stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
			store = [OSLogStore storeWithURL:[NSURL fileURLWithPath:arc] error:&err];
		}
		if (!store) {
			fprintf(stderr, "sweetlog: no log store: %s\n", err.description.UTF8String);
			return 1;
		}
		OSLogPosition *pos = [store positionWithDate:[NSDate dateWithTimeIntervalSinceNow:-secs]];
		OSLogEnumerator *en = [store entriesEnumeratorWithOptions:0 position:pos predicate:nil error:&err];
		if (!en) {
			fprintf(stderr, "sweetlog: enumerator: %s\n", err.description.UTF8String);
			return 1;
		}
		NSDateFormatter *fmt = [NSDateFormatter new];
		fmt.dateFormat = @"HH:mm:ss.SSS";
		for (OSLogEntry *e in en) {
			NSString *proc = @"", *sub = @"", *cat = @"";
			int pid = 0;
			if ([e isKindOfClass:[OSLogEntryLog class]]) {
				OSLogEntryLog *l = (OSLogEntryLog *)e;
				proc = l.process ?: @"";
				pid = l.processIdentifier;
				sub = l.subsystem ?: @"";
				cat = l.category ?: @"";
			} else if ([e isKindOfClass:[OSLogEntryActivity class]]) {
				proc = ((OSLogEntryActivity *)e).process ?: @"";
				pid = ((OSLogEntryActivity *)e).processIdentifier;
			}
			NSString *msg = e.composedMessage ?: @"";
			if (words.count) {
				NSString *hay = [[NSString stringWithFormat:@"%@ %@ %@ %@", proc, sub, cat, msg] lowercaseString];
				BOOL hit = NO;
				for (NSString *w in words)
					if ([hay containsString:w]) { hit = YES; break; }
				if (!hit)
					continue;
			}
			printf("%s %s[%d] %s/%s: %s\n", [fmt stringFromDate:e.date].UTF8String, proc.UTF8String, pid, sub.UTF8String,
			       cat.UTF8String, msg.UTF8String);
		}
	}
	return 0;
}
