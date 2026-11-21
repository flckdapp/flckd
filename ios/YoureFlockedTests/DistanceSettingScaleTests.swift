import XCTest
@testable import YoureFlocked

/// The distance sliders in Settings: metric scales are what they always were,
/// Standard scales are round imperial values, and storage stays metric.
final class DistanceSettingScaleTests: XCTestCase {

    private let metersPerFoot = 0.3048
    private let kilometersPerMile = 1.609_344

    private func make(_ setting: DistanceSetting, _ units: DistanceUnits) -> DistanceSettingScale {
        setting.scale(for: units)
    }

    // MARK: - Metric is unchanged

    func testMetricAlertRadiusIs50To500MetresIn25MetreSteps() {
        let steps = make(.alertRadius, .metric).steps
        XCTAssertEqual(steps.map(\.stored), Array(stride(from: 50.0, through: 500.0, by: 25.0)))
        XCTAssertEqual(steps.first?.label, "50m")
        XCTAssertEqual(steps[6].label, "200m")
        XCTAssertEqual(steps.last?.label, "500m")
    }

    func testMetricFetchRadiusIs1To20KilometresInHalfKilometreSteps() {
        let steps = make(.fetchRadius, .metric).steps
        XCTAssertEqual(steps.map(\.stored), Array(stride(from: 1.0, through: 20.0, by: 0.5)))
        XCTAssertEqual(steps.first?.label, "1.0 km")
        XCTAssertEqual(steps[8].label, "5.0 km")
        XCTAssertEqual(steps.last?.label, "20.0 km")
    }

    func testMetricOfflineRadiusIs5To50KilometresIn5KilometreSteps() {
        let steps = make(.offlineRadius, .metric).steps
        XCTAssertEqual(steps.map(\.stored), Array(stride(from: 5.0, through: 50.0, by: 5.0)))
        XCTAssertEqual(steps.first?.label, "5.0 km")
        XCTAssertEqual(steps[3].label, "20.0 km")
        XCTAssertEqual(steps.last?.label, "50.0 km")
    }

    func testMetricValuesOnTheScaleAreShownAndKeptExactly() {
        for setting in DistanceSetting.allCases {
            let scale = make(setting, .metric)
            for (index, step) in scale.steps.enumerated() {
                XCTAssertEqual(scale.index(nearest: step.stored), index)
                XCTAssertNil(scale.stored(movingTo: index, from: step.stored))
            }
        }
    }

    // MARK: - Standard steps

    func testStandardAlertRadiusIs150To1650FeetIn50FootSteps() {
        let steps = make(.alertRadius, .imperial).steps
        XCTAssertEqual(steps.count, 31)
        XCTAssertEqual(Array(steps.map(\.label).prefix(4)), ["150 ft", "200 ft", "250 ft", "300 ft"])
        XCTAssertEqual(Array(steps.map(\.label).suffix(3)), ["1,550 ft", "1,600 ft", "1,650 ft"])
        XCTAssertTrue(steps.map(\.label).contains("1,000 ft"))
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(step.stored, Double(150 + 50 * index) * metersPerFoot, accuracy: 1e-9)
        }
    }

    func testStandardFetchRadiusIsThreeQuartersThenHalfMilesTo12AndAHalf() {
        let steps = make(.fetchRadius, .imperial).steps
        XCTAssertEqual(steps.count, 25)
        XCTAssertEqual(Array(steps.map(\.label).prefix(5)), ["\u{00BE} mi", "1 mi", "1\u{00BD} mi", "2 mi", "2\u{00BD} mi"])
        XCTAssertEqual(Array(steps.map(\.label).suffix(2)), ["12 mi", "12\u{00BD} mi"])
        XCTAssertEqual(steps[0].stored, 0.75 * kilometersPerMile, accuracy: 1e-9)
        for (index, step) in steps.dropFirst().enumerated() {
            XCTAssertEqual(step.stored, (1 + 0.5 * Double(index)) * kilometersPerMile, accuracy: 1e-9)
        }
    }

    func testStandardOfflineRadiusIsEveryMileFrom3To31() {
        let steps = make(.offlineRadius, .imperial).steps
        XCTAssertEqual(steps.map(\.label), (3...31).map { "\($0) mi" })
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(step.stored, Double(3 + index) * kilometersPerMile, accuracy: 1e-9)
        }
    }

    func testStandardScalesCoverTheMetricRange() {
        for setting in DistanceSetting.allCases {
            let metric = make(setting, .metric).steps
            let standard = make(setting, .imperial).steps
            let largestGap = zip(standard, standard.dropFirst()).map { $1.stored - $0.stored }.max() ?? 0
            // Each end of the metric slider is within half a Standard step of an end of the Standard one.
            XCTAssertEqual(standard[0].stored, metric[0].stored, accuracy: largestGap / 2, "\(setting)")
            XCTAssertEqual(standard[standard.count - 1].stored, metric[metric.count - 1].stored,
                           accuracy: largestGap / 2, "\(setting)")
        }
    }

    func testStandardFetchRadiusNeverGoesBelowTheMetricMinimum() {
        XCTAssertGreaterThanOrEqual(make(.fetchRadius, .imperial).steps[0].stored, 1.0)
    }

    func testEveryScaleIsStrictlyIncreasing() {
        for setting in DistanceSetting.allCases {
            for units in DistanceUnits.allCases {
                let stored = make(setting, units).steps.map(\.stored)
                XCTAssertEqual(stored, stored.sorted(), "\(setting) \(units)")
                XCTAssertEqual(Set(stored).count, stored.count, "\(setting) \(units)")
            }
        }
    }

    // MARK: - Nearest-step display of a stored metric value

    func testDefault200MetresShowsAs650Feet() {
        let scale = make(.alertRadius, .imperial)
        XCTAssertEqual(scale.step(nearest: 200).label, "650 ft")
        // 650 ft is 198.12 m: the readout is 1.88 m (about 6 ft) under the 200 m in use.
        XCTAssertEqual(200 - scale.step(nearest: 200).stored, 1.88, accuracy: 0.001)
    }

    func testDefault5KilometreFetchRadiusShowsAs3Miles() {
        XCTAssertEqual(make(.fetchRadius, .imperial).step(nearest: 5).label, "3 mi")
    }

    func testDefault20KilometreOfflineRadiusShowsAs12Miles() {
        XCTAssertEqual(make(.offlineRadius, .imperial).step(nearest: 20).label, "12 mi")
    }

    func testMetricEndsShowAsTheStandardEnds() {
        XCTAssertEqual(make(.alertRadius, .imperial).step(nearest: 50).label, "150 ft")
        XCTAssertEqual(make(.alertRadius, .imperial).step(nearest: 500).label, "1,650 ft")
        XCTAssertEqual(make(.fetchRadius, .imperial).step(nearest: 1).label, "\u{00BE} mi")
        XCTAssertEqual(make(.fetchRadius, .imperial).step(nearest: 20).label, "12\u{00BD} mi")
        XCTAssertEqual(make(.offlineRadius, .imperial).step(nearest: 5).label, "3 mi")
        XCTAssertEqual(make(.offlineRadius, .imperial).step(nearest: 50).label, "31 mi")
    }

    func testEveryMetricStepShowsWithinHalfAStandardStep() {
        for setting in DistanceSetting.allCases {
            let standard = make(setting, .imperial)
            let largestGap = zip(standard.steps, standard.steps.dropFirst()).map { $1.stored - $0.stored }.max() ?? 0
            for step in make(setting, .metric).steps {
                let shown = standard.step(nearest: step.stored)
                XCTAssertLessThanOrEqual(abs(shown.stored - step.stored), largestGap / 2 + 1e-9,
                                         "\(setting) \(step.label) shows as \(shown.label)")
            }
        }
    }

    func testValuesOutsideTheScaleShowAsTheNearestEnd() {
        let scale = make(.alertRadius, .imperial)
        XCTAssertEqual(scale.step(nearest: 0).label, "150 ft")
        XCTAssertEqual(scale.step(nearest: 10_000).label, "1,650 ft")
    }

    func testAStandardValueShowsAsTheNearestMetricStepAfterSwitchingUnits() {
        // 500 ft is 152.4 m, which the metric slider shows as 150 m.
        XCTAssertEqual(make(.alertRadius, .metric).step(nearest: 500 * metersPerFoot).label, "150m")
    }

    // MARK: - Conversion on change

    func testMovingToAStandardStepStoresItInMetres() throws {
        let scale = make(.alertRadius, .imperial)
        let index = try XCTUnwrap(scale.steps.firstIndex { $0.label == "500 ft" })
        let stored = try XCTUnwrap(scale.stored(movingTo: index, from: 200))
        XCTAssertEqual(stored, 152.4, accuracy: 1e-9)
        XCTAssertEqual(scale.step(nearest: stored).label, "500 ft")
    }

    func testMovingToAStandardStepStoresMilesInKilometres() throws {
        let fetch = make(.fetchRadius, .imperial)
        let half = try XCTUnwrap(fetch.steps.firstIndex { $0.label == "2\u{00BD} mi" })
        XCTAssertEqual(try XCTUnwrap(fetch.stored(movingTo: half, from: 5)), 2.5 * kilometersPerMile, accuracy: 1e-9)

        let offline = make(.offlineRadius, .imperial)
        let ten = try XCTUnwrap(offline.steps.firstIndex { $0.label == "10 mi" })
        XCTAssertEqual(try XCTUnwrap(offline.stored(movingTo: ten, from: 20)), 10 * kilometersPerMile, accuracy: 1e-9)
    }

    func testStayingOnTheShownStepDoesNotRewriteTheStoredValue() {
        let scale = make(.alertRadius, .imperial)
        XCTAssertNil(scale.stored(movingTo: scale.index(nearest: 200), from: 200))
    }

    func testEveryStandardStepSurvivesBeingStoredAndShownAgain() {
        for setting in DistanceSetting.allCases {
            let scale = make(setting, .imperial)
            for (index, step) in scale.steps.enumerated() {
                XCTAssertEqual(scale.index(nearest: step.stored), index, "\(setting) \(step.label)")
            }
        }
    }

    func testMovingPastEitherEndStoresTheEnd() {
        let scale = make(.offlineRadius, .imperial)
        XCTAssertEqual(scale.stored(movingTo: -4, from: 20), scale.steps.first?.stored)
        XCTAssertEqual(scale.stored(movingTo: 99, from: 20), scale.steps.last?.stored)
    }

    // MARK: - VoiceOver

    func testSpokenLabelsAvoidSymbolsAndAbbreviations() {
        XCTAssertEqual(make(.alertRadius, .imperial).step(nearest: 200).spokenLabel, "650 feet")
        XCTAssertEqual(make(.alertRadius, .metric).step(nearest: 200).spokenLabel, "200 meters")
        XCTAssertEqual(make(.fetchRadius, .imperial).steps[0].spokenLabel, "0.75 miles")
        XCTAssertEqual(make(.fetchRadius, .imperial).steps[1].spokenLabel, "1 mile")
        XCTAssertEqual(make(.fetchRadius, .imperial).steps[2].spokenLabel, "1.5 miles")
        XCTAssertEqual(make(.fetchRadius, .metric).step(nearest: 5).spokenLabel, "5.0 kilometers")
    }
}
