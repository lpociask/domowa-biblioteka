import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import HomeLibrary

@MainActor
final class PilotDashboardViewTests: XCTestCase {
    func testCompletedItemsAndProgressUseCompletedCatalogOnly() {
        let report = PilotReportBuilder.build(from: [
            record(1, .catalog(.init(
                publicationKind: .book,
                outcome: .completed,
                activeMilliseconds: 10_000
            ))),
            record(2, .catalog(.init(
                publicationKind: .periodical,
                outcome: .completed,
                activeMilliseconds: 20_000
            ))),
            record(3, .catalog(.init(
                publicationKind: .book,
                outcome: .cancelled,
                activeMilliseconds: 30_000
            )))
        ])

        XCTAssertEqual(PilotDashboardPresenter.completedItems(in: report), 2)
        XCTAssertEqual(PilotDashboardPresenter.progressValue(in: report), 0.01)
        XCTAssertEqual(
            PilotDashboardPresenter.progressSummary(in: report),
            "2 z 100 do pierwszego podsumowania"
        )
    }

    func testCompletedItemsSubtractSuccessfulQuickAddUndo() {
        let report = PilotReportBuilder.build(from: [
            record(1, .catalog(.init(
                publicationKind: .book,
                outcome: .completed,
                activeMilliseconds: 10_000
            ))),
            record(2, .mutation(.init(action: .undoAdd, outcome: .completed)))
        ])

        XCTAssertEqual(PilotDashboardPresenter.completedItems(in: report), 0)
    }

    func testProgressSummaryDistinguishesMinimumAndTarget() {
        let minimumReport = reportWithCompletedBooks(100)
        let targetReport = reportWithCompletedBooks(200)
        let beyondTargetReport = reportWithCompletedBooks(205)

        XCTAssertEqual(
            PilotDashboardPresenter.progressSummary(in: minimumReport),
            "Minimum osiągnięte · 100 z 200 obiektów"
        )
        XCTAssertEqual(
            PilotDashboardPresenter.progressSummary(in: targetReport),
            "Cel pilota osiągnięty · 200 obiektów"
        )
        XCTAssertEqual(PilotDashboardPresenter.progressValue(in: beyondTargetReport), 1)
    }

    func testFormattingKeepsMissingSamplesExplicit() {
        XCTAssertEqual(PilotDashboardPresenter.duration(nil), "—")
        XCTAssertEqual(PilotDashboardPresenter.duration(1_500), "1,5 s")
        XCTAssertEqual(PilotDashboardPresenter.duration(15_000), "15 s")
        XCTAssertEqual(PilotDashboardPresenter.duration(75_000), "1 min 15 s")
        XCTAssertEqual(PilotDashboardPresenter.percent(.init(numerator: 0, denominator: 0)), "—")
        XCTAssertEqual(PilotDashboardPresenter.percent(.init(numerator: 3, denominator: 4)), "75%")
    }

    func testOrdinaryTransfersUseCompletionWhileRoundTripUsesVerification() throws {
        let report = PilotReportBuilder.build(from: [
            record(1, .transfer(.init(direction: .export, outcome: .completed))),
            record(2, .transfer(.init(direction: .export, outcome: .completed))),
            record(3, .transfer(.init(direction: .export, outcome: .failed))),
            record(4, .transfer(.init(direction: .export, outcome: .cancelled))),
            record(5, .transfer(.init(direction: .roundTrip, outcome: .verified))),
            record(6, .transfer(.init(direction: .roundTrip, outcome: .verified))),
            record(7, .transfer(.init(direction: .roundTrip, outcome: .mismatch))),
            record(8, .transfer(.init(direction: .roundTrip, outcome: .failed))),
            record(9, .transfer(.init(direction: .roundTrip, outcome: .cancelled)))
        ])
        let export = try XCTUnwrap(report.transfers.first { $0.direction == .export })
        let roundTrip = try XCTUnwrap(report.transfers.first { $0.direction == .roundTrip })

        XCTAssertEqual(
            PilotDashboardPresenter.transferRate(export),
            PilotRate(numerator: 2, denominator: 4)
        )
        XCTAssertEqual(
            PilotDashboardPresenter.transferDetail(export),
            "Ukończone: 2 · błędy: 1 · anulowane: 1"
        )
        XCTAssertEqual(
            PilotDashboardPresenter.transferRate(roundTrip),
            PilotRate(numerator: 2, denominator: 3)
        )
        XCTAssertEqual(
            PilotDashboardPresenter.transferDetail(roundTrip),
            "2 potwierdzonych · 1 rozbieżności"
        )
    }

    func testExportFileDeclaresOnlyAggregateJSONAndCSVRepresentations() {
        XCTAssertEqual(PilotDashboardExportFormat.json.contentType, .json)
        XCTAssertEqual(PilotDashboardExportFormat.csv.contentType, .commaSeparatedText)
        XCTAssertEqual(PilotDashboardExportFormat.json.fileName, "raport-pilota-kpi.json")
        XCTAssertEqual(PilotDashboardExportFormat.csv.fileName, "raport-pilota-kpi.csv")
        XCTAssertEqual(PilotDashboardExportFormat.json.buttonTitle, "Udostępnij raport JSON")
        XCTAssertEqual(PilotDashboardJSONExport(data: Data("{}".utf8)).data, Data("{}".utf8))
        XCTAssertEqual(PilotDashboardCSVExport(data: Data("a,b\n".utf8)).data, Data("a,b\n".utf8))
    }

    func testDefaultViewCanBeConstructedAtAccessibilitySizes() {
        let view = PilotDashboardView()
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.horizontalSizeClass, .compact)

        XCTAssertNotNil(view)
    }

    private func reportWithCompletedBooks(_ count: Int) -> PilotReport {
        PilotReportBuilder.build(from: (0..<count).map { index in
            record(
                UInt64(index + 1),
                .catalog(.init(
                    publicationKind: .book,
                    outcome: .completed,
                    activeMilliseconds: 1_000
                ))
            )
        })
    }

    private func record(_ sequence: UInt64, _ event: PilotMetricEvent) -> PilotMetricRecord {
        PilotMetricRecord(sequence: sequence, dayIndex: 0, event: event)
    }
}
