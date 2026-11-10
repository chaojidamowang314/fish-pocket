import CoreLocation
import Foundation
import WeatherKit

/// weather 能力的实现。
///
/// 和 `AlarmProvider` 绕的是同一圈、原因也一样：WeatherKit 没有 ObjC 接口 —— 入口
/// 只有 `async throws`，答案全是包着 `Measurement` 的 Swift 值类型，ObjC 里没有
/// 东西可声明。所以 `caps_weather.m` 只是转发壳，真正调框架的在这里。
///
/// **这个类不做任何决策。** 经纬度和 `hours` 进来之前已经在 `caps_weather.m` 里
/// 查过范围，这里不再查；截到调用方要的条数、失败时怎么措辞，也都在那边。这里
/// 只做两件事：问 WeatherKit，把答案按它给的顺序原样摊成字典（§4.5）。
///
/// 它也不读用户的位置。坐标是调用方给的，「这里的天气」要先走 `location`。
@objc final class WeatherProvider: NSObject {
    @objc static let shared = WeatherProvider()

    private override init() { super.init() }

    /// 启动时登记，和 `AlarmProvider.install()` 挨着、在引擎起来之前。
    @objc static func install() {
        DshWeatherSetProvider(shared)
    }

    /// 每个数字的单位。写死而不是跟着系统地区走：读这些数的是模型，它没法知道
    /// 这台手机设的是摄氏还是华氏，而猜错一次就是把 20 度说成零下。所以单位固定，
    /// 并且跟着每个结果一起出去。
    static let units: [String: String] = [
        "temperature": "celsius",
        "speed": "km/h",
        "pressure": "hPa",
        "distance": "km",
        "precipitation": "mm",
    ]

    /// 所有时间都写成 UTC。
    ///
    /// WeatherKit 的答案里没有时区：`WeatherMetadata` 只有 `date`、`expirationDate`
    /// 和 `location`。要写成预报地点的当地时间，就得自己拿坐标去反查时区，那是
    /// 拼出来的，不是框架给的，第一版不做。写成手机的时区更糟 —— 人在上海查东京，
    /// 得到的是一串看起来像当地时间、其实不是的数。UTC 至少不会被误读，结果里的
    /// `timeZone` 也明说了这一点。
    static let timeZone = "UTC"

    /// `ISO8601DateFormatter` 默认就是 UTC、`2026-11-10T08:00:00Z` 这个形状，
    /// 并且可以跨线程用。
    private static let formatter = ISO8601DateFormatter()

    static func stamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - DshWeatherProviding

extension WeatherProvider: DshWeatherProviding {
    // 标签是 Swift 的 ObjC 导入器定的：`currentWeatherAtLatitude:` 推出来的第一个
    // 标签是 `atLatitude:`。和 AlarmProvider 里那条注释是同一个坑。
    @objc(currentWeatherAtLatitude:longitude:completion:)
    func currentWeather(
        atLatitude latitude: Double,
        longitude: Double,
        completion done: @escaping ([String: Any]?, Error?) -> Void
    ) {
        let place = CLLocation(latitude: latitude, longitude: longitude)
        Task {
            do {
                var answer = try await WeatherProvider.envelope()
                let now = try await WeatherService.shared.weather(for: place, including: .current)
                answer["current"] = WeatherProvider.describe(now)
                done(answer, nil)
            } catch {
                done(nil, error)
            }
        }
    }

    @objc(hourlyWeatherAtLatitude:longitude:hours:completion:)
    func hourlyWeather(
        atLatitude latitude: Double,
        longitude: Double,
        hours: Int,
        completion done: @escaping ([String: Any]?, Error?) -> Void
    ) {
        let place = CLLocation(latitude: latitude, longitude: longitude)
        // 不带起止时间的 `.hourly` 固定只给 25 个小时，而调用方最多能要 240 个，
        // 所以窗口自己给。窗口两头那半个小时算不算由框架决定，这里可能多回一条
        // —— 原样交出去，截到 N 条是 caps_weather.m 的事。
        let start = Date()
        let end = start.addingTimeInterval(TimeInterval(hours) * 3600)
        Task {
            do {
                var answer = try await WeatherProvider.envelope()
                let forecast = try await WeatherService.shared.weather(
                    for: place,
                    including: .hourly(startDate: start, endDate: end)
                )
                answer["hours"] = forecast.forecast.map { WeatherProvider.describe($0) }
                done(answer, nil)
            } catch {
                done(nil, error)
            }
        }
    }

    @objc(dailyWeatherAtLatitude:longitude:completion:)
    func dailyWeather(
        atLatitude latitude: Double,
        longitude: Double,
        completion done: @escaping ([String: Any]?, Error?) -> Void
    ) {
        let place = CLLocation(latitude: latitude, longitude: longitude)
        Task {
            do {
                var answer = try await WeatherProvider.envelope()
                // 默认的 `.daily` 就是从今天起的十天。不自己给起止日期：「今天」
                // 从哪一刻开始取决于预报地点的时区，而我们手里没有它。
                let forecast = try await WeatherService.shared.weather(for: place, including: .daily)
                answer["days"] = forecast.forecast.map { WeatherProvider.describe($0) }
                done(answer, nil)
            } catch {
                done(nil, error)
            }
        }
    }
}

// MARK: - WeatherKit

extension WeatherProvider {
    /// 每个结果都带的那几项：单位、时区、出处。
    ///
    /// **出处是许可条款要求的，不是客套。** 凡是展示 WeatherKit 数据的地方都得带上
    /// Apple Weather 的名字和法律页链接，所以它跟着数据一起走，而不是指望上层记得
    /// 加。也因此先取它：取不到，整次调用就失败，数据不会不带出处地出去。
    static func envelope() async throws -> [String: Any] {
        let attribution = try await WeatherService.shared.attribution
        return [
            "units": units,
            "timeZone": timeZone,
            "attribution": [
                "service": attribution.serviceName,
                "legalURL": attribution.legalPageURL.absoluteString,
            ],
        ]
    }

    /// `condition` 是 WeatherKit 自己的枚举名（`mostlyCloudy` 这种），原样过去，
    /// 不在这里对成别的词表（§4.5）。`conditionDescription` 是框架给的那句人话，
    /// 语言跟着手机的系统语言走。
    static func describe(_ now: CurrentWeather) -> [String: Any] {
        [
            "date": stamp(now.date),
            "temperature": celsius(now.temperature),
            "apparentTemperature": celsius(now.apparentTemperature),
            "humidity": now.humidity,
            "condition": now.condition.rawValue,
            "conditionDescription": now.condition.description,
            "symbolName": now.symbolName,
            "wind": describe(now.wind),
            "pressure": now.pressure.converted(to: .hectopascals).value,
            "visibility": now.visibility.converted(to: .kilometers).value,
            "uvIndex": now.uvIndex.value,
            "cloudCover": now.cloudCover,
            "dewPoint": celsius(now.dewPoint),
            "isDaylight": now.isDaylight,
        ]
    }

    static func describe(_ hour: HourWeather) -> [String: Any] {
        [
            "date": stamp(hour.date),
            "temperature": celsius(hour.temperature),
            "apparentTemperature": celsius(hour.apparentTemperature),
            "condition": hour.condition.rawValue,
            "conditionDescription": hour.condition.description,
            "precipitationChance": hour.precipitationChance,
            "precipitationAmount": hour.precipitationAmount.converted(to: .millimeters).value,
            "windSpeed": kilometersPerHour(hour.wind.speed),
            "humidity": hour.humidity,
            "uvIndex": hour.uvIndex.value,
        ]
    }

    static func describe(_ day: DayWeather) -> [String: Any] {
        var entry: [String: Any] = [
            // 预报地点当天的零点，但写成 UTC：北京的 11 月 11 日在这里是
            // `2026-11-10T16:00:00Z`。日期看着早一天不是 bug，见 `timeZone`。
            "date": stamp(day.date),
            "high": celsius(day.highTemperature),
            "low": celsius(day.lowTemperature),
            "condition": day.condition.rawValue,
            "conditionDescription": day.condition.description,
            "precipitationChance": day.precipitationChance,
            "precipitationAmount": day.precipitationAmount.converted(to: .millimeters).value,
            "uvIndex": day.uvIndex.value,
            "windSpeed": kilometersPerHour(day.wind.speed),
        ]
        // 极昼极夜的地方没有日出日落。没有就不写这个键，不拿空字符串顶。
        if let sunrise = day.sun.sunrise { entry["sunrise"] = stamp(sunrise) }
        if let sunset = day.sun.sunset { entry["sunset"] = stamp(sunset) }
        return entry
    }

    static func describe(_ wind: Wind) -> [String: Any] {
        var entry: [String: Any] = [
            "speed": kilometersPerHour(wind.speed),
            // 风的来向，不是去向：Apple 的文档写的是「coming from」。
            "direction": wind.direction.converted(to: .degrees).value,
        ]
        if let gust = wind.gust { entry["gust"] = kilometersPerHour(gust) }
        return entry
    }

    // 显式换算，不读 `.value`：WeatherKit 给的 `Measurement` 是什么单位取决于它
    // 自己，文档没有承诺是公制。
    static func celsius(_ value: Measurement<UnitTemperature>) -> Double {
        value.converted(to: .celsius).value
    }

    static func kilometersPerHour(_ value: Measurement<UnitSpeed>) -> Double {
        value.converted(to: .kilometersPerHour).value
    }
}
