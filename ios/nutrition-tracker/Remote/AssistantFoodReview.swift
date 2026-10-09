import Foundation

/// Assistant nutrient values describe the entire proposed quantity, never an implicit 100 g base.
enum AssistantFoodReview {
    static func draft(for proposal: AssistantProposal, fallbackDate: Date, intent: String? = nil) throws -> FoodEntryDraft {
        guard ["add", "update"].contains(proposal.action), !proposal.requires_clarification,
              let rawName = proposal.name, rawName.count <= 500,
              let amount = proposal.quantity, amount.isFinite, amount > 0, amount <= 1_000_000,
              let rawUnit = proposal.unit, let unit = FoodUnit(rawValue: rawUnit),
              let totals = proposal.nutrients, totals.isValid,
              proposal.assumptions.count <= 20 else { throw NutritionError.invalidData }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NutritionError.invalidData }
        let preparation: FoodPreparation
        if let state = proposal.state {
            guard let value = FoodPreparation(rawValue: state) else { throw NutritionError.invalidData }
            preparation = value
        } else { preparation = .unspecified }
        let nutrition: NutrientValues
        let conversion: PortionConversion?
        switch unit {
        case .gram:
            nutrition = totals; conversion = PortionConversion(gramsPerServing: amount)
        case .milliliter:
            nutrition = totals; conversion = PortionConversion(millilitersPerServing: amount)
        case .serving:
            nutrition = totals.scaled(by: 1 / amount); conversion = nil
        }
        let draft = FoodEntryDraft(name: name, consumedAt: fallbackDate, amount: amount, unit: unit,
            preparation: preparation, nutrition: nutrition, basis: .perServing, conversion: conversion,
            source: intent == "label" ? .label : .estimate, notes: proposal.assumptions.joined(separator: "\n"))
        // No product or recipe identity is inferred from an assistant response.
        try draft.validate()
        return draft
    }
}

#if canImport(UIKit)
import SwiftUI

struct AssistantFoodAmountReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Double
    @State private var date: Date
    @State private var errorKey: String?
    private let original: FoodEntryDraft
    private let onSave: (FoodEntryDraft) throws -> Void

    init(draft: FoodEntryDraft, onSave: @escaping (FoodEntryDraft) throws -> Void) {
        original = draft; self.onSave = onSave
        _amount = State(initialValue: draft.amount)
        _date = State(initialValue: draft.consumedAt)
    }
    private var candidate: FoodEntryDraft {
        var value = original; value.amount = amount; value.consumedAt = date
        return value
    }
    private var isValid: Bool { (try? candidate.validate()) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("What you ate") {
                    Text(verbatim: original.name).font(.headline)
                    RequiredNumberField(title: "Amount consumed", value: $amount, identifier: "assistant.review.amount")
                    LabeledContent("Unit") { Text(unitTitle) }
                    DatePicker("Consumed at", selection: $date)
                    LabeledContent("Preparation") { Text(LocalizedStringKey(original.preparation.titleKey)) }
                }
                if let values = try? candidate.values() {
                    Section {
                        NutrientValuesRows(values: values)
                    } header: { Text(LocalizedStringKey(original.source == .label ? "Confirmed label" : "Estimated nutrition")) }
                    footer: { Text("Nutrition scales with the amount you consumed. Clarify assumptions in chat.") }
                }
                if !original.notes.isEmpty {
                    Section("Notes and assumptions") { Text(verbatim: original.notes).font(.footnote).foregroundStyle(.secondary) }
                }
                if let errorKey { Section { OperationErrorView(key: errorKey) } }
            }
            .navigationTitle("Review consumed amount").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this quantity") {
                        do { let value = candidate; try value.validate(); try onSave(value); dismiss() }
                        catch { errorKey = (error as? NutritionError)?.userFacingKey ?? "Could not save the record. Your saved data is unchanged." }
                    }.disabled(!isValid).accessibilityIdentifier("assistant.review.save")
                }
            }
        }
    }
    private var unitTitle: LocalizedStringKey {
        switch original.unit { case .gram: "Grams"; case .milliliter: "Milliliters"; case .serving: "Servings" }
    }
}
#endif
