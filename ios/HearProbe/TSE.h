#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The voice filter (REAL-TSE, causal, int8 ONNX), streaming at 16 kHz.
/// A port of voxlock's Stream: reflect padding at the start, 512-sample frames every 128 samples, overlap-add
/// with a squared Hann window, output aligned with the input (about 24 ms of lookahead is held back).
@interface TSE : NSObject
- (nullable instancetype)initWithThreads:(int)threads error:(NSString * _Nullable * _Nullable)error;
/// Set whose voice to keep, from exactly 3 s (48000 samples) of them at 16 kHz.
/// resetState = YES for a different person (clears the filter's memory), NO to refine the same person.
- (BOOL)setVoice:(const float *)samples count:(int)count resetState:(BOOL)resetState;
/// Push 16 kHz mic audio; writes the filtered audio that is ready into out (up to capacity), returns how many samples.
- (int)push:(const float *)samples count:(int)count out:(float *)out capacity:(int)capacity;
/// Start a new stream (fresh padding and memory), keeping the voice.
- (void)restart;
@property (readonly) double lastMs;      // compute time of the last push
@property (readonly) BOOL hasVoice;
@end

NS_ASSUME_NONNULL_END
