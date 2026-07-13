import SwiftUI
import AppKit

@main
struct KeychainManagerApp: App {
    var body: some Scene {
        WindowGroup("Keychain Manager") {
            ContentView()
        }
        .defaultSize(width: 760, height: 560)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", generic = "Generic", internet = "Internet"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var items: [KItem] = []
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var revealed: [UUID: String] = [:]      // id -> plaintext (in memory only)
    @State private var busy: Set<UUID> = []
    @State private var showAdd = false
    @State private var alert: String?
    @State private var toast: String?
    @State private var pendingDelete: KItem?

    private var filtered: [KItem] {
        items.filter { it in
            switch filter {
            case .generic where it.isInternet: return false
            case .internet where !it.isInternet: return false
            default: break
            }
            if search.isEmpty { return true }
            return "\(it.service) \(it.account) \(it.label)"
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text(items.isEmpty ? "Loading…" : "Nothing matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { row($0) }
                    .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .overlay(alignment: .bottom) { toastView }
        .onAppear(perform: load)
        .sheet(isPresented: $showAdd) {
            AddSheet { service, account, password, note in
                do {
                    try Keychain.addGeneric(service: service, account: account,
                                            password: password, note: note)
                    flash("Saved"); load()
                } catch { alert = error.localizedDescription }
            }
        }
        .alert("Couldn’t complete that",
               isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(alert ?? "") }
        .confirmationDialog(
            "Delete this password?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete “\(item.service.isEmpty ? item.label : item.service)”", role: .destructive) {
                do { try Keychain.delete(item); flash("Deleted"); load() }
                catch { alert = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.account)\nThis can’t be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.tint)
            Text("Keychain Manager").font(.headline)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search service or account", text: $search)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160, maxWidth: 240)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()

            Button(action: load) { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
                .keyboardShortcut("n")
        }
        .padding(12)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: KItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.service.isEmpty ? item.label : item.service)
                    .fontWeight(.medium).lineLimit(1)
                Text(item.account.isEmpty ? "—" : item.account)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let pw = revealed[item.id] {
                    Text(pw.isEmpty ? "(empty)" : pw)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Text(item.kindLabel.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            if busy.contains(item.id) {
                ProgressView().controlSize(.small).frame(width: 62)
            } else if let pw = revealed[item.id] {
                Button("Copy") { copy(pw) }.frame(width: 62)
            } else {
                Button("Reveal") { reveal(item) }.frame(width: 62)
            }

            Button(role: .destructive) { pendingDelete = item } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Delete")
        }
        .padding(.vertical, 4)
    }

    private var toastView: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
    }

    // MARK: - Actions

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Keychain.list()
            DispatchQueue.main.async { items = result }
        }
    }

    private func reveal(_ item: KItem) {
        if revealed[item.id] != nil { revealed[item.id] = nil; return }
        busy.insert(item.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Keychain.reveal(item) }
            DispatchQueue.main.async {
                busy.remove(item.id)
                switch outcome {
                case .success(let pw): revealed[item.id] = pw
                case .failure(let e):  alert = e.localizedDescription
                }
            }
        }
    }

    private func copy(_ pw: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pw, forType: .string)
        flash("Copied to clipboard")
    }

    private func flash(_ msg: String) {
        toast = msg
        let stamp = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == stamp { toast = nil }
        }
    }
}

// MARK: - Add sheet

struct AddSheet: View {
    var onSave: (_ service: String, _ account: String, _ password: String, _ note: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var service = ""
    @State private var account = ""
    @State private var password = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add password").font(.title3).fontWeight(.semibold)
            Text("Creates a generic password in your login keychain (updates it if the service + account already exist).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            field("Service", "e.g. My API", $service)

            VStack(alignment: .leading, spacing: 4) {
                Text("Account / Username").font(.caption).foregroundStyle(.secondary)
                TextField("username, email, or a label like “token”", text: $account)
                    .textFieldStyle(.roundedBorder)
                Text("Who the secret belongs to. For an API token with no user, just use a label like “token” or “default”.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Password", "secret value", $password)
            field("Note (optional)", "description", $note)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(service.trimmingCharacters(in: .whitespaces),
                           account.trimmingCharacters(in: .whitespaces),
                           password, note.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(service.trimmingCharacters(in: .whitespaces).isEmpty
                          || account.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
