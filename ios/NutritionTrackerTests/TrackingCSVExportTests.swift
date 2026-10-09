import XCTest
@testable import nutrition_tracker

@MainActor final class TrackingCSVExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200.125)
    private func snapshot() -> NutritionSnapshot {
        var s=NutritionSnapshot();let batch=UUID();let product=UUID();let recipe=UUID()
        let d=FoodEntryDraft(name:"Milk, \"label\"",mealName:"Breakfast",consumedAt:date,amount:200,unit:.milliliter,preparation:.raw,nutrition:NutrientValues(energy:45,protein:nil,carbohydrates:5,fat:1),basis:.per100Milliliters,conversion:PortionConversion(gramsPerMilliliter:1.03),source:.label,notes:"First line, \"quoted\"\nSecond line",productID:product,productVersion:2)
        s.entries=[FoodEntry(id:UUID(),version:3,dayID:s.profile.dayID(for:date),draft:d,createdAt:date,updatedAt:date)]
        s.weights=[ManualWeightEntry(id:UUID(),recordedAt:date,kilograms:72,source:.spreadsheet,notes:"Scale note",importBatchID:batch)]
        s.activities=[ManualActivityEntry(id:UUID(),recordedAt:date,kind:"Running",durationMinutes:nil,activeEnergy:200,source:.manual,notes:"Duration unknown")]
        s.historicalSummaries=[HistoricalNutritionSummary(id:UUID(),dayID:"2026-10-07",nutrients:NutrientValues(energy:1800),isClosed:true,notes:"Original summary",importBatchID:batch,sourceRow:"row 7")]
        s.importBatches=[NutritionImportBatch(id:batch,fingerprint:"fixture",importedAt:date,fileName:"original.csv")]
        s.products=[FoodProduct(id:product,version:2,name:"Milk",brand:"Confirmed brand",nutrition:d.nutrition,basis:d.basis,conversion:d.conversion,updatedAt:date)]
        s.recipes=[FoodRecipe(id:recipe,version:1,name:"Milk recipe",ingredients:[d],finalWeightGrams:206,servings:2,updatedAt:date)]
        s.goals=[NutritionGoalVersion(id:UUID(),effectiveDay:s.profile.dayID(for:date),effectiveDate:date,goals:NutritionGoals(energy:2000,protein:100,carbohydrates:200,fat:70),createdAt:date)]
        s.intakeResolutions=[IntakeResolution(dayID:s.profile.dayID(for:date),selection:.manual)]
        var totals=NutritionTotals();totals.include(NutrientValues(energy:90,protein:nil,carbohydrates:10,fat:2))
        s.days=[NutritionDayLog(id:s.profile.dayID(for:date),version:2,isClosed:true,summaries:[ClosedDaySummary(id:UUID(),version:1,closedAt:date,completeness:.incomplete,totals:totals,entryVersions:[s.entries[0].id.uuidString:3],goalVersionID:s.goals[0].id,intakeSource:.manual)])]
        return s
    }
    func testCSVKeepsEveryTrackingEntityUnitsDatesProvenanceAndMultilineNotes() throws {
        let data=try TrackingCSVExport.encode(nutrition:snapshot())
        let records=try parse(data)
        XCTAssertEqual(Set(records.map { $0["record_type"]! }),["profile","food_entry","day","closed_day","historical_nutrition","weight","activity","goal","product","recipe","recipe_ingredient","import_batch","intake_resolution"])
        let food=try XCTUnwrap(records.first { $0["record_type"]=="food_entry" })
        XCTAssertEqual(food["name"],"Milk, \"label\"");XCTAssertEqual(food["notes"],"First line, \"quoted\"\nSecond line")
        XCTAssertEqual(food["unit"],"milliliter");XCTAssertEqual(food["quantity"],"200.0");XCTAssertEqual(food["nutrition_basis"],"per100Milliliters")
        XCTAssertEqual(food["kcal"],"45.0");XCTAssertEqual(food["consumed_kcal"],"90.0");XCTAssertEqual(food["protein_g"],"")
        XCTAssertEqual(food["recorded_at"],"2026-10-08T16:00:00.125000000Z");XCTAssertEqual(food["time_zone"],"America/Montevideo")
        let weight=try XCTUnwrap(records.first { $0["record_type"]=="weight" });XCTAssertEqual(weight["source"],"spreadsheet");XCTAssertEqual(weight["unit"],"kg");XCTAssertEqual(weight["notes"],"Scale note")
        let activity=try XCTUnwrap(records.first { $0["record_type"]=="activity" });XCTAssertEqual(activity["duration_minutes"],"");XCTAssertEqual(activity["active_kcal"],"200.0")
        let object=try JSONSerialization.jsonObject(with:Data(food["details_json"]!.utf8)) as! [String:Any]
        XCTAssertEqual(object["version"] as? Int,3)
    }
    func testHealthRequiresOptInAndPortableScopeExcludesOtherAccountsAndPendingContexts() throws {
        let owner=UUID().uuidString;let foreign=UUID().uuidString
        var health=HealthSnapshot();health.configuration=HealthImportConfiguration(metrics:[.weight,.dietaryEnergy],startDate:nil,timeZoneIdentifier:"America/Montevideo")
        health.samples=[HealthSampleRecord(id:UUID(),metric:.weight,startDate:date,endDate:date,value:72,sourceName:"Scale",sourceBundleIdentifier:"fixture.scale",deviceName:"Fixture",workoutActivityCode:nil)]
        health.dailyValues=[HealthDayValue(metric:.dietaryEnergy,date:date,value:1400,sourceNames:["Fixture source"])]
        let own=HealthNutritionClosure(id:UUID(),accountScope:owner.lowercased(),dayID:"2026-10-08",closedAt:date,values:[HealthDayValue(metric:.dietaryEnergy,date:date,value:1234,sourceNames:[])],goals:nil)
        let other=HealthNutritionClosure(id:UUID(),accountScope:foreign.lowercased(),dayID:"2026-10-08",closedAt:date,values:[HealthDayValue(metric:.dietaryEnergy,date:date,value:9876,sourceNames:[])],goals:nil)
        health.closedNutritionDays=[own,other];health.pendingChatContexts=[owner.lowercased()+":"+UUID().uuidString:Data("OWN_PRIVATE_PENDING_CONTEXT".utf8),foreign.lowercased()+":"+UUID().uuidString:Data("FOREIGN_PENDING_CONTEXT".utf8)]
        let ordinary=String(decoding:try TrackingCSVExport.encode(nutrition: snapshot(),ownerID:owner),as:UTF8.self)
        XCTAssertFalse(ordinary.contains("health_observation"));XCTAssertFalse(ordinary.contains("Fixture source"))
        let opted=String(decoding:try TrackingCSVExport.encode(nutrition:snapshot(),health:health,ownerID:owner),as:UTF8.self)
        XCTAssertTrue(opted.contains("health_observation"));XCTAssertTrue(opted.contains("1234.0"));XCTAssertFalse(opted.contains("9876"));XCTAssertFalse(opted.contains(foreign.lowercased()));XCTAssertFalse(opted.contains("PENDING_CONTEXT"))
        let portable=try TrackingExportScope.health(health,ownerID:owner)
        XCTAssertEqual(portable.closedNutritionDays,[own]);XCTAssertNil(portable.pendingChatContexts)
        XCTAssertEqual(try TrackingExportScope.health(health,ownerID:nil).closedNutritionDays,[])
    }
    func testInvalidHealthExportFailsBeforeWritingInsteadOfSerializingNonfiniteValues() {
        var health=HealthSnapshot();health.dailyValues=[HealthDayValue(metric:.weight,date:date,value:.infinity,sourceNames:[])]
        XCTAssertThrowsError(try TrackingCSVExport.encode(nutrition:snapshot(),health:health))
        XCTAssertThrowsError(try TrackingExportScope.health(health,ownerID:"not-an-owner"))
    }
    /// Independent CSV reader verifies field boundaries, RFC quoting and embedded newlines.
    private func parse(_ data: Data) throws -> [[String:String]] {
        let chars=Array(String(decoding:data,as:UTF8.self).unicodeScalars);var i=0;var quoted=false;var field="";var row:[String]=[];var table:[[String]]=[]
        while i<chars.count {
            let char=chars[i]
            if char=="\"" { if quoted && i+1<chars.count && chars[i+1]=="\"" { field.append("\"");i+=1 } else { quoted.toggle() } }
            else if char=="," && !quoted { row.append(field);field="" }
            else if char=="\r" && !quoted { row.append(field);field="";table.append(row);row=[];if i+1<chars.count && chars[i+1]=="\n" { i+=1 } }
            else { field.unicodeScalars.append(char) }
            i+=1
        }
        XCTAssertFalse(quoted);let headers=try XCTUnwrap(table.first)
        return table.dropFirst().map { values in XCTAssertEqual(values.count,headers.count);return Dictionary(uniqueKeysWithValues:zip(headers,values)) }
    }
}
