import SwiftUI

/// Shown after a valid QR scan and before the one-time code is sent.
struct PairingConfirmationView: View {
    let host: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var deviceName = DeviceDisplayName.fallback

    var body: some View {
        Form {
            Section {
                Text(host)
                    .font(.headline)
                    .textSelection(.enabled)
            } header: {
                Text("Адрес Katana")
            } footer: {
                Text("Подключайтесь, только если узнаёте этот адрес.")
            }

            Section {
                TextField("Имя устройства", text: $deviceName)
                    .autocorrectionDisabled()
                    .onChange(of: deviceName) { newValue in
                        if newValue.count > DeviceDisplayName.maxLength {
                            deviceName = String(newValue.prefix(DeviceDisplayName.maxLength))
                        }
                    }
            } header: {
                Text("Имя этого iPhone в Katana")
            } footer: {
                Text("До \(DeviceDisplayName.maxLength) символов. Пустое имя заменится на «\(DeviceDisplayName.fallback)».")
            }

            Section {
                Label("Подключение даст Katana доступ только к функциям, которые вы явно разрешите на этом iPhone. Фотографии в Katana не отправляются.",
                      systemImage: "lock.shield")
                    .font(.footnote)
            }

            Section {
                Button {
                    onConfirm(deviceName)
                } label: {
                    Text("Подключить").bold()
                }
                Button("Отмена", role: .cancel, action: onCancel)
            }
        }
    }
}
