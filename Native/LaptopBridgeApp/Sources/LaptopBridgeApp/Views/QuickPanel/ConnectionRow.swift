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

#if DEBUG
#Preview("Connection row") {
    VStack(spacing: 12) {
        ConnectionRow(name: "ChatGPT", connected: true)
        ConnectionRow(name: "Claude", connected: false)
    }.padding().frame(width: 340)
}
#endif
