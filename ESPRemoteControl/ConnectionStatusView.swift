import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var input: RemoteInputController
    var compact = false
    @State private var showsBluetooth = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Підключення", selection: Binding(get: { input.mode }, set: input.selectMode)) {
                    ForEach(RemoteInputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(input.mode == .esp ? "ESP" : "BT").fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .disabled(input.isSwitching)
            .accessibilityLabel("Режим підключення")
            .accessibilityValue(input.mode.title)

            Circle().fill(input.isReady ? .green : .orange).frame(width: 7, height: 7)
            Text(input.statusText)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if input.mode == .bluetooth {
                Button { showsBluetooth = true } label: {
                    Image(systemName: "link.badge.plus")
                }
                .accessibilityLabel("Комп’ютери та сполучення Bluetooth")
                .disabled(input.isSwitching)
            }
            Button(action: input.reconnectNow) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(input.isSwitching)
            .accessibilityLabel("Перепідключити")
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showsBluetooth) {
            DirectBluetoothSheet(transport: input.direct, browser: input.direct.browser)
        }
    }
}

private struct DirectBluetoothSheet: View {
    @ObservedObject var transport: DirectHIDTransport
    @ObservedObject var browser: BluetoothHostBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var hostToRename: SavedHIDHost?
    @State private var hostToForget: SavedHIDHost?
    @State private var editedName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(transport.statusText, systemImage: transport.isReady ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(transport.isReady ? .green : .primary)
                    if let error = transport.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                if !transport.savedHosts.isEmpty {
                    Section {
                        ForEach(transport.savedHosts) { host in
                            HStack(spacing: 12) {
                                Button { transport.connect(to: host.id) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(host.name)
                                            Text(hostStatus(host.id))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if transport.connectedHostID == host.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                        } else if transport.selectedHostID == host.id {
                                            Image(systemName: "clock").foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .disabled(!transport.canPair)
                                Menu {
                                    Button("Перейменувати", systemImage: "pencil") {
                                        editedName = host.customName ?? host.discoveredName ?? ""
                                        hostToRename = host
                                    }
                                    Button("Забути в застосунку", systemImage: "trash", role: .destructive) {
                                        hostToForget = host
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .padding(.vertical, 8)
                                }
                                .accessibilityLabel("Налаштування: \(host.name)")
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: {
                        Text("Мої комп’ютери")
                    } footer: {
                        Text("Натисни на комп’ютер, щоб спрямувати ввід до нього. Якщо назва недоступна, задай її через меню ⋯. Для зміни комп’ютера іноді потрібно від’єднати iPhone від попереднього в налаштуваннях Bluetooth.")
                    }
                }
                Section("Сполучення з комп’ютера") {
                    Text("У налаштуваннях Bluetooth комп’ютера вибери «\(transport.advertisedName)» або ім’я цього iPhone. Підтвердь системний запит, якщо він з’явиться.")
                        .font(.subheadline)
                    Button(transport.isPairing ? "Сполучення відкрите · поновити" : "Дозволити нове сполучення") {
                        transport.beginPairing()
                    }
                    .disabled(!transport.canPair)
                }
                Section("Сполучення з iPhone") {
                    Text("Якщо Mac уже знає iPhone й не показує його як клавіатуру, відкрий Bluetooth на Mac, запусти пошук тут і вибери Mac. Комп’ютер має бути доступний через Bluetooth LE.")
                        .font(.subheadline)
                    Button(browser.isScanning ? "Зупинити пошук" : "Знайти комп’ютер") {
                        if browser.isScanning { browser.stopScan() } else { browser.scan() }
                    }
                    .disabled(!transport.canPair)
                    if !browser.statusText.isEmpty {
                        Text(browser.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(browser.devices.filter { device in !transport.savedHosts.contains { $0.id == device.id } }) { device in
                        Button {
                            transport.connect(to: device.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                    if let signal = device.signal {
                                        Text("\(signal) dBm").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if transport.connectedHostID == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                } else if transport.selectedHostID == device.id {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(!transport.canPair || !device.isConnectable)
                    }
                }
                Section("Журнал підключення") {
                    ShareLink(item: transport.diagnosticText) {
                        Label("Поділитися журналом", systemImage: "square.and.arrow.up")
                    }
                    Text("Журнал містить етапи підключення, назву та скорочений ідентифікатор комп’ютера, без введеного тексту.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(transport.diagnostics.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .alert("Назва комп’ютера", isPresented: Binding(
            get: { hostToRename != nil },
            set: { if !$0 { hostToRename = nil } }
        ), presenting: hostToRename) { host in
            TextField("Наприклад, Linux або MacBook", text: $editedName)
            Button("Зберегти") {
                transport.renameHost(host.id, to: editedName)
                hostToRename = nil
            }
            Button("Скасувати", role: .cancel) { hostToRename = nil }
        } message: { _ in
            Text("Ця назва використовується лише в ESP Remote. Порожнє поле повертає автоматичну назву.")
        }
        .alert("Забути комп’ютер?", isPresented: Binding(
            get: { hostToForget != nil },
            set: { if !$0 { hostToForget = nil } }
        ), presenting: hostToForget) { host in
            Button("Забути", role: .destructive) {
                transport.forgetHost(host.id)
                hostToForget = nil
            }
            Button("Скасувати", role: .cancel) { hostToForget = nil }
        } message: { host in
            Text("\(host.name) буде вилучено зі списку та автопідключення застосунку. Системне спарювання залишиться. Щоб видалити і його: Налаштування iPhone → Bluetooth → ⓘ → Забути цей пристрій або видали iPhone на комп’ютері.")
        }
        .onDisappear { browser.stopScan() }
    }

    private func hostStatus(_ id: UUID) -> String {
        if transport.connectedHostID == id { return "Клавіатура й миша підключені" }
        if transport.selectedHostID == id { return "Вибрано · очікуємо підключення" }
        return "Натисни, щоб підключити"
    }
}
