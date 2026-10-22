#import "rig_tone_api.h"
#include <cstdio>
#include <cassert>

static int failures = 0;
#define CHECK(x) do { if (!(x)) { ++failures; std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); } } while (0)

int main(int argc, char** argv) {
  @autoreleasepool {
    // 1. Empty query check
    Tone3000FetchResult* emptyRes = tone3000FetchBestProfile(@"", 1, nil);
    CHECK(!emptyRes.success);
    CHECK([emptyRes.statusMessage containsString:@"empty"]);

    // 2. Setup mock cache entry for query "rectifier"
    NSString* searchPath = @"/tones/search?sort=downloads-all-time&page=1&page_size=15&query=rectifier";
    NSDictionary* mockSearch = @{
      @"data": @[
        @{
          @"id": @101,
          @"title": @"Legacy Recto",
          @"gear": @"amp",
          @"a1_models_count": @1,
          @"a2_models_count": @0,
          @"downloads_count": @50,
          @"description": @"vintage 90s dual rectifier capture"
        },
        @{
          @"id": @102,
          @"title": @"Modern Dual Rectifier",
          @"gear": @"amp",
          @"a1_models_count": @0,
          @"a2_models_count": @1,
          @"downloads_count": @500,
          @"description": @"modern red channel high gain mesa"
        },
        @{
          @"id": @103,
          @"title": @"Recto 4x12 V30",
          @"gear": @"cab",
          @"a1_models_count": @0,
          @"a2_models_count": @1,
          @"downloads_count": @350,
          @"description": @"mesa rectifier oversized cab IR"
        }
      ],
      @"page": @1,
      @"total_pages": @1
    };
    saveSearchPageForPath(searchPath, mockSearch);

    // Verify cache read
    NSDictionary* cached = cachedSearchPageForPath(searchPath, 60.0);
    CHECK(cached != nil);
    CHECK([cached[@"data"] count] == 3);

    // 3. Test Best Profile Selection for Stage 1 (Amp)
    // Evaluates candidates and selects the modern A2 Rectifier (id 102) over the A1 (id 101)
    Tone3000FetchResult* ampRes = tone3000FetchBestProfile(@"rectifier", 1, @"/tmp/test_tone3000_lib");
    CHECK([ampRes.toneTitle isEqualToString:@"Modern Dual Rectifier"]);
    CHECK(ampRes.downloadsCount == 500);
    if (ampRes.success) {
      CHECK([ampRes.relativePath hasPrefix:@"Amp/Modern Dual Rectifier/"]);
      CHECK([ampRes.modelName length] > 0);
      CHECK([ampRes.architecture isEqualToString:@"2"]);
    } else {
      CHECK([ampRes.statusMessage containsString:@"not signed in"]);
    }

    // 4. Test Best Profile Selection for Stage 2 (Cab)
    // Must select the Cab entry (id 103) rather than amps
    Tone3000FetchResult* cabRes = tone3000FetchBestProfile(@"rectifier", 2, @"/tmp/test_tone3000_lib");
    CHECK([cabRes.toneTitle isEqualToString:@"Recto 4x12 V30"]);
    if (cabRes.success) {
      CHECK([cabRes.relativePath hasPrefix:@"Cab/Recto 4x12 V30/"]);
    }

    std::printf("verify_tone3000_fetch: %d failures\n", failures);
    return failures ? 1 : 0;
  }
}
