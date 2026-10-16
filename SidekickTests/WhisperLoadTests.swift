import XCTest
@testable import Sidekick

final class WhisperLoadTests: XCTestCase {
    func testUsesTheModelAlreadyOnDiskOnlyWhenComplete() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for part in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(part), withIntermediateDirectories: true)
        }
        XCTAssertNil(WhisperKitSTT.localModel(.small, base: base))          // incomplete download → fetch again
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("MelSpectrogram.mlmodelc"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        XCTAssertEqual(WhisperKitSTT.localModel(.small, base: base)?.lastPathComponent, "openai_whisper-small")
        XCTAssertNil(WhisperKitSTT.localModel(.largeTurbo, base: base))
    }
}
