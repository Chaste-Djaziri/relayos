import SwiftUI

struct ConnectionRow: View {
    let name: String
    let connected: Bool

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(connected ? "Connected" : "OAuth ready")
                .font(.caption)
                .foregroundStyle(connected ? .green : .secondary)
        }
    }
}
