#import "ORTBench.h"
#import "TSE.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <onnxruntime/coreml_provider_factory.h>
#include <vector>
#include <algorithm>
#include <chrono>
#include <cmath>

static std::vector<float> loadF32(NSString *name) {
    NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:@"f32"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    std::vector<float> v(d.length / sizeof(float));
    memcpy(v.data(), d.bytes, d.length);
    return v;
}

static Ort::Env &env() { static Ort::Env e(ORT_LOGGING_LEVEL_WARNING, "bench"); return e; }

@implementation ORTBench

+ (NSString *)runModel:(NSString *)model provider:(NSString *)provider threads:(int)threads {
    try {
        NSString *dir = [[NSBundle mainBundle] resourcePath];
        std::string enrollPath = [[dir stringByAppendingPathComponent:@"enroll.onnx"] UTF8String];
        std::string chunkPath = [[dir stringByAppendingPathComponent:[model stringByAppendingString:@".onnx"]] UTF8String];

        // enrollment always on CPU (runs once per person, not time-critical)
        Ort::SessionOptions eo; eo.SetIntraOpNumThreads(2);
        Ort::Session enrollS(env(), enrollPath.c_str(), eo);

        Ort::SessionOptions so;
        so.SetIntraOpNumThreads(threads);
        so.AddConfigEntry("session.intra_op.allow_spinning", "0");
        if ([provider hasPrefix:@"coreml"]) {
            std::unordered_map<std::string, std::string> opts;
            opts[kCoremlProviderOption_ModelFormat] = "MLProgram";
            opts[kCoremlProviderOption_MLComputeUnits] =
                [provider isEqualToString:@"coreml_ane"] ? kCoremlProviderOption_MLComputeUnits_CPUAndNeuralEngine :
                [provider isEqualToString:@"coreml_gpu"] ? kCoremlProviderOption_MLComputeUnits_CPUAndGPU :
                                                            kCoremlProviderOption_MLComputeUnits_ALL;
            so.AppendExecutionProvider("CoreML", opts);
        }
        auto tLoad = std::chrono::steady_clock::now();
        Ort::Session chunkS(env(), chunkPath.c_str(), so);
        double loadMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tLoad).count();

        auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<float> enroll = loadF32(@"enroll_16k");
        std::vector<float> mix = loadF32(@"mix_padded_16k");
        std::vector<float> ref = loadF32([model isEqualToString:@"chunk_int8"] ? @"ref_int8_frames" : @"ref_fp32_frames");

        // enrollment -> enroll_n, k, v
        int64_t eShape[2] = {1, (int64_t)enroll.size()};
        Ort::Value eIn = Ort::Value::CreateTensor<float>(mem, enroll.data(), enroll.size(), eShape, 2);
        const char *eInNames[] = {"enroll"};
        const char *eOutNames[] = {"enroll_n", "k", "v"};
        auto eOut = enrollS.Run(Ort::RunOptions{nullptr}, eInNames, &eIn, 1, eOutNames, 3);

        std::vector<float> h(6 * 32 * 256, 0.f), c(6 * 32 * 256, 0.f);
        int64_t hShape[3] = {6, 32, 256};
        const char *inNames[] = {"wav", "enroll_n", "k", "v", "h", "c"};
        const char *outNames[] = {"frames", "h_out", "c_out"};
        const int N = 98, hop = 640, seg = 1024, perCall = 5 * 512;
        std::vector<double> ms;
        double maxDiff = 0, maxRef = 0;
        const int warm = 5;
        for (int pass = 0; pass < 2; pass++) {            // pass 0 = warm-up (first calls compile/cache), pass 1 = timed
            std::fill(h.begin(), h.end(), 0.f); std::fill(c.begin(), c.end(), 0.f);
            for (int i = 0; i < N; i++) {
                int64_t wShape[2] = {1, seg};
                std::vector<Ort::Value> in;
                in.push_back(Ort::Value::CreateTensor<float>(mem, mix.data() + i * hop, seg, wShape, 2));
                for (int j = 0; j < 3; j++) {
                    auto info = eOut[j].GetTensorTypeAndShapeInfo();
                    auto shp = info.GetShape();
                    in.push_back(Ort::Value::CreateTensor<float>(mem, eOut[j].GetTensorMutableData<float>(), info.GetElementCount(), shp.data(), shp.size()));
                }
                in.push_back(Ort::Value::CreateTensor<float>(mem, h.data(), h.size(), hShape, 3));
                in.push_back(Ort::Value::CreateTensor<float>(mem, c.data(), c.size(), hShape, 3));
                auto t0 = std::chrono::steady_clock::now();
                auto out = chunkS.Run(Ort::RunOptions{nullptr}, inNames, in.data(), in.size(), outNames, 3);
                double dt = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
                const float *fr = out[0].GetTensorData<float>();
                memcpy(h.data(), out[1].GetTensorData<float>(), h.size() * 4);
                memcpy(c.data(), out[2].GetTensorData<float>(), c.size() * 4);
                if (pass == 1) {
                    if (i >= warm) ms.push_back(dt);
                    for (int k = 0; k < perCall; k++) {
                        maxDiff = std::max(maxDiff, (double)std::fabs(fr[k] - ref[i * perCall + k]));
                        maxRef = std::max(maxRef, (double)std::fabs(ref[i * perCall + k]));
                    }
                }
                if (pass == 0 && i >= 20) break;          // warm-up: 20 calls are enough
            }
        }
        std::sort(ms.begin(), ms.end());
        double mean = 0; for (double v : ms) mean += v; mean /= ms.size();
        double p95 = ms[(size_t)(ms.size() * 0.95)], mx = ms.back();
        BOOL ok = maxDiff < 0.02 * std::max(maxRef, 1e-6) + 1e-3;
        return [NSString stringWithFormat:@"%@ %@ %dT: mean %.1f ms, p95 %.1f, max %.1f per 40 ms chunk (budget 40) | load %.0f ms | output vs Mac: max diff %.4f of %.3f %@",
                model, provider, threads, mean, p95, mx, loadMs, maxDiff, maxRef, ok ? @"MATCH" : @"MISMATCH"];
    } catch (const std::exception &e) {
        return [NSString stringWithFormat:@"%@ %@ %dT: ERROR %s", model, provider, threads, e.what()];
    }
}

+ (NSString *)streamCheck {
    NSString *err = nil;
    TSE *t = [[TSE alloc] initWithThreads:4 error:&err];
    if (!t) return [NSString stringWithFormat:@"filter port check: ERROR %@", err];
    std::vector<float> enroll = loadF32(@"enroll_16k"), pad = loadF32(@"mix_padded_16k"), ref = loadF32(@"ref_stream_int8");
    if (![t setVoice:enroll.data() count:(int)enroll.size() resetState:YES]) return @"filter port check: ERROR setVoice";
    std::vector<float> mix(pad.begin() + 256, pad.end()), out(mix.size() + 4096);
    int n = 0; double worst = 0;
    for (size_t i = 0; i < mix.size(); i += 640) {
        int len = (int)std::min<size_t>(640, mix.size() - i);
        n += [t push:mix.data() + i count:len out:out.data() + n capacity:(int)(out.size() - n)];
        worst = std::max(worst, t.lastMs);
    }
    size_t m = std::min<size_t>(n, ref.size());
    double num = 0, den = 0, maxd = 0;
    for (size_t i = 0; i < m; i++) { double d = out[i] - ref[i]; num += ref[i] * ref[i]; den += d * d; maxd = std::max(maxd, std::fabs(d)); }
    double snr = 10 * log10(num / (den + 1e-20));
    return [NSString stringWithFormat:@"filter port check: %d samples (Mac %zu), difference from Mac %.1f dB below the signal (max %.4f), worst push %.0f ms -> %@",
            n, ref.size(), snr, maxd, worst, (n == (int)ref.size() && snr > 25) ? @"SAME AS MAC" : @"DIFFERENT"];
}

@end
