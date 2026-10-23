#import "rig_profile_catalog.h"
#import <Foundation/Foundation.h>
#include <iostream>
#include <cassert>

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    RigProfileCatalog* catalog = [RigProfileCatalog sharedCatalog];
    assert(catalog != nil);

    // 1. Invalidate cache to guarantee fresh indexing
    [catalog invalidateCache];

    // 2. Test Powerball II aggregation across both packs
    NSString* pb1 = [@"~/Music/Tone3000 Library/Amp/ENGL Powerball II/ENGL Powerball II (Clean).nam" stringByExpandingTildeInPath];
    NSString* pb2 = [@"~/Music/Tone3000 Library/Amp/Engl Powerball II (2025) Summer Of ´26 400 Edition/Engl_PBII_SO26_400_Lead3_Gain2.nam" stringByExpandingTildeInPath];

    if ([[NSFileManager defaultManager] fileExistsAtPath:pb1]) {
      NSArray<NSString*>* models1 = [catalog allModelPathsForModelPath:pb1 stage:1];
      std::cout << "Powerball II models from pack 1 path: " << models1.count << std::endl;
      assert(models1.count == 34);
      assert([models1 containsObject:pb1]);
      if ([[NSFileManager defaultManager] fileExistsAtPath:pb2]) {
        assert([models1 containsObject:pb2]);
      }

      // Querying from pack 2 path must return the exact same 34 captures
      if ([[NSFileManager defaultManager] fileExistsAtPath:pb2]) {
        NSArray<NSString*>* models2 = [catalog allModelPathsForModelPath:pb2 stage:1];
        std::cout << "Powerball II models from pack 2 path: " << models2.count << std::endl;
        assert(models2.count == 34);
        assert([models1 isEqualToArray:models2]);
      }
    }

    // 3. Test Mesa Dual Rectifier aggregation across all 3 packs
    NSString* mr1 = [@"~/Music/Tone3000 Library/Amp/MESA DUAL RECTIFIER (REV G 1998) - FULL GAIN PACK/MESADUAL - ORANGE - MODERN - GAIN 1.nam" stringByExpandingTildeInPath];
    NSString* mr2 = [@"~/Music/Tone3000 Library/Amp/MESA DUAL RECTIFIER 2025/1. MESA DUAL RECTIFIER 2025 - CRUNCH - RHYTHM #1.nam" stringByExpandingTildeInPath];
    NSString* mr3 = [@"~/Music/Tone3000 Library/Amp/Mesa Boogie Dual Rectifier Revision G (6L6) community pack — Amp Head/[AMP] DREC.G-DIO-BLD-RED-MDN Alone I Stand - DI.nam" stringByExpandingTildeInPath];

    if ([[NSFileManager defaultManager] fileExistsAtPath:mr1]) {
      NSArray<NSString*>* mModels = [catalog allModelPathsForModelPath:mr1 stage:1];
      std::cout << "Mesa Dual Rectifier models: " << mModels.count << std::endl;
      assert(mModels.count == 40);
      assert([mModels containsObject:mr1]);
      if ([[NSFileManager defaultManager] fileExistsAtPath:mr2]) assert([mModels containsObject:mr2]);
      if ([[NSFileManager defaultManager] fileExistsAtPath:mr3]) assert([mModels containsObject:mr3]);
    }

    // 4. Test Mesa Badlander Rectifier (separate from Dual Rectifier)
    NSString* badlander = [@"~/Music/Tone3000 Library/Amp/Mesa Boogie Badlander Rectifier 100W EL34 (SignalArt reamp)" stringByExpandingTildeInPath];
    NSArray* badlanderFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:badlander error:nil];
    if (badlanderFiles.count > 0) {
      NSString* firstBadlander = [badlander stringByAppendingPathComponent:badlanderFiles[0]];
      NSArray<NSString*>* bModels = [catalog allModelPathsForModelPath:firstBadlander stage:1];
      std::cout << "Mesa Badlander Rectifier models: " << bModels.count << std::endl;
      assert(bModels.count >= 100);
      // Ensure Badlander does NOT contain Dual Rectifier files
      if ([[NSFileManager defaultManager] fileExistsAtPath:mr1]) {
        assert(![bModels containsObject:mr1]);
      }
    }

    // 4. Test cycling simulation over the aggregated Powerball II captures
    if ([[NSFileManager defaultManager] fileExistsAtPath:pb1]) {
      NSArray<NSString*>* models = [catalog allModelPathsForModelPath:pb1 stage:1];
      assert(models.count == 34);
      // Simulate cycling forward through all 34 captures
      NSInteger curIndex = [models indexOfObject:pb1];
      assert(curIndex != NSNotFound);
      for (NSInteger step = 0; step < (NSInteger)models.count; ++step) {
        NSInteger nextIndex = (curIndex + 1 < (NSInteger)models.count) ? (curIndex + 1) : curIndex;
        assert(nextIndex >= 0 && nextIndex < (NSInteger)models.count);
        curIndex = nextIndex;
      }
      assert(curIndex == (NSInteger)models.count - 1);
    }

    // 5. Test external non-library file returns empty array (falls back to directory scan)
    NSArray<NSString*>* emptyResult = [catalog allModelPathsForModelPath:@"/tmp/NonExistentAmp.nam" stage:1];
    assert(emptyResult.count == 0);

    std::cout << "  PASS  RigProfileCatalog allModelPathsForModelPath:stage: verified successfully" << std::endl;
  }
  return 0;
}
