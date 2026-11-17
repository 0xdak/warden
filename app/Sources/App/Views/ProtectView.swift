import SwiftUI
import GuardCore

struct ProtectView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CustomRule?

    var body: some View {
        Page(title: "Protect", subtitle: "Choose how strict \(Brand.appName) is, then fine-tune single rules.") {
            Card(title: "Preset") {
                HStack(spacing: 10) {
                    ForEach(Preset.allCases) { p in
                        Button { model.update { $0.preset = p } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(p.title).font(.headline)
                                    Spacer()
                                    if model.settings.preset == p { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                                }
                                Text(p.blurb).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(model.settings.preset == p ? Theme.accent : Color.secondary.opacity(0.25), lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Picker("Mode", selection: Binding(get: { model.settings.mode }, set: { v in model.update { $0.mode = v } })) {
                    Text("Enforce: block and ask as the rules say").tag(ProtectionMode.enforce)
                    Text("Observe: log only, stop nothing (baseline)").tag(ProtectionMode.observe)
                }.pickerStyle(.radioGroup)
            }

            ForEach(RuleCategory.allCases.filter { $0 != .custom }, id: \.self) { cat in
                Card(title: cat.title) {
                    ForEach(RuleCatalog.all.filter { $0.category == cat }) { r in
                        RuleRow(rule: r)
                        if r.id != RuleCatalog.all.filter({ $0.category == cat }).last?.id { Divider() }
                    }
                }
            }

            Card(title: RuleCategory.custom.title) {
                if model.settings.customRules.isEmpty {
                    Text("Add your own path globs, command patterns or regular expressions.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.customRules) { r in
                    HStack {
                        Toggle("", isOn: Binding(get: { r.enabled }, set: { v in
                            model.update { s in if let i = s.customRules.firstIndex(where: { $0.id == r.id }) { s.customRules[i].enabled = v } }
                        })).labelsHidden()
                        VStack(alignment: .leading) {
                            Text(r.name).font(.callout.weight(.medium))
                            Text("\(r.kind.title): \(r.pattern)\(r.agents.isEmpty ? "" : " · " + r.agents.map(\.displayName).joined(separator: ", "))")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(r.action.title).foregroundStyle(Theme.color(r.action))
                        Button("Edit") { editing = r }
                        Button(role: .destructive) { model.update { $0.customRules.removeAll { $0.id == r.id } } } label: { Image(systemName: "trash") }
                    }
                }
                Button("Add rule…") { editing = CustomRule(name: "", kind: .pathGlob, pattern: "", action: .block) }
            }
        }
        .sheet(item: $editing) { r in CustomRuleEditor(rule: r).environment(model) }
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: BuiltinRule

    var body: some View {
        let presetAction = rule.action(for: model.settings.preset)
        let override = model.settings.ruleOverrides[rule.id]
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.callout.weight(.medium))
                    SeverityBadge(severity: rule.severity)
                }
                Text(rule.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if override != nil {
                Button("Reset") { model.update { $0.ruleOverrides[rule.id] = nil } }.font(.caption)
                    .help("Back to the preset (\(presetAction.title))")
            }
            Picker("", selection: Binding(get: { override ?? presetAction }, set: { v in
                model.update { $0.ruleOverrides[rule.id] = (v == presetAction ? nil : v) }
            })) {
                ForEach(RuleAction.allCases) { a in Text(a.title).tag(a) }
            }
            .labelsHidden().frame(width: 110)
        }
    }
}

struct CustomRuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: CustomRule

    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            Picker("Match", selection: $rule.kind) { ForEach(CustomRule.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
            TextField("Pattern", text: $rule.pattern, prompt: Text(placeholder)).font(.system(.body, design: .monospaced))
            Picker("Action", selection: $rule.action) { ForEach(RuleAction.allCases.filter { $0 != .off }) { Text($0.title).tag($0) } }
            Picker("Risk", selection: $rule.severity) { ForEach(Severity.allCases) { Text($0.title).tag($0) } }
            Section("Agents (none selected = all)") {
                ForEach(Agent.allCases) { a in
                    Toggle(a.displayName, isOn: Binding(get: { rule.agents.contains(a) }, set: { on in
                        if on { rule.agents.append(a) } else { rule.agents.removeAll { $0 == a } }
                    }))
                }
            }
            if rule.kind == .regex, (try? NSRegularExpression(pattern: rule.pattern)) == nil, !rule.pattern.isEmpty {
                Text("That regular expression isn't valid.").foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.update { s in
                        if let i = s.customRules.firstIndex(where: { $0.id == rule.id }) { s.customRules[i] = rule } else { s.customRules.append(rule) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty || rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    var placeholder: String {
        switch rule.kind { case .pathGlob: "~/clients/**  or  *.sqlite"; case .commandPattern: "terraform destroy"; case .regex: #"prod-db-\d+"# }
    }
}
