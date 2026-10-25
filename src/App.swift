import SwiftUI
import AppKit

@main
struct KeychainManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Keychain Manager") {
            RootView()
                .environmentObject(appDelegate.secrets)
        }
        .defaultSize(width: 760, height: 580)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Keychain", systemImage: "key.fill") }
            LaunchdView()
                .tabItem { Label("launchd", systemImage: "gearshape.2.fill") }
        }
        .frame(minWidth: 620, minHeight: 460)
        .padding(.top, 6)
    }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", generic = "Generic", internet = "Internet"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var secrets: SecretSession
    @State private var items: [KItem] = []
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var loading = true
    @State private var loadError: String?
    @State private var loadID = UUID()
    @State private var showAdd = false
    @State private var alert: String?
    @State private var toast: String?
    @State private var pendingDelete: KItem?
    @State private var pendingUpdate: KItem?

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
            if let loadError {
                Spacer()
                Text("Couldn’t load passwords").font(.headline)
                Text(loadError).foregroundStyle(.secondary).padding(.horizontal)
                Button("Try Again", action: load).padding(.top, 8)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text(items.isEmpty ? (loading ? "Loading…" : "No passwords found.") : "Nothing matches.")
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
        .onDisappear { secrets.clear() }
        .sheet(isPresented: $showAdd) {
            AddSheet { flash("Saved"); load() }
        }
        .sheet(item: $pendingUpdate) { item in
            UpdateSheet(item: item) { flash("Updated"); load() }
        }
        .alert("Couldn’t complete that",
               isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(alert ?? "") }
        .sheet(item: $pendingDelete) { item in
            DeleteSheet(item: item) {
                do { try Keychain.delete(item); flash("Deleted"); load() }
                catch { alert = error.localizedDescription }
            }
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
                .disabled(loading)
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
                if let pw = secrets.revealed[item.id] {
                    Text(pw.isEmpty ? "(empty)" : pw)
                        .font(.system(.caption, design: .monospaced))
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

            if secrets.isBusy(item.id) {
                ProgressView().controlSize(.small).frame(width: 62)
            } else if let pw = secrets.revealed[item.id] {
                Button("Hide") { secrets.hide(item.id) }.help("Hide this password")
                Button("Copy") { copy(pw) }.frame(width: 62)
            } else {
                Button("Reveal") { reveal(item) }.frame(width: 62)
            }

            Button("Update") {
                secrets.hide(item.id)
                pendingUpdate = item
            }
            .help("Update this password or token")

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
        secrets.clear()
        loading = true
        loadError = nil
        let request = UUID()
        loadID = request
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Keychain.list() }
            DispatchQueue.main.async {
                guard loadID == request else { return }
                loading = false
                switch result {
                case .success(let loaded): items = loaded
                case .failure(let error): items = []; loadError = error.localizedDescription
                }
            }
        }
    }

    private func reveal(_ item: KItem) {
        let token = secrets.beginReveal(for: item.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Keychain.reveal(item) }
            DispatchQueue.main.async {
                guard secrets.finishReveal(for: item.id, token: token, result: outcome) else { return }
                if case .failure(let error) = outcome { alert = error.localizedDescription }
            }
        }
    }

    private func copy(_ pw: String) {
        SecretClipboard.shared.copy(pw)
        flash("Copied — clears in 60s")
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
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var service = ""
    @State private var account = ""
    @State private var password = ""
    @State private var note = ""
    @State private var saving = false
    @State private var saveAlert: SaveAlert?

    private enum SaveAlert {
        case replace(KItem), error(String)
        var title: String {
            switch self {
            case .replace: return "Replace saved password?"
            case .error: return "Couldn’t save password"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add password").font(.title3).fontWeight(.semibold)
            Text("Creates a generic password in your default keychain. You’ll be asked before replacing an existing password.")
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Password").font(.caption).foregroundStyle(.secondary)
                SecureField("secret value", text: $password).textFieldStyle(.roundedBorder)
            }

            field("Note (optional)", "description", $note)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(service.trimmingCharacters(in: .whitespaces).isEmpty
                          || account.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onDisappear { password = "" }
        .alert(saveAlert?.title ?? "",
               isPresented: Binding(get: { saveAlert != nil }, set: { if !$0 { saveAlert = nil } }),
               presenting: saveAlert) { kind in
            switch kind {
            case .replace(let item):
                Button("Cancel", role: .cancel) { }
                Button("Replace", role: .destructive) { save(replacing: item) }
            case .error:
                Button("OK", role: .cancel) { }
            }
        } message: { kind in
            switch kind {
            case .replace(let item):
                Text("A password already exists for \(item.service) / \(item.account). Replace its saved value? This can’t be undone.")
            case .error(let message):
                Text(message)
            }
        }
    }

    private func save(replacing item: KItem? = nil) {
        let service = service.trimmingCharacters(in: .whitespaces)
        let account = account.trimmingCharacters(in: .whitespaces)
        let password = password
        let note = note.trimmingCharacters(in: .whitespaces)
        saving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                if let item {
                    try Keychain.replaceGeneric(item, password: password, note: note)
                } else {
                    try Keychain.addGeneric(service: service, account: account, password: password, note: note)
                }
            }
            DispatchQueue.main.async {
                saving = false
                switch outcome {
                case .success:
                    self.password = ""
                    onSaved()
                    dismiss()
                case .failure(KError.duplicateItem(let existing)):
                    saveAlert = .replace(existing)
                case .failure(let error):
                    saveAlert = .error(error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Update sheet

struct UpdateSheet: View {
    let item: KItem
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var saving = false
    @State private var saveError: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update password or token").font(.title3).fontWeight(.semibold)
            Text("Enter the new value for this item. Its name, account, and other settings stay the same.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.service.isEmpty ? item.label : item.service)
                    .fontWeight(.medium).textSelection(.enabled)
                Text(item.account.isEmpty ? "—" : item.account)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(item.kindLabel.capitalized + " password")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("New password / token").font(.caption).foregroundStyle(.secondary)
                SecureField("new secret value", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Updating…" : "Update") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { passwordFocused = true }
        .onDisappear { password = "" }
        .alert("Couldn’t update password",
               isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(saveError ?? "") }
    }

    private func save() {
        let password = password
        saving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Keychain.updatePassword(item, password: password) }
            DispatchQueue.main.async {
                saving = false
                switch outcome {
                case .success:
                    self.password = ""
                    onSaved()
                    dismiss()
                case .failure(let error):
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Delete sheet (type-to-confirm)

struct DeleteSheet: View {
    let item: KItem
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var name: String { item.service.isEmpty ? item.label : item.service }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete password").font(.title3).fontWeight(.semibold)
            Text("This permanently removes the item from your keychain. It can’t be undone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium).lineLimit(1)
                Text(item.account.isEmpty ? "—" : item.account)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text("Type the name to confirm:").font(.caption).foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).foregroundStyle(.secondary)
                TextField("", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if typed == name { onDelete(); dismiss() } }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete") { onDelete(); dismiss() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(typed != name)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
