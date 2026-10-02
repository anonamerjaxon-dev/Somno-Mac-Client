import SwiftUI

struct ContentView: View {
    @StateObject private var sensor = MotionSensorManager()

    var body: some View {
        VStack(spacing: 24) {
            header
            Divider()
            axisData
            magnitudeRow
            Spacer()
            footer
        }
        .padding(28)
        .onAppear { sensor.start() }
        .onDisappear { sensor.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("🍎 Motion Sensor")
                .font(.largeTitle.bold())

            HStack(spacing: 6) {
                Circle()
                    .fill(sensor.isConnected ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(sensor.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Axis data

    private var axisData: some View {
        VStack(spacing: 16) {
            AxisRow(label: "X", value: sensor.x, color: .red)
            AxisRow(label: "Y", value: sensor.y, color: .green)
            AxisRow(label: "Z", value: sensor.z, color: .blue)
        }
    }

    // MARK: - Magnitude

    private var magnitudeRow: some View {
        HStack {
            Text("‖a‖")
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .frame(width: 36, alignment: .leading)

            Text(String(format: "%.4f", sensor.magnitude))
                .font(.system(.title3, design: .monospaced))

            Text("g")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Reads the Bosch BMI286 IMU via IOHID (AppleSPUHIDDevice). Requires Apple Silicon Mac (M2+ or M1 Pro) and sudo.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Axis row

struct AxisRow: View {
    let label: String
    let value: Double
    let color: Color

    private let geometry = AxisBarGeometry()

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.title2.bold())
                .foregroundStyle(color)
                .frame(width: 24, alignment: .leading)

            Text(String(format: "%7.3f g", value))
                .font(.system(.title3, design: .monospaced))
                .frame(width: 110, alignment: .trailing)

            ZStack(alignment: .center) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 12)

                // Center marker
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 1, height: 16)

                // Value bar — anchored at the centre marker.
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.7))
                    .frame(width: geometry.width(for: value), height: 12)
                    .offset(x: geometry.offset(for: value))
            }
            .frame(height: 12)
        }
    }
}
