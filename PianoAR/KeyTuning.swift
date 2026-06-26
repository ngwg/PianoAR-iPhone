import Combine
import Foundation

final class KeyTuning: ObservableObject {
    @Published var panelVisible = false
    @Published private(set) var revision = 0

    private static let offsetKey = "keyTuning.xOffsets"
    private static let widthKey = "keyTuning.widthExtras"
    private var xOffsets: [Float]
    private var widthExtras: [Float]

    init() {
        let defaults = UserDefaults.standard
        xOffsets = Self.loadArray(defaults.array(forKey: Self.offsetKey), fallback: 0)
        widthExtras = Self.loadArray(defaults.array(forKey: Self.widthKey), fallback: 0)
    }

    func xOffset(for keyIndex: Int) -> Float {
        guard keyIndex >= 0, keyIndex < xOffsets.count else { return 0 }
        return xOffsets[keyIndex]
    }

    func widthExtra(for keyIndex: Int) -> Float {
        guard keyIndex >= 0, keyIndex < widthExtras.count else { return 0 }
        return widthExtras[keyIndex]
    }

    func adjustX(for keyIndex: Int?, by delta: Float) {
        guard let keyIndex, keyIndex >= 0, keyIndex < xOffsets.count else { return }
        xOffsets[keyIndex] = clamp(xOffsets[keyIndex] + delta, min: -0.018, max: 0.018)
        save()
    }

    func adjustWidth(for keyIndex: Int?, by delta: Float) {
        guard let keyIndex, keyIndex >= 0, keyIndex < widthExtras.count else { return }
        widthExtras[keyIndex] = clamp(widthExtras[keyIndex] + delta, min: -0.006, max: 0.018)
        save()
    }

    func reset(keyIndex: Int?) {
        guard let keyIndex, keyIndex >= 0, keyIndex < xOffsets.count else { return }
        xOffsets[keyIndex] = 0
        widthExtras[keyIndex] = 0
        save()
    }

    func status(for keyIndex: Int?) -> String {
        guard let keyIndex,
              keyIndex >= 0,
              keyIndex < KeyboardLayout.keys.count
        else { return "Tune: no target" }

        let key = KeyboardLayout.keys[keyIndex]
        let xMM = Int((xOffset(for: keyIndex) * 1000).rounded())
        let wMM = Int((widthExtra(for: keyIndex) * 1000).rounded())
        return "Tune \(key.noteName): x \(xMM)mm width +\(wMM)mm"
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(xOffsets.map { Double($0) }, forKey: Self.offsetKey)
        defaults.set(widthExtras.map { Double($0) }, forKey: Self.widthKey)
        revision += 1
    }

    private func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    private static func loadArray(_ stored: [Any]?, fallback: Float) -> [Float] {
        var values = Array(repeating: fallback, count: 88)
        guard let stored else { return values }
        for (idx, value) in stored.enumerated() where idx < 88 {
            if let double = value as? Double {
                values[idx] = Float(double)
            } else if let float = value as? Float {
                values[idx] = float
            }
        }
        return values
    }
}
