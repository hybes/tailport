import SwiftUI
import AppKit

struct PortsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Forward from").foregroundStyle(.secondary)
                Picker("Machine", selection: Binding(get: { model.machine }, set: model.selectMachine)) {
                    if !model.peers.contains(where: { $0.target == model.machine }) {
                        Text(model.machine).tag(model.machine)
                    }
                    ForEach(model.peers) { peer in
                        Text(peer.online ? peer.name : "\(peer.name) · Offline").tag(peer.target)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing ports") }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listening ports").font(.title2.weight(.semibold))
                    Text("Forward to the same port on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("All ports", isOn: Binding(get: { model.hasForwards }, set: model.setAllEnabled))
                    .toggleStyle(.switch)
                    .disabled(model.eligiblePorts.isEmpty || (!model.discoveryAvailable && !model.hasForwards))
                    .help("Turn all allowed ports on, or stop forwarding. Exclusions always stay off.")
                    .accessibilityIdentifier("allPorts")
            }
            .padding(22)

            if let error = model.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await model.refresh() } }.disabled(model.refreshing)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4))
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }

            Divider()
            if !model.visiblePorts.isEmpty {
                List(model.visiblePorts) { port in PortRow(model: model, port: port) }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
            } else {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Show ignored (\(model.ignoredCount))", isOn: $model.showIgnored)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("showIgnored")
                Spacer()
                if model.forwardingCount > 0 {
                    Text("\(model.forwardingCount) forwarding").foregroundStyle(.secondary)
                } else if let refreshed = model.lastRefresh {
                    Text("Checked \(refreshed, style: .time)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
        }
        .frame(minWidth: 620, minHeight: 420)
        .toolbar {
            ToolbarItemGroup {
                Button { model.showExclusions = true } label: { Label("Exclusions", systemImage: "line.3.horizontal.decrease") }
                    .help("Edit ignored ports and services")
                    .accessibilityIdentifier("exclusions")
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(model.refreshing)
            }
        }
        .sheet(isPresented: $model.showExclusions) { ExclusionsView(model: model) }
    }

    @ViewBuilder private var emptyState: some View {
        if model.refreshing && model.lastRefresh == nil {
            VStack(spacing: 12) { ProgressView(); Text("Finding listening ports…").foregroundStyle(.secondary) }
        } else if model.error != nil {
            ContentUnavailableView("Ports unavailable", systemImage: "network.slash",
                                   description: Text("Fix the connection above, then refresh."))
        } else if model.ignoredCount > 0 {
            ContentUnavailableView("All ports are ignored", systemImage: "line.3.horizontal.decrease",
                                   description: Text("Show ignored ports or edit your exclusions."))
        } else {
            ContentUnavailableView("No listening ports", systemImage: "network",
                                   description: Text("Start a development server on \(model.machineName). This list refreshes every 10 seconds."))
        }
    }
}

private struct PortRow: View {
    @ObservedObject var model: AppModel
    let port: ListeningPort
    private var ignored: String? { model.ignoreReason(port) }

    var body: some View {
        HStack(spacing: 18) {
            Text(String(port.number))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(port.service).lineLimit(2)
                status.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.states[port.number] == .forwarding {
                Link("localhost:\(String(port.number))", destination: URL(string: "http://localhost:\(port.number)")!)
                    .font(.callout.monospacedDigit())
            }
            if model.states[port.number] == .connecting { ProgressView().controlSize(.small) }
            Toggle("Forward port \(String(port.number))", isOn: Binding(get: { model.isEnabled(port) }, set: { model.setEnabled($0, for: port) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(ignored != nil || (!model.discoveryAvailable && !model.isEnabled(port)))
                .accessibilityIdentifier("port-\(port.number)")
        }
        .padding(.vertical, 9)
        .contextMenu {
            if ignored == nil {
                Button("Ignore port \(String(port.number))") { model.ignore(port) }
            } else {
                Button("Edit exclusions…") { model.showExclusions = true }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let ignored {
            Text("Ignored · \(ignored)").foregroundStyle(.secondary)
        } else {
            switch model.states[port.number] {
            case .connecting:
                Text("Connecting…").foregroundStyle(.secondary)
            case .forwarding:
                Label("Forwarding", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            case nil:
                Text("Available").foregroundStyle(.secondary)
            }
        }
    }
}

struct ExclusionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var ports = ""
    @State private var processes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Exclusions").font(.title2.weight(.semibold)).padding([.horizontal, .top], 24)
            Text("Ignored ports stay off, including when you enable all ports.")
                .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 6)
            Form {
                Section {
                    TextField("Ports", text: $ports, axis: .vertical)
                        .lineLimit(2...3)
                        .accessibilityIdentifier("ignoredPorts")
                } footer: {
                    Text("Separate ports with commas. Ranges such as 8000-8010 are supported.")
                }
                Section {
                    TextField("Processes", text: $processes, axis: .vertical)
                        .lineLimit(3...5)
                        .accessibilityIdentifier("ignoredProcesses")
                } footer: {
                    Text("Exact process names, separated by commas. AirPlay is ignored by process, so development servers can still use ports 5000 and 7000.")
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 24).padding(.bottom, 12) }
            HStack {
                Button("Restore defaults") { ports = IgnoreRules.defaultPorts; processes = IgnoreRules.defaultProcesses; error = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try model.applyExclusions(ports: ports, processes: processes); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 460)
        .onAppear { ports = model.ignoredPorts; processes = model.ignoredProcesses }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(model.forwardingCount) ports forwarding")
        Button("Open Tailport") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Stop all forwarding", action: model.stopAll).disabled(!model.hasForwards)
        Button("Quit Tailport") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
