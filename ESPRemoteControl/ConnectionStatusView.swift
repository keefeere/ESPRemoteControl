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
                .accessibilityLabel("Сполучення Bluetooth")
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
                    ForEach(browser.devices) { device in
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
                                if browser.requestedHost == device.id {
                                    if transport.isReady {
                                        Image(systemName: "checkmark.circle.fill")
                                    } else {
                                        ProgressView()
                                    }
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
                    Text("Журнал містить етапи підключення, без введеного тексту.")
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
        .onDisappear { browser.stopScan() }
    }
}
