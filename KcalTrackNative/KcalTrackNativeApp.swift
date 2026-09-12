import SwiftUI
import Foundation

// Native SwiftUI rewrite of the current KcalTrack HTML app.
// Supabase is accessed directly over HTTPS using URLSession; no WebView is used.

private let supabaseURL = URL(string: "https://pikhgfyxqgtdjkzzducf.supabase.co")!
private let supabaseKey = "sb_publishable_BIxFvhlRGRh1nAbqZBqbbQ_SsX487M7"
private let supabaseSchema = "kcaltracker"

struct FoodEntry: Identifiable, Codable, Hashable {
    var id: String
    var date: Date
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var meal: String
}

struct WorkoutEntry: Identifiable, Codable, Hashable {
    var id: String
    var date: Date
    var type: String
    var minutes: Double
    var kcal: Double
}

struct WeightEntry: Identifiable, Codable, Hashable {
    var id: String
    var date: Date
    var weight: Double
}

struct Profile: Codable, Equatable {
    var name = ""
    var age = 25
    var height = 170.0
    var currentWeight = 70.0
    var goalWeight = 65.0
    var sex = "Male"
    var activity = "Moderately Active"
    var calorieTarget = 2000.0
    var proteinTarget = 125.0
    var carbTarget = 230.0
    var fatTarget = 80.0
    var fiberTarget = 30.0
    var workoutTarget = 300.0
}

struct Session: Codable {
    let accessToken: String
    let refreshToken: String
    let userId: String
}

@MainActor
final class AppStore: ObservableObject {
    @Published var session: Session?
    @Published var profile = Profile()
    @Published var foods: [FoodEntry] = []
    @Published var workouts: [WorkoutEntry] = []
    @Published var weights: [WeightEntry] = []
    @Published var isBusy = false
    @Published var errorMessage: String?

    init() {
        loadSession()
        if session != nil { Task { await sync() } }
    }

    var isSignedIn: Bool { session != nil }

    func signIn(email: String, password: String) async -> Bool {
        isBusy = true; defer { isBusy = false }
        do {
            struct TokenResponse: Decodable { let access_token: String; let refresh_token: String; let user: UserResponse? }
            let token: TokenResponse = try await request(
                path: "/auth/v1/token?grant_type=password", method: "POST",
                body: ["email": email, "password": password], authenticated: false)
            guard let userId = token.user?.id else { throw APIError.message("No user returned by Supabase.") }
            session = Session(accessToken: token.access_token, refreshToken: token.refresh_token, userId: userId)
            persistSession()
            await sync()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func signUp(email: String, password: String) async -> Bool {
        isBusy = true; defer { isBusy = false }
        do {
            struct SignupResponse: Decodable { let access_token: String?; let refresh_token: String?; let user: UserResponse? }
            let r: SignupResponse = try await request(path: "/auth/v1/signup", method: "POST", body: ["email": email, "password": password], authenticated: false)
            guard let access = r.access_token, let refresh = r.refresh_token, let userId = r.user?.id else {
                errorMessage = "Account created. Check your email to confirm, then sign in."; return true
            }
            session = Session(accessToken: access, refreshToken: refresh, userId: userId)
            persistSession()
            await sync()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func signOut() {
        session = nil
        foods = []; workouts = []; weights = []; profile = Profile()
        UserDefaults.standard.removeObject(forKey: "kcaltrack_session")
    }

    func sync() async {
        guard session != nil else { return }
        isBusy = true; defer { isBusy = false }
        do {
            try await refreshIfNeeded()
            async let p: Profile = fetchProfile()
            async let f: [FoodEntry] = fetchFoods()
            async let w: [WorkoutEntry] = fetchWorkouts()
            async let wt: [WeightEntry] = fetchWeights()
            profile = try await p
            foods = try await f
            workouts = try await w
            weights = try await wt
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFood(name: String, meal: String, date: Date, calories: Double, protein: Double, carbs: Double, fat: Double, fiber: Double) async {
        guard let userId = session?.userId else { return }
        let id = UUID().uuidString.lowercased()
        let entry = FoodEntry(id: id, date: date, name: name, calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber, meal: meal)
        foods.insert(entry, at: 0)
        do {
            try await insertFood(entry, userId: userId)
        } catch {
            foods.removeAll { $0.id == id }; errorMessage = error.localizedDescription
        }
    }

    func addWorkout(type: String, date: Date, minutes: Double, kcal: Double) async {
        guard let userId = session?.userId else { return }
        let id = UUID().uuidString.lowercased()
        let entry = WorkoutEntry(id: id, date: date, type: type, minutes: minutes, kcal: kcal)
        workouts.insert(entry, at: 0)
        do {
            try await insertWorkout(entry, userId: userId)
        } catch {
            workouts.removeAll { $0.id == id }; errorMessage = error.localizedDescription
        }
    }

    func deleteFood(_ id: String) async {
        foods.removeAll { $0.id == id }
        do { try await delete(path: "/rest/v1/food_entries?id=eq.\(id)") } catch { errorMessage = error.localizedDescription }
    }

    func deleteWorkout(_ id: String) async {
        workouts.removeAll { $0.id == id }
        do { try await delete(path: "/rest/v1/workout_entries?id=eq.\(id)") } catch { errorMessage = error.localizedDescription }
    }

    func saveProfile(_ newProfile: Profile) async {
        profile = newProfile
        guard let userId = session?.userId else { return }
        do { try await upsertProfile(newProfile, id: userId) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Supabase REST

    private struct UserResponse: Decodable { let id: String }
    private struct ProfileRow: Codable {
        var id: String; var name: String?; var age: Int?; var height: Double?; var current_weight: Double?; var goal_weight: Double?
        var sex: String?; var activity: String?; var calorie_target: Double?; var protein_target: Double?; var carb_target: Double?; var fat_target: Double?; var fiber_target: Double?; var workout_target: Double?
    }
    private struct FoodRow: Codable { let id: String; let date: String; let name: String; let calories: Double?; let protein: Double?; let carbs: Double?; let fat: Double?; let fiber: Double?; let meal: String? }
    private struct WorkoutRow: Codable { let id: String; let date: String; let name: String; let duration: Double?; let calories_burned: Double? }
    private struct WeightRow: Codable { let id: String; let date: String; let weight: Double? }

    private func makeRequest(path: String, method: String, body: Any? = nil, authenticated: Bool = true) throws -> URLRequest {
        var req = URLRequest(url: supabaseURL.appending(path: path))
        req.httpMethod = method
        req.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue(supabaseSchema, forHTTPHeaderField: "Accept-Profile")
        req.setValue(supabaseSchema, forHTTPHeaderField: "Content-Profile")
        if authenticated, let access = session?.accessToken { req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body as Any) }
        return req
    }

    private func request<T: Decodable>(path: String, method: String, body: [String: Any], authenticated: Bool) async throws -> T {
        var req = try makeRequest(path: path, method: method, body: body, authenticated: authenticated)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchProfile() async throws -> Profile {
        let id = try requireSession().userId
        let path = "/rest/v1/profiles?id=eq.\(id)&select=*"
        let rows: [ProfileRow] = try await get(path: path)
        guard let r = rows.first else { return profile }
        var p = Profile(); p.name = r.name ?? ""; p.age = r.age ?? 25; p.height = r.height ?? 170; p.currentWeight = r.current_weight ?? 70; p.goalWeight = r.goal_weight ?? 65; p.sex = r.sex ?? "Male"; p.activity = r.activity ?? "Moderately Active"; p.calorieTarget = r.calorie_target ?? 2000; p.proteinTarget = r.protein_target ?? 125; p.carbTarget = r.carb_target ?? 230; p.fatTarget = r.fat_target ?? 80; p.fiberTarget = r.fiber_target ?? 30; p.workoutTarget = r.workout_target ?? 300; return p
    }

    private func fetchFoods() async throws -> [FoodEntry] {
        let id = try requireSession().userId
        let rows: [FoodRow] = try await get(path: "/rest/v1/food_entries?user_id=eq.\(id)&select=*&order=date.desc")
        return rows.compactMap { r in FoodEntry(id:r.id, date: isoDate(r.date), name:r.name, calories:r.calories ?? 0, protein:r.protein ?? 0, carbs:r.carbs ?? 0, fat:r.fat ?? 0, fiber:r.fiber ?? 0, meal:r.meal ?? "Breakfast") }
    }

    private func fetchWorkouts() async throws -> [WorkoutEntry] {
        let id = try requireSession().userId
        let rows: [WorkoutRow] = try await get(path: "/rest/v1/workout_entries?user_id=eq.\(id)&select=*&order=date.desc")
        return rows.compactMap { r in WorkoutEntry(id:r.id, date: isoDate(r.date), type:r.name, minutes:r.duration ?? 0, kcal:r.calories_burned ?? 0) }
    }

    private func fetchWeights() async throws -> [WeightEntry] {
        let id = try requireSession().userId
        let rows: [WeightRow] = try await get(path: "/rest/v1/weight_entries?user_id=eq.\(id)&select=*&order=date.asc")
        return rows.compactMap { r in WeightEntry(id:r.id, date: isoDate(r.date), weight:r.weight ?? 0) }
    }

    private func insertFood(_ f: FoodEntry, userId: String) async throws {
        let body: [String: Any] = ["id":f.id,"user_id":userId,"date":ISO8601DateFormatter().string(from:f.date),"name":f.name,"quantity":NSNull(),"unit":NSNull(),"calories":f.calories,"protein":f.protein,"carbs":f.carbs,"fat":f.fat,"fiber":f.fiber,"meal":f.meal,"notes":NSNull()]
        try await mutate(path:"/rest/v1/food_entries", method:"POST", body:body)
    }

    private func insertWorkout(_ w: WorkoutEntry, userId: String) async throws {
        let body: [String: Any] = ["id":w.id,"user_id":userId,"date":ISO8601DateFormatter().string(from:w.date),"name":w.type,"duration":w.minutes,"calories_burned":w.kcal,"notes":NSNull()]
        try await mutate(path:"/rest/v1/workout_entries", method:"POST", body:body)
    }

    private func upsertProfile(_ p: Profile, id: String) async throws {
        let body: [String: Any] = ["id":id,"name":p.name,"age":p.age,"height":p.height,"current_weight":p.currentWeight,"goal_weight":p.goalWeight,"sex":p.sex,"activity":p.activity,"calorie_target":p.calorieTarget,"protein_target":p.proteinTarget,"carb_target":p.carbTarget,"fat_target":p.fatTarget,"fiber_target":p.fiberTarget,"workout_target":p.workoutTarget]
        var req = try makeRequest(path:"/rest/v1/profiles?on_conflict=id", method:"POST", body:body)
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField:"Prefer")
        let (data,response) = try await URLSession.shared.data(for:req); try validate(response,data:data)
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let req = try makeRequest(path:path, method:"GET")
        let (data,response)=try await URLSession.shared.data(for:req); try validate(response,data:data); return try JSONDecoder().decode(T.self,from:data)
    }

    private func mutate(path: String, method: String, body: [String:Any]) async throws {
        var req = try makeRequest(path:path,method:method,body:body)
        req.setValue("return=minimal", forHTTPHeaderField:"Prefer")
        let (data,response)=try await URLSession.shared.data(for:req); try validate(response,data:data)
    }

    private func delete(path: String) async throws { let req=try makeRequest(path:path,method:"DELETE"); let (data,response)=try await URLSession.shared.data(for:req); try validate(response,data:data) }

    private func refreshIfNeeded() async throws {
        guard let s = session, !s.refreshToken.isEmpty else { return }
        // Supabase access tokens are short-lived. Attempt a refresh before every sync; Supabase safely rotates refresh tokens.
        struct R: Decodable { let access_token:String; let refresh_token:String; let user:UserResponse }
        do {
            let r:R = try await request(path:"/auth/v1/token?grant_type=refresh_token",method:"POST",body:["refresh_token":s.refreshToken],authenticated:false)
            session = Session(accessToken:r.access_token,refreshToken:r.refresh_token,userId:r.user.id); persistSession()
        } catch { }
    }

    private func requireSession() throws -> Session { guard let s=session else { throw APIError.message("Not signed in.") }; return s }
    private func isoDate(_ s:String)->Date { ISO8601DateFormatter().date(from:s) ?? Date() }
    private func validate(_ response: URLResponse, data: Data) throws { guard let http=response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { let msg=String(data:data,encoding:.utf8) ?? "Supabase request failed."; throw APIError.message(msg) } }

    private func persistSession() { if let s=session, let data=try? JSONEncoder().encode(s) { UserDefaults.standard.set(data,forKey:"kcaltrack_session") } }
    private func loadSession() { if let data=UserDefaults.standard.data(forKey:"kcaltrack_session"), let s=try? JSONDecoder().decode(Session.self,from:data){session=s} }
}

enum APIError: LocalizedError { case message(String); var errorDescription:String? { if case .message(let s)=self{return s};return "Unknown error" } }

@main
struct KcalTrackNativeApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene { WindowGroup { RootView().environmentObject(store) } }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Group { if store.isSignedIn { MainView() } else { LoginView() } }
            .alert("KcalTrack", isPresented: Binding(get:{store.errorMessage != nil}, set:{_ in store.errorMessage=nil})) { Button("OK", role:.cancel){} } message:{Text(store.errorMessage ?? "")}
    }
}

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email=""; @State private var password=""; @State private var signup=false
    var body: some View {
        NavigationStack { Form { Section { Text("Calorie tracker").font(.largeTitle.bold()); Text("by Razik Aslam").foregroundStyle(.secondary) }
            Section { TextField("Email",text:$email).textInputAutocapitalization(.never).keyboardType(.emailAddress); SecureField("Password",text:$password)
                Button(signup ? "Create account" : "Sign In") { Task { if signup { _=await store.signUp(email:email,password:password) } else {_=await store.signIn(email:email,password:password)} } }.disabled(email.isEmpty || password.count<6)
                Button(signup ? "Already have an account? Sign In" : "Create account") { signup.toggle() }.buttonStyle(.plain)
            }
        }.navigationTitle("KcalTrack") }
    }
}

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab=0
    var body: some View {
        TabView(selection:$tab) {
            HomeView().tabItem{Label("Home",systemImage:"house.fill")}.tag(0)
            FoodView().tabItem{Label("Food",systemImage:"fork.knife")}.tag(1)
            WorkoutView().tabItem{Label("Workout",systemImage:"figure.strengthtraining.traditional")}.tag(2)
            ProgressViewNative().tabItem{Label("Progress",systemImage:"chart.line.uptrend.xyaxis")}.tag(3)
            ProfileView().tabItem{Label("More",systemImage:"ellipsis.circle")}.tag(4)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var period="day"
    var body: some View {
        ScrollView { VStack(spacing:14) { Picker("",selection:$period){Text("Day").tag("day");Text("Week").tag("week");Text("Month").tag("month")}.pickerStyle(.segmented)
            let d=periodData(period)
            SummaryCard(title:"Calories",value:fmt(d.kcal),target:fmt(targetCalories(period)),unit:"kcal",left:max(0,targetCalories(period)-d.kcal))
            MacroCard(data:d)
            SummaryCard(title:"Workout Burn",value:fmt(d.burn),target:fmt(targetWorkout(period)),unit:"kcal",left:max(0,targetWorkout(period)-d.burn))
            WeightCard()
        }.padding() }
        .navigationTitle("\(greeting())")
    }
    func periodData(_ p:String)->(kcal:Double,protein:Double,carbs:Double,fat:Double,fiber:Double,burn:Double){
        let start:Date; let now=Date(); let cal=Calendar.current
        if p=="day"{start=cal.startOfDay(for:now)} else if p=="week"{ start=cal.dateInterval(of:.weekOfYear,for:now)!.start } else {start=cal.dateInterval(of:.month,for:now)!.start}
        let f=store.foods.filter{$0.date>=start && $0.date<=now}; let w=store.workouts.filter{$0.date>=start && $0.date<=now}
        return (f.reduce(0){$0+$1.calories},f.reduce(0){$0+$1.protein},f.reduce(0){$0+$1.carbs},f.reduce(0){$0+$1.fat},f.reduce(0){$0+$1.fiber},w.reduce(0){$0+$1.kcal})
    }
    func days(_ p:String)->Double{let cal=Calendar.current;let now=Date();if p=="day"{return 1};if p=="week"{return 7};return Double(cal.dateComponents([.day],from:cal.dateInterval(of:.month,for:now)!.start,to:now).day!+1)}
    func targetCalories(_ p:String)->Double{store.profile.calorieTarget*days(p)}
    func targetWorkout(_ p:String)->Double{p=="day" ? store.profile.workoutTarget : p=="week" ? store.profile.workoutTarget*4 : store.profile.workoutTarget*(4.0/7.0)*days(p)}
    func greeting()->String{let h=Calendar.current.component(.hour,from:Date());let t=h<12 ? "Morning" : h<17 ? "Afternoon" : "Evening";return "Good \(t), \(store.profile.name.isEmpty ? "there" : store.profile.name)"}
}

struct SummaryCard: View { let title:String; let value:String; let target:String; let unit:String; let left:Double; var body: some View { VStack(spacing:8){Text(title).font(.headline); Text("\(value) / \(target) \(unit)").font(.system(size:30,weight:.bold,design:.rounded)); Text("\(fmt(left)) \(unit) left").foregroundStyle(.green)}.frame(maxWidth:.infinity).padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius:18)) } }
struct MacroCard: View { let data:(kcal:Double,protein:Double,carbs:Double,fat:Double,fiber:Double,burn:Double); @EnvironmentObject var store:AppStore; var body: some View{VStack{HStack{MacroCell(name:"Protein",v:data.protein,t:store.profile.proteinTarget);MacroCell(name:"Carbs",v:data.carbs,t:store.profile.carbTarget);MacroCell(name:"Fat",v:data.fat,t:store.profile.fatTarget);MacroCell(name:"Fiber",v:data.fiber,t:store.profile.fiberTarget)}}.padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius:18))} }
struct MacroCell: View {let name:String;let v:Double;let t:Double;var body:some View{VStack{Text(fmt(v)).font(.headline);Text("/ \(fmt(t)) g").font(.caption).foregroundStyle(.secondary);Text(name).font(.caption)}}}
struct WeightCard: View {@EnvironmentObject var store:AppStore;var body:some View{HStack{VStack(alignment:.leading){Text("Current Weight").foregroundStyle(.secondary);Text("\(store.profile.currentWeight, specifier:"%.1f") kg").font(.title3.bold())};Spacer();Image(systemName:"chart.line.uptrend.xyaxis").foregroundStyle(.green)}.padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius:18))}}

struct FoodView: View {
    @EnvironmentObject var store:AppStore; @State private var date=Date(); @State private var showAdd=false
    var foods:[FoodEntry]{store.foods.filter{Calendar.current.isDate($0.date,inSameDayAs:date)}}
    var body: some View{NavigationStack{List{Section{DatePicker("Date",selection:$date,in:.distantPast...Date(),displayedComponents:.date)}
        ForEach(["Breakfast","Lunch","Dinner","Snack"],id:\.self){meal in let items=foods.filter{$0.meal==meal}; if !items.isEmpty{Section(meal){ForEach(items){f in VStack(alignment:.leading){Text(f.name).font(.headline);Text("\(fmt(f.calories)) kcal · \(fmt(f.protein))P \(fmt(f.carbs))C \(fmt(f.fat))F").font(.caption).foregroundStyle(.secondary)}.swipeActions{Button(role:.destructive){Task{await store.deleteFood(f.id)}}label:{Image(systemName:"trash")}}}}}}
    }.navigationTitle("Food Log").toolbar{ToolbarItem(placement:.topBarTrailing){Button{showAdd=true}label:{Image(systemName:"plus")}}}.sheet(isPresented:$showAdd){AddFoodView(date:date)} }
    }
}

struct AddFoodView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let date: Date

    @State private var name = ""
    @State private var meal = "Breakfast"
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Food name", text: $name)

                Picker("Meal", selection: $meal) {
                    ForEach(meals, id: \.self) { item in
                        Text(item)
                    }
                }

                TextField("Calories", text: $kcal)
                    .keyboardType(.decimalPad)
                TextField("Protein (g)", text: $protein)
                    .keyboardType(.decimalPad)
                TextField("Carbs (g)", text: $carbs)
                    .keyboardType(.decimalPad)
                TextField("Fat (g)", text: $fat)
                    .keyboardType(.decimalPad)
                TextField("Fiber (g)", text: $fiber)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Add Food")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.addFood(
                                name: name,
                                meal: meal,
                                date: date,
                                calories: Double(kcal) ?? 0,
                                protein: Double(protein) ?? 0,
                                carbs: Double(carbs) ?? 0,
                                fat: Double(fat) ?? 0,
                                fiber: Double(fiber) ?? 0
                            )
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct WorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var date = Date()
    @State private var showAdd = false

    var wos: [WorkoutEntry] {
        store.workouts.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    var body: some View {
        NavigationStack {
            List {
                DatePicker(
                    "Date",
                    selection: $date,
                    in: .distantPast...Date(),
                    displayedComponents: .date
                )

                ForEach(wos) { w in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(w.type)
                                .font(.headline)
                            Text("\(fmt(w.minutes)) min")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(fmt(w.kcal)) kcal")
                            .bold()
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await store.deleteWorkout(w.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddWorkoutView(date: date)
            }
        }
    }
}

struct AddWorkoutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let date: Date

    @State private var type = "Weight Training"
    @State private var minutes = ""
    @State private var kcal = ""

    private let workoutTypes = [
        "Weight Training", "Running", "Cycling", "Walking", "HIIT",
        "Swimming", "Yoga", "Sports", "Other"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Workout", selection: $type) {
                    ForEach(workoutTypes, id: \.self) { item in
                        Text(item)
                    }
                }

                TextField("Minutes", text: $minutes)
                    .keyboardType(.decimalPad)

                TextField("Calories burned", text: $kcal)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Add Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.addWorkout(
                                type: type,
                                date: date,
                                minutes: Double(minutes) ?? 0,
                                kcal: Double(kcal) ?? 0
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct ProgressViewNative: View { @EnvironmentObject var store:AppStore; var body:some View{NavigationStack{List{HStack{Text("Food kcal");Spacer();Text(fmt(store.foods.reduce(0){$0+$1.calories}))};HStack{Text("Workout burn");Spacer();Text(fmt(store.workouts.reduce(0){$0+$1.kcal}))};HStack{Text("Entries");Spacer();Text("\(store.foods.count)")}}.navigationTitle("Progress")}} }

struct ProfileView: View { @EnvironmentObject var store:AppStore; @State private var draft=Profile(); @State private var first=true; var body:some View{NavigationStack{Form{Section("Profile"){TextField("Name",text:$draft.name);Stepper("Age: \(draft.age)",value:$draft.age,in:1...120);TextField("Height (cm)",value:$draft.height,format:.number).keyboardType(.decimalPad);TextField("Current weight (kg)",value:$draft.currentWeight,format:.number).keyboardType(.decimalPad);TextField("Goal weight (kg)",value:$draft.goalWeight,format:.number).keyboardType(.decimalPad)};Section("Targets"){TextField("Calories",value:$draft.calorieTarget,format:.number).keyboardType(.decimalPad);TextField("Protein",value:$draft.proteinTarget,format:.number).keyboardType(.decimalPad);TextField("Carbs",value:$draft.carbTarget,format:.number).keyboardType(.decimalPad);TextField("Fat",value:$draft.fatTarget,format:.number).keyboardType(.decimalPad);TextField("Fiber",value:$draft.fiberTarget,format:.number).keyboardType(.decimalPad);TextField("Workout burn",value:$draft.workoutTarget,format:.number).keyboardType(.decimalPad)};Button("Save profile"){Task{await store.saveProfile(draft)}};Button("Sign Out",role:.destructive){store.signOut()}}.navigationTitle("More").onAppear{if first{draft=store.profile;first=false}}}} }

private func fmt(_ v:Double)->String { v.rounded()==v ? String(Int(v)) : String(format:"%.2f",v).replacingOccurrences(of:"0+$",with:"",options:.regularExpression).replacingOccurrences(of:"\\.$",with:"",options:.regularExpression) }
