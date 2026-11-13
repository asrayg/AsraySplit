import Foundation

/// Bundled, read-only trip guide (itinerary, food, packing). Works fully offline.
struct TripGuide: Sendable {
    struct Flight: Identifiable, Sendable { let person, from, arrives, returns: String; var id: String { person } }
    struct Stop: Identifiable, Sendable { let time, title: String; var notes: [String] = []; var id: String { time + title } }
    struct Day: Identifiable, Sendable { let date, title, transport: String; let stops: [Stop]; var id: String { date } }
    struct Pick: Identifiable, Sendable { let name, note: String; var id: String { name } }
    struct ChecklistSection: Identifiable, Sendable { let title: String; let items: [String]; var id: String { title } }

    let title, dates, airbnb, airport: String
    let flights: [Flight]
    let days: [Day]
    let restaurants: [Pick]
    let foodChecklist: [String]
    let drinks: [Pick]
    let softDrinks: [Pick]
    let allergyMessage: String
    let transport: [Pick]
    let bookingChecklist: [String]
    let info: [Pick]
    let packing: [ChecklistSection]
    let outfits: [Pick]
}

extension TripGuide {
    static let puertoRico = TripGuide(
        title: "🇵🇷 Puerto Rico Thanksgiving",
        dates: "Nov 26 – Dec 1, 2026 · 5 nights",
        airbnb: "1364 Calle Estrella, San Juan, PR 00907",
        airport: "SJU – Luis Muñoz Marín International",
        flights: [
            Flight(person: "Asray", from: "Baltimore (BWI)", arrives: "Thu Nov 26 · 3:00 PM", returns: "Dec 1 · 5:01 AM"),
            Flight(person: "Anoop", from: "Hartford (BDL)", arrives: "Thu Nov 26 · 8:23 PM", returns: "Dec 1 · 8:30 AM"),
            Flight(person: "Arjun", from: "Chicago Midway (MDW)", arrives: "Fri Nov 27 · 1:36 AM", returns: "Dec 1 · 5:01 AM"),
            Flight(person: "Justin", from: "Chicago O’Hare (ORD)", arrives: "Fri Nov 27 · 6:32 AM", returns: "Dec 1 · 11:48 AM"),
        ],
        days: [
            Day(date: "Thu, Nov 26", title: "Thanksgiving / Arrival", transport: "Uber", stops: [
                Stop(time: "3:00 PM", title: "Asray lands in San Juan"),
                Stop(time: "4:00 PM", title: "Airbnb check-in, drop luggage"),
                Stop(time: "5:00 PM", title: "Explore Condado", notes: ["Beach walk", "Groceries"]),
                Stop(time: "7:00 PM", title: "Thanksgiving dinner", notes: ["Restaurant with confirmed holiday hours"]),
                Stop(time: "8:23 PM", title: "Anoop lands"),
                Stop(time: "9:00 PM", title: "Dinner at Vagon or a local spot"),
                Stop(time: "9:30 PM", title: "Meet up — nearby bars or chill at the Airbnb"),
                Stop(time: "1:36 AM Fri", title: "Arjun arrives"),
                Stop(time: "6:32 AM Fri", title: "Justin arrives"),
            ]),
            Day(date: "Fri, Nov 27", title: "Old San Juan, Beach & Nightlife", transport: "Uber / walking", stops: [
                Stop(time: "10:00 AM", title: "Breakfast / brunch", notes: ["Near Escambrón beach", "Coffee and plan the day"]),
                Stop(time: "11:30 AM", title: "Escambrón Beach", notes: ["Swimming", "Optional snorkeling"]),
                Stop(time: "2:00 PM", title: "Lunch", notes: ["Café Berlin or St. Germain Bistro & Bar"]),
                Stop(time: "3:00 PM", title: "Explore Old San Juan", notes: ["Castillo San Felipe del Morro", "Colorful historic streets", "Paseo de la Princesa", "Shops and souvenirs"]),
                Stop(time: "6:00 PM", title: "Sunset, back to Airbnb to get ready"),
                Stop(time: "7:30 PM", title: "Puerto Rican dinner", notes: ["Mofongo, tostones, arroz con gandules"]),
                Stop(time: "10:00 PM", title: "La Placita de Santurce", notes: ["Bars, salsa & reggaetón, dancing"]),
            ]),
            Day(date: "Sat, Nov 28", title: "El Yunque & Luquillo Beach", transport: "Rental car", stops: [
                Stop(time: "7:00 AM", title: "Breakfast"),
                Stop(time: "7:30 AM", title: "Drive to El Yunque", notes: ["Arrive early — parking is limited"]),
                Stop(time: "8:30 AM", title: "Explore El Yunque (until noon)", notes: ["Juan Diego Falls — short walk to a waterfall", "Angelito Trail — easy trail to a river swimming hole", "Optional: La Coca Falls, Yokahú Tower"]),
                Stop(time: "1:00 PM", title: "Lunch at Luquillo Kiosks", notes: ["Find vegetarian and allergy-safe options"]),
                Stop(time: "2:00 PM", title: "Luquillo Beach (until 4:30)", notes: ["Swimming, palm trees, beach games"]),
                Stop(time: "5:30 PM", title: "Drive back to San Juan"),
                Stop(time: "7:30 PM", title: "Dinner"),
                Stop(time: "8:30 PM", title: "El Batey — casual first drink"),
                Stop(time: "9:30 PM", title: "La Factoría — cocktails and dancing"),
                Stop(time: "11:00 PM", title: "More Calle San Sebastián bars or a club"),
            ]),
            Day(date: "Sun, Nov 29", title: "Icacos Island & Snorkeling", transport: "Rental car + boat", stops: [
                Stop(time: "7:00 AM", title: "Breakfast"),
                Stop(time: "7:30 AM", title: "Drive toward Fajardo"),
                Stop(time: "9:00 AM", title: "Icacos Island boat excursion (until 3)", notes: ["Catamaran or speedboat", "Snorkeling, white-sand beaches"]),
                Stop(time: "3:30 PM", title: "Return to San Juan"),
                Stop(time: "6:00 PM", title: "Relax at Airbnb"),
                Stop(time: "7:30 PM", title: "Dinner in Condado or Old San Juan"),
                Stop(time: "8:30 PM", title: "Bar hopping (until midnight)", notes: ["La Vergüenza — rooftop, ocean views", "El Batey — dive bar", "La Taberna Lúpulo — PR craft beer", "Monostereo — cocktails, livelier", "Los 3 Cuernos — chichaíto shots to finish"]),
            ]),
            Day(date: "Mon, Nov 30", title: "Water Activities & Final Day", transport: "Uber / walking", stops: [
                Stop(time: "10:00 AM", title: "Brunch"),
                Stop(time: "11:30 AM", title: "Condado Lagoon", notes: ["Kayaking", "Paddleboarding"]),
                Stop(time: "1:30 PM", title: "Lunch"),
                Stop(time: "3:00 PM", title: "Pick an afternoon", notes: ["Beach", "Surf lesson", "Souvenirs", "More Old San Juan", "Santurce street art"]),
                Stop(time: "6:30 PM", title: "Final group dinner — Bebo’s Café"),
                Stop(time: "8:00 PM", title: "Pack, clean up, coordinate airport rides"),
            ]),
            Day(date: "Tue, Dec 1", title: "Fly Home", transport: "Uber", stops: [
                Stop(time: "2:30 AM", title: "Asray & Arjun leave for SJU", notes: ["Flights at 5:01 AM"]),
                Stop(time: "6:00 AM", title: "Anoop leaves", notes: ["Flight at 8:30 AM"]),
                Stop(time: "9:00 AM", title: "Justin leaves", notes: ["Flight at 11:48 AM"]),
            ]),
        ],
        restaurants: [
            Pick(name: "Café Berlin", note: "Old San Juan · vegetarian & vegan options"),
            Pick(name: "St. Germain Bistro & Bar", note: "Old San Juan · vegetarian choices"),
            Pick(name: "Orozco’s Restaurant", note: "Condado · traditional Puerto Rican"),
            Pick(name: "Atabey", note: "Condado · breakfast, vegan-inclusive"),
            Pick(name: "Verde Mesa", note: "Old San Juan · vegetable-forward, nicer"),
            Pick(name: "Luquillo Kiosks", note: "Casual local food after El Yunque"),
            Pick(name: "Bebo’s Café", note: "Final group dinner"),
        ],
        foodChecklist: ["Mofongo", "Tostones", "Maduros", "Arroz con gandules", "Empanadillas", "Local seafood or chicken", "Puerto Rican coffee", "Fresh tropical fruit"],
        drinks: [
            Pick(name: "Piña Colada", note: "Rum, pineapple, coconut cream"),
            Pick(name: "Chichaíto", note: "Rum + anise shot"),
            Pick(name: "Medalla Light", note: "The local beer"),
            Pick(name: "Coquito", note: "Holiday coconut-rum drink"),
            Pick(name: "Pitorro", note: "Strong cane spirit — commercial only"),
            Pick(name: "Don Q", note: "Local rum"),
            Pick(name: "Ron del Barrilito", note: "Aged sipping rum"),
            Pick(name: "Mojito de Parcha", note: "Passionfruit mojito"),
        ],
        softDrinks: [
            Pick(name: "Jugo de Parcha", note: "Passionfruit juice"),
            Pick(name: "Jugo de Guanábana", note: "Soursop juice"),
            Pick(name: "Agua de Coco", note: "Fresh coconut water"),
            Pick(name: "Café con Leche", note: "PR coffee with steamed milk"),
            Pick(name: "Malta India", note: "Sweet non-alcoholic malt"),
        ],
        allergyMessage: "Tengo alergias alimentarias al maní (cacahuate) y al huevo. ¿Pueden preparar mi comida sin estos ingredientes y sin contaminación cruzada, usando utensilios, superficies y aceite limpios?",
        transport: [
            Pick(name: "Thu", note: "Uber airport → Airbnb"),
            Pick(name: "Fri", note: "Uber / walking"),
            Pick(name: "Sat", note: "Rental car — El Yunque & Luquillo"),
            Pick(name: "Sun", note: "Rental car — Fajardo & Icacos"),
            Pick(name: "Mon", note: "Uber / walking"),
            Pick(name: "Tue", note: "Airport transfers for early flights"),
        ],
        bookingChecklist: [
            "Reserve rental car for Nov 28–29",
            "Reserve Icacos excursion for Nov 29",
            "Verify excursion allergy accommodations",
            "Research Thanksgiving dinner options",
            "Pick restaurants with vegetarian + allergy-safe options",
            "Check Frontier baggage policies",
            "Pack swimwear, sunscreen, and hiking shoes",
            "Bring snorkeling gear if desired",
            "Confirm who’s paying for shared reservations",
        ],
        info: [
            Pick(name: "Emergency", note: "911"),
            Pick(name: "Currency", note: "US Dollar"),
            Pick(name: "Language", note: "Spanish and English"),
            Pick(name: "Documents", note: "No passport needed from the mainland — bring TSA-accepted ID"),
            Pick(name: "Weather", note: "Warm, humid; expect rain in the rainforest"),
        ],
        packing: [
            ChecklistSection(title: "Clothes", items: ["6–7 underwear", "5–6 pairs of socks", "5–6 T-shirts", "2–3 shorts", "2 swim trunks", "2 going-out shirts", "Nice pants / chinos", "Joggers for flights", "Light hoodie", "Rain jacket / poncho", "Pajamas", "Hat", "Sunglasses"]),
            ChecklistSection(title: "Footwear", items: ["Grippy sneakers (no flip-flops in El Yunque)", "Flip-flops / slides", "Going-out shoes", "Water shoes (optional)"]),
            ChecklistSection(title: "Beach & rainforest", items: ["Beach towel", "Sunscreen SPF 30+", "Bug spray", "Reusable water bottle", "Small backpack", "Waterproof phone pouch", "Bag for wet swimwear", "Portable charger", "SPF lip balm", "Dry bag for the boat (optional)"]),
            ChecklistSection(title: "Toiletries", items: ["Toothbrush", "Toothpaste", "Deodorant", "Shampoo", "Body wash", "Face wash", "Moisturizer", "Hair products", "Razor", "Contacts / glasses", "Nail clippers", "Prescription meds", "Justin: EpiPens in carry-on"]),
            ChecklistSection(title: "Electronics & documents", items: ["Phone + charger", "Portable charger + cable", "Headphones", "REAL ID / TSA-accepted ID", "Wallet / card", "Flight confirmation", "Airbnb details", "Health insurance card", "Cash for kiosks & tips"]),
            ChecklistSection(title: "Airport", items: ["Personal item within Frontier limits", "Carry-on / checked bag (if bought)", "Comfy plane outfit", "Empty water bottle", "Snacks", "Downloaded entertainment"]),
            ChecklistSection(title: "Final check before leaving home", items: ["Underwear", "Socks", "Swim trunks", "Hiking sneakers", "Flip-flops", "Going-out outfit", "Toothbrush", "Deodorant", "Phone charger", "Wallet and ID", "Medication", "Flight and Airbnb details saved"]),
            ChecklistSection(title: "Shared — one person brings", items: ["First-aid kit", "Extra sunscreen", "Extra bug spray", "Cards / party games", "Bluetooth speaker", "Car phone charger", "Laundry pods"]),
        ],
        outfits: [
            Pick(name: "Thu", note: "T-shirt, shorts/joggers, sneakers"),
            Pick(name: "Fri", note: "Day: trunks + slides · Night: nice shirt, chinos"),
            Pick(name: "Sat", note: "Athletic fit, grippy sneakers, rain jacket, trunks after"),
            Pick(name: "Sun", note: "Day: trunks, rash guard · Night: nice shirt"),
            Pick(name: "Mon", note: "Casual + trunks · Dinner: polo or button-down"),
            Pick(name: "Tue", note: "Comfy tee, joggers, sneakers"),
        ])
}
