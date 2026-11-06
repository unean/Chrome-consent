#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/ucred.h>
#include <unistd.h>
#include <libproc.h>
#include <poll.h>
#include <fcntl.h>
#include <time.h>
#include "Bridge.h"

static NSString *const support = @"/Library/Application Support/ChromeConsent";
static NSString *const appBinary = @"/Applications/Chrome Consent.app/Contents/MacOS/ChromeConsent";

static NSDictionary *config(void) {
    NSString *path = [support stringByAppendingPathComponent:@"config.plist"];
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022)) return nil;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *hash = d[@"appCDHash"];
    if (![hash isKindOfClass:NSString.class] || hash.length != 40) return nil;
    if ([hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return nil;
    return d;
}

int cc_console_uid(void) {
    uid_t uid = 0; gid_t gid = 0;
    CFStringRef name = SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid);
    if (!name) return -1;
    BOOL login = CFEqual(name, CFSTR("loginwindow"));
    CFRelease(name);
    return login || uid < 501 ? -1 : (int)uid;
}

int cc_lock_state(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    id sessionFlag = session[@"CGSSessionScreenIsLocked"];
    // Absence of this optional CGSession key is not evidence of a locked session.
    int a = session ? [sessionFlag boolValue] : -1;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return -1;
    CFTypeRef flag = IORegistryEntryCreateCFProperty(root, CFSTR("IOConsoleLocked"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    int b = flag && CFGetTypeID(flag) == CFBooleanGetTypeID() ? CFBooleanGetValue(flag) : -1;
    if (flag) CFRelease(flag);
    return a == b ? a : -1;
}

static BOOL codeValid(SecCodeRef code, BOOL agent) {
    CFDictionaryRef raw = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw) != errSecSuccess) return NO;
    NSDictionary *info = CFBridgingRelease(raw);
    NSURL *executable = info[(__bridge id)kSecCodeInfoMainExecutable];
    NSString *requirement;
    if (agent) {
        NSString *path = executable.path;
        NSString *prefix = @"/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/";
        BOOL known = [path isEqual:[prefix stringByAppendingString:@"MacOS/SecurityAgent"]] ||
                     [path isEqual:[prefix stringByAppendingString:@"XPCServices/SecurityAgentHelper-arm64.xpc/Contents/MacOS/SecurityAgentHelper-arm64"]] ||
                     [path isEqual:[prefix stringByAppendingString:@"XPCServices/SecurityAgentHelper-x86_64.xpc/Contents/MacOS/SecurityAgentHelper-x86_64"]];
        if (!known) return NO;
        requirement = @"anchor apple";
    } else {
        NSDictionary *d = config();
        if (!d || ![executable.path isEqual:appBinary]) return NO;
        struct stat st;
        if (stat(appBinary.fileSystemRepresentation, &st) || st.st_uid != 0 || (st.st_mode & 0022)) return NO;
        requirement = [NSString stringWithFormat:@"cdhash H\"%@\"", d[@"appCDHash"]];
    }
    SecRequirementRef req = NULL;
    if (SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &req) != errSecSuccess) return NO;
    BOOL valid = SecCodeCheckValidity(code, kSecCSDefaultFlags, req) == errSecSuccess;
    CFRelease(req);
    return valid;
}

static int peer(int fd, BOOL agent) {
    audit_token_t token; socklen_t length = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) || length != sizeof(token)) return 0;
    NSData *data = [NSData dataWithBytes:&token length:sizeof(token)];
    NSDictionary *attributes = @{(__bridge id)kSecGuestAttributeAudit: data};
    SecCodeRef code = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) != errSecSuccess) return 0;
    BOOL result = codeValid(code, agent);
    CFRelease(code);
    return result;
}

int cc_peer_is_app(int fd) { return peer(fd, NO); }
int cc_peer_is_security_agent(int fd) { return peer(fd, YES); }

int cc_parent_is_app(int pid) {
    if (pid <= 1 || pid != getppid()) return 0;
    NSDictionary *attributes = @{(__bridge id)kSecGuestAttributePid: @(pid)};
    SecCodeRef code = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) != errSecSuccess) return 0;
    BOOL result = codeValid(code, NO);
    CFRelease(code);
    return result;
}

int cc_install_ready(void) {
    NSDictionary *d = config();
    if (!d || ![d[@"enabled"] boolValue] || [d[@"ownerUID"] intValue] != cc_console_uid()) return 0;
    NSString *plugin = @"/Library/Security/SecurityAgentPlugins/ChromeConsentAuthorizationPlugin.bundle/Contents/MacOS/ChromeConsentAuthorizationPlugin";
    struct stat st;
    if (lstat(plugin.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022)) return 0;
    CFDictionaryRef parent = NULL, own = NULL;
    if (AuthorizationRightGet("system.login.screensaver", &parent) != errAuthorizationSuccess) return 0;
    NSDictionary *parentRule = CFBridgingRelease(parent);
    if (![parentRule[@"class"] isEqual:@"rule"] || [parentRule[@"k-of-n"] intValue] != 1 ||
        ![parentRule[@"rule"] isKindOfClass:NSArray.class] || [parentRule[@"rule"] count] < 2 ||
        ![parentRule[@"rule"] containsObject:@"local.chromeconsent.unlock"]) return 0;
    if (AuthorizationRightGet("local.chromeconsent.unlock", &own) != errAuthorizationSuccess) return 0;
    NSDictionary *ownRule = CFBridgingRelease(own);
    if (![ownRule[@"class"] isEqual:@"evaluate-mechanisms"] ||
        ![ownRule[@"mechanisms"] isEqual:@[@"ChromeConsentAuthorizationPlugin:allow"]]) return 0;
    SecCodeRef me = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &me) != errSecSuccess) return 0;
    BOOL valid = codeValid(me, NO);
    CFRelease(me);
    return valid;
}

static NSString *socketPath(void) {
    NSDictionary *d = config();
    int uid = cc_console_uid();
    if (!d || ![d[@"enabled"] boolValue] || uid < 501 || [d[@"ownerUID"] intValue] != uid) return nil;
    return [NSString stringWithFormat:@"/Library/Application Support/ChromeConsent/Runtime/%d/approval.sock", uid];
}

static int makeSocket(NSString *path, struct sockaddr_un *address) {
    if (!path || strlen(path.fileSystemRepresentation) >= sizeof(address->sun_path)) return -1;
    memset(address, 0, sizeof(*address)); address->sun_family = AF_UNIX;
    strlcpy(address->sun_path, path.fileSystemRepresentation, sizeof(address->sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 350000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    return fd;
}

int cc_socket_listen(void) {
    NSString *path = socketPath();
    if (!path || !cc_install_ready()) return -1;
    struct stat st;
    if (!lstat(path.fileSystemRepresentation, &st)) {
        if (!S_ISSOCK(st.st_mode) || st.st_uid != getuid()) return -1;
        unlink(path.fileSystemRepresentation);
    }
    struct sockaddr_un address; int fd = makeSocket(path, &address);
    if (fd < 0) return -1;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || chmod(path.fileSystemRepresentation, 0666) || listen(fd, 4)) {
        close(fd); return -1;
    }
    return fd;
}

int cc_socket_connect(void) {
    NSString *path = socketPath(); struct sockaddr_un address;
    int fd = makeSocket(path, &address);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) { close(fd); return -1; }
    return fd;
}

void cc_socket_cleanup(void) {
    NSString *path = socketPath();
    struct stat st;
    if (path && !lstat(path.fileSystemRepresentation, &st) && S_ISSOCK(st.st_mode) && st.st_uid == getuid()) unlink(path.fileSystemRepresentation);
}

int cc_read_line(int fd, char *buffer, int size) {
    if (size < 2) return -1;
    struct timespec started;
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (int i = 0; i < size - 1; i++) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int remaining = 350 - (int)((now.tv_sec - started.tv_sec) * 1000 + (now.tv_nsec - started.tv_nsec) / 1000000);
        if (remaining <= 0) return -1;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, remaining) != 1 || !(p.revents & POLLIN)) return -1;
        ssize_t n = read(fd, buffer + i, 1);
        if (n != 1) return -1;
        if (buffer[i] == '\n') { buffer[i + 1] = 0; return i + 1; }
    }
    return -1;
}

int cc_write_line(int fd, const char *text) {
    size_t n = strlen(text);
    return n <= 128 && send(fd, text, n, 0) == n;
}

int cc_lock_available(void) { return AXIsProcessTrusted(); }

void cc_request_lock(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) return;
    // Control-Command-Q is the system Lock Screen shortcut; no password is used.
    CGKeyCode codes[] = {55, 59, 12, 12, 59, 55};
    bool downs[] = {true, true, true, false, false, false};
    CGEventFlags flags[] = {kCGEventFlagMaskCommand, kCGEventFlagMaskCommand|kCGEventFlagMaskControl,
        kCGEventFlagMaskCommand|kCGEventFlagMaskControl, kCGEventFlagMaskCommand|kCGEventFlagMaskControl,
        kCGEventFlagMaskCommand, 0};
    for (int i = 0; i < 6; i++) {
        CGEventRef event = CGEventCreateKeyboardEvent(source, codes[i], downs[i]);
        if (event) {
            CGEventSetFlags(event, flags[i]); CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, getpid());
            CGEventPost(kCGHIDEventTap, event); CFRelease(event);
        }
    }
    CFRelease(source);
}

int cc_login_pid(void) {
    NSArray *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.loginwindow"];
    if (running.count != 1) return -1;
    pid_t pid = [(NSRunningApplication *)running[0] processIdentifier];
    NSDictionary *attributes = @{(__bridge id)kSecGuestAttributePid: @(pid)};
    SecCodeRef code = NULL; SecRequirementRef requirement = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, 0, &code) != errSecSuccess) return -1;
    BOOL valid = SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.loginwindow\""), 0, &requirement) == errSecSuccess &&
        SecCodeCheckValidity(code, 0, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    CFRelease(code);
    return valid ? pid : -1;
}

int cc_submit_login(int expected_pid) {
    if (cc_lock_state() != 1 || cc_console_uid() != getuid() || expected_pid <= 1 || cc_login_pid() != expected_pid) return 0;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 36, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 36, false);
    if (!down || !up) { if (down) CFRelease(down); if (up) CFRelease(up); return 0; }
    CGEventRef events[] = {down, up};
    UniChar character = '\r';
    for (int i = 0; i < 2; i++) {
        CGEventSetFlags(events[i], 0);
        CGEventKeyboardSetUnicodeString(events[i], 1, &character);
        CGEventSetIntegerValueField(events[i], kCGEventSourceUnixProcessID, getpid());
        CGEventPostToPid(expected_pid, events[i]); CFRelease(events[i]);
    }
    return 1;
}
