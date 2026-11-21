import AVFoundation
import Accelerate
import Foundation
import MediaToolbox
import CZlib

// CoreAudio Real-Time Processing Context
private final class AudioTapProcessorContext {
    var gains: [Float] = [0, 0, 0, 0, 0]
    var loudnessMultiplier: Float = 1.0
    var isEnabled: Bool = true
    var loudnessNormalizationEnabled: Bool = true
}

@MainActor
final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    @Published var isEnabled: Bool = true {
        didSet { syncContext() }
    }

    @Published var loudnessNormalizationEnabled: Bool = true {
        didSet { syncContext() }
    }

    @Published var currentPreset: EQPreset = .flat {
        didSet {
            bands = zip(EQPreset.standardFrequencies, currentPreset.gains).map {
                EQBand(frequency: $0, gain: $1)
            }
            syncContext()
        }
    }

    @Published var bands: [EQBand] = [
        EQBand(frequency: 60.0, gain: 0),
        EQBand(frequency: 230.0, gain: 0),
        EQBand(frequency: 910.0, gain: 0),
        EQBand(frequency: 3600.0, gain: 0),
        EQBand(frequency: 14000.0, gain: 0)
    ] {
        didSet { syncContext() }
    }

    @Published var targetLoudnessDb: Double = -14.0 // Standard EBU R128 / ReplayGain target

    private let context = AudioTapProcessorContext()

    private init() {
        syncContext()
    }

    func setBandGain(at index: Int, gain: Double) {
        guard bands.indices.contains(index) else { return }
        bands[index].gain = min(max(gain, -12.0), 12.0)
        syncContext()
    }

    private func syncContext() {
        context.isEnabled = isEnabled
        context.loudnessNormalizationEnabled = loudnessNormalizationEnabled
        context.gains = bands.map { Float($0.gain) }
        // -14dB target vs standard 0dB reference gives ~0.89 scalar default leveling
        let targetScalar = pow(10.0, Float(targetLoudnessDb) / 20.0) * 4.5
        context.loudnessMultiplier = loudnessNormalizationEnabled ? min(max(targetScalar, 0.5), 1.5) : 1.0
    }

    // Applies MTAudioProcessingTap to an AVPlayerItem
    func configureAudio(for item: AVPlayerItem) {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(context).toOpaque(),
            init: { tap, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in },
            prepare: { tap, maxFrames, processingFormat in },
            unprepare: { tap in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }

                let storage = MTAudioProcessingTapGetStorage(tap)
                let processorContext = Unmanaged<AudioTapProcessorContext>.fromOpaque(storage).takeUnretainedValue()

                guard processorContext.isEnabled || processorContext.loudnessNormalizationEnabled else { return }

                let bufferList = bufferListInOut.pointee
                let numBuffers = Int(bufferList.mNumberBuffers)
                let multiplier = processorContext.loudnessNormalizationEnabled ? processorContext.loudnessMultiplier : 1.0

                // Average gain boost across bands to calculate compensation factor
                var avgGainDb: Float = 0.0
                if processorContext.isEnabled {
                    for g in processorContext.gains { avgGainDb += g }
                    avgGainDb /= Float(processorContext.gains.count)
                }
                let eqScale = pow(10.0, avgGainDb / 20.0)
                let totalGain = multiplier * eqScale

                // Real-time audio frame processing
                withUnsafeMutablePointer(to: &bufferListInOut.pointee.mBuffers) { buffersPtr in
                    let buffers = UnsafeMutableBufferPointer(start: buffersPtr, count: numBuffers)
                    for i in 0..<numBuffers {
                        let audioBuffer = buffers[i]
                        guard let rawData = audioBuffer.mData else { continue }
                        let sampleCount = Int(numberFrames)
                        let floatPtr = rawData.assumingMemoryBound(to: Float.self)

                        // 1. Apply volume and EQ gain scaling via vDSP
                        if totalGain != 1.0 {
                            var gain = totalGain
                            vDSP_vsmul(floatPtr, 1, &gain, floatPtr, 1, vDSP_Length(sampleCount))
                        }

                        // 2. Soft-knee peak limiter to prevent digital clipping
                        for sampleIdx in 0..<sampleCount {
                            let sample = floatPtr[sampleIdx]
                            if sample > 1.0 {
                                floatPtr[sampleIdx] = 1.0 - exp(-sample)
                            } else if sample < -1.0 {
                                floatPtr[sampleIdx] = -1.0 + exp(sample)
                            }
                        }
                    }
                }
            }
        )

        var tap: MTAudioProcessingTap?
        let tapStatus = withUnsafeMutablePointer(to: &tap) { tapPtr in
            echoCreateAudioProcessingTap(&callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, tapPtr)
        }
        guard tapStatus == noErr, let tap = tap else { return }

        let audioMix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = tap
        audioMix.inputParameters = [params]
        item.audioMix = audioMix
    }
}
