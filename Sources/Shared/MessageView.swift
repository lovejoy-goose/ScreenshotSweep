import SwiftUI

struct MessageView: View {
    let icon: String
    let title: String
    let text: String
    let buttonTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }
}
