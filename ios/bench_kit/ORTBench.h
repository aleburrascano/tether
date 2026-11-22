#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Speed + correctness test of the REAL-TSE voice filter on this phone.
/// Runs the same 98 live-sized chunks (40 ms each) that were run on the Mac, with the model's memory carried
/// from chunk to chunk exactly like the live app, and compares the output with the Mac's.
@interface ORTBench : NSObject
/// model: "chunk_int8" or "chunk"; provider: "cpu" or "coreml_ane" / "coreml_all" / "coreml_gpu"
/// Returns one line of results (or an error line). Blocking; call off the main thread.
+ (NSString *)runModel:(NSString *)model provider:(NSString *)provider threads:(int)threads;
/// Streams the test clip through the app's own filter code (TSE) in 40 ms pieces and compares with the Mac's output.
+ (NSString *)streamCheck;
@end

NS_ASSUME_NONNULL_END
