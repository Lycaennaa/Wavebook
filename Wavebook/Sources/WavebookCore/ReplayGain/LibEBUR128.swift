/*
 Copyright (c) 2011 Jan Kokemüller

 Derived from libebur128 v1.2.6.
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
*/

import Foundation

enum LibEBUR128StateError: Error {
    case invalidConfiguration
    case invalidChannelIndex
    case invalidInput
}

final class LibEBUR128State {
    private static let histogramEnergyBoundaries: [Double] = (0...1000).map { index in
        pow(10.0, (Double(index) / 10.0 - 70.0 + 0.691) / 10.0)
    }
    private static let histogramEnergies: [Double] = (0..<1000).map { index in
        pow(10.0, (Double(index) / 10.0 - 69.95 + 0.691) / 10.0)
    }

    struct MeasurementSnapshot: Sendable {
        fileprivate let blockEnergyHistogram: [Int]
    }

    private let channelCount: Int
    private let samplesIn100ms: Int
    private let audioDataFrames: Int
    private let filterNumerator: [Double]
    private let filterDenominator: [Double]
    private var filterStates: [Double]
    private var audioData: [Double]
    private var blockEnergyHistogram: [Int]
    private var samplePeaks: [Double]
    private var previousSamplePeaks: [Double]
    private var audioDataIndex = 0
    private var neededFrames: Int

    init(channelCount: UInt32, sampleRate: UInt) throws {
        guard channelCount == 1 || channelCount == 2,
              sampleRate >= 16,
              sampleRate <= 192_000 else {
            throw LibEBUR128StateError.invalidConfiguration
        }

        let channelCount = Int(channelCount)
        let sampleRate = Int(sampleRate)
        let samplesIn100ms = (sampleRate + 5) / 10
        var audioDataFrames = sampleRate * 400 / 1000
        if audioDataFrames % samplesIn100ms != 0 {
            audioDataFrames += samplesIn100ms - audioDataFrames % samplesIn100ms
        }
        let initialBlockFrames = samplesIn100ms * 4
        audioDataFrames = max(audioDataFrames, initialBlockFrames)

        let coefficients = Self.filterCoefficients(sampleRate: Double(sampleRate))
        self.channelCount = channelCount
        self.samplesIn100ms = samplesIn100ms
        self.audioDataFrames = audioDataFrames
        filterNumerator = coefficients.numerator
        filterDenominator = coefficients.denominator
        filterStates = Array(repeating: 0, count: channelCount * 5)
        audioData = Array(repeating: 0, count: audioDataFrames * channelCount)
        blockEnergyHistogram = Array(repeating: 0, count: 1000)
        samplePeaks = Array(repeating: 0, count: channelCount)
        previousSamplePeaks = Array(repeating: 0, count: channelCount)
        neededFrames = initialBlockFrames
    }

    func addFramesFloat(_ samples: UnsafeBufferPointer<Float>, frameCount: Int) throws {
        guard frameCount >= 0, frameCount <= samples.count / channelCount else {
            throw LibEBUR128StateError.invalidInput
        }

        for channel in 0..<channelCount {
            previousSamplePeaks[channel] = 0
        }

        var sourceFrame = 0
        var remainingFrames = frameCount
        while remainingFrames > 0 {
            let blockFrames = min(remainingFrames, neededFrames)
            filter(samples: samples, firstFrame: sourceFrame, frameCount: blockFrames)
            sourceFrame += blockFrames
            remainingFrames -= blockFrames
            audioDataIndex += blockFrames * channelCount

            if blockFrames == neededFrames {
                calculateGatingBlock(framesPerBlock: samplesIn100ms * 4)
                neededFrames = samplesIn100ms
                if audioDataIndex == audioData.count {
                    audioDataIndex = 0
                }
            } else {
                neededFrames -= blockFrames
            }
        }

        for channel in 0..<channelCount where previousSamplePeaks[channel] > samplePeaks[channel] {
            samplePeaks[channel] = previousSamplePeaks[channel]
        }
    }

    func snapshot() -> MeasurementSnapshot {
        MeasurementSnapshot(blockEnergyHistogram: blockEnergyHistogram)
    }

    func loudnessGlobal() -> Double {
        Self.loudnessGlobalMultiple(snapshots: [snapshot()])
    }

    static func loudnessGlobalMultiple(snapshots: [MeasurementSnapshot]) -> Double {
        var relativeThreshold = 0.0
        var aboveThresholdCount = 0
        for snapshot in snapshots {
            for index in 0..<1000 {
                relativeThreshold += Double(snapshot.blockEnergyHistogram[index]) * histogramEnergies[index]
                aboveThresholdCount += snapshot.blockEnergyHistogram[index]
            }
        }

        guard aboveThresholdCount > 0 else { return -Double.infinity }

        relativeThreshold /= Double(aboveThresholdCount)
        relativeThreshold *= 0.1

        let startIndex: Int
        if relativeThreshold < histogramEnergyBoundaries[0] {
            startIndex = 0
        } else {
            var index = findHistogramIndex(relativeThreshold)
            if relativeThreshold > histogramEnergies[index] {
                index += 1
            }
            startIndex = index
        }

        var gatedLoudness = 0.0
        var gatedCount = 0
        for snapshot in snapshots {
            for index in startIndex..<1000 {
                gatedLoudness += Double(snapshot.blockEnergyHistogram[index]) * histogramEnergies[index]
                gatedCount += snapshot.blockEnergyHistogram[index]
            }
        }

        guard gatedCount > 0 else { return -Double.infinity }
        return energyToLoudness(gatedLoudness / Double(gatedCount))
    }

    func samplePeak(channelNumber: UInt32) throws -> Double {
        guard channelNumber < UInt32(channelCount) else {
            throw LibEBUR128StateError.invalidChannelIndex
        }
        return samplePeaks[Int(channelNumber)]
    }

    private func filter(
        samples: UnsafeBufferPointer<Float>,
        firstFrame: Int,
        frameCount: Int
    ) {
        for channel in 0..<channelCount {
            let filterStateIndex = channel * 5
            var maximum = 0.0
            for frame in 0..<frameCount {
                let value = Double(samples[(firstFrame + frame) * channelCount + channel])
                let magnitude = value >= 0 ? value : -value
                if magnitude > maximum {
                    maximum = magnitude
                }

                let current = value
                    - filterDenominator[1] * filterStates[filterStateIndex + 1]
                    - filterDenominator[2] * filterStates[filterStateIndex + 2]
                    - filterDenominator[3] * filterStates[filterStateIndex + 3]
                    - filterDenominator[4] * filterStates[filterStateIndex + 4]
                let filtered = filterNumerator[0] * current
                    + filterNumerator[1] * filterStates[filterStateIndex + 1]
                    + filterNumerator[2] * filterStates[filterStateIndex + 2]
                    + filterNumerator[3] * filterStates[filterStateIndex + 3]
                    + filterNumerator[4] * filterStates[filterStateIndex + 4]
                audioData[audioDataIndex + frame * channelCount + channel] = filtered
                filterStates[filterStateIndex + 4] = filterStates[filterStateIndex + 3]
                filterStates[filterStateIndex + 3] = filterStates[filterStateIndex + 2]
                filterStates[filterStateIndex + 2] = filterStates[filterStateIndex + 1]
                filterStates[filterStateIndex + 1] = current
            }
            if maximum > previousSamplePeaks[channel] {
                previousSamplePeaks[channel] = maximum
            }
        }
    }

    private func calculateGatingBlock(framesPerBlock: Int) {
        var sum = 0.0
        let currentFrame = audioDataIndex / channelCount

        for channel in 0..<channelCount {
            var channelSum = 0.0
            if audioDataIndex < framesPerBlock * channelCount {
                for frame in 0..<currentFrame {
                    let value = audioData[frame * channelCount + channel]
                    channelSum += value * value
                }
                let wrappedStart = audioDataFrames - (framesPerBlock - currentFrame)
                for frame in wrappedStart..<audioDataFrames {
                    let value = audioData[frame * channelCount + channel]
                    channelSum += value * value
                }
            } else {
                for frame in (currentFrame - framesPerBlock)..<currentFrame {
                    let value = audioData[frame * channelCount + channel]
                    channelSum += value * value
                }
            }
            sum += channelSum
        }

        let energy = sum / Double(framesPerBlock)
        guard energy >= Self.histogramEnergyBoundaries[0] else { return }
        blockEnergyHistogram[Self.findHistogramIndex(energy)] += 1
    }

    private static func findHistogramIndex(_ energy: Double) -> Int {
        var lower = 0
        var upper = 1000
        repeat {
            let middle = (lower + upper) / 2
            if energy >= histogramEnergyBoundaries[middle] {
                lower = middle
            } else {
                upper = middle
            }
        } while upper - lower != 1
        return lower
    }

    private static func energyToLoudness(_ energy: Double) -> Double {
        10.0 * (log(energy) / log(10.0)) - 0.691
    }

    private static func filterCoefficients(sampleRate: Double) -> (numerator: [Double], denominator: [Double]) {
        let firstCornerFrequency = 1681.974450955533
        let firstQuality = 0.7071752369554196
        let firstTangent = tan(Double.pi * firstCornerFrequency / sampleRate)
        let high = pow(10.0, 3.999843853973347 / 20.0)
        let shelf = pow(high, 0.4996667741545416)

        var numeratorFirst = [0.0, 0.0, 0.0]
        var denominatorFirst = [1.0, 0.0, 0.0]
        let firstA0 = 1.0 + firstTangent / firstQuality + firstTangent * firstTangent
        numeratorFirst[0] = (high + shelf * firstTangent / firstQuality + firstTangent * firstTangent) / firstA0
        numeratorFirst[1] = 2.0 * (firstTangent * firstTangent - high) / firstA0
        numeratorFirst[2] = (high - shelf * firstTangent / firstQuality + firstTangent * firstTangent) / firstA0
        denominatorFirst[1] = 2.0 * (firstTangent * firstTangent - 1.0) / firstA0
        denominatorFirst[2] = (1.0 - firstTangent / firstQuality + firstTangent * firstTangent) / firstA0

        let secondCornerFrequency = 38.13547087602444
        let secondQuality = 0.5003270373238773
        let secondTangent = tan(Double.pi * secondCornerFrequency / sampleRate)
        let numeratorSecond = [1.0, -2.0, 1.0]
        var denominatorSecond = [1.0, 0.0, 0.0]
        let secondA0 = 1.0 + secondTangent / secondQuality + secondTangent * secondTangent
        denominatorSecond[1] = 2.0 * (secondTangent * secondTangent - 1.0) / secondA0
        denominatorSecond[2] = (1.0 - secondTangent / secondQuality + secondTangent * secondTangent) / secondA0

        let numerator = [
            numeratorFirst[0] * numeratorSecond[0],
            numeratorFirst[0] * numeratorSecond[1] + numeratorFirst[1] * numeratorSecond[0],
            numeratorFirst[0] * numeratorSecond[2]
                + numeratorFirst[1] * numeratorSecond[1]
                + numeratorFirst[2] * numeratorSecond[0],
            numeratorFirst[1] * numeratorSecond[2] + numeratorFirst[2] * numeratorSecond[1],
            numeratorFirst[2] * numeratorSecond[2]
        ]
        let denominator = [
            denominatorFirst[0] * denominatorSecond[0],
            denominatorFirst[0] * denominatorSecond[1] + denominatorFirst[1] * denominatorSecond[0],
            denominatorFirst[0] * denominatorSecond[2]
                + denominatorFirst[1] * denominatorSecond[1]
                + denominatorFirst[2] * denominatorSecond[0],
            denominatorFirst[1] * denominatorSecond[2] + denominatorFirst[2] * denominatorSecond[1],
            denominatorFirst[2] * denominatorSecond[2]
        ]
        return (numerator, denominator)
    }
}
