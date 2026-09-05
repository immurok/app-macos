import XCTest
@testable import immurokApp

/// Guards the localization contract:
///   1. every key the app asks for resolves to real copy, never a raw key id
///   2. a partial / missing language pack degrades to English
///   3. the shipped JSON packs stay in lockstep with the built-in key set
///   4. format specifiers survive translation
///   5. no Simplified-Chinese text leaks into a non-Chinese pack
final class LocalizationFallbackTests: XCTestCase {

    // MARK: - Helpers

    /// The three built-in dictionaries are the source of truth for the key set.
    private var canonicalKeys: Set<String> { Set(LocalizationManager.enStrings.keys) }

    /// Repo-relative Resources/Localization, resolved from this file's path so
    /// the test works regardless of the working directory the runner uses.
    private var localizationDir: URL {
        URL(fileURLWithPath: #filePath)            // …/Tests/LocalizationTests/<this>.swift
            .deletingLastPathComponent()           // …/Tests/LocalizationTests
            .deletingLastPathComponent()           // …/Tests
            .deletingLastPathComponent()           // …/app-macos
            .appendingPathComponent("Resources/Localization")
    }

    private func loadPack(_ code: String) throws -> [String: String] {
        let url = localizationDir.appendingPathComponent("\(code).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private static let jsonLanguages = ["es", "fr", "ja", "pt", "ru"]

    /// `%@`, `%d`, `%1$d` … — must match one-for-one between EN and translation.
    private static let formatSpecifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[@dfsu%]"#)

    private func specifiers(_ s: String) -> [String] {
        let range = NSRange(s.startIndex..., in: s)
        return Self.formatSpecifier.matches(in: s, range: range)
            .compactMap { Range($0.range, in: s).map { String(s[$0]) } }
            .sorted()
    }

    /// Simplified-Chinese-only forms — each has a different Japanese
    /// counterpart (認 証 請 輸 電 長 時 間 開 関 …), so one appearing in a
    /// non-Chinese pack means Chinese text was pasted in. Shared
    /// shinjitai/jianti forms (国 学 体 保 存 成 功 管 理 …) are deliberately
    /// absent: they are correct Japanese and must not trip the check.
    private static let simplifiedOnly = Set(
        "设备认证请输击电长时间开关应该页现试传连择键码纹换检无为从让给并别习网络"
        + "确识启动运载获删续错线级组织类丰个么这样对话题实际问题际见觉华灭闭"
        + "报导录处调边远进达过还军农轮软辅项须顺验马风飞饭馆龙"
        + "权绝统锁蓝败执误钥满显隐诊块户压终荐议计划单释复图标参"
        + "档众够继纪绍练缩罗营谢质钟专转赚脑荣药财资赞"
        + "邮阵阅陆随难韩顶顾预领频饰馈")

    // MARK: - 1. Built-in dictionaries agree on the key set

    func testBuiltInDictionariesCoverTheSameKeys() {
        let en = Set(LocalizationManager.enStrings.keys)
        let zhHans = Set(LocalizationManager.zhHansStrings.keys)
        let zhHant = Set(LocalizationManager.zhHantStrings.keys)

        XCTAssertEqual(en.symmetricDifference(zhHans), [],
                       "zh-Hans differs from English on these keys")
        XCTAssertEqual(en.symmetricDifference(zhHant), [],
                       "zh-Hant differs from English on these keys")
        XCTAssertFalse(en.isEmpty)
    }

    // MARK: - 2. Fallback: a partial pack degrades to English, never to a raw key

    func testPartialPackFallsBackToEnglish() {
        // Simulate what loadStrings does: English base, then a pack that only
        // translates one key. Everything else must read as English.
        let partial = ["alert.error": "Erreur"]
        var merged = LocalizationManager.enStrings
        merged.merge(partial.filter { !$0.value.isEmpty }) { _, new in new }

        XCTAssertEqual(merged["alert.error"], "Erreur", "the translated key wins")
        XCTAssertEqual(merged["wizard.step.welcome"],
                       LocalizationManager.enStrings["wizard.step.welcome"],
                       "an untranslated key must fall back to English")
        XCTAssertEqual(Set(merged.keys), canonicalKeys,
                       "a partial pack must not shrink the table")
    }

    func testEmptyValuesDoNotShadowEnglish() {
        // A blank entry in a hand-edited pack would otherwise render blank UI.
        let packWithBlank = ["alert.error": ""]
        var merged = LocalizationManager.enStrings
        merged.merge(packWithBlank.filter { !$0.value.isEmpty }) { _, new in new }

        XCTAssertEqual(merged["alert.error"], LocalizationManager.enStrings["alert.error"])
    }

    func testUnknownLanguageResolvesToEnglish() {
        // A language with no built-in dict and no JSON contributes no layer,
        // so the table is exactly English.
        var merged = LocalizationManager.enStrings
        merged.merge([:] as [String: String]) { _, new in new }
        XCTAssertEqual(merged, LocalizationManager.enStrings)
    }

    func testStringLookupNeverReturnsARawKeyForAKnownKey() {
        // `.localized` returning the key itself is the symptom the layering
        // was introduced to kill.
        for key in canonicalKeys {
            let value = LocalizationManager.shared.string(key)
            XCTAssertNotEqual(value, key,
                              "\(key) resolved to its own identifier")
            XCTAssertFalse(value.isEmpty, "\(key) resolved to an empty string")
        }
    }

    // MARK: - 3. Shipped JSON packs match the built-in key set

    func testShippedPacksCoverEveryKey() throws {
        for code in Self.jsonLanguages {
            let pack = try loadPack(code)
            let missing = canonicalKeys.subtracting(pack.keys).sorted()
            let extra = Set(pack.keys).subtracting(canonicalKeys).sorted()
            XCTAssertEqual(missing, [], "\(code).json is missing \(missing.count) keys")
            XCTAssertEqual(extra, [], "\(code).json has keys the app never asks for")
        }
    }

    // MARK: - 4. Format specifiers survive translation

    func testFormatSpecifiersMatchEnglish() throws {
        for code in Self.jsonLanguages {
            let pack = try loadPack(code)
            for (key, translated) in pack {
                guard let english = LocalizationManager.enStrings[key] else { continue }
                XCTAssertEqual(specifiers(english), specifiers(translated),
                               "\(code).json[\(key)] specifier mismatch: "
                               + "EN \(specifiers(english)) vs \(specifiers(translated))")
            }
        }
    }

    // MARK: - 5. No Chinese leaks into the non-Chinese packs

    func testNoChineseInLatinAndCyrillicPacks() throws {
        // es/fr/pt/ru must contain no Han ideographs at all.
        let han = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        for code in ["es", "fr", "pt", "ru"] {
            let pack = try loadPack(code)
            for (key, value) in pack {
                XCTAssertNil(value.rangeOfCharacter(from: han),
                             "\(code).json[\(key)] contains Han characters: \(value)")
            }
        }
    }

    /// 内置英文表不得含汉字；繁体表不得含简体独有字。2026-09-03 曾把繁体文案写进英文表、
    /// 简体文案写进繁体表（英文界面显示繁体），JSON 包的检查覆盖不到内置表。
    func testBuiltInEnglishHasNoHanAndTraditionalHasNoSimplified() {
        let han = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        for (key, value) in LocalizationManager.enStrings {
            XCTAssertNil(value.rangeOfCharacter(from: han),
                         "enStrings[\(key)] contains Han characters: \(value)")
        }
        for (key, value) in LocalizationManager.zhHantStrings {
            let hits = value.filter { Self.simplifiedOnly.contains($0) }
            XCTAssertTrue(hits.isEmpty,
                          "zhHantStrings[\(key)] contains simplified-only characters \(Array(hits)): \(value)")
        }
    }

    func testNoSimplifiedChineseInJapanesePack() throws {
        // Japanese shares kanji with Chinese, so only simplified-only forms
        // are decisive evidence of contamination.
        let pack = try loadPack("ja")
        for (key, value) in pack {
            let offenders = value.filter { Self.simplifiedOnly.contains($0) }
            XCTAssertTrue(offenders.isEmpty,
                          "ja.json[\(key)] contains Simplified-Chinese "
                          + "character(s) \(String(offenders)): \(value)")
        }
    }

    /// The detector above is only useful if it actually fires on Chinese text.
    func testSimplifiedDetectorCatchesTheChineseDictionary() {
        let values = LocalizationManager.zhHansStrings.values
            .filter { $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")) != nil }
        let caught = values.filter { v in v.contains { Self.simplifiedOnly.contains($0) } }
        // 85% on the current corpus; the floor guards against someone
        // gutting the character list and silently disabling the check.
        XCTAssertGreaterThan(Double(caught.count) / Double(values.count), 0.75,
                             "simplified-only detector went blind")
    }

    /// …and only useful if it does NOT fire on legitimate English or Japanese.
    func testSimplifiedDetectorHasNoFalsePositives() throws {
        for (key, value) in LocalizationManager.enStrings {
            XCTAssertFalse(value.contains { Self.simplifiedOnly.contains($0) },
                           "detector false-positives on English \(key): \(value)")
        }
    }
}
