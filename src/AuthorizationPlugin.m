#import <Foundation/Foundation.h>
#import <Security/AuthorizationPlugin.h>
#import <Security/SecRandom.h>
#import <os/log.h>
#include <unistd.h>
#include <pwd.h>
#include "Bridge.h"

typedef struct { const AuthorizationCallbacks *callbacks; } Plugin;
typedef struct { Plugin *plugin; AuthorizationEngineRef engine; } Mechanism;

static OSStatus destroyPlugin(AuthorizationPluginRef p) { free(p); return errAuthorizationSuccess; }
static OSStatus createMechanism(AuthorizationPluginRef p, AuthorizationEngineRef e,
                               AuthorizationMechanismId name, AuthorizationMechanismRef *out) {
    if (!out || strcmp(name, "allow")) return errAuthorizationInternal;
    Mechanism *m = calloc(1, sizeof(*m));
    if (!m) return errAuthorizationInternal;
    m->plugin = p; m->engine = e; *out = m;
    return errAuthorizationSuccess;
}

static OSStatus invokeMechanism(AuthorizationMechanismRef ref) {
    Mechanism *m = ref;
    BOOL allowed = NO;
    @autoreleasepool {
        const AuthorizationValue *username = NULL;
        BOOL sameUser = NO;
        if (m->plugin->callbacks->GetContextValue &&
            m->plugin->callbacks->GetContextValue(m->engine, "username", NULL, &username) == errSecSuccess &&
            username && username->data && username->length > 0 && username->length <= 256) {
            char name[257] = {0};
            memcpy(name, username->data, username->length);
            int uid = cc_console_uid();
            struct passwd entry, *found = NULL; char buffer[4096];
            if (uid >= 501 && getpwuid_r(uid, &entry, buffer, sizeof(buffer), &found) == 0 && found) {
                sameUser = !strcmp(found->pw_name, name);
            }
        }
        int fd = sameUser ? cc_socket_connect() : -1;
        if (fd >= 0) {
            if (cc_peer_is_app(fd) && cc_lock_state() == 1) {
                unsigned char random[16];
                if (SecRandomCopyBytes(kSecRandomDefault, sizeof(random), random) == errSecSuccess) {
                    NSMutableString *nonce = [NSMutableString string];
                    for (int i = 0; i < 16; i++) [nonce appendFormat:@"%02x", random[i]];
                    NSString *request = [NSString stringWithFormat:@"CONSUME %d %@\n", cc_console_uid(), nonce];
                    char response[128] = {0};
                    if (cc_write_line(fd, request.UTF8String) && cc_read_line(fd, response, sizeof(response)) > 0) {
                        NSString *expected = [NSString stringWithFormat:@"ALLOW %@\n", nonce];
                        allowed = !strcmp(response, expected.UTF8String);
                    }
                }
            }
            close(fd);
        }
        os_log(OS_LOG_DEFAULT, "ChromeConsent authorization decision: %{public}s", allowed ? "ALLOW" : "DENY");
    }
    return m->plugin->callbacks->SetResult(m->engine, allowed ? kAuthorizationResultAllow : kAuthorizationResultDeny);
}
static OSStatus deactivateMechanism(AuthorizationMechanismRef ref) {
    Mechanism *m = ref; return m->plugin->callbacks->DidDeactivate(m->engine);
}
static OSStatus destroyMechanism(AuthorizationMechanismRef ref) { free(ref); return errAuthorizationSuccess; }
static const AuthorizationPluginInterface interface = {
    kAuthorizationPluginInterfaceVersion, destroyPlugin, createMechanism, invokeMechanism,
    deactivateMechanism, destroyMechanism
};
OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *out,
                                 const AuthorizationPluginInterface **outInterface) {
    if (!callbacks || !out || !outInterface) return errAuthorizationInternal;
    Plugin *plugin = calloc(1, sizeof(*plugin));
    if (!plugin) return errAuthorizationInternal;
    plugin->callbacks = callbacks; *out = plugin; *outInterface = &interface;
    return errAuthorizationSuccess;
}
