#import <Cocoa/Cocoa.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <lv2/core/lv2.h>
#include <lv2/patch/patch.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>

#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#import "rig_theme.h"
#import "rig_tone_api.h"
#import "rig_tone_browser.h"
#include "rig_ui_state.h"

// Shared image cache so tone cards don't re-read artwork from disk on every layout.
static NSCache<NSString*, NSImage*>* artworkCache(void) {
  static NSCache *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [[NSCache alloc] init];
    cache.countLimit = 200;
  });
  return cache;
}

// Forward declarations (definitions are below, after the keychain helpers).
static NSString* artworkCachePathForTone(NSInteger toneId, NSInteger stage);
static NSString* artworkForTone(NSInteger toneId, NSInteger stage);
@implementation ToneItem @end

@implementation ToneCardItem {
  NSImageView *_artView;
  NSTextField *_titleField;
  NSTextField *_detailField;
  NSButton *_favButton;
}
- (void)loadView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 190, 74)];
  v.wantsLayer = YES;
  v.layer.backgroundColor = rigRaised().CGColor;
  v.layer.cornerRadius = 8;

  _artView = [[NSImageView alloc] initWithFrame:NSMakeRect(6, 7, 60, 60)];
  _artView.imageScaling = NSImageScaleProportionallyUpOrDown;
  _artView.wantsLayer = YES;
  _artView.layer.cornerRadius = 6;
  _artView.layer.masksToBounds = YES;
  [v addSubview:_artView];

  _titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(72, 42, 92, 16)];
  _titleField.font = [NSFont boldSystemFontOfSize:11];
  _titleField.textColor = rigText();
  _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
  _titleField.editable = NO; _titleField.selectable = NO; _titleField.drawsBackground = NO; _titleField.bordered = NO;
  [v addSubview:_titleField];

  _detailField = [[NSTextField alloc] initWithFrame:NSMakeRect(72, 24, 112, 14)];
  _detailField.font = [NSFont systemFontOfSize:9.5];
  _detailField.textColor = rigDimText();
  _detailField.lineBreakMode = NSLineBreakByTruncatingTail;
  _detailField.editable = NO; _detailField.selectable = NO; _detailField.drawsBackground = NO; _detailField.bordered = NO;
  [v addSubview:_detailField];

  // Favorite star (top-right). Clicking reports to the browser controller;
  // the star is intentionally NOT a title/mode control, just a toggle.
  _favButton = [[NSButton alloc] initWithFrame:NSMakeRect(168, 42, 18, 18)];
  _favButton.bordered = NO;
  _favButton.imagePosition = NSImageOnly;
  _favButton.target = self;
  _favButton.action = @selector(favClicked:);
  [v addSubview:_favButton];

  self.view = v;
  [self attachTone3000Menu];
}
- (void)setRepresentedObject:(id)representedObject {
  [super setRepresentedObject:representedObject];
  if (![representedObject isKindOfClass:[ToneItem class]]) return;
  ToneItem *item = (ToneItem *)representedObject;
  _titleField.stringValue = item.title ?: @"";
  _detailField.stringValue = [NSString stringWithFormat:@"@%@  ·  %@", item.creator, item.gear.uppercaseString];
  _favButton.image = [NSImage imageWithSystemSymbolName:(item.favorite ? @"star.fill" : @"star") accessibilityDescription:nil];
  _favButton.contentTintColor = item.favorite ? rigAccent() : rigDimText();

  // Placeholder immediately; load real artwork asynchronously from cache or disk.
  _artView.image = [NSImage imageWithSystemSymbolName:@"guitars" accessibilityDescription:nil];

  // Resolution order: downloaded artwork file → NAM Rig's cached PNG → online JPEG.
  NSString *path = item.artworkPath;
  if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path])
    path = artworkForTone(item.toneId, item.stage);

  __weak NSImageView *weakArt = _artView;
  if (path.length) {
    NSImage *cached = [artworkCache() objectForKey:path];
    if (cached) { _artView.image = cached; return; }
    NSString *capturedPath = [path copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSImage *img = [[NSImage alloc] initWithContentsOfFile:capturedPath];
      if (!img) return;
      [artworkCache() setObject:img forKey:capturedPath];
      dispatch_async(dispatch_get_main_queue(), ^{
        NSImageView *strongArt = weakArt;
        if (strongArt) strongArt.image = img;
      });
    });
    return;
  }

  // No local artwork yet — fetch the online JPEG and cache it to disk so the
  // thumbnail is ready before the tone's model is even downloaded.
  NSString *urlString = item.imageURL.length ? item.imageURL : nil;
  if (!urlString.length) return;

  NSImage *mem = [artworkCache() objectForKey:urlString];
  if (mem) { _artView.image = mem; return; }

  NSString *capturedURL = [urlString copy];
  NSString *cacheName = artworkCachePathForTone(item.toneId, item.stage);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:capturedURL]];
    if (!data.length) return;
    NSImage *img = [[NSImage alloc] initWithData:data];
    if (!img) return;
    // Persist to NAM Rig's artwork cache directory.
    NSError *dirErr = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheName.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:&dirErr];
    [data writeToFile:cacheName atomically:YES];
    [artworkCache() setObject:img forKey:capturedURL];
    [artworkCache() setObject:img forKey:cacheName];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSImageView *strongArt = weakArt;
      if (strongArt) strongArt.image = img;
    });
  });
}
- (IBAction)favClicked:(id)sender {
  if (self.onFavToggle && self.representedObject) self.onFavToggle((ToneItem*)self.representedObject);
}
// Right-click on the card offers "View on Tone3000" — opens the tone's page
// (https://www.tone3000.com/tones/<id>) in the default browser. Works for both
// search results and local-library cards: toneItem() builds toneURL with an
// id-based fallback when the manifest doesn't carry one. The menu is attached
// to the card's root view; right-clicks on any subview (art, title, star) with
// no menu of their own climb the responder chain to it.
- (void)attachTone3000Menu {
  if (!self.view) return;
  NSMenu *m = [[NSMenu alloc] init];
  NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"View on Tone3000"
                                                   action:@selector(openTone3000:)
                                            keyEquivalent:@""];
  openItem.target = self;  // reads self.representedObject at click time
  [m addItem:openItem];
  self.view.menu = m;
}
- (IBAction)openTone3000:(id)sender {
  ToneItem *item = (ToneItem *)self.representedObject;
  if (![item isKindOfClass:[ToneItem class]] || !item.toneURL.length) return;
  NSURL *url = [NSURL URLWithString:item.toneURL];
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}
@end
@implementation RigButton
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5];
  NSColor* fill;
  if (self.primary) {
    fill = (self.state == NSControlStateValueOn) ? rigAccent() : rigAccentDim();
  } else {
    BOOL on = self.state == NSControlStateValueOn;
    fill = on ? [rigAccent() colorWithAlphaComponent:0.32]
              : (self.isHighlighted ? rigRaised() : rigPanelBG());
  }
  [fill setFill]; [p fill];
  NSColor* border = self.primary ? rigAccent() : (self.state == NSControlStateValueOn
      ? [rigAccent() colorWithAlphaComponent:0.7] : rigPanelBorder());
  border = self.isHighlighted ? rigAccent() : border;
  [border setStroke]; p.lineWidth = 1.0; [p stroke];
  NSString* title = self.title;
  if (title.length) {
    NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSColor* tc = self.primary ? rigText() : (self.isHighlighted || self.state == NSControlStateValueOn ? rigText() : rigDimText());
    if (self.enabled == NO) tc = [rigDimText() colorWithAlphaComponent:0.5];
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
                            NSForegroundColorAttributeName: tc,
                            NSParagraphStyleAttributeName: ps};
    NSRect tr = NSInsetRect(self.bounds, 4, 0);
    [title drawInRect:tr withAttributes:attrs];
  }
}
@end

// Computes the on-disk artwork cache path for a tone (shared with NAM Rig's
// "Tone3000 State Artwork" cache so thumbnails persist across launches).
static NSString* artworkCachePathForTone(NSInteger toneId, NSInteger stage) {
  NSString* prefix = stage == 0 ? @"pedal" : (stage == 2 ? @"cab" : @"amp");
  NSString* name = [NSString stringWithFormat:@"%@-%ld.png", prefix, (long)toneId];
  NSString* root = [@"~/Library/Caches/NAM Rig/NAM Rig/Tone3000 State Artwork"
                    stringByExpandingTildeInPath];
  return [root stringByAppendingPathComponent:name];
}

static NSString* artworkForTone(NSInteger toneId, NSInteger stage) {
  NSString* path = artworkCachePathForTone(toneId, stage);
  return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

// ---- TONE3000 search cache (NAM-Rig-style: cache-first browsing) ----
// Full pagination of every keystroke/sort-change was getting us 429-throttled
// then 403-WAF-blocked (427 requests in ~2 minutes). NAM Rig avoids this by
// browsing from local data. We now do the same: every search page fetched from
// the API is persisted under ~/Library/Application Support/NAM Oversampled
// Rig/SearchCache/<sha1 of path>.json and served from disk when fresh (<10 min
// old). Pages load lazily (one page per filter change / scroll), so a full
// 30-page browse never re-downloads pages it already has.
static NSString* searchCacheDir(void) {
  static NSString* dir = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dir = [@("~/Library/Application Support/NAM Oversampled Rig/SearchCache")
           stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
  });
  return dir;
}

// A stable cache key: the request path (sort/gears/query/page), hashed so the
// filesystem doesn't see query characters it dislikes.
static NSString* searchCacheKeyForPath(NSString* path) {
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1([path UTF8String], (CC_LONG)strlen([path UTF8String]), digest);
  NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
  for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

// Returns the cached {data, page, total_pages, ...} dictionary for a search
// page if it exists and is younger than maxAgeSeconds; nil otherwise.
static NSDictionary* cachedSearchPageForPath(NSString* path, NSTimeInterval maxAgeSeconds) {
  NSString* file = [searchCacheDir() stringByAppendingPathComponent:
                    [searchCacheKeyForPath(path) stringByAppendingPathExtension:@"json"]];
  NSDictionary* wrapper = jsonDictionaryAtPath(file);
  NSDictionary* page = [wrapper[@"page"] isKindOfClass:NSDictionary.class] ? wrapper[@"page"] : nil;
  NSNumber* fetched = [wrapper[@"fetchedAt"] respondsToSelector:@selector(doubleValue)]
      ? wrapper[@"fetchedAt"] : nil;
  if (!page || !fetched) return nil;
  if ([[NSDate date] timeIntervalSince1970] - fetched.doubleValue > maxAgeSeconds) return nil;
  return page;
}

// Persists a fetched search page (called after every successful API page).
static void saveSearchPageForPath(NSString* path, NSDictionary* page) {
  if (![page isKindOfClass:NSDictionary.class] || !page[@"data"]) return;
  NSDictionary* wrapper = @{
    @"fetchedAt": @([[NSDate date] timeIntervalSince1970]),
    @"path": path,
    @"page": page,
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil];
  if (!json) return;
  NSString* file = [searchCacheDir() stringByAppendingPathComponent:
                    [searchCacheKeyForPath(path) stringByAppendingPathExtension:@"json"]];
  [json writeToFile:file options:NSDataWritingAtomic error:nil];
}
static ToneItem* toneItem(NSDictionary* tone, NSArray<NSString*>* models, NSDate* modified) {
  if (![tone[@"title"] isKindOfClass:NSString.class] || ![tone[@"id"] respondsToSelector:@selector(integerValue)])
    return nil;
  ToneItem* item = [[ToneItem alloc] init];
  item.toneId = [tone[@"id"] integerValue];
  item.title = tone[@"title"];
  item.gear = [tone[@"gear"] isKindOfClass:NSString.class] ? tone[@"gear"] : @"unknown";
  item.stage = stageForGear(item.gear);
  NSDictionary* user = [tone[@"user"] isKindOfClass:NSDictionary.class] ? tone[@"user"] : nil;
  item.creator = [user[@"username"] isKindOfClass:NSString.class] ? user[@"username"] : @"Tone3000";
  item.toneURL = [tone[@"url"] isKindOfClass:NSString.class] ? tone[@"url"] :
      [NSString stringWithFormat:@"https://www.tone3000.com/tones/%ld", (long)item.toneId];
  NSArray* images = [tone[@"images"] isKindOfClass:NSArray.class] ? tone[@"images"] : nil;
  item.imageURL = [images.firstObject isKindOfClass:NSString.class] ? images.firstObject : nil;
  item.artworkPath = artworkForTone(item.toneId, item.stage);
  item.models = models ?: @[];
  item.remoteModels = @[];
  item.toneData = tone;
  item.local = item.models.count > 0;
  item.favorite = [tone[@"is_favorite"] respondsToSelector:@selector(boolValue)] && [tone[@"is_favorite"] boolValue];

  // Capture the tone's real publication date and download count so the list
  // can mirror tone3000.com's Newest/Oldest/Most Downloaded ordering locally.
  NSString* createdAtString = [tone[@"created_at"] isKindOfClass:NSString.class] ? tone[@"created_at"] : nil;
  NSDate* createdAt = nil;
  if (createdAtString.length) {
    static NSISO8601DateFormatter* sDateFmt = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
      sDateFmt = [NSISO8601DateFormatter new];
      sDateFmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    createdAt = [sDateFmt dateFromString:createdAtString];
  }
  item.createdAt = createdAt;
  item.downloadsCount = [tone[@"downloads_count"] respondsToSelector:@selector(integerValue)] ? [tone[@"downloads_count"] integerValue] : 0;

  // Leave `modified` exactly as the original code set it (caller-supplied file
  // date for local items, distant-past for online items). Only the new,
  // additive `createdAt`/`downloadsCount` feed the Browse-mode sorts.
  item.modified = modified ?: [NSDate distantPast];
  return item;
}
@implementation ToneBrowserController
// Persist the Browse filter dropdowns (gear + sort) to disk on every USER change
// (sender != nil; programmatic [self filterChanged:nil] calls never write), and
// re-select the saved titles when the popup is built. Element recreates the
// plugin editor (and these NSPopUpButtons) every time the window is reopened,
// so without this the selections reset to "All Gear"/"Newest".
- (void)persistFilterSelection {
  NSString* dir = [@("~/Library/Application Support/NAM Oversampled Rig") stringByExpandingTildeInPath];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* path = [dir stringByAppendingPathComponent:@"browse-filters.txt"];
  NSString* line = [NSString stringWithFormat:@"%@\n%@\n",
                    self.gear.titleOfSelectedItem ?: @"", self.sort.titleOfSelectedItem ?: @""];
  [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
+ (void)restoreFilterSelectionForGear:(NSPopUpButton*)gear sort:(NSPopUpButton*)sort {
  NSString* path = [[@("~/Library/Application Support/NAM Oversampled Rig") stringByExpandingTildeInPath]
                    stringByAppendingPathComponent:@"browse-filters.txt"];
  NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if (![text isKindOfClass:[NSString class]] || !text.length) return;
  NSArray* lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  NSString* savedGear = lines.count > 0 ? lines[0] : @"";
  NSString* savedSort = lines.count > 1 ? lines[1] : @"";
  for (NSString* title in gear.itemTitles)
    if ([title isEqualToString:savedGear]) { [gear selectItemWithTitle:title]; break; }
  for (NSString* title in sort.itemTitles)
    if ([title isEqualToString:savedSort]) { [sort selectItemWithTitle:title]; break; }
}

- (void)dealloc {
  [self logTone3000:@"ToneBrowserController dealloc"];
  // Teardown hygiene: the repeating connect timer is retained by the main run
  // loop (not by self) — without invalidation every plugin-window recreation
  // leaks one zombie timer that fires forever. Same for a pending login timer.
  [self.connectTimer invalidate];
  self.connectTimer = nil;
  [self.oauthTimer invalidate];
  self.oauthTimer = nil;
  // Explicit (the bounds-change observer for infinite scroll). Modern macOS
  // auto-unregisters deallocated observers, but that is an implementation
  // kindness, not a contract — remove it deterministically.
  [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (instancetype)init {
  if ((self = [super init])) {
    _allItems = [NSMutableArray array]; _visibleItems = @[];
    _searchResults = [NSMutableArray array];
    _images = [NSMutableDictionary dictionary]; _mode = @"Browse";
    _nextSearchPage = 1; _searchTotalPages = 0; _searchGeneration = 0;
    _searchIds = [NSMutableSet set];
    // Prefer the plugin's OWN persisted session. If absent (fresh install / not
    // yet connected), bootstrap from NAM Rig's session so we can refresh it and
    // persist our own copy — from then on we no longer depend on NAM Rig.
    // Only adopt plausible tokens (same gate as connectIfNeeded): a rotated
    // refresh stub would poison the refresh path with 401s. NOTE: real
    // Tone3000 refresh tokens are SHORT (~12 chars — verified against NAM
    // Rig's own working keychain session), so the floor is 8, not 20+.
    NSDictionary* session = pluginSession();
    if (!session) session = namRigSession();
    NSString* access = [session[@"accessToken"] isKindOfClass:NSString.class]
        ? session[@"accessToken"] : nil;
    NSString* refresh = [session[@"refreshToken"] isKindOfClass:NSString.class]
        ? session[@"refreshToken"] : nil;
    if (access.length >= 100 && (!refresh.length || refresh.length >= 8)) {
      _accessToken = access;
      _refreshToken = refresh;
    }
    [self logTone3000:[NSString stringWithFormat:@"INIT tokens access=%d refresh=%d",
                       (int)access.length, (int)refresh.length]];
  }
  return self;
}

- (void)setOnlineStatus:(NSString*)message {
  dispatch_async(dispatch_get_main_queue(), ^{ self.status.stringValue = message; });
}

- (void)setAuthStatus:(NSString*)message color:(NSColor*)color {
  dispatch_async(dispatch_get_main_queue(), ^{ self.authStatus.stringValue = message; self.authStatus.textColor = color; });
}

- (void)logTone3000:(NSString*)message {
  NSString* line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], message ?: @""];
  NSString* path = @"/private/tmp/nam_oversampled_rig_tone3000.log";
  NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!file) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
  [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}

- (void)apiGET:(NSString*)path completion:(void (^)(NSDictionary*, NSInteger, NSError*))completion {
  NSURL* url = [NSURL URLWithString:[kToneAPI stringByAppendingString:path]];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
  if (self.accessToken.length) [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger status = [(NSHTTPURLResponse*)response statusCode];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    [self logTone3000:[NSString stringWithFormat:@"GET %@ -> %ld, rows=%lu, error=%@", path, (long)status,
                       (unsigned long)([json[@"data"] isKindOfClass:NSArray.class] ? [json[@"data"] count] : 0), error.localizedDescription ?: @"none"]];
    completion([json isKindOfClass:NSDictionary.class] ? json : nil, status, error);
  }] resume];
}

- (void)mergeRemoteTones:(NSArray*)tones favorite:(BOOL)favorite {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSMutableDictionary<NSNumber*, ToneItem*>* byId = [NSMutableDictionary dictionary];
    for (ToneItem* item in self.allItems) byId[@(item.toneId)] = item;
    NSMutableArray<ToneItem*>* ordered = [NSMutableArray array];
    for (NSDictionary* tone in tones) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
      if (!key) continue;
      ToneItem* existing = byId[key];
      if (existing) { existing.favorite |= favorite; existing.toneData = tone; if (!favorite) [ordered addObject:existing]; continue; }
      ToneItem* item = toneItem(tone, @[], nil); if (!item) continue;
      item.favorite |= favorite; [self.allItems addObject:item]; byId[key] = item; if (!favorite) [ordered addObject:item];
    }
    if (!favorite) {
      NSMutableSet<NSNumber*>* seen = [NSMutableSet set]; for (ToneItem* item in ordered) [seen addObject:@(item.toneId)];
      for (ToneItem* item in self.allItems) if (![seen containsObject:@(item.toneId)]) [ordered addObject:item];
      self.allItems = ordered;
    }
    [self filterChanged:nil];
  });
}

// Favorite/unfavorite a tone from its card's star toggle. Optimistic UI: flip
// the flag and redraw immediately; revert if the API call fails. Idempotent
// per API docs (PUT → 200, DELETE → 204), so retries are safe.
- (void)toggleFavoriteFromCard:(ToneItem*)item {
  if (!item) return;
  if (!self.accessToken.length) {
    self.status.stringValue = @"Connect to Tone3000 to save favorites";
    return;
  }
  BOOL adding = !item.favorite;
  item.favorite = adding;

  // If the card is visible, redraw it (and siblings sharing the tone).
  for (ToneCardItem *card in self.collectionView.visibleItems) {
    ToneItem *cardItem = (ToneItem *)card.representedObject;
    if ([cardItem isKindOfClass:[ToneItem class]] && cardItem.toneId == item.toneId) {
      card.representedObject = cardItem;   // re-runs setRepresentedObject → star redraw
    }
  }

  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/tones/%ld/favorite", kToneAPI, (long)item.toneId]]];
  request.HTTPMethod = adding ? @"PUT" : @"DELETE";
  request.timeoutInterval = 15;
  [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];

  __weak ToneBrowserController *weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger status = [(NSHTTPURLResponse*)response statusCode];
    BOOL ok = (status >= 200 && status < 300) && !error;
    dispatch_async(dispatch_get_main_queue(), ^{
      ToneBrowserController *strongSelf = weakSelf; if (!strongSelf) return;
      if (ok) {
        [strongSelf logTone3000:[NSString stringWithFormat:@"FAVORITE %@ -> %ld tone=%ld", adding ? @"PUT" : @"DELETE", (long)status, (long)item.toneId]];
        strongSelf.status.stringValue = adding ? @"Added to favorites" : @"Removed from favorites";
        if (!adding) {
          // Drop the tone from the in-memory union so Favorites mode and the
          // extras section stop offering it (mirrors mergeRemoteTones cleanup).
          NSMutableArray<ToneItem*>* kept = [NSMutableArray array];
          for (ToneItem* it in strongSelf.allItems) if (it.toneId != item.toneId) [kept addObject:it];
          strongSelf.allItems = kept;
          [strongSelf filterChanged:nil];
        }
      } else {
        item.favorite = !adding;   // revert optimistic flip
        [strongSelf logTone3000:[NSString stringWithFormat:@"FAVORITE FAILED tone=%ld -> %ld %@ %@", (long)item.toneId, (long)status, error.localizedDescription ?: @"", data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @""]];
        strongSelf.status.stringValue = @"Favorite failed — try again";
        for (ToneCardItem *card in strongSelf.collectionView.visibleItems) {
          ToneItem *cardItem = (ToneItem *)card.representedObject;
          if ([cardItem isKindOfClass:[ToneItem class]] && cardItem.toneId == item.toneId) card.representedObject = cardItem;
        }
      }
    });
  }] resume];
}

- (void)refreshOnline {
  // Prefer the plugin's own persisted session; refresh it (and persist) on 401.
  // NAM Rig is only consulted as a bootstrap seed when we have no session yet.
  NSDictionary* session = pluginSession();
  if (!session) session = namRigSession();
  NSString* fresh = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
  if (fresh.length) self.accessToken = fresh;
  if (!self.accessToken.length) { return; }
  NSDictionary* sortValues = @{@"Newest":@"newest", @"Trending":@"trending",
                               @"Most Downloaded":@"downloads-all-time", @"Oldest":@"oldest",
                               @"Best Match":@"best-match"};
  NSString* sort = sortValues[self.sort.titleOfSelectedItem] ?: @"newest";
  // Mirror tone3000.com's server-side gear filter so the result set and order
  // match the site (the site/NAM Rig send &gears=... rather than filtering
  // client-side after pulling all gear types). No &architecture= param is sent
  // because the site's default Format filter shows every model architecture;
  // hardcoding architecture=2 previously shrank result sets to A2-only.
  NSString* gearTitle = self.gear.titleOfSelectedItem;
  NSString* gearParam = @"";
  if ([gearTitle isEqualToString:@"Amps"]) gearParam = @"&gears=amp";
  else if ([gearTitle isEqualToString:@"Cabs"]) gearParam = @"&gears=cab";
  else if ([gearTitle isEqualToString:@"Pedals"]) gearParam = @"&gears=pedal";
  else if ([gearTitle isEqualToString:@"Amp + Cab"]) gearParam = @"&gears=amp-cab";
  NSString* encodedQuery = [self.search.stringValue stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  NSString* prefix = [NSString stringWithFormat:@"/tones/search?sort=%@%@%@", sort, gearParam,
                      encodedQuery.length ? [@"&query=" stringByAppendingString:encodedQuery] : @""];
  // A fresh search: draw a new generation and reset paging state. allItems is
  // a persistent union (local packs, favorites, previously seen tones) — we do
  // NOT prune it here; filterChanged renders searchResults first, extras after.
  self.searchGeneration++;
  [self.searchIds removeAllObjects];
  self.activeSearchPrefix = prefix;
  self.nextSearchPage = 1;
  self.searchTotalPages = 0;
  // Cache-first: page 1 comes from the local SearchCache when fresh, so re-
  // sorting / re-searching within 10 minutes costs ZERO network requests.
  [self loadMoreSearchResults];
  // Favorites still come from the API (small, single page) — but not while a
  // rate-limit cooldown is active; the cached flags carry us until it lifts.
  if ([[NSDate date] timeIntervalSince1970] >= self.rateLimitUntil) {
    [self apiGET:@"/tones/favorited?page=1&page_size=100" completion:^(NSDictionary* json, NSInteger status, NSError* error) {
      NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
      [self mergeRemoteTones:data favorite:YES];
    }];
  }
}

// Loads the NEXT page of the active search — NAM-Rig-style cache-first lazy
// pagination. Page 1 loads on every refresh; further pages load only as the
// user scrolls toward the bottom of the list (scrollViewDidScroll). Fresh
// pages are persisted to the SearchCache so revisits never touch the network.
- (void)loadMoreSearchResults {
  NSString* prefix = self.activeSearchPrefix;
  if (!prefix.length) return;
  if (self.loadingNextPage) return;                       // one page unit in flight
  if (self.searchTotalPages > 0 && self.nextSearchPage > self.searchTotalPages) return;  // exhausted
  if ([[NSDate date] timeIntervalSince1970] < self.rateLimitUntil) return;
  const NSInteger page = self.nextSearchPage;
  const NSInteger generation = self.searchGeneration;
  // The API caps search page_size at 25 (docs). CRITICAL: omitting the
  // architecture param applies the LEGACY default (A1 + Custom ONLY —
  // documented "excludes A2-only tones"), which hides nearly all new uploads
  // and mismatched the site's result set/order. We fetch each architecture
  // explicitly and merge: A2 first, then Custom, then A1, deduped by tone id.
  NSString* p2  = [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=2", prefix, (long)page];
  NSString* p1  = [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=1", prefix, (long)page];
  NSString* pc  = [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=custom", prefix, (long)page];
  NSArray<NSString*>* paths = @[p2, pc, p1];

  // 1) Cache-first: serve any page (<10 min old) from disk; only the misses
  // hit the network (sequential, ~150ms apart — server-friendly).
  NSMutableDictionary* fetched = [NSMutableDictionary dictionary];   // path -> json
  NSMutableArray<NSString*>* misses = [NSMutableArray array];
  for (NSString* p in paths) {
    NSDictionary* cached = cachedSearchPageForPath(p, 600.0);
    if (cached) fetched[p] = cached; else [misses addObject:p];
  }
  if (misses.count == 0) {
    [self mergeArchPages:fetched page:page generation:generation fromCache:YES];
    return;
  }
  self.loadingNextPage = YES;
  __weak ToneBrowserController* weakSelf = self;
  __block NSInteger missIndex = 0;
  void (^fetchNextMiss)(void);
  void (^__block fetchNextMissCopy)(void);
  fetchNextMiss = ^{
    ToneBrowserController* s = weakSelf;
    if (!s) return;
    if (missIndex >= (NSInteger)misses.count) {   // all done — merge
      s.loadingNextPage = NO;
      [s mergeArchPages:fetched page:page generation:generation fromCache:NO];
      return;
    }
    NSString* p = misses[missIndex];
    [s apiGET:p completion:^(NSDictionary* json, NSInteger status, NSError* error) {
      __strong ToneBrowserController* s2 = weakSelf;
      if (!s2) return;
      if (s2.searchGeneration != generation) { s2.loadingNextPage = NO; return; }
      if (status == 401) {
        s2.loadingNextPage = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ [s2 refreshToneSession]; });
        return;
      }
      if (status == 429 || status == 403) {
        s2.loadingNextPage = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
          [s2 logTone3000:[NSString stringWithFormat:@"RATE LIMIT: %ld — serving cache; cooling down 60s", (long)status]];
          s2.rateLimitUntil = [[NSDate date] timeIntervalSince1970] + 60.0;
        });
        return;
      }
      if (status == 200 && [json isKindOfClass:NSDictionary.class]) {
        saveSearchPageForPath(p, json);
        fetched[p] = json;
      }
      missIndex++;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), fetchNextMissCopy);
    }];
  };
  fetchNextMissCopy = fetchNextMiss;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    fetchNextMiss();
  });
}

// Merges the three architecture pages of one page index into a single search
// page and applies it. A2 first (matches the site's default), then Custom,
// then A1, deduped by tone id. total_pages = max across arches, so the scroll
// chain runs until every architecture is exhausted.
- (void)mergeArchPages:(NSDictionary<NSString*, NSDictionary*>*)fetched page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache {
  NSMutableArray<NSDictionary*>* merged = [NSMutableArray array];
  NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
  NSInteger totalPages = 0;
  for (NSString* p in @[
        [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=2", self.activeSearchPrefix, (long)page],
        [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=custom", self.activeSearchPrefix, (long)page],
        [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=1", self.activeSearchPrefix, (long)page]]) {
    NSDictionary* json = fetched[p];
    if (!json) continue;
    NSInteger tp = [json[@"total_pages"] respondsToSelector:@selector(integerValue)] ? [json[@"total_pages"] integerValue] : 0;
    if (tp > totalPages) totalPages = tp;
    for (NSDictionary* tone in [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[]) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
      if (!key || [seen containsObject:key]) continue;
      [seen addObject:key];
      [merged addObject:tone];
    }
  }
  if (totalPages <= 0) totalPages = (merged.count > 0) ? page + 1 : page;
  NSDictionary* synthesized = @{@"data": merged, @"page": @(page), @"page_size": @(25), @"total_pages": @(totalPages)};
  [self applySearchPage:synthesized page:page generation:generation fromCache:fromCache];
}

// Merges one search page (cache or network) into the list. Pages merge in
// ascending order, so appending new items at the END preserves the server's
// ordering across the whole search. Search results live in their own array
// (strict server order); everything else (local packs, favorites) renders
// after them, never interleaved — this keeps page1→pageN contiguous.
- (void)applySearchPage:(NSDictionary*)json page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache {
  NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
  NSInteger pages = [json[@"total_pages"] respondsToSelector:@selector(integerValue)]
      ? [json[@"total_pages"] integerValue] : 0;
  if (pages <= 0) pages = (data.count >= 25) ? page + 1 : page;   // full page ⇒ probably more
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.searchGeneration != generation) return;
    self.searchTotalPages = pages;
    NSMutableDictionary<NSNumber*, ToneItem*>* byId = [NSMutableDictionary dictionary];
    for (ToneItem* item in self.allItems) byId[@(item.toneId)] = item;
    NSMutableArray<ToneItem*>* pageItems = [NSMutableArray array];
    for (NSDictionary* tone in data) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
      if (!key) continue;
      ToneItem* existing = byId[key];
      if (existing) {
        existing.toneData = tone;            // refresh metadata in place
        [byId removeObjectForKey:key];       // claimed
      } else {
        ToneItem* item = toneItem(tone, @[], nil);
        if (!item) continue;
        existing = item;
        [self.allItems addObject:item];      // allItems stays the full union
        byId[key] = item;
      }
      if (![self.searchIds containsObject:key]) [self.searchIds addObject:key];
      [pageItems addObject:existing];
    }
    // Page 1 replaces any previously-loaded search rows; later pages append
    // (pages load strictly in ascending order via the scroll chain).
    BOOL page1 = (page == 1);
    if (page1) {
      // Drop any previously-loaded search rows (all pages) then add this page.
      NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];
      for (NSUInteger i = 0; i < self.searchResults.count; i++)
        if ([self.searchIds containsObject:@(self.searchResults[i].toneId)]) [drop addIndex:i];
      [self.searchResults removeObjectsAtIndexes:drop];
      [self.searchResults replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:pageItems];
    } else {
      // Append (pages load strictly in ascending order via the scroll chain).
      [self.searchResults addObjectsFromArray:pageItems];
    }
    self.nextSearchPage = page + 1;
    [self filterChanged:nil];
    self.status.stringValue = [NSString stringWithFormat:@"%lu tones • page %ld of %ld%@ — scroll for more",
                               (unsigned long)self.visibleItems.count, (long)page, (long)pages,
                               fromCache ? @" (cached)" : @""];
  });
}

- (void)sortChanged:(id)sender { if (sender) [self persistFilterSelection]; [self refreshOnline]; }

// Infinite scroll: as the user nears the bottom of the tone list, pull the
// next search page (cache-first, one page at a time). Fired via the clip
// view's bounds-change notification; note.object is the NSClipView.
- (void)scrollViewDidScroll:(NSNotification *)note {
  if (![self.activeSearchPrefix length]) return;
  NSClipView* clip = note.object;
  if (![clip isKindOfClass:NSClipView.class] || !clip.documentView) return;
  const CGFloat visibleHeight = clip.bounds.size.height;
  if (visibleHeight <= 0) return;
  const CGFloat documentHeight = clip.documentView.bounds.size.height;
  const CGFloat distanceToBottom = documentHeight - clip.bounds.origin.y - visibleHeight;
  if (distanceToBottom < 240.0)   // within ~2 rows of the bottom
    [self loadMoreSearchResults];
}

- (void)connectTone3000:(id)sender {
  // Manual Connect button — the ONLY user gesture that may open the browser.
  // Clears the login backoff so an explicit click always tries immediately.
  self.oauthLoginAttempts = 0;
  self.loginBackoffUntil = 0;
  [self setAuthStatus:@"CHECKING SESSION…" color:NSColor.systemOrangeColor];
  [self connectIfNeededAllowBrowser:YES];
}

// Background connection. Uses a stored session when valid and silently
// refreshes when expired — it NEVER opens the browser on its own. If the
// session is dead or missing it falls back to a "Not connected" state and
// waits for the user to click Connect (the only path that opens the browser).
- (void)connectIfNeededAllowBrowser:(BOOL)allowBrowser {
  if (self.connectRequested || self.oauthActive) return;   // don't stack attempts
  self.connectRequested = YES;
  __weak ToneBrowserController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ToneBrowserController* strongSelf = weakSelf;
    if (!strongSelf) { return; }
    NSDictionary* session = pluginSession();
    BOOL fromNamRig = NO;
    if (!session) { session = namRigSession(); fromNamRig = YES; }
    NSString* access = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
    NSString* refresh = [session[@"refreshToken"] isKindOfClass:NSString.class] ? session[@"refreshToken"] : nil;
    [strongSelf logTone3000:[NSString stringWithFormat:@"CONNECT session=%@ source=%@ access=%d refresh=%d",
                             session ? @"yes" : @"no", fromNamRig ? @"namrig" : @"own",
                             (int)access.length, (int)refresh.length]];
    // Sanity gate: never adopt a session whose tokens are garbage. A real
    // access token is a ~900-char JWT. A real Tone3000 refresh token is SHORT
    // (~12 chars — e.g. NAM Rig's own keychain session holds a 12-char one),
    // so the floor is 8; only a missing/empty refresh is treated as poisoned.
    if ((access.length < 100) || (refresh.length && refresh.length < 8)) {
      [strongSelf logTone3000:[NSString stringWithFormat:@"CONNECT rejecting implausible session (access=%d refresh=%d)",
                               (int)access.length, (int)refresh.length]];
      strongSelf.connectRequested = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (allowBrowser)
          [strongSelf startOAuthLogin];
        else
          [strongSelf setAuthStatus:@"Not connected — click Connect to sign in"
                              color:NSColor.systemGrayColor];
      });
      return;
    }
    if (!session || !access.length) {
      // No stored session. Only a manual Connect click may open the browser;
      // background paths just show the signed-out state and stay usable.
      strongSelf.connectRequested = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (allowBrowser)
          [strongSelf startOAuthLogin];
        else
          [strongSelf setAuthStatus:@"Not connected — click Connect to sign in"
                              color:NSColor.systemGrayColor];
      });
      return;
    }
    strongSelf.accessToken = access;
    strongSelf.refreshToken = refresh;
    // If the stored access token has already expired, don't claim "Signed in".
    // Try a refresh first (fast path); when the refresh token is also dead, the
    // refresh handler clears the poisoned session and auto-launches the login.
    NSTimeInterval expMs = jwtExpiryMilliseconds(access);
    NSNumber* savedExp = [session[@"expiresAtMilliseconds"] respondsToSelector:@selector(doubleValue)]
        ? session[@"expiresAtMilliseconds"] : nil;
    if (savedExp) expMs = savedExp.doubleValue;
    const BOOL expired = expMs > 0 && expMs < ([[NSDate date] timeIntervalSince1970] * 1000.0 + 60000.0);
    if (expired) {
      // Try a silent refresh when a refresh token exists; otherwise (corrupt
      // or partial session) only a manual Connect click opens the browser.
      strongSelf.connectRequested = NO;
      if (refresh.length)
        dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refreshToneSessionAllowBrowser:allowBrowser]; });
      else
        dispatch_async(dispatch_get_main_queue(), ^{
          if (allowBrowser)
            [strongSelf startOAuthLogin];
          else
            [strongSelf setAuthStatus:@"Session expired — click Connect to sign in again"
                                color:NSColor.systemOrangeColor];
        });
      return;
    }
    // If we bootstrapped from NAM Rig, persist our own copy immediately.
    if (fromNamRig && refresh.length) {
      NSMutableDictionary* saved = [NSMutableDictionary dictionary];
      if (access.length) saved[@"accessToken"] = access;
      saved[@"refreshToken"] = refresh;
      savePluginSession(saved);
      [strongSelf logTone3000:@"BOOTSTRAP: saved plugin session from NAM Rig"];
    }
    strongSelf.connectRequested = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf setAuthStatus:(fromNamRig ? @"Signed in via NAM Rig" : @"Signed in")
                          color:NSColor.systemGreenColor];
      [strongSelf refreshOnline];
    });
  });
}

// Silent variant used by UI build + periodic timer; never opens the browser.
- (void)connectIfNeeded {
  [self connectIfNeededAllowBrowser:NO];
}

// Kick-starts the background connect when the browser UI is built and keeps a
// periodic safety net: if the session dies silently while the plugin is open
// (no request fired to trigger the 401 chain), re-establish it. This path is
// silent-only: it may refresh tokens but never launches a browser login.
- (void)autoConnect {
  __weak ToneBrowserController* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    [s connectIfNeeded];
  });
  if (self.connectTimer) return;
  self.connectTimer = [NSTimer scheduledTimerWithTimeInterval:1200.0 repeats:YES block:^(NSTimer* t) {
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    if (s.oauthActive || s.connectRequested) return;      // a flow is already running
    [s connectIfNeeded];                                  // silent: never opens the browser
  }];
}

// ---- TONE3000 OAuth login flow (authorization-code + PKCE) ----
// Binds a one-shot HTTP listener on 127.0.0.1 at an OS-chosen port, opens the
// authorize page in the default browser, waits for the redirect, exchanges the
// code for tokens, and persists the session to the plugin's keychain.
- (void)startOAuthLogin {
  if (self.oauthActive) return;
  // Auto-retry pacing: don't re-open the browser during a backoff window set
  // by a recent failed attempt. Manual Connect clears the backoff.
  if ([[NSDate date] timeIntervalSince1970] < self.loginBackoffUntil) {
    [self setAuthStatus:@"Sign-in is on a short cooldown — click Connect again in a moment"
                  color:NSColor.systemOrangeColor];
    return;
  }
  self.oauthActive = YES;

  int sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0) { [self oauthCleanup]; [self setAuthStatus:@"Could not start sign-in" color:NSColor.systemRedColor]; return; }
  int yes = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;   // OS-assigned free port
  if (bind(sock, (struct sockaddr*)&addr, sizeof addr) < 0) { close(sock); [self oauthCleanup]; [self setAuthStatus:@"Could not start sign-in" color:NSColor.systemRedColor]; return; }
  socklen_t alen = sizeof addr;
  getsockname(sock, (struct sockaddr*)&addr, &alen);
  self.oauthPort = ntohs(addr.sin_port);
  if (listen(sock, 1) < 0) { close(sock); [self oauthCleanup]; [self setAuthStatus:@"Could not start sign-in" color:NSColor.systemRedColor]; return; }

  NSString* verifier = base64URLStringNoPadding(randomDataOfLength(32));   // 43 chars
  self.oauthVerifier = verifier;
  self.oauthState = base64URLStringNoPadding(randomDataOfLength(24));
  NSString* challenge = base64URLStringNoPadding(sha256Data(verifier));

  // Accept the browser redirect on a background thread.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self acceptOAuthCallbackOnSocket:sock];
  });

  NSString* redirect = [NSString stringWithFormat:@"http://127.0.0.1:%d/callback", self.oauthPort];
  NSString* authorizeURL = [NSString stringWithFormat:
      @"%@/oauth/authorize?client_id=%@&response_type=code&redirect_uri=%@&code_challenge=%@&code_challenge_method=S256&state=%@",
      kToneAPI, kPluginPublishableKey,
      percentEncode(redirect), challenge, self.oauthState];
  [self setAuthStatus:@"Waiting for browser sign-in…" color:NSColor.systemOrangeColor];
  self.status.stringValue = @"Authorize in the browser that opened — then come back here";
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:authorizeURL]];
  [self logTone3000:[NSString stringWithFormat:@"OAUTH authorize opened (port %d)", self.oauthPort]];

  __weak ToneBrowserController* weakSelf = self;
  // Timeout: stop the flow quietly. Login is always user-initiated now, so the
  // next attempt happens only when the user clicks Connect again — never by
  // re-opening the browser on a timer.
  self.oauthTimer = [NSTimer scheduledTimerWithTimeInterval:180.0 repeats:NO block:^(NSTimer* t) {
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    if (!s.oauthActive) return;
    [s oauthCleanup];
    [s setAuthStatus:@"Sign-in timed out — click Connect to try again" color:NSColor.systemRedColor];
  }];
}

// Runs on a background thread: accept()s the browser's redirect, parses the
// callback query, responds with a tiny HTML page, then hands off to main.
- (void)acceptOAuthCallbackOnSocket:(int)sock {
  NSString* code = nil;
  NSString* state = nil;
  BOOL failed = NO;
  int c = accept(sock, NULL, NULL);
  close(sock);
  if (c >= 0) {
    char buf[16384];
    ssize_t n = read(c, buf, sizeof buf - 1);
    if (n > 0) {
      buf[n] = 0;
      NSString* req = [NSString stringWithUTF8String:buf];
      NSRange sp = [req rangeOfString:@" "];
      if (sp.location != NSNotFound) {
        NSRange rest = NSMakeRange(sp.location + 1, req.length - sp.location - 1);
        NSRange sp2 = [req rangeOfString:@" " options:0 range:rest];
        NSString* target = sp2.location == NSNotFound
            ? [req substringWithRange:rest]
            : [req substringWithRange:NSMakeRange(rest.location, sp2.location - rest.location)];
        NSRange q = [target rangeOfString:@"?"];
        NSString* query = q.location == NSNotFound ? @"" : [target substringFromIndex:q.location + 1];
        NSDictionary* params = parseQueryString(query);
        if (params[@"error"]) failed = YES;
        code = [params[@"code"] isKindOfClass:NSString.class] ? params[@"code"] : nil;
        state = params[@"state"];
        [self logTone3000:[NSString stringWithFormat:@"OAUTH callback received (code=%lu state=%@)", (unsigned long)code.length, state ? @"yes" : @"no"]];
      } else {
        failed = YES;
      }
    } else {
      failed = YES;
    }
    const char* resp =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
        "<html><body style='font-family:sans-serif;padding:2em'><h2>Sign-in complete</h2>"
        "<p>You can close this window and return to the plugin.</p></body></html>";
    write(c, resp, strlen(resp));
    close(c);
  } else {
    failed = YES;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (failed || !code.length) {
      [self oauthCleanup];
      [self setAuthStatus:@"Sign-in failed — click Connect to try again" color:NSColor.systemRedColor];
      return;
    }
    [self handleOAuthCode:code state:state];
  });
}

- (void)handleOAuthCode:(NSString*)code state:(NSString*)state {
  [self logTone3000:[NSString stringWithFormat:@"OAUTH handle: code=%lu state=%lu expect=%lu",
                     (unsigned long)code.length, (unsigned long)state.length,
                     (unsigned long)self.oauthState.length]];
  if (![state isEqualToString:self.oauthState]) {
    [self logTone3000:@"OAUTH handle: STATE MISMATCH — aborting"];
    [self oauthCleanup];
    [self setAuthStatus:@"Sign-in failed (state mismatch) — click Connect to try again" color:NSColor.systemRedColor];
    return;
  }
  [self setAuthStatus:@"Completing sign-in…" color:NSColor.systemOrangeColor];
  // Strong capture — the login flow MUST survive UI teardown. Element can
  // destroy the plugin window while the browser authorize is in flight (e.g.
  // the user switches to the browser to approve); with a weak capture the
  // controller would deallocate and the exchange would die silently. Retain
  // self so the flow completes and the session is saved even if the window
  // is gone. The blocks release the controller once the exchange resolves.
  ToneBrowserController* strongSelf = self;
  NSString* verifier = self.oauthVerifier;
  NSString* redirect = [NSString stringWithFormat:@"http://127.0.0.1:%d/callback", self.oauthPort];
  NSString* body = [NSString stringWithFormat:
      @"grant_type=authorization_code&code=%@&client_id=%@&redirect_uri=%@&code_verifier=%@",
      percentEncode(code), kPluginPublishableKey, percentEncode(redirect), percentEncode(verifier)];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kToneAPI stringByAppendingString:@"/oauth/token"]]];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  __block BOOL finished = NO;
  // Hard timeout so a hung exchange can never die silently.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (finished) return;
    finished = YES;
    [strongSelf logTone3000:@"EXCHANGE timed out after 25s (no response from /oauth/token)"];
    [strongSelf oauthCleanup];
    [strongSelf setAuthStatus:@"Sign-in didn't complete (timeout) — click Connect to try again" color:NSColor.systemRedColor];
  });
  [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger statusCode = [(NSHTTPURLResponse*)response statusCode];
    if (finished) { return; }
    finished = YES;
    NSDictionary* token = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    [strongSelf logTone3000:[NSString stringWithFormat:@"EXCHANGE response: status=%ld data=%lu err=%@",
                    (long)statusCode, (unsigned long)data.length, error.localizedDescription ?: @"none"]];
    // Tolerate both flat responses and a nested {"data": {...}} envelope.
    NSDictionary* payload = token;
    NSDictionary* nested = [token[@"data"] isKindOfClass:NSDictionary.class] ? token[@"data"] : nil;
    if (nested) payload = nested;
    NSString* access = [payload[@"access_token"] isKindOfClass:NSString.class] ? payload[@"access_token"] : nil;
    if (statusCode == 200 && access.length) {
      NSString* refresh = [payload[@"refresh_token"] isKindOfClass:NSString.class] ? payload[@"refresh_token"] : @"";
      NSNumber* expMs = [payload[@"expires_at"] respondsToSelector:@selector(doubleValue)]
          ? @([payload[@"expires_at"] doubleValue] * 1000.0) : nil;
      if (!expMs && [payload[@"expires_at_millis"] respondsToSelector:@selector(doubleValue)])
        expMs = payload[@"expires_at_millis"];
      if (!expMs && [payload[@"expires_in"] respondsToSelector:@selector(doubleValue)])
        expMs = @(([[NSDate date] timeIntervalSince1970] + [payload[@"expires_in"] doubleValue]) * 1000.0);
      NSMutableDictionary* saved = [@{@"accessToken": access} mutableCopy];
      if (refresh.length) saved[@"refreshToken"] = refresh;
      if (expMs) saved[@"expiresAtMilliseconds"] = expMs;
      savePluginSession(saved);
      strongSelf.accessToken = access;
      strongSelf.refreshToken = refresh;
      strongSelf.oauthLoginAttempts = 0;         // login succeeded: reset retry budget + backoff
      strongSelf.loginBackoffUntil = 0;
      [strongSelf oauthCleanup];
      [strongSelf logTone3000:@"OAUTH login success (session saved)"];
      [strongSelf setAuthStatus:@"Signed in" color:NSColor.systemGreenColor];
      [strongSelf refreshOnline];
    } else {
      [strongSelf oauthCleanup];
      NSString* errMsg = [token[@"error_description"] isKindOfClass:NSString.class] ? token[@"error_description"]
          : ([token[@"msg"] isKindOfClass:NSString.class] ? token[@"msg"]
             : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]);
      [strongSelf logTone3000:[NSString stringWithFormat:@"OAUTH exchange failed: %@", errMsg]];
      strongSelf.loginBackoffUntil = [[NSDate date] timeIntervalSince1970] + 30.0;
      [strongSelf setAuthStatus:@"Sign-in didn't complete — click Connect to try again" color:NSColor.systemRedColor];
    }
  }] resume];
    }

- (void)oauthCleanup {
  self.oauthActive = NO;
  [self.oauthTimer invalidate];
  self.oauthTimer = nil;
  self.oauthVerifier = nil;
  self.oauthState = nil;
}

// Best-effort token refresh. NAM Rig usually refreshes on its own; this is a
// safety net when the local token has expired. On success the updated token
// pair is applied in memory and persisted to the plugin's own keychain entry
// (NAM Rig's keychain entry is left untouched, since NAM Rig is the owner).
- (void)refreshToneSession {
  [self refreshToneSessionAllowBrowser:NO];
}

// Refreshes the access token with the stored refresh token. Called from the
// search-401 path and the background connect with allowBrowser=NO: on failure
// the poisoned session is cleared and the UI shows the signed-out state
// instead of launching a browser. Only the manual Connect button passes
// allowBrowser=YES.
- (void)refreshToneSessionAllowBrowser:(BOOL)allowBrowser {
  if (!self.refreshToken.length) return;
  if (self.refreshingToken) return;   // concurrent 401s can't stack refreshes
  self.refreshingToken = YES;
  NSString* clientId = kPluginPublishableKey;
  NSString* body = [NSString stringWithFormat:@"grant_type=refresh_token&refresh_token=%@&client_id=%@",
                    [self.refreshToken stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet],
                    [clientId stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kToneAPI stringByAppendingString:@"/oauth/token"]]];
  request.HTTPMethod = @"POST"; request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  __weak ToneBrowserController* weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* e) {
    ToneBrowserController* strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf.refreshingToken = NO;    // clear before the branches below
    NSDictionary* token = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString* access = [token[@"access_token"] isKindOfClass:NSString.class]
        ? token[@"access_token"] : nil;
    if (access.length) {
      strongSelf.accessToken = access;
      NSString* newRefresh = [token[@"refresh_token"] isKindOfClass:NSString.class]
          ? token[@"refresh_token"] : nil;
      if (newRefresh.length) strongSelf.refreshToken = newRefresh;
      // The plugin now owns this session: persist it to OUR keychain entry so
      // future loads no longer depend on NAM Rig.
      NSNumber* expiry = [token[@"expires_at"] respondsToSelector:@selector(longLongValue)]
          ? @([token[@"expires_at"] longLongValue] * 1000.0) : nil;
      if (!expiry) expiry = [token[@"expires_at_millis"] respondsToSelector:@selector(longLongValue)]
          ? @([token[@"expires_at_millis"] longLongValue]) : nil;
      NSMutableDictionary* saved = [NSMutableDictionary dictionary];
      saved[@"accessToken"] = access;
      if (newRefresh.length) saved[@"refreshToken"] = newRefresh;
      if (expiry) saved[@"expiresAtMilliseconds"] = expiry;
      savePluginSession(saved);
      [strongSelf logTone3000:@"REFRESH token success (saved to plugin session)"];
      dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refreshOnline]; });
    } else {
      // The refresh endpoint reports failures as {"code":400,"error_code":"...","msg":"..."};
      // some grants use the standard {"error","error_description"} shape. Read both.
      NSString* err = [token[@"error_code"] isKindOfClass:NSString.class] ? token[@"error_code"]
          : ([token[@"error"] isKindOfClass:NSString.class] ? token[@"error"] : @"?");
      NSString* desc = [token[@"msg"] isKindOfClass:NSString.class] ? token[@"msg"]
          : ([token[@"error_description"] isKindOfClass:NSString.class] ? token[@"error_description"]
             : (e.localizedDescription ?: @"?"));
      [strongSelf logTone3000:[NSString stringWithFormat:@"REFRESH failed: %@ / %@", err, desc]];
      // A value error (not a network problem) means the stored refresh token
      // was rotated server-side ("refresh_token_already_used" / "not_found");
      // keeping it poisons every request with 401. Drop the poisoned session
      // and open a fresh browser login so Connect never dead-ends again.
      if ([err containsString:@"used"] || [err containsString:@"not_found"]
          || [err containsString:@"invalid_grant"] || [err containsString:@"invalid-client"]
          || [err containsString:@"invalid_client"]   // server sends underscore form ("Client does not match the session's OAuth client")
          || [err containsString:@"expired"] || [err containsString:@"invalid_request"]) {
        clearPluginSession();
        dispatch_async(dispatch_get_main_queue(), ^{
          strongSelf.accessToken = nil;
          strongSelf.refreshToken = nil;
          if (allowBrowser) {
            [strongSelf setAuthStatus:@"Session expired — signing you in…" color:NSColor.systemOrangeColor];
            [strongSelf startOAuthLogin];
          } else {
            [strongSelf setAuthStatus:@"Session expired — click Connect to sign in again"
                                color:NSColor.systemRedColor];
          }
        });
        return;
      }
      // Fall back to any NAM Rig tokens we still have.
      NSDictionary* s = pluginSession();
      if (!s) s = namRigSession();
      NSString* fresh = [s[@"accessToken"] isKindOfClass:NSString.class] ? s[@"accessToken"] : nil;
      if (fresh.length) strongSelf.accessToken = fresh;
    }
  }] resume];
}

- (void)reloadLibrary:(id)sender {
  self.status.stringValue = @"Refreshing NAM Rig / Tone3000 cache…";
  __weak ToneBrowserController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ToneBrowserController* strongSelf = weakSelf; if (!strongSelf) return;
    NSMutableArray<ToneItem*>* items = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, ToneItem*>* localByTone = [NSMutableDictionary dictionary];
    NSString* library = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
    NSDirectoryEnumerator* files = [[NSFileManager defaultManager] enumeratorAtPath:library];
    for (NSString* relative in files) {
      if (![relative.lastPathComponent isEqualToString:@"_tone3000.json"]) continue;
      NSString* manifest = [library stringByAppendingPathComponent:relative];
      NSDictionary* root = jsonDictionaryAtPath(manifest);
      NSDictionary* tone = [root[@"tone"] isKindOfClass:NSDictionary.class] ? root[@"tone"] : nil;
      if (!tone) continue;
      NSString* folder = manifest.stringByDeletingLastPathComponent;
      NSMutableArray<NSString*>* models = [NSMutableArray array];
      for (NSDictionary* download in [root[@"downloads"] isKindOfClass:NSArray.class] ? root[@"downloads"] : @[]) {
        NSString* filename = [download[@"local_filename"] isKindOfClass:NSString.class] ? download[@"local_filename"] : nil;
        if (!filename) continue;
        NSString* path = [folder stringByAppendingPathComponent:filename];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [models addObject:path];
      }
      NSDate* date = [[[NSFileManager defaultManager] attributesOfItemAtPath:manifest error:nil]
                      fileModificationDate];
      ToneItem* item = toneItem(tone, models, date);
      if (item) {
        ToneItem *existing = localByTone[@(item.toneId)];
        if (existing) {
          // Same tone found in another folder — merge models into the existing item.
          NSMutableArray *merged = [existing.models mutableCopy];
          for (NSString *m in item.models) {
            if (![merged containsObject:m]) [merged addObject:m];
          }
          existing.models = merged;
        } else {
          [items addObject:item];
          localByTone[@(item.toneId)] = item;
        }
      }
    }

    // NAM Rig's URL cache contains Browse/Favorites tone metadata. Reuse the
    // public metadata while leaving NAM Rig's OAuth credentials untouched.
    NSString* cache = [@"~/Library/Caches/com.nouratone.namrig/fsCachedData" stringByExpandingTildeInPath];
    for (NSString* name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cache error:nil]) {
      NSDictionary* page = jsonDictionaryAtPath([cache stringByAppendingPathComponent:name]);
      NSArray* data = [page[@"data"] isKindOfClass:NSArray.class] ? page[@"data"] : nil;
      if (!data || ![data.firstObject isKindOfClass:NSDictionary.class]) continue;
      for (NSDictionary* tone in data) {
        if (![tone[@"title"] isKindOfClass:NSString.class] || ![tone[@"gear"] isKindOfClass:NSString.class]) continue;
        NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
        if (!key) continue;
        ToneItem* local = localByTone[key];
        const BOOL favorite = [tone[@"is_favorite"] respondsToSelector:@selector(boolValue)] && [tone[@"is_favorite"] boolValue];
        if (local) { if (favorite) local.favorite = YES; continue; }
        ToneItem* item = toneItem(tone, @[], nil);
        if (item && ![items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ToneItem* x, NSDictionary*) { return x.toneId == item.toneId; }]].count)
          [items addObject:item];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      ToneBrowserController* selfRef = weakSelf; if (!selfRef) return;
      selfRef.allItems = items; [selfRef filterChanged:nil]; [selfRef refreshOnline];
    });
  });
}

- (void)selectMode:(NSButton*)sender {
  self.mode = sender.title;
  for (RigButton* b in self.modeButtons) b.state = (b == sender) ? NSControlStateValueOn : NSControlStateValueOff;
  [self filterChanged:nil];
}
- (void)controlTextDidChange:(NSNotification*)notification { [self filterChanged:nil]; }
- (void)controlTextDidEndEditing:(NSNotification*)notification { if (self.accessToken.length) [self refreshOnline]; }

- (void)filterChanged:(id)sender {
  if (sender) [self persistFilterSelection];
  NSString* query = self.search.stringValue.lowercaseString;
  NSString* gear = self.gear.titleOfSelectedItem;
  NSMutableArray<ToneItem*>* shown = [NSMutableArray array];
  // Browse mode: the search API returns results ALREADY sorted — render
  // searchResults (strict server order, page1→pageN contiguous) first, then
  // locally-known extras (local packs, favorites not in this search). Never
  // re-sort by local fields: a downloaded tone's createdAt is its file's
  // modification date, which would scramble the true server ordering.
  const BOOL browseServerOrder = [self.mode isEqualToString:@"Browse"] && self.searchResults.count > 0;
  if (browseServerOrder) {
    for (ToneItem* item in self.searchResults) {
      if (!gearMatchesFilter(item.gear, gear)) continue;
      NSString* searchable = [NSString stringWithFormat:@"%@ %@ %@", item.title, item.creator, item.gear].lowercaseString;
      if (query.length && [searchable rangeOfString:query].location == NSNotFound) continue;
      [shown addObject:item];
    }
  }
  NSMutableSet<NSNumber*>* emitted = [NSMutableSet set];
  for (ToneItem* item in shown) [emitted addObject:@(item.toneId)];
  for (ToneItem* item in self.allItems) {
    if (browseServerOrder && [emitted containsObject:@(item.toneId)]) continue;   // already shown
    if ([self.mode isEqualToString:@"Favorites"] && !item.favorite) continue;
    if ([self.mode isEqualToString:@"Local"] && !item.local) continue;
    if (!gearMatchesFilter(item.gear, gear)) continue;
    NSString* searchable = [NSString stringWithFormat:@"%@ %@ %@", item.title, item.creator, item.gear].lowercaseString;
    if (query.length && [searchable rangeOfString:query].location == NSNotFound) continue;
    [shown addObject:item];
  }
  if ([self.mode isEqualToString:@"Recent"]) {
    [shown sortUsingComparator:^NSComparisonResult(ToneItem* a, ToneItem* b) { return [b.modified compare:a.modified]; }];
  }
  self.visibleItems = shown;
  [self.collectionView reloadData];
  self.status.stringValue = [NSString stringWithFormat:@"%lu tones • %lu local packs • shared with NAM Rig",
                             (unsigned long)shown.count,
                             (unsigned long)[shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ToneItem* x, NSDictionary*) { return x.local; }]].count];
}

- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)collectionView { return 1; }
- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return self.visibleItems.count; }
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
  ToneCardItem *card = [collectionView makeItemWithIdentifier:@"ToneCard" forIndexPath:indexPath];
  card.representedObject = self.visibleItems[indexPath.item];
  __weak ToneBrowserController *weakSelf = self;
  card.onFavToggle = ^(ToneItem *item) {
    [weakSelf toggleFavoriteFromCard:item];
  };
  return card;
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
  NSIndexPath *path = indexPaths.anyObject;
  if (!path || path.item >= (NSInteger)self.visibleItems.count) return;
  ToneItem *item = self.visibleItems[path.item];
  if (item.local) {
    [self showModelsForItem:item andLoad:YES];
    return;
  }
  self.status.stringValue = @"Getting this tone's models…";
  if (self.accessToken.length) {
    NSInteger selectedToneId = item.toneId;
    __weak ToneBrowserController *weakSelf = self;
    // The /models endpoint is architecture-specific: omitting the param returns
    // NOTHING even when models exist. Default to A2 (the current default), and
    // fall back to A1 legacy if that tone only has A1 models.
    void (^fetch)(NSString*, void (^)(NSArray*)) = ^(NSString *arch, void (^done)(NSArray*)) {
      __strong ToneBrowserController *s = weakSelf;
      if (!s) { done(@[]); return; }
      [s apiGET:[NSString stringWithFormat:@"/models?tone_id=%ld&page=1&page_size=100&architecture=%@", (long)selectedToneId, arch]
          completion:^(NSDictionary *json, NSInteger status, NSError *error) {
        done([json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[]);
      }];
    };
    void (^finish)(NSArray*) = ^(NSArray *data) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ToneBrowserController *strongSelf = weakSelf; if (!strongSelf) return;
        NSIndexPath *current = strongSelf.collectionView.selectionIndexPaths.anyObject;
        if (!current || current.item >= (NSInteger)strongSelf.visibleItems.count || strongSelf.visibleItems[current.item].toneId != selectedToneId) return;
        item.remoteModels = data;
        if (data.count > 0) {
          strongSelf.status.stringValue = [NSString stringWithFormat:@"%lu models — downloading all…", (unsigned long)data.count];
          [strongSelf downloadAllModels:item];
        } else {
          strongSelf.status.stringValue = @"No downloadable models found";
        }
      });
    };
    // A2 + Custom are the default set (merged, deduped by model id). A1 legacy
    // is fetched ONLY when neither A2 nor Custom has any models. Verified
    // against the live API: tone 44691 → arch2=44, arch1=39, arch3=0 rows.
    void (^fetchMaybeA1)(NSArray*, NSArray*) = ^(NSArray *a2, NSArray *custom) {
      if (a2.count == 0 && custom.count == 0) {
        fetch(@"1", ^(NSArray *a1) { finish(a1); });
        return;
      }
      NSMutableArray *merged = [NSMutableArray arrayWithArray:a2];
      for (NSDictionary *m in custom) {
        id mid = m[@"id"];
        BOOL dup = NO;
        for (NSDictionary *e in a2) if (mid && [e[@"id"] isEqual:mid]) { dup = YES; break; }
        if (!dup) [merged addObject:m];
      }
      finish(merged);
    };
    fetch(@"2", ^(NSArray *a2) {
      fetch(@"custom", ^(NSArray *custom) { fetchMaybeA1(a2, custom); });
    });
  } else {
    self.status.stringValue = @"Connect Tone3000 to download models";
  }
}

// Populate the selected stage's tile selector and load the first model.
- (void)showModelsForItem:(ToneItem *)item andLoad:(BOOL)load {
  if (self.state)
    self.state->setStageModels((size_t)item.stage, item.models);
  if (item.models.count > 0) {
    if (load && self.state) {
      self.state->sendPath((size_t)item.stage, item.models.firstObject.fileSystemRepresentation);
      self.state->setStageThumb((size_t)item.stage, item.artworkPath, item.toneId, item.imageURL);
      self.status.stringValue = [NSString stringWithFormat:@"%lu models — loaded", (unsigned long)item.models.count];
    }
  }
}

// Downloads EVERY model of a tone into one folder (one card = one folder =
// one _tone3000.json whose downloads[] fills the tile's model dropdown),
// mirroring NAM Rig's layout. Sequential (one request at a time) to stay
// server-friendly. Self-healing: files already on disk with the right size
// are skipped, so re-selecting a tone only fetches missing models — and
// folders created by the old first-model-only build get topped up here.
- (void)downloadAllModels:(ToneItem*)item {
  if (!self.accessToken.length || item.remoteModels.count == 0) return;
  NSString* category;
  if (item.stage == 0) category = @"Pedal";
  else if (item.stage == 2) category = @"Cab";
  else if ([item.gear.lowercaseString isEqualToString:@"amp-cab"] || [item.gear.lowercaseString isEqualToString:@"full-rig"])
    category = @"Full Rig";   // NAM Rig's library layout: full rigs get their own folder
  else category = @"Amp";
  NSString* folder = [[[[[@"~/Music/Tone3000 Library" stringByExpandingTildeInPath]
                        stringByAppendingPathComponent:category]
                       stringByAppendingPathComponent:@"NAM Oversampled Rig"]
                      stringByAppendingPathComponent:safeFilename(item.title)] copy];
  NSFileManager* fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableArray<NSDictionary*>* downloads = [NSMutableArray array];
  NSDictionary* old = jsonDictionaryAtPath([folder stringByAppendingPathComponent:@"_tone3000.json"]);
  for (NSDictionary* d in [old[@"downloads"] isKindOfClass:NSArray.class] ? old[@"downloads"] : @[])
    if ([d isKindOfClass:NSDictionary.class]) [downloads addObject:d];
  [self downloadModelStep:0 of:item.remoteModels item:item folder:folder downloads:downloads];
}

// One step of the sequential downloader: process models[index], then recurse.
- (void)downloadModelStep:(NSInteger)index
                       of:(NSArray*)models
                     item:(ToneItem*)item
                   folder:(NSString*)folder
                downloads:(NSMutableArray<NSDictionary*>*)downloads {
  if (index >= (NSInteger)models.count) {
    [self finishModelDownload:item folder:folder downloads:downloads];
    return;
  }
  NSFileManager* fm = [NSFileManager defaultManager];
  NSDictionary* model = models[index];
  NSString* name = [model[@"name"] isKindOfClass:NSString.class] ? model[@"name"] : @"Tone3000 Model";
  NSString* ext = [model[@"model_url"] isKindOfClass:NSString.class] && [model[@"model_url"] pathExtension].length
      ? [model[@"model_url"] pathExtension] : (item.stage == 2 ? @"wav" : @"nam");
  NSString* filename = [safeFilename(name) stringByAppendingPathExtension:ext];
  NSString* path = [folder stringByAppendingPathComponent:filename];
  self.status.stringValue = [NSString stringWithFormat:@"Downloading model %ld of %ld — %@",
                            (long)index + 1, (long)models.count, name];
  // Self-heal skip: already on disk at the expected size → just record it.
  NSDictionary* existing = nil;
  for (NSDictionary* d in downloads)
    if ([d[@"local_filename"] isKindOfClass:NSString.class] && [d[@"local_filename"] isEqualToString:filename]) { existing = d; break; }
  NSUInteger expected = [model[@"size"] respondsToSelector:@selector(longLongValue)] ? [model[@"size"] longLongValue] : 0;
  if (existing && [fm fileExistsAtPath:path]) {
    NSDictionary* attr = [fm attributesOfItemAtPath:path error:nil];
    if (!expected || [attr fileSize] == expected) {
      [self downloadModelStep:index + 1 of:models item:item folder:folder downloads:downloads];
      return;
    }
  }
  NSString* urlString = [model[@"model_url"] isKindOfClass:NSString.class] ? model[@"model_url"] : nil;
  if (!urlString.length) {
    [self downloadModelStep:index + 1 of:models item:item folder:folder downloads:downloads];
    return;
  }
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
  [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];
  __weak ToneBrowserController* weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger code = [(NSHTTPURLResponse*)response statusCode];
    dispatch_async(dispatch_get_main_queue(), ^{
      ToneBrowserController* s = weakSelf; if (!s) return;
      if (data.length && code >= 200 && code < 300) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        NSDictionary* download = @{@"model_id": model[@"id"] ?: @0, @"original_model": model,
                                   @"local_filename": filename, @"bytes": @(data.length),
                                   @"status": @"downloaded", @"downloaded_at": [[NSDate date] description]};
        if (existing) [downloads removeObjectIdenticalTo:existing];
        [downloads addObject:download];
      } else {
        [s logTone3000:[NSString stringWithFormat:@"MODEL DOWNLOAD FAILED (%@, HTTP %ld): %@",
                        name, (long)code, error.localizedDescription ?: @"none"]];
      }
      [s downloadModelStep:index + 1 of:models item:item folder:folder downloads:downloads];
    });
  }] resume];
}

// All models processed: write the complete manifest (schema matches NAM
// Rig's exactly, so reloadLibrary merges it like any NAM Rig pack) and
// populate the stage tile with every downloaded file.
- (void)finishModelDownload:(ToneItem*)item folder:(NSString*)folder downloads:(NSMutableArray<NSDictionary*>*)downloads {
  NSDictionary* manifest = @{@"powered_by": @"Tone3000", @"tone": item.toneData ?: @{}, @"downloads": downloads};
  NSData* json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
  [json writeToFile:[folder stringByAppendingPathComponent:@"_tone3000.json"] options:NSDataWritingAtomic error:nil];
  NSFileManager* fm = [NSFileManager defaultManager];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (NSDictionary* d in downloads) {
    NSString* p = [folder stringByAppendingPathComponent:d[@"local_filename"]];
    if (p.length && [fm fileExistsAtPath:p]) [paths addObject:p];
  }
  item.models = paths; item.local = YES;
  self.status.stringValue = [NSString stringWithFormat:@"%ld models ready — %@", (long)paths.count, item.title];
  if (self.state) {
    self.state->setStageModels((size_t)item.stage, item.models);
    if (paths.count) {
      self.state->sendPath((size_t)item.stage, paths.firstObject.fileSystemRepresentation);
      self.state->setStageThumb((size_t)item.stage, item.artworkPath, item.toneId, item.imageURL);
    }
  }
}

@end
