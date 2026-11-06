// Test-only dyld interposer: emulate an indefinitely pending OS authorization
// without reading or changing any real Keychain item. Never ship this library.
#import <AVFoundation/AVFoundation.h>
#include <objc/runtime.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <unistd.h>
#include <assert.h>
static NSInteger BlockedAuthorization(id, SEL, NSString*) {
  static const char marker[] = "TEST TCC preflight blocked\n";
  write(STDERR_FILENO, marker, sizeof(marker) - 1);
  dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
  __builtin_unreachable();
}
__attribute__((constructor)) static void Loaded() {
  if (getenv("REARC_BLOCK_TCC")) {
    Method method = class_getClassMethod([AVCaptureDevice class],
        @selector(authorizationStatusForMediaType:));
    assert(method);
    method_setImplementation(method, reinterpret_cast<IMP>(&BlockedAuthorization));
  }
  static const char marker[] = "TEST Keychain interposer loaded\n";
  write(STDERR_FILENO, marker, sizeof(marker) - 1);
}
static OSStatus BlockedCopyMatching(CFDictionaryRef query, CFTypeRef* result) {
  CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
  const bool rearc = service && CFEqual(service, CFSTR("ReArc Safe Storage"));
  if (rearc) {
    CFTypeRef account = CFDictionaryGetValue(query, kSecAttrAccount);
    assert(account && CFEqual(account, CFSTR("ReArc")));
    static const char branded[] = "TEST service=ReArc Safe Storage account=ReArc\n";
    write(STDERR_FILENO, branded, sizeof(branded) - 1);
  }
  if (service && (rearc || CFEqual(service, CFSTR("Chromium Safe Storage")))) {
    static const char marker[] = "TEST Keychain authorization blocked\n";
    write(STDERR_FILENO, marker, sizeof(marker) - 1);
    dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
    __builtin_unreachable();
  }
  return SecItemCopyMatching(query, result);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void* replacement; const void* original; } interpose = {
  reinterpret_cast<const void*>(&BlockedCopyMatching),
  reinterpret_cast<const void*>(&SecItemCopyMatching)
};
