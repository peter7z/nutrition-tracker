import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Nutrition Tracker",
                systemImage: "heart.text.square",
                description: Text("Your nutrition history and progress. Apple Health import is the first feature planned.")
            )
            .navigationTitle("Nutrition Tracker")
        }
    }
}

#Preview {
    ContentView()
}
