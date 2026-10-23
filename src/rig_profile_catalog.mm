// RigProfileCatalog — Discovers and categorizes local profiles (Amps, Pedals, Cabs)
// into a clean 3-tier hierarchy: Brand > Specific Model > all .nam captures.
#import "rig_profile_catalog.h"
#import <Cocoa/Cocoa.h>

@interface RigLibraryModelEntry : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* fullPath;
@property(nonatomic, copy) NSString* packName;
@end

@implementation RigLibraryModelEntry
@end

@interface RigLibraryProfilePack : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* folderPath;
@property(nonatomic, strong) NSMutableArray<RigLibraryModelEntry*>* models;
@end

@implementation RigLibraryProfilePack
- (instancetype)init {
  if (self = [super init]) {
    _models = [NSMutableArray array];
  }
  return self;
}
@end

@interface RigProfileCatalog () {
  NSMutableDictionary<NSNumber*, NSDate*>* _lastScannedDates;
  NSMutableDictionary<NSNumber*, NSDictionary<NSString*, NSDictionary<NSString*, NSMutableArray<RigLibraryProfilePack*>*>*>*>* _cachedCatalogs;
}
@end

@implementation RigProfileCatalog

+ (instancetype)sharedCatalog {
  static RigProfileCatalog* sInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sInstance = [[RigProfileCatalog alloc] init];
  });
  return sInstance;
}

- (instancetype)init {
  if (self = [super init]) {
    _lastScannedDates = [NSMutableDictionary dictionary];
    _cachedCatalogs = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)invalidateCache {
  @synchronized(self) {
    [_lastScannedDates removeAllObjects];
    [_cachedCatalogs removeAllObjects];
  }
}

static NSString* libraryDirectoryForStage(size_t stage) {
  NSString* base = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
  if (stage == 0) return [base stringByAppendingPathComponent:@"Pedal"];
  if (stage == 1) return [base stringByAppendingPathComponent:@"Amp"];
  return [base stringByAppendingPathComponent:@"Cab"];
}

#pragma mark - Classification Rules

struct BrandRule {
  const char* brandName;
  const char* keywords[16];
};

static const BrandRule sBrandRules[] = {
  {"Mesa Boogie", {"mesa boogie", "mesa/boogie", "mesa", "rectifier", "recto", "badlander", "mark iv", "mark v", "mark iii", "mark vii", NULL}},
  {"Marshall", {"marshall", "jcm800", "jcm900", "jcm2000", "jcm", "plexi", "valvestate", "silver jubilee", "1960", NULL}},
  {"Bogner", {"bogner", "ecstasy", "uberschall", "shiva", "helena", NULL}},
  {"Peavey / EVH", {"peavey", "evh", "5150", "6505", "van halen", "block letter", NULL}},
  {"Orange", {"orange", "dark terror", "dual terror", "jim root terror", "rockerverb", "dual dark", "thunderverb", "ppc412", NULL}},
  {"ENGL", {"engl", "fireball", "powerball", "ironball", "savage", "inferno", "e650", "e670", NULL}},
  {"Blackstar", {"blackstar", "artisan", "series one", "st. james", "st james", "ht-100", "tv-10", NULL}},
  {"Diezel", {"diezel", "vh4", "herbert", "einstein", "hagen", NULL}},
  {"Soldano", {"soldano", "slo100", "slo-100", "slo 100", "slo30", "slo-30", "super lead overdrive", NULL}},
  {"Fortin", {"fortin", "natas", "cali", "evil pumpkin", "meshuggah", "fourteen", "roan", NULL}},
  {"Friedman", {"friedman", "be-100", "be100", "hbe", "brown eye", "dirty shirley", "jj-100", "butterslax", NULL}},
  {"Dumble / Two-Rock", {"dumble", "two-rock", "two rock", "steel string singer", "vibroverb", "overdrive special", NULL}},
  {"Fender", {"fender", "twin reverb", "deluxe reverb", "bassman", "princeton", "bandmaster", "super reverb", NULL}},
  {"Vox", {"vox", "ac30", "ac15", "top boost", NULL}},
  {"Boss", {"boss", "sd-1", "ds-1", "bd-2", "hm-2", "mt-2", "katana", "waza", NULL}},
  {"Ibanez", {"ibanez", "ts808", "ts9", "ts10", "tube screamer", "tubescreamer", NULL}},
  {"Revv", {"revv", "generator", "g20", "d20", NULL}},
  {"VHT / Fryette", {"vht", "fryette", "sigx", "sig-x", "deliverance", "pittbull", NULL}},
  {"PRS", {"prs", "archon", "mt15", "tremonti", "hdrx", NULL}},
  {"Randall", {"randall", "satan", "warhead", "rh150", "rg100", "century", NULL}},
  {"Ceriatone", {"ceriatone", "molecular", "chupacabra", "king kong", "yeti", "ots", NULL}},
  {"Rivera", {"rivera", "knucklehead", "m100", NULL}},
  {"Victory", {"victory", "kraken", "super kraken", "sheriff", "jack", "copper", NULL}},
  {"Laney", {"laney", "ironheart", "gh100", "supergroup", "lead top", NULL}},
  {"Hughes & Kettner", {"hughes & kettner", "hughes and kettner", "tubemeister", "triamp", "grandmeister", NULL}},
  {"Krank", {"krank", "krankenstein", "revolution", NULL}},
  {"Gallien Krueger", {"gallien krueger", "gallien-krueger", "rb800", "800rb", NULL}},
  {"Matchless", {"matchless", "dc30", "dc-30", "chieftain", "spitfire", NULL}},
  {"Bad Cat", {"bad cat", "badcat", "hot cat", "lynx", NULL}},
  {"Celestion", {"celestion", "vintage 30", "greenback", "creamback", "g12t", NULL}},
  {"Yerasov", {"yerasov", "detonator", NULL}},
  {NULL, {NULL}}
};

struct SpecificModelRule {
  const char* brandName;
  const char* modelName;
  const char* keywords[8];
};

// Priority order: more specific sub-models (e.g. Powerball II, Triple Rectifier) BEFORE broad roots.
static const SpecificModelRule sSpecificModelRules[] = {
  // ENGL
  {"ENGL", "Powerball II", {"powerball ii", "powerball 2", "pbii", "pb2", NULL}},
  {"ENGL", "Powerball", {"powerball", NULL}},
  {"ENGL", "Fireball 25 KT77", {"fireball.*kt77", "kt77", NULL}},
  {"ENGL", "Fireball 25", {"fireball 25", "fireball", NULL}},
  {"ENGL", "Ironball", {"ironball", NULL}},
  {"ENGL", "Savage 120 MKII", {"savage.*mkii", "savage.*mk2", NULL}},
  {"ENGL", "Savage 120", {"savage 120", "savage", NULL}},
  {"ENGL", "Special Edition E670", {"e670", "se 670", "special edition", NULL}},
  {"ENGL", "Inferno", {"inferno", NULL}},
  {"ENGL", "Thunder 50", {"thunder 50", "thunder", NULL}},
  {"ENGL", "E650 Blackmore", {"e650", "blackmore", NULL}},
  {"ENGL", "Sovereign 100", {"sovereign", NULL}},

  // Mesa Boogie
  {"Mesa Boogie", "Triple Rectifier", {"triple rectifier", "triple recto", "triple", NULL}},
  {"Mesa Boogie", "Dual Rectifier", {"dual rectifier", "dual recto", "rev g", "revision g", "rectifier", "recto", NULL}},
  {"Mesa Boogie", "Badlander Rectifier", {"badlander", NULL}},
  {"Mesa Boogie", "Road King", {"road king", NULL}},
  {"Mesa Boogie", "Mark III", {"mark iii", "mark 3", "mk3", "mkiii", NULL}},
  {"Mesa Boogie", "Mark IV", {"mark iv", "mark 4", "mk4", "mkiv", NULL}},
  {"Mesa Boogie", "Mark V", {"mark v", "mark 5", "mkv", NULL}},
  {"Mesa Boogie", "Mark VII", {"mark vii", "mark 7", "mkvii", NULL}},
  {"Mesa Boogie", "Lone Star", {"lone star", "lonestar", NULL}},

  // Bogner
  {"Bogner", "Ecstasy 101B", {"ecstasy 101b", "101b", NULL}},
  {"Bogner", "Ecstasy (Synergy)", {"ecstasy.*synergy", "synergy.*ecstasy", "synergy", NULL}},
  {"Bogner", "Ecstasy", {"ecstasy", NULL}},
  {"Bogner", "Uberschall Rev Blue", {"uberschall.*rev blue", "rev blue", "berschall rev blue", NULL}},
  {"Bogner", "Uberschall", {"uberschall", NULL}},
  {"Bogner", "Shiva", {"shiva", NULL}},

  // Peavey / EVH
  {"Peavey / EVH", "5150 Block Letter", {"5150.*block", "block letter", NULL}},
  {"Peavey / EVH", "5150 / 6505 Original", {"5150.*original", "6505.*1992", "6505 original", NULL}},
  {"Peavey / EVH", "5150 II / 6505+", {"5150 ii", "5150 2", "6505+", "6505 plus", NULL}},
  {"Peavey / EVH", "EVH 5150 III Stealth", {"5150.*iii.*stealth", "5150.*stealth", NULL}},
  {"Peavey / EVH", "EVH 5150 III", {"5150.*iii", "5150.*3", "gone with the wind", NULL}},
  {"Peavey / EVH", "5150 / 6505 Series", {"5150", "6505", NULL}},

  // Orange
  {"Orange", "Dark Terror", {"dark terror", NULL}},
  {"Orange", "Dual Dark 50", {"dual dark", NULL}},
  {"Orange", "Dual Terror", {"dual terror", NULL}},
  {"Orange", "Jim Root Terror", {"jim root", NULL}},
  {"Orange", "Tiny Terror", {"tiny terror", NULL}},
  {"Orange", "Terror Series", {"terror", NULL}},
  {"Orange", "Rockerverb 50", {"rockerverb 50", "rv50", NULL}},
  {"Orange", "Rockerverb 100 / MKIII", {"rockerverb 100", "rockerverb.*mk3", "rockerverb.*mkiii", "rockerverb", NULL}},
  {"Orange", "Thunderverb 50", {"thunderverb", NULL}},
  {"Orange", "OR15 / OR50", {"or15", "or50", "or60", NULL}},

  // Diezel
  {"Diezel", "VH4", {"vh4", NULL}},
  {"Diezel", "Herbert", {"herbert", NULL}},
  {"Diezel", "Einstein", {"einstein", NULL}},
  {"Diezel", "Hagen", {"hagen", NULL}},

  // Soldano
  {"Soldano", "SLO-100", {"slo100", "slo-100", "slo 100", NULL}},
  {"Soldano", "SLO-30", {"slo30", "slo-30", "slo 30", NULL}},

  // Marshall
  {"Marshall", "JCM 800 (Zakk Wylde)", {"zakk wylde", NULL}},
  {"Marshall", "JCM 800", {"jcm800", "jcm 800", "2203", "2204", NULL}},
  {"Marshall", "JCM 900", {"jcm900", "jcm 900", NULL}},
  {"Marshall", "JCM 2000 (TSL100)", {"jcm2000", "jcm 2000", "tsl", "dsl", NULL}},
  {"Marshall", "Silver Jubilee", {"silver jubilee", "2555", NULL}},
  {"Marshall", "Valvestate 8100", {"valvestate", "8100", NULL}},
  {"Marshall", "Plexi / Super Lead", {"plexi", "1959", "super lead", NULL}},
  {"Marshall", "JTM 45", {"jtm45", "jtm 45", NULL}},
  {"Marshall", "1960 Lead Cab", {"1960", NULL}},

  // Blackstar
  {"Blackstar", "Artisan 100", {"artisan", NULL}},
  {"Blackstar", "Series One 100", {"series one", NULL}},
  {"Blackstar", "St. James 100", {"st. james", "st james", NULL}},
  {"Blackstar", "HT-100 Stage", {"ht-100", "ht 100", NULL}},
  {"Blackstar", "TV-10", {"tv-10", "tv 10", NULL}},

  // Pedals
  {"Ibanez", "TS808 Tube Screamer", {"ts808", "808", NULL}},
  {"Ibanez", "TS9 Tube Screamer", {"ts9", NULL}},
  {"Boss", "SD-1 Super Overdrive", {"sd-1", "super overdrive", NULL}},
  {"Fortin", "Fourteen Overdrive", {"fourteen", NULL}},

  {NULL, NULL, {NULL}}
};

static BOOL textMatchesPattern(NSString* textLower, const char* kw) {
  if (!kw || !kw[0]) return NO;
  NSString* kwStr = [NSString stringWithUTF8String:kw];
  // Regex match with word boundaries
  NSString* pattern = [NSString stringWithFormat:@"\\b%@\\b", kwStr];
  NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:nil];
  if (re) {
    NSRange match = [re rangeOfFirstMatchInString:textLower options:0 range:NSMakeRange(0, textLower.length)];
    return match.location != NSNotFound;
  }
  return [textLower containsString:kwStr.lowercaseString];
}

static NSString* detectBrandInCorpus(NSString* text) {
  if (!text.length) return nil;
  NSString* lower = text.lowercaseString;
  for (size_t i = 0; sBrandRules[i].brandName != NULL; ++i) {
    for (size_t k = 0; sBrandRules[i].keywords[k] != NULL; ++k) {
      if (textMatchesPattern(lower, sBrandRules[i].keywords[k])) {
        return [NSString stringWithUTF8String:sBrandRules[i].brandName];
      }
    }
  }
  return nil;
}

static NSString* detectSpecificModel(NSString* brand, NSString* text) {
  if (!brand.length || !text.length) return nil;
  NSString* lower = text.lowercaseString;
  for (size_t i = 0; sSpecificModelRules[i].brandName != NULL; ++i) {
    if ([brand isEqualToString:[NSString stringWithUTF8String:sSpecificModelRules[i].brandName]]) {
      for (size_t k = 0; sSpecificModelRules[i].keywords[k] != NULL; ++k) {
        if (textMatchesPattern(lower, sSpecificModelRules[i].keywords[k])) {
          return [NSString stringWithUTF8String:sSpecificModelRules[i].modelName];
        }
      }
    }
  }
  return nil;
}

static NSString* fallbackCleanModelName(NSString* name) {
  NSString* c = name;
  // Strip common brand words
  c = [c stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  NSRegularExpression* stripRe = [NSRegularExpression regularExpressionWithPattern:
      @"(?i)\\b(engl|mesa boogie|mesa/boogie|mesa|marshall|bogner|peavey|evh|orange|diezel|soldano|fortin|blackstar|friedman|two-rock|dumble|head|amp head|combo|community pack|gain pack|pack|full gain pack|edition|2025|summer of.*|signalart reamp|\\(6l6\\)|\\(e34l\\)|\\(0\\.5\\.2\\)|teaser|signature)\\b"
      options:0 error:nil];
  if (stripRe) {
    c = [stripRe stringByReplacingMatchesInString:c options:0 range:NSMakeRange(0, c.length) withTemplate:@""];
  }
  NSRegularExpression* bracketRe = [NSRegularExpression regularExpressionWithPattern:@"\\[.*?\\]|\\(.*?\\)" options:0 error:nil];
  if (bracketRe) {
    c = [bracketRe stringByReplacingMatchesInString:c options:0 range:NSMakeRange(0, c.length) withTemplate:@""];
  }
  c = [c stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" -–—:.,_"]];
  return (c.length >= 2) ? c : @"Standard";
}

static void classifyProfileIntoBrandAndModel(NSString* folderName,
                                             NSArray<NSString*>* makes,
                                             NSArray<NSString*>* tags,
                                             NSString* desc,
                                             NSString** outBrand,
                                             NSString** outModel) {
  NSString* normFolder = [folderName stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  NSString* textCorpus = [NSString stringWithFormat:@"%@ %@ %@",
                          normFolder,
                          [makes componentsJoinedByString:@" "],
                          [tags componentsJoinedByString:@" "]];

  // 1. Detect Brand
  NSString* b = detectBrandInCorpus(textCorpus);
  if (!b && desc.length > 0) {
    b = detectBrandInCorpus([desc substringToIndex:MIN(desc.length, (NSUInteger)300)]);
  }
  if (!b) b = @"Other";

  // 2. Detect Specific Model
  NSString* m = detectSpecificModel(b, textCorpus);
  if (!m) {
    m = fallbackCleanModelName(normFolder);
  }

  *outBrand = b;
  *outModel = m;
}

#pragma mark - Scanning Library

static NSString* cleanModelName(NSString* filename) {
  NSString* fn = [filename stringByDeletingPathExtension];
  if ([fn hasPrefix:@"preview_"]) {
    NSArray<NSString*>* parts = [fn componentsSeparatedByString:@"_"];
    if (parts.count >= 4) {
      NSRange first = [fn rangeOfString:@"_"];
      NSRange second = [fn rangeOfString:@"_" options:0 range:NSMakeRange(NSMaxRange(first), fn.length - NSMaxRange(first))];
      if (second.location != NSNotFound) {
        NSRange third = [fn rangeOfString:@"_" options:0 range:NSMakeRange(NSMaxRange(second), fn.length - NSMaxRange(second))];
        if (third.location != NSNotFound && NSMaxRange(third) < fn.length) {
          fn = [fn substringFromIndex:NSMaxRange(third)];
        }
      }
    }
  }
  return fn;
}

- (NSDictionary<NSString*, NSDictionary<NSString*, NSMutableArray<RigLibraryProfilePack*>*>*>*)catalogForStage:(size_t)stage {
  size_t effectiveCategoryStage = (stage == 3) ? 2 : stage;
  NSString* dir = libraryDirectoryForStage(effectiveCategoryStage);
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:dir]) return @{};

  NSDictionary* dirAttrs = [fm attributesOfItemAtPath:dir error:nil];
  NSDate* modDate = dirAttrs.fileModificationDate ?: [NSDate date];

  @synchronized(self) {
    NSDate* last = _lastScannedDates[@(effectiveCategoryStage)];
    if (last && [last isEqualToDate:modDate] && _cachedCatalogs[@(effectiveCategoryStage)]) {
      return _cachedCatalogs[@(effectiveCategoryStage)];
    }
  }

  // Brand -> Specific Model -> Array of RigLibraryProfilePack
  NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSMutableArray<RigLibraryProfilePack*>*>*>* tree =
      [NSMutableDictionary dictionary];

  NSArray<NSString*>* entries = [fm contentsOfDirectoryAtPath:dir error:nil];
  NSSet* allowedExts = (effectiveCategoryStage == 2)
      ? [NSSet setWithObjects:@"wav", @"nam", @"nammodel", @"aidax", @"aidadspmodel", nil]
      : [NSSet setWithObjects:@"nam", @"nammodel", @"aidax", @"aidadspmodel", nil];

  for (NSString* entry in entries) {
    if ([entry hasPrefix:@"."] || [entry hasPrefix:@"_"]) continue;
    NSString* fullPath = [dir stringByAppendingPathComponent:entry];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) continue;

    if (isDir) {
      NSString* manifest = [fullPath stringByAppendingPathComponent:@"_tone3000.json"];
      NSMutableArray<NSString*>* makes = [NSMutableArray array];
      NSMutableArray<NSString*>* tags = [NSMutableArray array];
      NSString* desc = @"";
      NSString* title = entry;

      if ([fm fileExistsAtPath:manifest]) {
        NSData* data = [NSData dataWithContentsOfFile:manifest];
        if (data) {
          id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary* tone = json[@"tone"];
            if ([tone isKindOfClass:[NSDictionary class]]) {
              if ([tone[@"title"] isKindOfClass:[NSString class]]) title = tone[@"title"];
              if ([tone[@"description"] isKindOfClass:[NSString class]]) desc = tone[@"description"];
              for (id m in [tone[@"makes"] isKindOfClass:[NSArray class]] ? tone[@"makes"] : @[]) {
                if ([m isKindOfClass:[NSDictionary class]] && [m[@"name"] isKindOfClass:[NSString class]])
                  [makes addObject:m[@"name"]];
              }
              for (id t in [tone[@"tags"] isKindOfClass:[NSArray class]] ? tone[@"tags"] : @[]) {
                if ([t isKindOfClass:[NSDictionary class]] && [t[@"name"] isKindOfClass:[NSString class]])
                  [tags addObject:t[@"name"]];
              }
            }
          }
        }
      }

      NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:fullPath error:nil];
      NSMutableArray<RigLibraryModelEntry*>* modelEntries = [NSMutableArray array];

      for (NSString* f in files) {
        if ([f hasPrefix:@"."] || [f hasPrefix:@"_"]) continue;
        NSString* ext = f.pathExtension.lowercaseString;
        if ([allowedExts containsObject:ext]) {
          RigLibraryModelEntry* me = [[RigLibraryModelEntry alloc] init];
          me.title = cleanModelName(f);
          me.fullPath = [fullPath stringByAppendingPathComponent:f];
          me.packName = title;
          [modelEntries addObject:me];
        }
      }

      if (modelEntries.count == 0) continue;

      [modelEntries sortUsingComparator:^NSComparisonResult(RigLibraryModelEntry* a, RigLibraryModelEntry* b) {
        return [a.title localizedCaseInsensitiveCompare:b.title];
      }];

      if (makes.count == 0 && modelEntries.count > 0) {
        NSString* firstModel = modelEntries.firstObject.fullPath;
        if ([firstModel.pathExtension.lowercaseString hasPrefix:@"nam"]) {
          NSData* mData = [NSData dataWithContentsOfFile:firstModel options:NSDataReadingMappedIfSafe error:nil];
          if (mData) {
            id mJson = [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil];
            if ([mJson isKindOfClass:[NSDictionary class]] && [mJson[@"metadata"] isKindOfClass:[NSDictionary class]]) {
              NSDictionary* meta = mJson[@"metadata"];
              if ([meta[@"gear_make"] isKindOfClass:[NSString class]]) [makes addObject:meta[@"gear_make"]];
              if ([meta[@"gear_model"] isKindOfClass:[NSString class]]) [makes addObject:meta[@"gear_model"]];
            }
          }
        }
      }

      NSString* brand = nil;
      NSString* specificModel = nil;
      classifyProfileIntoBrandAndModel(title, makes, tags, desc, &brand, &specificModel);

      RigLibraryProfilePack* pack = [[RigLibraryProfilePack alloc] init];
      pack.name = title;
      pack.folderPath = fullPath;
      pack.models = modelEntries;

      if (!tree[brand]) tree[brand] = [NSMutableDictionary dictionary];
      if (!tree[brand][specificModel]) tree[brand][specificModel] = [NSMutableArray array];
      [tree[brand][specificModel] addObject:pack];
    } else {
      // Loose model file in the category directory
      NSString* ext = entry.pathExtension.lowercaseString;
      if (![allowedExts containsObject:ext]) continue;

      NSMutableArray<NSString*>* makes = [NSMutableArray array];
      if ([ext hasPrefix:@"nam"]) {
        NSData* mData = [NSData dataWithContentsOfFile:fullPath options:NSDataReadingMappedIfSafe error:nil];
        if (mData) {
          id mJson = [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil];
          if ([mJson isKindOfClass:[NSDictionary class]] && [mJson[@"metadata"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary* meta = mJson[@"metadata"];
            if ([meta[@"gear_make"] isKindOfClass:[NSString class]]) [makes addObject:meta[@"gear_make"]];
            if ([meta[@"gear_model"] isKindOfClass:[NSString class]]) [makes addObject:meta[@"gear_model"]];
          }
        }
      }

      NSString* brand = nil;
      NSString* specificModel = nil;
      classifyProfileIntoBrandAndModel(entry, makes, @[], @"", &brand, &specificModel);

      RigLibraryModelEntry* me = [[RigLibraryModelEntry alloc] init];
      me.title = cleanModelName(entry);
      me.fullPath = fullPath;
      me.packName = me.title;

      RigLibraryProfilePack* pack = [[RigLibraryProfilePack alloc] init];
      pack.name = me.title;
      pack.folderPath = dir;
      [pack.models addObject:me];

      if (!tree[brand]) tree[brand] = [NSMutableDictionary dictionary];
      if (!tree[brand][specificModel]) tree[brand][specificModel] = [NSMutableArray array];
      [tree[brand][specificModel] addObject:pack];
    }
  }

  @synchronized(self) {
    _lastScannedDates[@(effectiveCategoryStage)] = modDate;
    _cachedCatalogs[@(effectiveCategoryStage)] = [tree copy];
  }

  return tree;
}

#pragma mark - Menu Construction (Direct 3-Tier Hierarchy: Brand > Specific Model > .nam files)

- (NSMenu*)buildLibraryMenuForStage:(size_t)stage
                             target:(id)target
                             action:(SEL)action
                        currentPath:(nullable NSString*)currentPath {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Library Profiles"];
  NSDictionary* tree = [self catalogForStage:stage];
  if (tree.count == 0) {
    NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"No Downloaded Profiles in Library" action:NULL keyEquivalent:@""];
    empty.enabled = NO;
    [menu addItem:empty];
    return menu;
  }

  NSArray<NSString*>* sortedBrands = [tree.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  if ([sortedBrands containsObject:@"Other"]) {
    NSMutableArray* reordered = [sortedBrands mutableCopy];
    [reordered removeObject:@"Other"];
    [reordered addObject:@"Other"];
    sortedBrands = reordered;
  }

  for (NSString* brandName in sortedBrands) {
    NSDictionary<NSString*, NSMutableArray<RigLibraryProfilePack*>*>* models = tree[brandName];
    if (models.count == 0) continue;

    NSMenuItem* brandItem = [[NSMenuItem alloc] initWithTitle:brandName action:NULL keyEquivalent:@""];
    NSMenu* brandSubmenu = [[NSMenu alloc] initWithTitle:brandName];
    brandItem.submenu = brandSubmenu;
    [menu addItem:brandItem];

    NSArray<NSString*>* sortedModels = [models.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    for (NSString* modelName in sortedModels) {
      NSArray<RigLibraryProfilePack*>* packs = models[modelName];
      if (packs.count == 0) continue;

      NSMenuItem* modelItem = [[NSMenuItem alloc] initWithTitle:modelName action:NULL keyEquivalent:@""];
      NSMenu* modelSubmenu = [[NSMenu alloc] initWithTitle:modelName];
      modelItem.submenu = modelSubmenu;
      [brandSubmenu addItem:modelItem];

      const BOOL multiplePacks = (packs.count > 1);

      for (NSUInteger pIdx = 0; pIdx < packs.count; ++pIdx) {
        RigLibraryProfilePack* pack = packs[pIdx];
        if (pack.models.count == 0) continue;

        // If multiple profile packs contribute to this model, separate them with a disabled section header
        if (multiplePacks) {
          if (pIdx > 0) {
            [modelSubmenu addItem:[NSMenuItem separatorItem]];
          }
          NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"── %@ ──", pack.name]
                                                          action:NULL keyEquivalent:@""];
          header.enabled = NO;
          [modelSubmenu addItem:header];
        }

        // Add all individual .nam captures directly under this model
        for (RigLibraryModelEntry* me in pack.models) {
          NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:me.title action:action keyEquivalent:@""];
          item.target = target;
          item.action = action;
          item.representedObject = me.fullPath;
          item.tag = (NSInteger)stage;
          if (currentPath && [currentPath isEqualToString:me.fullPath]) {
            item.state = NSControlStateValueOn;
            modelItem.state = NSControlStateValueOn;
            brandItem.state = NSControlStateValueOn;
          }
          [modelSubmenu addItem:item];
        }
      }
    }
  }

  return menu;
}

- (nullable NSMenuItem*)stageCardLibraryMenuItemForStage:(size_t)stage
                                                  target:(id)target
                                                  action:(SEL)action
                                             currentPath:(nullable NSString*)currentPath {
  NSString* title;
  if (stage == 0) title = @"Choose Pedal from Library";
  else if (stage == 1) title = @"Choose Amp from Library";
  else if (stage == 2) title = @"Choose Cab A from Library";
  else title = @"Choose Cab B from Library";

  NSMenuItem* rootItem = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
  NSMenu* submenu = [self buildLibraryMenuForStage:stage target:target action:action currentPath:currentPath];
  if (!submenu || submenu.numberOfItems == 0) return nil;
  rootItem.submenu = submenu;
  return rootItem;
}

- (nullable NSMenuItem*)modelPickerLibraryMenuItemForStage:(size_t)stage
                                                    target:(id)target
                                                    action:(SEL)action
                                               currentPath:(nullable NSString*)currentPath {
  NSMenuItem* rootItem = [[NSMenuItem alloc] initWithTitle:@"Browse Local Library" action:NULL keyEquivalent:@""];
  NSMenu* submenu = [self buildLibraryMenuForStage:stage target:target action:action currentPath:currentPath];
  if (!submenu || submenu.numberOfItems == 0) return nil;
  rootItem.submenu = submenu;
  return rootItem;
}

@end
