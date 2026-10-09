import SwiftUI

struct FoodLibraryView: View {
    @Environment(NutritionStore.self) private var store
    @State private var showNewProduct = false
    @State private var showNewRecipe = false
    var body: some View {
        List {
            Section {
                ForEach(store.snapshot.products.sorted { lhs, rhs in
                    if (lhs.source == .label) != (rhs.source == .label) { return lhs.source == .label }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }) { product in
                    NavigationLink { FoodProductDetailView(productID: product.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.name).font(.headline)
                            if !product.brand.isEmpty { Text(product.brand).font(.subheadline).foregroundStyle(.secondary) }
                            HStack {
                                Text(LocalizedStringKey(product.basis.titleKey))
                                Text("·")
                                Text(LocalizedStringKey(product.source.titleKey))
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.snapshot.products.isEmpty { Text("Save a product from its confirmed label or a clearly marked estimate.").foregroundStyle(.secondary) }
                Button("New product", systemImage: "plus") { showNewProduct = true }
            } header: { Text("Products") } footer: { Text("Choose the exact brand and version. Confirmed labels appear before estimates. Editing a product only changes future records.") }
            Section {
                ForEach(store.snapshot.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { recipe in
                    NavigationLink { FoodRecipeDetailView(recipeID: recipe.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.name).font(.headline)
                            Text("\(recipe.ingredients.count) ingredients").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.snapshot.recipes.isEmpty { Text("Save a recipe with its ingredients and measured final weight or number of servings.").foregroundStyle(.secondary) }
                Button("New recipe", systemImage: "plus") { showNewRecipe = true }
            } header: { Text("Recipes") } footer: { Text("A recipe is a preparation, not a meal record. Log only the amount you actually consumed; leftovers remain uncounted.") }
        }
        .navigationTitle("Food library")
        .sheet(isPresented: $showNewProduct) { FoodProductEditor() }
        .sheet(isPresented: $showNewRecipe) { FoodRecipeEditor() }
    }
}

private struct FoodProductDetailView: View {
    @Environment(NutritionStore.self) private var store
    let productID: UUID
    @State private var editing = false
    @State private var logging = false
    @State private var applying = false
    private var product: FoodProduct? { store.snapshot.products.first { $0.id == productID } }
    var body: some View {
        Group {
            if let product {
                List {
                    Section("Product") {
                        LabeledContent("Food name", value: product.name)
                        if !product.brand.isEmpty { LabeledContent("Brand", value: product.brand) }
                        LabeledContent("Source") { Text(LocalizedStringKey(product.source.titleKey)) }
                        LabeledContent("Version") { Text(product.version, format: .number) }
                    }
                    Section { NutrientValuesRows(values: product.nutrition) } header: { Text(LocalizedStringKey(product.basis.titleKey)) }
                    if let conversion = product.conversion {
                        Section("Portions and units") {
                            if let value = conversion.gramsPerServing { LabeledContent("Grams per serving") { Text(value, format: .number) } }
                            if let value = conversion.millilitersPerServing { LabeledContent("Milliliters per serving") { Text(value, format: .number) } }
                            if let value = conversion.gramsPerMilliliter { LabeledContent("Density (g/ml)") { Text(value, format: .number) } }
                        }
                    }
                    Section {
                        Button("Record this product", systemImage: "plus.circle.fill") { logging = true }
                        Button("Edit product", systemImage: "pencil") { editing = true }
                        Button("Apply to an existing record", systemImage: "arrow.triangle.2.circlepath") { applying = true }
                    } footer: { Text("The record keeps a copy of this version's nutrition. Editing the product later does not rewrite previous meals.") }
                }
                .sheet(isPresented: $editing) { FoodProductEditor(product: product) }
                .sheet(isPresented: $logging) {
                    let unit: FoodUnit = product.basis == .per100Grams ? .gram : product.basis == .per100Milliliters ? .milliliter : .serving
                    FoodEntryEditor(draft: product.draft(amount: unit == .serving ? 1 : 100, unit: unit, consumedAt: Date(), mealName: "")) { draft in
                        try store.addEntry(draft)
                    }
                }
                .sheet(isPresented: $applying) { ExistingProductRecordPicker(product: product) }
            } else { ContentUnavailableView("Product unavailable", systemImage: "fork.knife") }
        }
        .navigationTitle(product?.name ?? String(localized: "Product"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExistingProductRecordPicker: View {
    @Environment(NutritionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let product: FoodProduct
    @State private var selectedEntry: FoodEntry?
    private var entries: [FoodEntry] { store.snapshot.entries.filter { !$0.deleted }.sorted { $0.draft.consumedAt > $1.draft.consumedAt } }
    private func isClosed(_ entry: FoodEntry) -> Bool { store.snapshot.days.contains { $0.id == entry.dayID && $0.isClosed } }
    private func replacement(for entry: FoodEntry) -> FoodEntryDraft {
        var draft = product.draft(amount: entry.draft.amount, unit: entry.draft.unit, consumedAt: entry.draft.consumedAt, mealName: entry.draft.mealName)
        draft.preparation = entry.draft.preparation; draft.notes = entry.draft.notes
        return draft
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(entries) { entry in
                        Button { selectedEntry = entry } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.draft.name).font(.headline).foregroundStyle(.primary)
                                Text(entry.draft.mealName).font(.subheadline).foregroundStyle(.secondary)
                                HStack {
                                    Text(entry.draft.consumedAt, style: .date)
                                    Text(entry.draft.amount, format: .number)
                                    Text(LocalizedStringKey(entry.draft.unit.titleKey))
                                }.font(.caption).foregroundStyle(.secondary)
                                if isClosed(entry) { Text("Closed day").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(isClosed(entry))
                    }
                    if entries.isEmpty { Text("No meal records yet.").foregroundStyle(.secondary) }
                } header: { Text("Choose the record to update") } footer: { Text("Only the record you choose will change, after you review and save it. Reopen a closed day from Today before correcting its records.") }
            }
            .navigationTitle("Apply product version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $selectedEntry) { entry in
                FoodEntryEditor(draft: replacement(for: entry), isEditing: true) { draft in
                    try store.updateEntry(id: entry.id, expectedVersion: entry.version, draft: draft)
                }
            }
        }
    }
}

private struct FoodProductEditor: View {
    @Environment(NutritionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var product: FoodProduct
    @State private var conversion: PortionConversion
    @State private var usesConversion: Bool
    @State private var errorKey: String?
    private let expectedVersion: Int?
    init(product: FoodProduct? = nil) {
        let value = product ?? FoodProduct(id: UUID(), version: 1, name: "", nutrition: NutrientValues(), basis: .per100Grams, updatedAt: Date())
        _product = State(initialValue: value); _conversion = State(initialValue: value.conversion ?? PortionConversion())
        _usesConversion = State(initialValue: value.conversion != nil); expectedVersion = product?.version
    }
    private var candidate: FoodProduct { var value = product; value.conversion = usesConversion ? conversion : nil; return value }
    private var isValid: Bool {
        let unit: FoodUnit = candidate.basis == .per100Grams ? .gram : candidate.basis == .per100Milliliters ? .milliliter : .serving
        return (try? candidate.draft(amount: 1, unit: unit, consumedAt: Date(), mealName: "Validation").validate()) != nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Food name", text: $product.name)
                    TextField("Brand", text: $product.brand)
                    Picker("Source", selection: $product.source) {
                        Text("Confirmed label").tag(FoodSource.label)
                        Text("Catalog").tag(FoodSource.catalog)
                        Text("Estimate").tag(FoodSource.estimate)
                        Text("Manual").tag(FoodSource.manual)
                    }
                }
                Section {
                    Picker("Nutrition basis", selection: $product.basis) { ForEach(NutritionBasis.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) } }
                    OptionalNutrientField(title: "Energy (kcal)", value: $product.nutrition.energy)
                    OptionalNutrientField(title: "Protein (g)", value: $product.nutrition.protein)
                    OptionalNutrientField(title: "Carbs (g)", value: $product.nutrition.carbohydrates)
                    OptionalNutrientField(title: "Fat (g)", value: $product.nutrition.fat)
                    OptionalNutrientField(title: "Saturated fat (g)", value: $product.nutrition.saturatedFat)
                } header: { Text("Nutrition information") } footer: { Text("Transcribe the exact basis printed on the label. Leave unreadable or unknown nutrients blank.") }
                Section {
                    Toggle("Specify unit conversion", isOn: $usesConversion)
                    if usesConversion {
                        OptionalNutrientField(title: "Grams per serving", value: $conversion.gramsPerServing)
                        OptionalNutrientField(title: "Milliliters per serving", value: $conversion.millilitersPerServing)
                        OptionalNutrientField(title: "Density (g/ml)", value: $conversion.gramsPerMilliliter)
                    }
                } header: { Text("Portions and units") } footer: { Text("A serving size or measured density is required when recording this product with a different unit.") }
                if expectedVersion != nil { Section { Text("Saving creates a new product version. Previously recorded meals keep their original nutrition.").foregroundStyle(.secondary) } }
                if let errorKey { Section { OperationErrorView(key: errorKey) } }
            }
            .navigationTitle(LocalizedStringKey(expectedVersion == nil ? "New product" : "Edit product"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do { try store.saveProduct(candidate, expectedVersion: expectedVersion); dismiss() }
                    catch let error as NutritionError { errorKey = error.userFacingKey }
                    catch { errorKey = "Could not save the record. Your saved data is unchanged." }
                }.disabled(!isValid) }
            }
        }
    }
}

private struct FoodRecipeDetailView: View {
    @Environment(NutritionStore.self) private var store
    let recipeID: UUID
    @State private var editing = false
    @State private var logging = false
    private var recipe: FoodRecipe? { store.snapshot.recipes.first { $0.id == recipeID } }
    private func recordDraft(_ recipe: FoodRecipe) -> FoodEntryDraft? {
        try? recipe.draft(amount: recipe.finalWeightGrams == nil ? 1 : 100, unit: recipe.finalWeightGrams == nil ? .serving : .gram, consumedAt: Date(), mealName: String(localized: "Meal"))
    }
    private func loggingDraft(_ recipe: FoodRecipe) -> FoodEntryDraft? {
        guard var draft = recordDraft(recipe) else { return nil }; draft.mealName = ""; return draft
    }
    var body: some View {
        Group {
            if let recipe {
                List {
                    Section("Recipe yield") {
                        if let grams = recipe.finalWeightGrams { LabeledContent("Measured final weight (g)") { Text(grams, format: .number) } }
                        if let servings = recipe.servings { LabeledContent("Number of servings") { Text(servings, format: .number) } }
                        LabeledContent("Version") { Text(recipe.version, format: .number) }
                    }
                    Section("Ingredients") {
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ingredient in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ingredient.name).font(.headline)
                                HStack {
                                    Text(ingredient.amount, format: .number)
                                    Text(LocalizedStringKey(ingredient.unit.titleKey))
                                    Text("·")
                                    Text(LocalizedStringKey(ingredient.preparation.titleKey))
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let draft = recordDraft(recipe), let values = try? draft.values() {
                        Section { NutrientValuesRows(values: values) } header: { Text(LocalizedStringKey(recipe.finalWeightGrams == nil ? "Per serving" : "Per 100 g")) }
                    }
                    Section {
                        Button("Record this recipe", systemImage: "plus.circle.fill") { logging = true }
                        Button("Edit recipe", systemImage: "pencil") { editing = true }
                    } footer: { Text("Enter the amount actually consumed. The full prepared batch and leftovers are never added to today's intake automatically.") }
                }
                .sheet(isPresented: $editing) { FoodRecipeEditor(recipe: recipe) }
                .sheet(isPresented: $logging) {
                    if let draft = loggingDraft(recipe) {
                        FoodEntryEditor(draft: draft) { try store.addEntry($0) }
                    }
                }
            } else { ContentUnavailableView("Recipe unavailable", systemImage: "book.closed") }
        }
        .navigationTitle(recipe?.name ?? String(localized: "Recipe"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecipeIngredientItem: Identifiable { var id = UUID(); var draft: FoodEntryDraft }
private struct RecipeIngredientSelection: Identifiable { var id: UUID; var draft: FoodEntryDraft; var isEditing: Bool }

private struct FoodRecipeEditor: View {
    @Environment(NutritionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var ingredients: [RecipeIngredientItem]
    @State private var finalWeightGrams: Double?
    @State private var servings: Double?
    @State private var selection: RecipeIngredientSelection?
    @State private var errorKey: String?
    private let id: UUID
    private let expectedVersion: Int?
    init(recipe: FoodRecipe? = nil) {
        id = recipe?.id ?? UUID(); expectedVersion = recipe?.version
        _name = State(initialValue: recipe?.name ?? "")
        _ingredients = State(initialValue: recipe?.ingredients.map { RecipeIngredientItem(draft: $0) } ?? [])
        _finalWeightGrams = State(initialValue: recipe?.finalWeightGrams)
        _servings = State(initialValue: recipe?.servings)
    }
    private var candidate: FoodRecipe { FoodRecipe(id: id, version: expectedVersion ?? 1, name: name, ingredients: ingredients.map(\.draft), finalWeightGrams: finalWeightGrams, servings: servings, updatedAt: Date()) }
    private var preview: FoodEntryDraft? { try? candidate.draft(amount: finalWeightGrams == nil ? 1 : 100, unit: finalWeightGrams == nil ? .serving : .gram, consumedAt: Date(), mealName: "Validation") }
    var body: some View {
        NavigationStack {
            Form {
                Section("Recipe") { TextField("Recipe name", text: $name) }
                Section {
                    ForEach(ingredients) { item in
                        Button {
                            selection = RecipeIngredientSelection(id: item.id, draft: item.draft, isEditing: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.draft.name).foregroundStyle(.primary)
                                HStack {
                                    Text(item.draft.amount, format: .number)
                                    Text(LocalizedStringKey(item.draft.unit.titleKey))
                                    Text("·")
                                    Text(LocalizedStringKey(item.draft.preparation.titleKey))
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityHint("Edit this ingredient")
                    }.onDelete { ingredients.remove(atOffsets: $0) }
                    Button("Add ingredient", systemImage: "plus") {
                        selection = RecipeIngredientSelection(id: UUID(), draft: FoodEntryDraft(name: "", mealName: String(localized: "Recipe ingredients"), amount: 100), isEditing: false)
                    }
                } header: { Text("Ingredients") } footer: { Text("Record all ingredients used in the preparation, with their raw or cooked state and confirmed nutrition. These ingredients are not added to your day's meals.") }
                Section {
                    OptionalNutrientField(title: "Measured final weight (g)", value: $finalWeightGrams)
                    OptionalNutrientField(title: "Number of servings", value: $servings)
                } header: { Text("Recipe yield") } footer: { Text("Specify the measured weight after preparation or the number of servings. Providing both lets you log grams or servings. Leave a value blank when it is unknown.") }
                if let preview, let values = try? preview.values() {
                    Section { NutrientValuesRows(values: values) } header: { Text(LocalizedStringKey(finalWeightGrams == nil ? "Per serving" : "Per 100 g")) } footer: { Text("If an ingredient's nutrient is unknown, that nutrient stays unknown for the recipe. Only a confirmed consumed portion is recorded.") }
                } else { Section { Text("Add ingredients and a valid final weight or serving count to calculate the recipe.").foregroundStyle(.secondary) } }
                if expectedVersion != nil { Section { Text("Saving creates a new recipe version. Previously consumed portions keep their original snapshot.").foregroundStyle(.secondary) } }
                if let errorKey { Section { OperationErrorView(key: errorKey) } }
            }
            .navigationTitle(LocalizedStringKey(expectedVersion == nil ? "New recipe" : "Edit recipe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do { try store.saveRecipe(candidate, expectedVersion: expectedVersion); dismiss() }
                    catch let error as NutritionError { errorKey = error.userFacingKey }
                    catch { errorKey = "Could not save the record. Your saved data is unchanged." }
                }.disabled(preview == nil) }
            }
            .sheet(item: $selection) { selected in
                FoodEntryEditor(draft: selected.draft, isEditing: selected.isEditing) { draft in
                    if let index = ingredients.firstIndex(where: { $0.id == selected.id }) { ingredients[index].draft = draft }
                    else { ingredients.append(RecipeIngredientItem(id: selected.id, draft: draft)) }
                }
            }
        }
    }
}
