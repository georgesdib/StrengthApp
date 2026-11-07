import SwiftUI
import HealthKit

struct ContentView: View {
    @State private var stepsText = "Tap to load steps"
    @State private var isLoading = false
    let healthStore = HKHealthStore()

    var body: some View {
        VStack(spacing: 20) {
            Text(stepsText)
                .font(.title2)
                .padding()

            Button(isLoading ? "Loading..." : "Load Today's Steps") {
                Task { await loadSteps() }
            }
            .disabled(isLoading)
        }
    }

    func loadSteps() async {
        isLoading = true
        defer { isLoading = false }

        guard HKHealthStore.isHealthDataAvailable() else {
            stepsText = "HealthKit not available"
            return
        }

        let stepType = HKQuantityType(.stepCount)
        let typesToRead: Set<HKObjectType> = [stepType]

        // 1) Request authorization
        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
        } catch {
            stepsText = "Auth error: \(error.localizedDescription)"
            return
        }

        // 2) Query today's steps from midnight to now
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date())

        // Use statistics query to sum step count over the period
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: stepType, predicate: predicate),
            options: .cumulativeSum
        )

        do {
            let result = try await descriptor.result(for: healthStore)
            let sum = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
            stepsText = "Today's steps: \(Int(sum))"
        } catch {
            stepsText = "Query error: \(error.localizedDescription)"
        }
    }
}
