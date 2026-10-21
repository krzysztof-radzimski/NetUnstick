import Foundation
import XCTest
import NetUnstickCore

final class LocalizationTests: XCTestCase {
    func testEverySupportedLanguageHasItsOwnCompleteRuntimeResources() throws {
        let resourceRoot = try XCTUnwrap(L10n.bundle.resourceURL)
        func table(_ language: String) throws -> [String: String] {
            // Construct the real filesystem path. Bundle's localized resource lookup
            // may silently return English when an advertised localization is missing.
            let directory = resourceRoot.appendingPathComponent(language + ".lproj", isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), language)
            XCTAssertTrue(isDirectory.boolValue, language)
            let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let englishKeys = Set(try table("en").keys)
        XCTAssertEqual(L10n.supportedLanguages.count, 24)
        for language in L10n.supportedLanguages {
            let values = try table(language)
            XCTAssertEqual(Set(values.keys), englishKeys, language)
            XCTAssertFalse(values.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), language)
            let locale = Locale(identifier: language)
            for key in ["run_diagnosis", "help_start_body", "privacy_local_body"] {
                XCTAssertEqual(L10n.text(key, locale: locale), try XCTUnwrap(values[key]), "\(language)/\(key)")
                XCTAssertNotEqual(L10n.text(key, locale: locale), key, language)
            }
            let template = try XCTUnwrap(values["helper_protocol"])
            let formatted = L10n.format("helper_protocol", locale: locale, arguments: [7])
            XCTAssertEqual(formatted, String(format: template, locale: locale, arguments: [7]), language)
            XCTAssertTrue(formatted.contains("7"), language)
            XCTAssertFalse(formatted.contains("%"), language)
            XCTAssertNotEqual(formatted, "helper_protocol", language)
        }
    }

    func testEnglishAndPolishKeysAndPlaceholderContractsMatch() throws {
        var tables: [[String: String]] = []
        for language in ["en", "pl"] {
            let url = try XCTUnwrap(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            let data = try Data(contentsOf: url)
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            XCTAssertGreaterThan(table.count, 300)
            XCTAssertFalse(table.values.contains(where: { $0.isEmpty }))
            tables.append(table)
        }
        XCTAssertEqual(Set(tables[0].keys), Set(tables[1].keys))
        let pattern = #"%(?:\d+\$)?[-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp]"#
        let regex = try NSRegularExpression(pattern: pattern)
        func placeholders(_ value: String) -> [String] {
            regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }
        }
        for key in tables[0].keys {
            XCTAssertEqual(placeholders(tables[0][key]!), placeholders(tables[1][key]!), key)
        }
    }

    func testExplicitLocaleAndEnglishFallbackDoNotDependOnMachineLanguage() {
        XCTAssertEqual(L10n.text("run_diagnosis", locale: Locale(identifier: "en-IE")), "Run diagnostics")
        XCTAssertEqual(L10n.text("run_diagnosis", locale: Locale(identifier: "pl-PL")), "Uruchom diagnostykę")
        XCTAssertEqual(L10n.text("run_diagnosis", locale: Locale(identifier: "ja-JP")), "Run diagnostics")
        XCTAssertEqual(L10n.format("helper_protocol", locale: Locale(identifier: "pl"), arguments: [2]), "Helper odpowiada (protokół 2).")
        XCTAssertEqual(L10n.format("repair_outcome", locale: Locale(identifier: "en"), arguments: ["Failed", "permissionDenied"]), "Repair: Failed; permissionDenied")
    }

    func testNextStepTranslationDoesNotChangeAllowlistOrPersistedEvidence() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try OperationResult(operationID: "helper_handshake", name: "helper_handshake", kind: .diagnostic,
            startedAt: start, endedAt: start, outcome: .permissionDenied,
            error: OperationError(domain: "helper", code: "notRegistered"), nextStep: NextStep.registerHelper.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(result)
        let session = ActivitySession(startedAt: start, appVersion: "1", macOSVersion: "14", entries: [result])
        let reportBefore = ReportRenderer().render(session: session)
        XCTAssertEqual(L10n.nextStep(NextStep.registerHelper.rawValue, locale: Locale(identifier: "en")), "Register the helper before repairing.")
        XCTAssertEqual(L10n.nextStep(NextStep.registerHelper.rawValue, locale: Locale(identifier: "pl")), "Zarejestruj helper przed naprawą.")
        XCTAssertEqual(try encoder.encode(result), before)
        XCTAssertEqual(result.nextStep, NextStep.registerHelper.rawValue)
        XCTAssertEqual(EvidenceSanitizer.safeNextStep("private.corp.invalid password=secret"), NextStep.reviewDetails.rawValue)
        XCTAssertEqual(L10n.nextStep("private.corp.invalid password=secret", locale: Locale(identifier: "en")), "Review the operation details.")
        XCTAssertEqual(ReportRenderer().render(session: session), reportBefore)
    }

    func testOfficialLanguageSetAndUnknownOperationLabelAreClosed() {
        XCTAssertEqual(Set(L10n.supportedLanguages), Set(["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "ga", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "sk", "sl", "sv"]))
        XCTAssertEqual(L10n.operationTitle("private.corp.invalid"), L10n.text("operation_other"))
        XCTAssertEqual(L10n.operationTitle("local_subnet_route"), L10n.text("operation_local_subnet_route"))
    }
}
