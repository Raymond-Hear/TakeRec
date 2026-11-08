import Foundation

enum ClickAudio {
    static func file(for preset: ClickSound, in folder: URL) throws -> URL {
        let filename: String
        switch preset {
        case .mechanical: filename = "mechanical"
        case .soft: filename = "soft"
        case .crisp: filename = "crisp"
        case .bell: filename = "bell"
        }
        let file = folder.appendingPathComponent("click-\(filename).wav")
        guard !FileManager.default.fileExists(atPath: file.path) else { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let rate: UInt32 = 48_000
        let samples: UInt32 = 2_640
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var word = value.littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }

        data.append(Data("RIFF".utf8))
        append(UInt32(36) + samples * 2)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(samples * 2)
        var seed: UInt64 = 45
        var previous = 0.0
        for index in 0..<samples {
            let time = Double(index) / Double(rate)
            seed = seed &* 6364136223846793005 &+ 1
            let noise = 2 * Double(UInt32(truncatingIfNeeded: seed >> 32)) / Double(UInt32.max) - 1
            let high = (noise - previous) * 0.5
            previous = noise

            let value: Double
            switch preset {
            case .mechanical:
                value = 0.82 * strike(time, noise: high, frequency: 720, decay: 290)
                    + 0.32 * strike(time - 0.017, noise: noise, frequency: 460, decay: 340)
            case .soft:
                value = 0.63 * strike(time, noise: noise * 0.4, frequency: 340, decay: 215)
            case .crisp:
                value = 0.85 * strike(time, noise: high, frequency: 1480, decay: 470)
                    + 0.21 * strike(time - 0.009, noise: high, frequency: 910, decay: 490)
            case .bell:
                let chord = 0.7 * sin(2 * .pi * 1180 * time) + 0.3 * sin(2 * .pi * 1960 * time)
                value = chord * min(1, time / 0.002) * exp(-82 * time)
            }
            append(Int16(clamp(value, -1, 1) * 21_000))
        }
        try data.write(to: file, options: .atomic)
        return file
    }

    private static func strike(_ time: Double, noise: Double, frequency: Double, decay: Double) -> Double {
        guard time >= 0 else { return 0 }
        let body = sin(2 * .pi * frequency * time) * exp(-1.5 * decay * time)
        return min(1, time / 0.0005) * (0.65 * noise * exp(-decay * time) + 0.35 * body)
    }
}
