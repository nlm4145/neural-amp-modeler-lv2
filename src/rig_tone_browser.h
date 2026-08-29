// Tone Explorer: tone items, browsing/search pagination, cards, buttons.
// Interfaces extracted verbatim from nam_rig_ui.mm (pure move, no behavior
// change) — except `- (void)autoConnect;`, newly declared because the old
// single translation unit made the method visible without a declaration.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

struct RigUIState;
@class RigButton;

@interface ToneItem : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* creator;
@property(nonatomic, copy) NSString* gear;
@property(nonatomic, copy) NSString* toneURL;
@property(nonatomic, copy) NSString* imageURL;
@property(nonatomic, copy) NSString* artworkPath;
@property(nonatomic, strong) NSArray<NSString*>* models;
@property(nonatomic, strong) NSArray<NSDictionary*>* remoteModels;
@property(nonatomic, strong) NSDictionary* toneData;
@property(nonatomic, strong) NSDate* modified;
@property(nonatomic, strong) NSDate* createdAt;
@property(nonatomic) NSInteger downloadsCount;
@property(nonatomic) NSInteger toneId;
@property(nonatomic) NSInteger stage;
@property(nonatomic) BOOL favorite;
@property(nonatomic) BOOL local;
@end

@interface ToneBrowserController : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate>
@property(nonatomic, assign) RigUIState* state;
@property(nonatomic, strong) NSMutableArray<ToneItem*>* allItems;
@property(nonatomic, strong) NSArray<ToneItem*>* visibleItems;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSImage*>* images;
@property(nonatomic, strong) NSCollectionView* collectionView;
@property(nonatomic, strong) NSSearchField* search;
@property(nonatomic, strong) NSPopUpButton* gear;
@property(nonatomic, strong) NSPopUpButton* sort;
@property(nonatomic, strong) NSTextField* status;
@property(nonatomic, strong) NSTextField* authStatus;
@property(nonatomic, strong) RigButton* connectButton;
@property(nonatomic, strong) NSArray<RigButton*>* modeButtons;
@property(nonatomic, copy) NSString* accessToken;
@property(nonatomic, copy) NSString* refreshToken;
@property(nonatomic, copy) NSString* mode;
// Pagination state for the online search. The explorer mirrors tone3000.com:
// the API returns {data, page, page_size, total, total_pages} and a search is
// fetched page-by-page (page_size=100) in server order until exhausted.
@property(nonatomic) NSInteger nextSearchPage;
@property(nonatomic) NSInteger searchTotalPages;
@property(nonatomic) NSInteger searchGeneration;   // bumped on every new search
@property(nonatomic, strong) NSMutableSet<NSNumber*>* searchIds;  // tone ids from the current search
@property(nonatomic, strong) NSMutableArray<ToneItem*>* searchResults;  // current search, strict server order
// One-shot OAuth login state (authorization-code + PKCE via a localhost callback).
@property(nonatomic) BOOL oauthActive;
@property(nonatomic) int oauthPort;
@property(nonatomic, copy) NSString* oauthVerifier;
@property(nonatomic, copy) NSString* oauthState;
@property(nonatomic, strong) NSTimer* oauthTimer;
// Background connect state: startup + the periodic timer only use a valid
// session and silently refresh an expired one — they NEVER open the browser.
// The browser login runs only from the manual Connect button.
// connectIfNeededAllowBrowser: is guarded so startup, the periodic timer and
// manual Connect clicks never stack concurrent attempts.
@property(nonatomic) BOOL connectRequested;
@property(nonatomic) NSInteger oauthLoginAttempts;   // reserved; login is manual-only now
@property(nonatomic, strong) NSTimer* connectTimer;
// Cooldown after a failed login so a re-click can't instantly re-open the
// browser. Manual Connect resets it.
@property(nonatomic) NSTimeInterval loginBackoffUntil;
@property(nonatomic) BOOL refreshingToken;   // guards concurrent refresh calls
// Cooldown after the server rate-limits (429) or WAF-blocks (403) us. While
// active, refreshOnline does nothing so browsing can't escalate the block.
@property(nonatomic) NSTimeInterval rateLimitUntil;
@property(nonatomic) BOOL loadingNextPage;          // one search page in flight
@property(nonatomic, copy) NSString* activeSearchPrefix;  // prefix the current page state belongs to
- (void)loadMoreSearchResults;
- (void)mergeArchPages:(NSDictionary<NSString*, NSDictionary*>*)fetched page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache;
- (void)applySearchPage:(NSDictionary*)json page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache;
- (void)downloadAllModels:(ToneItem*)item;
- (void)downloadModelStep:(NSInteger)index of:(NSArray*)models item:(ToneItem*)item folder:(NSString*)folder downloads:(NSMutableArray<NSDictionary*>*)downloads;
- (void)finishModelDownload:(ToneItem*)item folder:(NSString*)folder downloads:(NSMutableArray<NSDictionary*>*)downloads;
- (void)reloadLibrary:(id)sender;
- (void)selectMode:(NSButton*)sender;
- (void)filterChanged:(id)sender;
- (void)sortChanged:(id)sender;
+ (void)restoreFilterSelectionForGear:(NSPopUpButton*)gear sort:(NSPopUpButton*)sort;
- (void)toggleFavoriteFromCard:(ToneItem*)item;
- (void)connectTone3000:(id)sender;
- (void)connectIfNeeded;
- (void)connectIfNeededAllowBrowser:(BOOL)allowBrowser;
- (void)refreshToneSession;
- (void)refreshToneSessionAllowBrowser:(BOOL)allowBrowser;
- (void)autoConnect;
@end

// Multi-column tone card for the collection-view grid.
@interface ToneCardItem : NSCollectionViewItem
@property(nonatomic, copy) void (^onFavToggle)(ToneItem*);
@end
// A flat, NAM Rig-style rounded button drawn in dark theme. "primary" renders
// with an accent fill; otherwise a dark fill + subtle border. Highlight state
// brightens the fill so the active mode button reads as selected.
@interface RigButton : NSButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL check;
@end
#endif
