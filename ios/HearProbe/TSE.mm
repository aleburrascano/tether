#import "TSE.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <vector>
#include <memory>
#include <chrono>
#include <cmath>
#include <algorithm>

static const int HOP = 128, NFFT = 512, PAD = 256, SAMPLE = 48000, FPR = 100;
static const float GAIN = -1.0f;   // the REAL-TSE parent returns the target at about -1x

static Ort::Env &tseEnv() { static Ort::Env e(ORT_LOGGING_LEVEL_WARNING, "tse"); return e; }

@implementation TSE {
    std::unique_ptr<Ort::Session> _enroll, _chunk;
    std::unique_ptr<Ort::MemoryInfo> _memP;
    std::vector<float> _en, _k, _v;            // voice
    std::vector<int64_t> _enShape, _kShape, _vShape;
    std::vector<float> _h, _c;                 // LSTM memory
    std::vector<float> _head, _buf, _ola, _env, _win2;
    BOOL _started;
    int _dropped;
    double _lastMs;
    BOOL _hasVoice;
}

- (instancetype)initWithThreads:(int)threads error:(NSString **)error {
    if (!(self = [super init])) return nil;
    try {
        _memP = std::make_unique<Ort::MemoryInfo>(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault));
        NSString *dir = [[NSBundle mainBundle] resourcePath];
        Ort::SessionOptions eo; eo.SetIntraOpNumThreads(2);
        _enroll = std::make_unique<Ort::Session>(tseEnv(), [[dir stringByAppendingPathComponent:@"enroll.onnx"] UTF8String], eo);
        Ort::SessionOptions so; so.SetIntraOpNumThreads(threads);
        so.AddConfigEntry("session.intra_op.allow_spinning", "0");
        _chunk = std::make_unique<Ort::Session>(tseEnv(), [[dir stringByAppendingPathComponent:@"chunk_int8.onnx"] UTF8String], so);
    } catch (const std::exception &e) {
        if (error) *error = [NSString stringWithUTF8String:e.what()];
        return nil;
    }
    _h.assign(6 * 32 * 256, 0.f); _c.assign(6 * 32 * 256, 0.f);
    _win2.resize(NFFT);
    for (int i = 0; i < NFFT; i++) { float w = 0.5f - 0.5f * cosf(2 * M_PI * i / NFFT); _win2[i] = w * w; }
    [self restart];
    return self;
}

- (double)lastMs { return _lastMs; }
- (BOOL)hasVoice { return _hasVoice; }

- (void)restart {
    _head.clear(); _buf.clear();
    _ola.assign(NFFT, 0.f); _env.assign(NFFT, 0.f);
    _started = NO; _dropped = 0;
    std::fill(_h.begin(), _h.end(), 0.f); std::fill(_c.begin(), _c.end(), 0.f);
}

- (BOOL)setVoice:(const float *)samples count:(int)count resetState:(BOOL)resetState {
    if (count < SAMPLE) return NO;
    try {
        std::vector<float> s(samples, samples + SAMPLE);
        int64_t shp[2] = {1, SAMPLE};
        Ort::Value in = Ort::Value::CreateTensor<float>(*_memP, s.data(), s.size(), shp, 2);
        const char *inN[] = {"enroll"}; const char *outN[] = {"enroll_n", "k", "v"};
        auto out = _enroll->Run(Ort::RunOptions{nullptr}, inN, &in, 1, outN, 3);
        auto grab = [](Ort::Value &v, std::vector<float> &dst, std::vector<int64_t> &shape) {
            auto info = v.GetTensorTypeAndShapeInfo();
            shape = info.GetShape();
            const float *p = v.GetTensorData<float>();
            dst.assign(p, p + info.GetElementCount());
        };
        @synchronized (self) {
            grab(out[0], _en, _enShape); grab(out[1], _k, _kShape); grab(out[2], _v, _vShape);
            if (resetState) [self restart];
            _hasVoice = YES;
        }
        return YES;
    } catch (...) { return NO; }
}

- (int)run:(float *)out capacity:(int)cap {
    int produced = 0;
    const char *inN[] = {"wav", "enroll_n", "k", "v", "h", "c"};
    const char *outN[] = {"frames", "h_out", "c_out"};
    int64_t hShape[3] = {6, 32, 256};
    while ((int)_buf.size() >= NFFT) {
        int k = std::min(FPR, 1 + ((int)_buf.size() - NFFT) / HOP);
        int segLen = (k - 1) * HOP + NFFT;
        int64_t wShape[2] = {1, segLen};
        std::vector<Ort::Value> in;
        in.push_back(Ort::Value::CreateTensor<float>(*_memP, _buf.data(), segLen, wShape, 2));
        in.push_back(Ort::Value::CreateTensor<float>(*_memP, _en.data(), _en.size(), _enShape.data(), _enShape.size()));
        in.push_back(Ort::Value::CreateTensor<float>(*_memP, _k.data(), _k.size(), _kShape.data(), _kShape.size()));
        in.push_back(Ort::Value::CreateTensor<float>(*_memP, _v.data(), _v.size(), _vShape.data(), _vShape.size()));
        in.push_back(Ort::Value::CreateTensor<float>(*_memP, _h.data(), _h.size(), hShape, 3));
        in.push_back(Ort::Value::CreateTensor<float>(*_memP, _c.data(), _c.size(), hShape, 3));
        auto o = _chunk->Run(Ort::RunOptions{nullptr}, inN, in.data(), in.size(), outN, 3);
        const float *fr = o[0].GetTensorData<float>();
        memcpy(_h.data(), o[1].GetTensorData<float>(), _h.size() * 4);
        memcpy(_c.data(), o[2].GetTensorData<float>(), _c.size() * 4);
        // overlap-add k frames
        _ola.resize(NFFT + k * HOP, 0.f); _env.resize(NFFT + k * HOP, 0.f);
        for (int j = 0; j < k; j++)
            for (int i = 0; i < NFFT; i++) { _ola[j * HOP + i] += fr[j * NFFT + i]; _env[j * HOP + i] += _win2[i]; }
        int done = k * HOP;
        for (int i = 0; i < done; i++) {
            float y = _ola[i] / (_env[i] > 1e-11f ? _env[i] : 1.f) * GAIN;
            if (_dropped > 0) { _dropped--; continue; }
            if (produced < cap) out[produced++] = y;
        }
        _ola.erase(_ola.begin(), _ola.begin() + done); _env.erase(_env.begin(), _env.begin() + done);
        _buf.erase(_buf.begin(), _buf.begin() + done);
    }
    return produced;
}

- (int)push:(const float *)samples count:(int)count out:(float *)out capacity:(int)capacity {
    auto t0 = std::chrono::steady_clock::now();
    int n = 0;
    @synchronized (self) {
        if (!_hasVoice) return 0;
        try {
            if (!_started) {
                _head.insert(_head.end(), samples, samples + count);
                if ((int)_head.size() <= PAD) return 0;
                _buf.clear();
                for (int i = PAD; i >= 1; i--) _buf.push_back(_head[i]);    // reflect padding, as torch.stft centre
                _buf.insert(_buf.end(), _head.begin(), _head.end());
                _head.clear(); _started = YES; _dropped = PAD;
            } else {
                _buf.insert(_buf.end(), samples, samples + count);
            }
            n = [self run:out capacity:capacity];
        } catch (...) { n = 0; }
    }
    _lastMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    return n;
}

@end
