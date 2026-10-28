import Foundation

struct CityResult: Identifiable, Equatable {
    var id: String { "\(latitude),\(longitude)" }
    let name: String
    let region: String?
    let country: String?
    let latitude: Double
    let longitude: Double

    var subtitle: String { [region, country].compactMap { $0 }.filter { $0 != name }.joined(separator: ", ") }
}

/// Current conditions from Open-Meteo (free, no account or key) for a city the user picks.
/// No location permission is involved: only the chosen city's coordinates are sent.
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var temperature: Double?
    @Published private(set) var feelsLike: Double?
    @Published private(set) var code = 0
    @Published private(set) var isDay = true
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var rainChance: Int?
    @Published private(set) var updated: Date?
    @Published private(set) var failed = false

    private var timer: Timer?

    var city: String? {
        let name = Pref.string(Pref.weatherCity)
        return name.isEmpty ? nil : name
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func select(_ result: CityResult?) {
        let d = UserDefaults.standard
        if let result {
            d.set(result.name, forKey: Pref.weatherCity)
            d.set(result.latitude, forKey: Pref.weatherLatitude)
            d.set(result.longitude, forKey: Pref.weatherLongitude)
        } else {
            [Pref.weatherCity, Pref.weatherLatitude, Pref.weatherLongitude].forEach(d.removeObject)
            temperature = nil
        }
        refresh()
    }

    func refresh() {
        let lat = Pref.double(Pref.weatherLatitude), lon = Pref.double(Pref.weatherLongitude)
        // A city saved without coordinates would read as 0,0, out in the Gulf of Guinea.
        guard city != nil, lat != 0 || lon != 0 else { return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"),
        ]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { self?.apply(json) }
        }.resume()
    }

    private func apply(_ json: [String: Any]?) {
        guard let current = json?["current"] as? [String: Any] else { failed = true; return }
        let daily = json?["daily"] as? [String: Any]
        func first(_ key: String) -> Double? { (daily?[key] as? [Any])?.first.flatMap { ($0 as? NSNumber)?.doubleValue } }
        failed = false
        temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue
        feelsLike = (current["apparent_temperature"] as? NSNumber)?.doubleValue
        code = (current["weather_code"] as? NSNumber)?.intValue ?? 0
        isDay = ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1
        high = first("temperature_2m_max")
        low = first("temperature_2m_min")
        rainChance = first("precipitation_probability_max").map { Int($0) }
        updated = Date()
    }

    static func search(_ query: String, completion: @escaping ([CityResult]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return completion([]) }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "6"),
                        .init(name: "language", value: "tr"), .init(name: "format", value: "json")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let results = (json?["results"] as? [[String: Any]] ?? []).compactMap { r -> CityResult? in
                guard let name = r["name"] as? String, let lat = (r["latitude"] as? NSNumber)?.doubleValue,
                      let lon = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
                return CityResult(name: name, region: r["admin1"] as? String, country: r["country"] as? String,
                                  latitude: lat, longitude: lon)
            }
            DispatchQueue.main.async { completion(results) }
        }.resume()
    }

    /// SF Symbol and Turkish description for a WMO weather code.
    var condition: (symbol: String, text: String) { Self.describe(code, isDay: isDay) }

    static func describe(_ code: Int, isDay: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: return (isDay ? "sun.max.fill" : "moon.stars.fill", "Açık")
        case 1: return (isDay ? "sun.min.fill" : "moon.fill", "Çoğunlukla açık")
        case 2: return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Parçalı bulutlu")
        case 3: return ("cloud.fill", "Kapalı")
        case 45, 48: return ("cloud.fog.fill", "Sisli")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Çisenti")
        case 61, 63, 65, 66, 67: return ("cloud.rain.fill", "Yağmurlu")
        case 71, 73, 75, 77: return ("cloud.snow.fill", "Karlı")
        case 80, 81, 82: return ("cloud.heavyrain.fill", "Sağanak")
        case 85, 86: return ("cloud.snow.fill", "Kar sağanağı")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Gök gürültülü")
        default: return ("cloud.fill", "Bulutlu")
        }
    }
}

#if DEBUG
extension WeatherService {
    func loadPreview(temperature: Double, code: Int, high: Double, low: Double, rain: Int) {
        self.temperature = temperature
        self.code = code
        isDay = true
        self.high = high
        self.low = low
        rainChance = rain
        updated = Date()
    }
}
#endif
