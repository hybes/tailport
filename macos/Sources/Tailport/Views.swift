import SwiftUI
import AppKit

struct PortsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Forward from").foregroundStyle(.secondary)
                    Picker("Machine", selection: Binding(get: { model.machine }, set: model.selectMachine)) {
                        if !model.peers.contains(where: { $0.target == model.machine }) {
                            Text(model.machine).tag(model.machine)
                        }
                        ForEach(Peer.grouped(model.peers), id: \.owner) { group in
                            Section(group.owner ?? "My devices") {
                                ForEach(group.peers) { peer in
                                    Text(peer.online ? peer.displayName : "\(peer.displayName) · Offline").tag(peer.target)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)
                    if model.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing ports") }
                }
                GridRow {
                    Text("Route traffic through").foregroundStyle(.secondary)
                    RouterPicker(model: model)
                        .labelsHidden()
                        .frame(width: 260, alignment: .leading)
                        .help("Use a device as a Tailscale exit node to reach its network, such as your home router, from anywhere.")
                        .accessibilityIdentifier("router")
                    if model.routingBusy { ProgressView().controlSize(.small).accessibilityLabel("Changing route") }
                }
            }
            RoutingStatus(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 16)

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
                .padding(.top, 12)
            }

            Divider().padding(.top, 14)
            if !model.visiblePorts.isEmpty || !model.devices.isEmpty {
                List {
                    if !model.devices.isEmpty {
                        Section {
                            ForEach(model.devices) { device in DeviceRow(model: model, device: device) }
                        } header: {
                            SectionHeader(title: "Devices on \(model.machineName)’s network") {
                                Button("Add…") { model.showAddDevice = true }
                                    .buttonStyle(.link)
                                    .help("Reach another device on \(model.machineName)’s network")
                            }
                        }
                    }
                    Section {
                        if model.visiblePorts.isEmpty {
                            Text(portsPlaceholder).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(model.visiblePorts) { port in PortRow(model: model, port: port) }
                    } header: {
                        SectionHeader(title: "Listening ports on \(model.machineName)",
                                      help: "Each port you turn on opens at the same port on this Mac.") {
                            if !model.eligiblePorts.isEmpty || model.hasForwards { allPortsToggle }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Overlay scroll bars are hidden by default; flash them so rows below the fold are noticed.
                .scrollIndicatorsFlash(onAppear: true)
            } else {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Show excluded (\(model.ignoredCount))", isOn: $model.showIgnored)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("showIgnored")
                Spacer()
                if model.forwardingCount > 0 || model.failedCount > 0 {
                    Text([model.forwardingCount > 0 ? "\(model.forwardingCount) forwarding" : nil,
                          model.failedCount > 0 ? "\(model.failedCount) failed" : nil].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
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
                Button { model.showAddDevice = true } label: { Label("Add device", systemImage: "plus") }
                    .help("Reach a device on \(model.machineName)’s network, such as its router")
                    .accessibilityIdentifier("addDevice")
                Button { model.showExclusions = true } label: { Label("Exclusions", systemImage: "line.3.horizontal.decrease") }
                    .help("Edit excluded ports and services")
                    .accessibilityIdentifier("exclusions")
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(model.refreshing)
            }
        }
        .sheet(isPresented: $model.showExclusions) { ExclusionsView(model: model) }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceView(model: model) }
    }

    private var allPortsToggle: some View {
        Toggle("All ports", isOn: Binding(get: { model.hasForwards }, set: model.setAllEnabled))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.eligiblePorts.isEmpty || (!model.discoveryAvailable && !model.hasForwards))
            .help("Forward every allowed port to the same port on this Mac, or stop them all. Excluded ports stay off.")
            .accessibilityIdentifier("allPorts")
    }

    private var portsPlaceholder: String {
        if model.refreshing && model.lastRefresh == nil { return "Finding listening ports…" }
        if model.error != nil { return "Ports unavailable. See the message above." }
        if model.ignoredCount > 0 { return "All listening ports are excluded." }
        return "No listening ports found."
    }

    @ViewBuilder private var emptyState: some View {
        if model.refreshing && model.lastRefresh == nil {
            VStack(spacing: 12) { ProgressView(); Text("Finding listening ports…").foregroundStyle(.secondary) }
        } else if model.error != nil {
            ContentUnavailableView {
                Label("Ports unavailable", systemImage: "network.slash")
            } description: {
                Text("Fix the connection above, then refresh. You can still add a device on \(model.machineName)’s network.")
            } actions: {
                Button("Add device…") { model.showAddDevice = true }
            }
        } else if model.ignoredCount > 0 {
            ContentUnavailableView("All ports are excluded", systemImage: "line.3.horizontal.decrease",
                                   description: Text("Show excluded ports or edit your exclusions."))
        } else {
            ContentUnavailableView {
                Label("No listening ports", systemImage: "network")
            } description: {
                Text("Start a development server on \(model.machineName), or add a device on its network, such as its router.")
            } actions: {
                Button("Add device…") { model.showAddDevice = true }
            }
        }
    }
}

/// A list section title with an optional control on the right, used for devices and ports alike.
private struct SectionHeader<Accessory: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title).help(help ?? "")
            Spacer()
            accessory.font(.callout)
        }
    }
}

/// Status text in the normal text colour with a coloured icon, so small text stays readable in light mode
/// and the state is never shown by colour alone.
private struct StatusLabel: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary).textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

private struct FailureText: View {
    let message: String
    var body: some View { StatusLabel(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red) }
}

private struct RoutingStatus: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let error = model.routingError {
                FailureText(message: error)
            } else if let router = model.router {
                if router.online {
                    Text(Routing.summary(for: router)).foregroundStyle(.secondary)
                } else {
                    StatusLabel(text: "\(router.name) is offline, so this Mac may have no internet access. Choose Off or another device.",
                                systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
            } else if !model.peers.isEmpty && model.routers.isEmpty {
                Text("No online device offers routing. Turn on “Run as exit node” on one, then approve it in the Tailscale admin console.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Chooses the Tailscale exit node. Shared by the window and the menu bar.
struct RouterPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker("Route traffic through", selection: Binding(get: { model.router?.target ?? "" },
                                                           set: { target in Task { await model.route(through: target.isEmpty ? nil : target) } })) {
            Text("Off").tag("")
            ForEach(Peer.grouped(model.routers), id: \.owner) { group in
                Section(group.owner ?? "My devices") {
                    ForEach(group.peers) { peer in Text(label(for: peer)).tag(peer.target) }
                }
            }
        }
        .disabled(model.routingBusy || (model.routers.isEmpty && model.router == nil))
    }

    private func label(for peer: Peer) -> String {
        let network = peer.routes.isEmpty ? "" : " · \(peer.routes.joined(separator: ", "))"
        return peer.online ? peer.displayName + network : "\(peer.displayName) · Offline"
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
                status.font(.subheadline).fixedSize(horizontal: false, vertical: true)
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
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .contextMenu {
            if ignored == nil {
                Button("Exclude port \(String(port.number))") { model.ignore(port) }
            } else {
                Button("Edit exclusions…") { model.showExclusions = true }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let ignored {
            Text("Excluded · \(ignored)").foregroundStyle(.secondary)
        } else {
            switch model.states[port.number] {
            case .connecting:
                Text("Connecting…").foregroundStyle(.secondary)
            case .forwarding:
                StatusLabel(text: "Forwarding", systemImage: "checkmark.circle.fill", tint: .green)
            case .failed(let message):
                FailureText(message: message)
            case nil:
                Text("Opens at localhost:\(String(port.number)) when on").foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let device: NetworkDevice

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).lineLimit(1)
                status.font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.deviceStates[device.id] == .forwarding {
                if let url = device.url {
                    Link("localhost:\(String(device.localPort))", destination: url)
                        .font(.callout.monospacedDigit())
                } else {
                    Text("localhost:\(String(device.localPort))")
                        .font(.callout.monospacedDigit())
                        .textSelection(.enabled)
                        .help("Connect to this address in the device’s app")
                }
            }
            if model.deviceStates[device.id] == .connecting { ProgressView().controlSize(.small) }
            Toggle("Forward \(device.name)", isOn: Binding(get: { model.isEnabled(device) }, set: { model.setEnabled($0, for: device) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("device-\(device.id)")
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options for \(device.name)")
            .accessibilityLabel("More options for \(device.name)")
        }
        .padding(.vertical, 9)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .contextMenu { actions }
    }

    /// Shared by the row's ⋯ menu and its right-click menu, so removing a device does not depend on right-clicking.
    @ViewBuilder private var actions: some View {
        if let url = device.url {
            Button("Open localhost:\(String(device.localPort))") { NSWorkspace.shared.open(url) }
                .disabled(model.deviceStates[device.id] != .forwarding)
        }
        Button("Copy address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("localhost:\(device.localPort)", forType: .string)
        }
        Divider()
        Button("Remove \(device.name)", role: .destructive) { model.removeDevice(device) }
    }

    @ViewBuilder private var status: some View {
        switch model.deviceStates[device.id] {
        case .connecting:
            Text("Connecting…").foregroundStyle(.secondary)
        case .forwarding:
            StatusLabel(text: "\(device.address) via \(model.machineName)", systemImage: "checkmark.circle.fill", tint: .green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text(device.address).foregroundStyle(.secondary).monospacedDigit()
                FailureText(message: message)
            }
        case nil:
            Text("\(device.address) → localhost:\(String(device.localPort))").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct AddDeviceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add device").font(.title2.weight(.semibold)).padding([.horizontal, .top], 24)
            Text("Forward a device on \(model.machineName)’s network, such as its router, to this Mac over SSH.")
                .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(scanSummary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button(model.scannedSubnet == nil ? "Scan network" : "Scan again") { Task { await model.scanNetwork() } }
                    .disabled(model.scanning)
                    .accessibilityIdentifier("scanNetwork")
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if let scanError = model.scanError {
                FailureText(message: scanError).font(.callout)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            if !model.scannedHosts.isEmpty {
                List(model.scannedHosts) { host in
                    ScannedHostRow(model: model, host: host, address: $address, name: $name, error: $error)
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }

            if !model.scannedHosts.isEmpty { Divider() }
            VStack(alignment: .leading, spacing: 10) {
                Text("Or enter an address, for example 192.168.1.254:443").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Address", text: $address, prompt: Text("Address"))
                        .frame(width: 170)
                        .accessibilityIdentifier("deviceAddress")
                    TextField("Name", text: $name, prompt: Text("Name (optional)"))
                        .accessibilityIdentifier("deviceName")
                    Button("Add") {
                        do {
                            let device = try model.addDevice(name: name, address: address)
                            model.setEnabled(true, for: device)
                            address = ""
                            name = ""
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                if let error { FailureText(message: error).font(.callout) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 560, height: model.scannedHosts.isEmpty ? nil : 470)
    }

    private var scanSummary: String {
        if model.scanning { return "Scanning \(model.machineName)’s network…" }
        guard let subnet = model.scannedSubnet else { return "Find devices and their open ports." }
        let count = model.scannedHosts.count
        return "\(count) \(count == 1 ? "device" : "devices") on \(subnet). Click a port to forward it."
    }
}

private struct ScannedHostRow: View {
    @ObservedObject var model: AppModel
    let host: ScannedHost
    @Binding var address: String
    @Binding var name: String
    @Binding var error: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label).lineLimit(1).truncationMode(.middle)
                if host.label != host.ip {
                    Text(host.ip).font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(width: 150, alignment: .leading)
            if host.ports.isEmpty {
                Button("Enter port…") { address = "\(host.ip):"; name = host.label; error = nil }
                    .buttonStyle(.link)
                    .help("No common ports answered. Enter the port below.")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(host.ports, id: \.self) { port in portButton(port) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private func portButton(_ port: Int) -> some View {
        let device = model.devices.first { $0.host == host.ip && $0.port == port }
        let on = device.map(model.isEnabled) ?? false
        return Button {
            do { try model.connect(host, port: port); error = nil }
            catch { self.error = error.localizedDescription }
        } label: {
            Label {
                HStack(spacing: 4) {
                    if let service = NetworkScan.service(port) {
                        Text(service)
                        Text(String(port)).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text(String(port)).monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: on ? "checkmark.circle.fill" : "arrow.right.circle")
            }
            .font(.callout)
        }
        .controlSize(.small)
        .disabled(on)
        .help(on ? "Forwarding to localhost:\(String(device!.localPort))"
              : "Opens at localhost:\(String(device?.localPort ?? model.localPort(for: host, port: port)))")
        .accessibilityIdentifier("scan-\(host.ip)-\(port)")
    }
}

/// Wraps port buttons onto extra lines when a device has many open ports.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
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
            Text("Excluded ports stay off, including when you turn on all ports.")
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
            if let error { FailureText(message: error).font(.callout).padding(.horizontal, 24).padding(.bottom, 12) }
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
        Text(model.forwardingCount == 0 ? "Nothing forwarding" : "\(model.forwardingCount) forwarding")
        RouterPicker(model: model)
            .pickerStyle(.menu)
        Button("Open Tailport") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Stop all forwarding", action: model.stopAll).disabled(!model.hasAnyForwards)
        Button("Quit Tailport") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
