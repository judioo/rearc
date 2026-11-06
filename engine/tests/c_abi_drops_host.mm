#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
#include <vector>
// Drives Chromium's real NSDraggingDestination (WebContentsViewCocoa) with a
// synthetic NSDraggingInfo over real pasteboards. Never touches the general
// or system drag pasteboard.
@interface FakeDrag : NSObject <NSDraggingInfo>
@property(strong) NSPasteboard* pasteboard;
@property NSPoint location;
@property(strong) NSWindow* window;
@end
@implementation FakeDrag
@synthesize draggingFormation, animatesToDestination, numberOfValidItemsForDrop, springLoadingHighlight;
- (NSWindow*)draggingDestinationWindow { return _window; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric; }
- (NSPoint)draggingLocation { return _location; }
- (NSPoint)draggedImageLocation { return _location; }
- (NSImage*)draggedImage { return nil; }
- (NSPasteboard*)draggingPasteboard { return _pasteboard; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 7; }
- (void)slideDraggedImageTo:(NSPoint)point {}
- (NSArray<NSString*>*)namesOfPromisedFilesDroppedAtDestination:(NSURL*)url { return nil; }
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)o forView:(NSView*)v classes:(NSArray*)c searchOptions:(NSDictionary*)s usingBlock:(void (^)(NSDraggingItem*, NSInteger, BOOL*))b {}
- (void)resetSpringLoading {}
@end

static uint64_t tab;
static NSWindow* window;
static NSView* cocoa;
static ReArcAttachment lease{};
static std::string base, files;
static bool stopped, started;
static NSString* const kPrivate = @"com.rearc.test.sidebar-item";
static void after(double s, std::function<void()> f) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); });
}
static NSView* find(NSView* v) {
  if ([NSStringFromClass([v class]) isEqualToString:@"WebContentsViewCocoa"]) return v;
  for (NSView* s in v.subviews) if (NSView* f = find(s)) return f;
  return nil;
}
static NSPasteboard* board(NSArray* objects, NSDictionary<NSString*, NSData*>* extra = nil) {
  NSPasteboard* pb = [NSPasteboard pasteboardWithUniqueName];
  [pb clearContents];
  if (objects.count) assert([pb writeObjects:objects]);
  if (extra.count) {
    NSPasteboardItem* item = [NSPasteboardItem new];
    for (NSString* type in extra) [item setData:extra[type] forType:type];
    assert([pb writeObjects:@[ item ]]);
  }
  return pb;
}
// Full drag: enter, two updates, drop; then read the page's event log.
static void drag(NSPasteboard* pb, NSDragOperation expect_enter, std::function<void(std::string)> done) {
  FakeDrag* d = [FakeDrag new];
  d.pasteboard = pb;
  d.window = window;
  d.location = [(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(200, 150) toView:nil];
  NSDragOperation op = [(id<NSDraggingDestination>)cocoa draggingEntered:d];
  printf("DROPS enter op=%lu\n", (unsigned long)op);
  assert(op == expect_enter);
  after(0.3, [d, done] {
    [(id<NSDraggingDestination>)cocoa draggingUpdated:d];
    after(0.3, [d, done] {
      [(id<NSDraggingDestination>)cocoa draggingUpdated:d];
      after(0.3, [d, done] {
        BOOL ok = [(id<NSDraggingDestination>)cocoa performDragOperation:d];
        printf("DROPS perform=%d\n", ok);
        after(0.8, [done] {
          assert(ReArcTabEvaluateScript2(tab, "log.splice(0).join('\\n')", 1, nullptr, 10000,
            [](void* ctx, const ReArcScriptResult* r) {
              assert(r->status == 0);
              auto* f = static_cast<std::function<void(std::string)>*>(ctx);
              std::string log = r->json; printf("DROPS log=%s\n", log.c_str());
              auto g = std::move(*f); delete f; g(log);
            }, new std::function<void(std::string)>(done)) == 0);
        });
      });
    });
  });
}
static bool has(const std::string& s, const std::string& part) { return s.find(part) != std::string::npos; }
static NSURL* file(const char* name) { return [NSURL fileURLWithPath:[NSString stringWithUTF8String:(files + "/" + name).c_str()]]; }
static NSData* png() {
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:4 pixelsHigh:4 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static void finish() {
  assert(ReArcTabClose(tab, true, [](void*, ReArcStatus s, bool c) {
    assert(s == 0 && !c); ReArcViewRelease(lease.native_view);
    assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) { assert(s == 0 && !c); stopped = true;
      puts("DROPS legacy abort + text/url/file/image drops + private type invisible + accept-mask filtering PASS"); }, nullptr) == 0);
  }, nullptr) == 0);
}
static void run() {
  cocoa = find((__bridge NSView*)lease.native_view);
  assert(cocoa);
  // Legacy (no policy): page sees dragenter, the drop itself is aborted.
  drag(board(@[ @"legacy text" ]), NSDragOperationCopy, [](std::string log) {
    assert(has(log, "enter:") && !has(log, "drop|"));
    const char* blocked[] = {"com.rearc.test.sidebar-item"};
    const char* bad[] = {"has space"};
    assert(ReArcEngineSetDropPolicy(16, nullptr, 0) == REARC_INVALID_ARGUMENT);
    assert(ReArcEngineSetDropPolicy(1, nullptr, 1) == REARC_INVALID_ARGUMENT);
    assert(ReArcEngineSetDropPolicy(1, bad, 1) == REARC_INVALID_ARGUMENT);
    assert(ReArcEngineSetDropPolicy(15, blocked, 1) == REARC_OK);
    drag(board(@[ [NSURL URLWithString:@"https://example.com/dropped"], @"dropped text" ]), NSDragOperationCopy, [](std::string log) {
      assert(has(log, "drop|") && has(log, "dropped text") && has(log, "https://example.com/dropped"));
      drag(board(@[ file("a.txt") ]), NSDragOperationCopy, [](std::string log) {
        assert(has(log, "drop|") && has(log, "a.txt:text/plain:5") && has(log, "content=a.txt"));
        // Raw image bytes with no source URL/Content-Disposition: Chromium's
        // own policy never surfaces them as a File (other parts still drop).
        drag(board(@[ @"caption" ], @{NSPasteboardTypePNG : png()}), NSDragOperationCopy, [](std::string log) {
          assert(has(log, "drop|") && has(log, "text=caption") && has(log, "files=|"));
        // A promised image (bytes + Content-Disposition, as from a web page).
        drag(board(nil, @{NSPasteboardTypePNG : png(),
                          @"org.chromium.content-disposition" : [@"attachment; filename=\"pixel.png\"" dataUsingEncoding:NSUTF8StringEncoding]}), NSDragOperationCopy, [](std::string log) {
          assert(has(log, "drop|") && has(log, "pixel.png:image/png:"));
        drag(board(@[ file("pixel.png") ]), NSDragOperationCopy, [](std::string log) {
          assert(has(log, "drop|") && has(log, "files=pixel.png:image/png:"));
          // Shell-private drag: no page event at all, no operation.
          drag(board(nil, @{NSPasteboardTypeString : [@"sidebar-uuid" dataUsingEncoding:NSUTF8StringEncoding],
                            kPrivate : [@"sidebar-uuid" dataUsingEncoding:NSUTF8StringEncoding]}), NSDragOperationNone, [](std::string log) {
            assert(log == "\"\"");
            assert(ReArcEngineSetDropPolicy(REARC_DROP_TEXT, nullptr, 0) == REARC_OK);
            // Files-only drag under a text-only policy never reaches the page.
            drag(board(@[ file("b.txt") ]), NSDragOperationCopy, [](std::string log) {
              assert(!has(log, "enter:") && !has(log, "drop|"));
              // Mixed drag: the text part arrives, the file is stripped.
              drag(board(@[ file("b.txt"), @"only text" ]), NSDragOperationCopy, [](std::string log) {
                assert(has(log, "drop|") && has(log, "only text") && has(log, "files=|"));
                assert(ReArcEngineSetDropPolicy(0, nullptr, 0) == REARC_OK);
                drag(board(@[ @"refused" ]), NSDragOperationCopy, [](std::string log) {
                  assert(!has(log, "drop|") && !has(log, "refused"));
                  finish();
                });});});
              });
            });
          });
        });
      });
    });
  });
}
static void event(void*, const ReArcTabEvent* e) {
  static std::string committed;
  if (e->tab_id != tab) return;
  if (e->kind == 3) committed = e->url;
  if (e->kind == 1 && (e->changes & 4) && !e->is_loading && committed == base + "/drop" && !started) {
    started = true;
    after(0.5, [] { run(); });
  }
}
static void ready(void*, uint64_t p) {
  assert(ReArcEngineABIMinorVersion() >= 29 && ReArcEngineHasFeature("page_drops"));
  assert(ReArcTabCreate(p, 1, (base + "/drop").c_str(), &tab) == 0);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == 0);
  assert(ReArcViewAttach(tab, 1, 400, 300, 1, &lease) == 0);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  [window makeKeyAndOrderFront:nil];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == 0);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  files = getenv("REARC_FILES_DIR");
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  int r = ReArcEngineRun(argc, argv); assert(r == 0 && stopped); return r;
}}
