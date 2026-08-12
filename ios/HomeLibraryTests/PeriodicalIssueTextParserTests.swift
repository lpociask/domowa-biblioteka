import XCTest
@testable import HomeLibrary

final class PeriodicalIssueTextParserTests: XCTestCase {
    func testParsesPolishCoverFixture() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "ARCHITEKTURA", confidence: 0.99),
            .init(text: "NR 1–2/2026", confidence: 0.92),
            .init(text: "Tom 18", confidence: 0.88),
            .init(text: "sierpień 2026", confidence: 0.86)
        ])

        XCTAssertEqual(result.issueNumber?.value, "1-2/2026")
        XCTAssertEqual(result.issueNumber?.confidence, 0.92)
        XCTAssertEqual(result.issueNumber?.evidence, "NR 1–2/2026")
        XCTAssertEqual(result.issueVolume?.value, "18")
        XCTAssertEqual(result.issueDate?.value, "2026-08")
    }

    func testParsesEnglishCoverFixtureAndNormalizesFullDate() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "Issue 8/2026", confidence: 0.91),
            .init(text: "Vol. 42", confidence: 0.89),
            .init(text: "Published 21.07.2026", confidence: 0.87)
        ])

        XCTAssertEqual(result.issueNumber?.value, "8/2026")
        XCTAssertEqual(result.issueVolume?.value, "42")
        XCTAssertEqual(result.issueDate?.value, "2026-07-21")
        XCTAssertEqual(result.issueDate?.evidence, "Published 21.07.2026")
    }

    func testParsesGermanCoverFixture() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "Heft 7", confidence: 0.93),
            .init(text: "Jahrgang 33", confidence: 0.82),
            .init(text: "März 2026", confidence: 0.9)
        ])

        XCTAssertEqual(result.issueNumber?.value, "7")
        XCTAssertEqual(result.issueVolume?.value, "33")
        XCTAssertEqual(result.issueDate?.value, "2026-03")
    }

    func testSupportsOtherExplicitIssueAndVolumeLabels() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "Ausgabe: 5", confidence: 0.8),
            .init(text: "Band 12", confidence: 0.8),
            .init(text: "2026 Oktober", confidence: 0.8)
        ])

        XCTAssertEqual(result.issueNumber?.value, "5")
        XCTAssertEqual(result.issueVolume?.value, "12")
        XCTAssertEqual(result.issueDate?.value, "2026-10")
    }

    func testSupportsGermanMonthNamesAcrossTheYear() {
        for (monthName, expected) in [
            ("April", "2026-04"),
            ("August", "2026-08"),
            ("September", "2026-09"),
            ("November", "2026-11")
        ] {
            let result = PeriodicalIssueTextParser.parse([
                .init(text: "\(monthName) 2026", confidence: 0.9)
            ])
            XCTAssertEqual(result.issueDate?.value, expected)
        }
    }

    func testRejectsLowConfidenceAndAmbiguousUnlabelledNumbers() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "Nr 8", confidence: 0.299),
            .init(text: "Tom 2", confidence: .nan),
            .init(text: "42", confidence: 0.99),
            .init(text: "August", confidence: 0.99)
        ])

        XCTAssertEqual(result, .empty)
    }

    func testRejectsPricesAndPublicationIdentifiers() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "ISBN 978-83-2026-08-1", confidence: 0.99),
            .init(text: "EAN 9770033248007", confidence: 0.99),
            .init(text: "ISSN 1234-5678", confidence: 0.99),
            .init(text: "Cena 12,99 PLN", confidence: 0.99),
            .init(text: "Price No. 8.99 GBP", confidence: 0.99),
            .init(text: "Preis 12.05.2026 EUR", confidence: 0.99)
        ])

        XCTAssertEqual(result, .empty)
    }

    func testChoosesHighestConfidenceBeforeMoreSpecificCandidate() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "Issue 1-2/2026", confidence: 0.7),
            .init(text: "No. 9", confidence: 0.91),
            .init(text: "2026-08", confidence: 0.92),
            .init(text: "31.07.2026", confidence: 0.85)
        ])

        XCTAssertEqual(result.issueNumber?.value, "9")
        XCTAssertEqual(result.issueDate?.value, "2026-08")
    }

    func testUsesSpecificityThenCanonicalValueForStableTies() {
        let lines: [PeriodicalRecognizedTextLine] = [
            .init(text: "Issue 9", confidence: 0.8),
            .init(text: "Issue 8", confidence: 0.8),
            .init(text: "July 2026", confidence: 0.7),
            .init(text: "21.07.2026", confidence: 0.7)
        ]

        let forward = PeriodicalIssueTextParser.parse(lines)
        let reversed = PeriodicalIssueTextParser.parse(lines.reversed())

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.issueNumber?.value, "8")
        XCTAssertEqual(forward.issueDate?.value, "2026-07-21")
    }

    func testRejectsImpossibleDatesAndReversedIssueRange() {
        let result = PeriodicalIssueTextParser.parse([
            .init(text: "31.02.2026", confidence: 0.9),
            .init(text: "2026-13", confidence: 0.9),
            .init(text: "Nr 9-2/2026", confidence: 0.9)
        ])

        XCTAssertEqual(result, .empty)
    }
}
