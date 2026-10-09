import SwiftUI

extension FoodUnit {
    var titleKey: String { switch self { case .gram: "Grams"; case .milliliter: "Milliliters"; case .serving: "Servings" } }
}
extension NutritionBasis {
    var titleKey: String { switch self { case .per100Grams: "Per 100 g"; case .per100Milliliters: "Per 100 ml"; case .perServing: "Per serving" } }
}
extension FoodPreparation {
    var titleKey: String { switch self { case .unspecified: "Not specified"; case .raw: "Raw"; case .cooked: "Cooked" } }
}
extension FoodSource {
    var titleKey: String { switch self { case .manual: "Manual"; case .label: "Confirmed label"; case .catalog: "Catalog"; case .estimate: "Estimate"; case .recipe: "Recipe" } }
}
extension IntakeSelection {
    var titleKey: String { switch self { case .manual: "Recorded meals"; case .historical: "Spreadsheet summary"; case .health: "Apple Health" } }
}

struct OptionalNutrientField: View {
    let title: LocalizedStringKey
    @Binding var value: Double?
    var identifier = ""
    @Environment(\.locale) private var locale
    var body: some View {
        LabeledContent(title) {
            TextField("Unknown", text: Binding(get: {
                value.map { $0.formatted(.number.precision(.fractionLength(0...3)).locale(locale)) } ?? ""
            }, set: { text in
                if text.isEmpty { value = nil; return }
                let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal
                value = formatter.number(from: text)?.doubleValue ?? Double(text.replacingOccurrences(of: ",", with: ".")) ?? .nan
            }))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
        }
    }
}

struct RequiredNumberField: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    var identifier = ""
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool
    @State private var text: String
    init(title: LocalizedStringKey, value: Binding<Double>, identifier: String = "") {
        self.title = title; _value = value; self.identifier = identifier
        _text = State(initialValue: value.wrappedValue.isFinite ? value.wrappedValue.formatted(.number.precision(.fractionLength(0...3))) : "")
    }
    var body: some View {
        LabeledContent(title) {
            TextField(title, text: Binding(get: { text }, set: { input in
                text = input
                let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal
                value = input.isEmpty ? .nan : formatter.number(from: input)?.doubleValue ?? .nan
            })).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .focused($focused).accessibilityIdentifier(identifier).accessibilityLabel(Text(title))
                .onChange(of: value) { _, amount in
                    let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal
                    let parsed = formatter.number(from: text)?.doubleValue
                    if !focused, parsed != amount, !(amount.isNaN && (text.isEmpty || parsed == nil)) {
                        text = amount.isFinite ? amount.formatted(.number.precision(.fractionLength(0...3)).locale(locale)) : ""
                    }
                }
        }
    }
}

struct FoodEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FoodEntryDraft
    @State private var conversion = PortionConversion()
    @State private var useConversion = false
    @State private var errorKey: String?
    let isEditing: Bool
    let onSave: (FoodEntryDraft) throws -> Void
    init(draft: FoodEntryDraft = FoodEntryDraft(name: "", mealName: "", amount: 100), isEditing: Bool = false, onSave: @escaping (FoodEntryDraft) throws -> Void) {
        _draft = State(initialValue: draft)
        _conversion = State(initialValue: draft.conversion ?? PortionConversion())
        _useConversion = State(initialValue: draft.conversion != nil)
        self.isEditing = isEditing; self.onSave = onSave
    }
    private var candidate: FoodEntryDraft {
        var result = draft; result.conversion = useConversion ? conversion : nil; return result
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("What you ate") {
                    TextField("Food name", text: $draft.name).accessibilityIdentifier("food.name")
                    TextField("Meal name", text: $draft.mealName).accessibilityIdentifier("food.mealName")
                    DatePicker("Consumed at", selection: $draft.consumedAt)
                    RequiredNumberField(title: "Amount consumed", value: $draft.amount, identifier: "food.amount")
                    Picker("Unit", selection: $draft.unit) { ForEach(FoodUnit.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) } }
                    Picker("Preparation", selection: $draft.preparation) { ForEach(FoodPreparation.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) } }
                }
                Section {
                    Picker("Nutrition basis", selection: $draft.basis) { ForEach(NutritionBasis.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) } }
                    OptionalNutrientField(title: "Energy (kcal)", value: $draft.nutrition.energy, identifier: "food.energy")
                    OptionalNutrientField(title: "Protein (g)", value: $draft.nutrition.protein, identifier: "food.protein")
                    OptionalNutrientField(title: "Carbs (g)", value: $draft.nutrition.carbohydrates, identifier: "food.carbs")
                    OptionalNutrientField(title: "Fat (g)", value: $draft.nutrition.fat, identifier: "food.fat")
                    OptionalNutrientField(title: "Saturated fat (g)", value: $draft.nutrition.saturatedFat)
                } header: { Text("Nutrition information") } footer: { Text("Leave unknown nutrients blank. Calories use the confirmed value; they are not replaced with a 4/4/9 calculation.") }
                Section {
                    Toggle("Specify unit conversion", isOn: $useConversion)
                    if useConversion {
                        OptionalNutrientField(title: "Grams per serving", value: $conversion.gramsPerServing)
                        OptionalNutrientField(title: "Milliliters per serving", value: $conversion.millilitersPerServing)
                        OptionalNutrientField(title: "Density (g/ml)", value: $conversion.gramsPerMilliliter)
                    }
                } header: { Text("Portions and units") } footer: { Text("Use a measured serving size or density when converting units. Only the amount consumed is recorded; leftovers are excluded.") }
                Section("Source and notes") {
                    Picker("Source", selection: $draft.source) { ForEach(FoodSource.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) } }
                    TextField("Notes and assumptions", text: $draft.notes, axis: .vertical)
                }
                if let values = try? candidate.values() {
                    Section("Consumed nutrition preview") { NutrientValuesRows(values: values) }
                } else { Section { Text("A valid quantity and explicit unit conversion are required.").foregroundStyle(.orange) } }
                if let errorKey { Section { OperationErrorView(key: errorKey) } }
            }
            .navigationTitle(isEditing ? "Edit food" : "Record food").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do { try candidate.validate(); try onSave(candidate); dismiss() }
                    catch let error as NutritionError { errorKey = error.userFacingKey }
                    catch { errorKey = "Could not save the record. Your saved data is unchanged." }
                }.disabled((try? candidate.validate()) == nil).accessibilityIdentifier("food.save") }
            }
        }
    }
}

extension NutritionError {
    var userFacingKey: String {
        switch self {
        case .closedDay: "Reopen this day before changing its records."
        case .conversionRequired: "Specify the serving size or density to convert these units."
        case .conflict: "This record changed. Refresh it before trying again."
        case .invalidData: "Check the values and required fields."
        case .notFound: "This record is no longer available."
        default: "Could not save the record. Your saved data is unchanged."
        }
    }
}

struct NutrientValuesRows: View {
    let values: NutrientValues
    var body: some View {
        row("Energy", values.energy, "kcal")
        row("Protein", values.protein, "g")
        row("Carbs", values.carbohydrates, "g")
        row("Fat", values.fat, "g")
        row("Saturated fat", values.saturatedFat, "g")
    }
    private func row(_ title: LocalizedStringKey, _ value: Double?, _ unit: String) -> some View {
        LabeledContent(title) {
            if let value { Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)") }
            else { Text("Unknown").foregroundStyle(.secondary) }
        }
    }
}
