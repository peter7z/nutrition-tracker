import Foundation

/// Portable exports omit request contexts and archives belonging to another account.
enum TrackingExportScope {
    static func health(_ snapshot: HealthSnapshot, ownerID: String?) throws -> HealthSnapshot {
        let scope: String
        if let ownerID { guard let id = UUID(uuidString: ownerID) else { throw NutritionError.invalidData }; scope = id.uuidString.lowercased() }
        else { scope = "local" }
        var result = snapshot
        result.closedNutritionDays = snapshot.closedNutritionDays?.filter { $0.accountScope.lowercased() == scope }
        result.pendingChatContexts = nil
        return result
    }
}

/// Filter record_type before summing: food rows, source totals and frozen closures are separate records.
enum TrackingCSVExport {
    static let columns = ["record_type", "id", "parent_id", "version", "date", "recorded_at", "end_at", "time_zone", "source", "name", "meal", "quantity", "unit", "preparation", "nutrition_basis", "kcal", "protein_g", "carbohydrates_g", "fat_g", "saturated_fat_g", "grams_per_serving", "milliliters_per_serving", "grams_per_milliliter", "weight_kg", "activity_kind", "duration_minutes", "active_kcal", "closed", "completeness", "intake_selection", "notes", "product_id", "product_version", "recipe_id", "recipe_version", "import_batch_id", "source_row", "goal_version_id", "deleted", "metric", "value", "metric_unit", "provenance", "source_bundle_id", "device", "details_json", "consumed_kcal", "consumed_protein_g", "consumed_carbohydrates_g", "consumed_fat_g", "consumed_saturated_fat_g"]

    static func encode(nutrition: NutritionSnapshot, health: HealthSnapshot? = nil, ownerID: String? = nil) throws -> Data {
        try NutritionBackup.validate(nutrition)
        var rows = [columns.map(quoted).joined(separator: ",")]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in guard date.timeIntervalSinceReferenceDate.isFinite else { throw NutritionError.invalidData }; var container = encoder.singleValueContainer(); try container.encode(timestamp(date)) }
        func details<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func append(_ type: String, _ cells: [String: String]) {
            var row = cells; row["record_type"] = type; row["time_zone"] = row["time_zone"] ?? nutrition.profile.timeZoneIdentifier
            rows.append(columns.map { quoted(row[$0] ?? "") }.joined(separator: ","))
        }
        func nutrients(_ values: NutrientValues) -> [String: String] { ["kcal":number(values.energy),"protein_g":number(values.protein),"carbohydrates_g":number(values.carbohydrates),"fat_g":number(values.fat),"saturated_fat_g":number(values.saturatedFat)] }
        func draft(_ d: FoodEntryDraft) -> [String: String] {
            var cells = nutrients(d.nutrition)
            cells.merge(["name":d.name,"meal":d.mealName,"recorded_at":timestamp(d.consumedAt),"date":nutrition.profile.dayID(for:d.consumedAt),"quantity":number(d.amount),"unit":d.unit.rawValue,"preparation":d.preparation.rawValue,"nutrition_basis":d.basis.rawValue,"source":d.source.rawValue,"notes":d.notes,"grams_per_serving":number(d.conversion?.gramsPerServing),"milliliters_per_serving":number(d.conversion?.millilitersPerServing),"grams_per_milliliter":number(d.conversion?.gramsPerMilliliter),"product_id":d.productID?.uuidString ?? "","product_version":d.productVersion.map(String.init) ?? "","recipe_id":d.recipeID?.uuidString ?? "","recipe_version":d.recipeVersion.map(String.init) ?? ""], uniquingKeysWith: { _,new in new })
            return cells
        }
        append("profile", ["notes":nutrition.profile.preferences,"details_json":try details(nutrition.profile)])
        for entry in nutrition.entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var cells = draft(entry.draft); cells.merge(["id":entry.id.uuidString,"version":String(entry.version),"date":entry.dayID,"deleted":String(entry.deleted),"details_json":try details(entry)],uniquingKeysWith:{ _,new in new })
            let consumed = entry.values
            cells.merge(["consumed_kcal":number(consumed.energy),"consumed_protein_g":number(consumed.protein),"consumed_carbohydrates_g":number(consumed.carbohydrates),"consumed_fat_g":number(consumed.fat),"consumed_saturated_fat_g":number(consumed.saturatedFat)],uniquingKeysWith:{ _,new in new })
            append("food_entry",cells)
        }
        for day in nutrition.days.sorted(by: { $0.id < $1.id }) {
            append("day",["id":day.id,"date":day.id,"version":String(day.version),"closed":String(day.isClosed),"details_json":try details(day)])
            for closure in day.summaries {
                // Raw Health values belong to the opt-in scoped archive, never manual day metadata.
                var cells = nutrients(closure.intakeSource == .health ? NutrientValues() : closure.totals.completeValues)
                cells.merge(["id":closure.id.uuidString,"parent_id":day.id,"date":day.id,"recorded_at":timestamp(closure.closedAt),"version":String(closure.version),"closed":"true","completeness":closure.completeness.rawValue,"intake_selection":closure.intakeSource?.rawValue ?? "manual","goal_version_id":closure.goalVersionID?.uuidString ?? "","details_json":try details(closure)],uniquingKeysWith:{ _,new in new })
                append("closed_day",cells)
            }
        }
        for summary in nutrition.historicalSummaries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var cells = nutrients(summary.nutrients); cells.merge(["id":summary.id.uuidString,"date":summary.dayID,"source":"spreadsheet","closed":String(summary.isClosed),"notes":summary.notes,"import_batch_id":summary.importBatchID.uuidString,"source_row":summary.sourceRow,"details_json":try details(summary)],uniquingKeysWith:{ _,new in new }); append("historical_nutrition",cells)
        }
        for weight in nutrition.weights.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append("weight",["id":weight.id.uuidString,"recorded_at":timestamp(weight.recordedAt),"date":nutrition.profile.dayID(for:weight.recordedAt),"weight_kg":number(weight.kilograms),"unit":"kg","source":weight.source.rawValue,"notes":weight.notes,"import_batch_id":weight.importBatchID?.uuidString ?? "","details_json":try details(weight)])
        }
        for activity in nutrition.activities.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append("activity",["id":activity.id.uuidString,"recorded_at":timestamp(activity.recordedAt),"date":nutrition.profile.dayID(for:activity.recordedAt),"activity_kind":activity.kind,"duration_minutes":number(activity.durationMinutes),"active_kcal":number(activity.activeEnergy),"source":activity.source.rawValue,"notes":activity.notes,"import_batch_id":activity.importBatchID?.uuidString ?? "","details_json":try details(activity)])
        }
        for goal in nutrition.goals.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var cells = nutrients(NutrientValues(energy:goal.goals?.energy,protein:goal.goals?.protein,carbohydrates:goal.goals?.carbohydrates,fat:goal.goals?.fat)); cells.merge(["id":goal.id.uuidString,"date":goal.effectiveDay,"recorded_at":timestamp(goal.effectiveDate),"source":"manual","details_json":try details(goal)],uniquingKeysWith:{ _,new in new });append("goal",cells)
        }
        for product in nutrition.products.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var cells = nutrients(product.nutrition);cells.merge(["id":product.id.uuidString,"version":String(product.version),"name":product.name,"provenance":product.brand,"recorded_at":timestamp(product.updatedAt),"source":product.source.rawValue,"nutrition_basis":product.basis.rawValue,"grams_per_serving":number(product.conversion?.gramsPerServing),"milliliters_per_serving":number(product.conversion?.millilitersPerServing),"grams_per_milliliter":number(product.conversion?.gramsPerMilliliter),"details_json":try details(product)],uniquingKeysWith:{ _,new in new });append("product",cells)
        }
        for recipe in nutrition.recipes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append("recipe",["id":recipe.id.uuidString,"version":String(recipe.version),"name":recipe.name,"recorded_at":timestamp(recipe.updatedAt),"source":"recipe","quantity":number(recipe.finalWeightGrams),"unit":recipe.finalWeightGrams == nil ? "" : "gram","details_json":try details(recipe)])
            for (index,ingredient) in recipe.ingredients.enumerated() { var cells=draft(ingredient);cells["parent_id"]=recipe.id.uuidString;cells["id"]=recipe.id.uuidString+"/ingredient/"+String(index);cells["details_json"]=try details(ingredient);append("recipe_ingredient",cells) }
        }
        for batch in nutrition.importBatches.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { append("import_batch",["id":batch.id.uuidString,"recorded_at":timestamp(batch.importedAt),"name":batch.fileName,"source":"spreadsheet","details_json":try details(batch)]) }
        for resolution in nutrition.intakeResolutions.sorted(by: { $0.dayID < $1.dayID }) { append("intake_resolution",["id":resolution.revisionID.uuidString,"date":resolution.dayID,"intake_selection":resolution.selection.rawValue,"import_batch_id":resolution.createdByBatchID?.uuidString ?? "","details_json":try details(resolution)]) }
        if let health = try health.map({ try TrackingExportScope.health($0,ownerID:ownerID) }) {
            let zone = health.configuration?.timeZoneIdentifier ?? nutrition.profile.timeZoneIdentifier
            var profile = nutrition.profile;profile.timeZoneIdentifier = zone
            guard health.samples.allSatisfy({ $0.value.isFinite && $0.value >= 0 && $0.startDate.timeIntervalSince1970.isFinite && $0.endDate.timeIntervalSince1970.isFinite }), health.dailyValues.allSatisfy({ $0.value.isFinite && $0.value >= 0 && $0.date.timeIntervalSince1970.isFinite }), (health.closedNutritionDays ?? []).allSatisfy({ $0.closedAt.timeIntervalSince1970.isFinite && $0.values.allSatisfy({ $0.value.isFinite && $0.value >= 0 && $0.date.timeIntervalSince1970.isFinite }) }) else { throw NutritionError.invalidData }
            for sample in health.samples.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                append("health_observation",["id":sample.id.uuidString,"date":profile.dayID(for:sample.endDate),"recorded_at":timestamp(sample.startDate),"end_at":timestamp(sample.endDate),"time_zone":zone,"source":"health","metric":sample.metric.rawValue,"value":number(sample.value),"metric_unit":sample.metric.unit,"provenance":sample.sourceName,"source_bundle_id":sample.sourceBundleIdentifier,"device":sample.deviceName ?? "","details_json":try details(sample)])
            }
            for value in health.dailyValues.sorted(by: { $0.date == $1.date ? $0.metric.rawValue < $1.metric.rawValue : $0.date < $1.date }) { append("health_daily",["date":profile.dayID(for:value.date),"recorded_at":timestamp(value.date),"time_zone":zone,"source":"health","metric":value.metric.rawValue,"value":number(value.value),"metric_unit":value.metric.unit,"provenance":value.sourceNames.joined(separator:"; "),"details_json":try details(value)]) }
            for closure in health.closedNutritionDays ?? [] { for value in closure.values { append("health_closed_nutrition",["id":closure.id.uuidString,"date":closure.dayID,"recorded_at":timestamp(closure.closedAt),"time_zone":zone,"source":"health","closed":"true","metric":value.metric.rawValue,"value":number(value.value),"metric_unit":value.metric.unit,"details_json":try details(closure)]) } }
        }
        let data = Data((rows.joined(separator:"\r\n")+"\r\n").utf8)
        guard data.count <= 100_000_000 else { throw NutritionError.invalidData }
        return data
    }
    nonisolated private static func quoted(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
    nonisolated private static func number(_ value: Double?) -> String { value.map(String.init(describing:)) ?? "" }
    nonisolated private static func timestamp(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceReferenceDate;guard seconds.isFinite else { return "" };var whole=floor(seconds);var nanos=Int(((seconds-whole)*1_000_000_000).rounded())
        if nanos==1_000_000_000 { whole+=1;nanos=0 }
        let f=ISO8601DateFormatter();let base=f.string(from:Date(timeIntervalSinceReferenceDate:whole))
        return String(base.dropLast())+String(format:".%09dZ",nanos)
    }
}
