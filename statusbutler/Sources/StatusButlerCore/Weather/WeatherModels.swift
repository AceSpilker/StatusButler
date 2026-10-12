import Foundation

// T-040（A8·WX-01/05）：天气数据模型 + WMO 代码映射 + 单位换算——全部纯函数，无网络无状态。
// 网络纪律闸见 WeatherNetworkPolicy；取数与缓存见 WeatherProvider。

/// 一帧"当前天气"快照：槽位/弹层/A6 组件三端共用（E5·WX-01/02）
public struct WeatherNow: Codable, Sendable, Equatable {
    public var temperatureC: Double
    /// WMO weather interpretation code（Open-Meteo weather_code 原值，映射见 symbolism(code:)）
    public var weatherCode: Int
    /// 今日最高/最低（Open-Meteo daily 数组首元素；daily 缺失时为 nil）
    public var dailyMaxC: Double?
    public var dailyMinC: Double?
    public var fetchedAt: Date

    public init(
        temperatureC: Double,
        weatherCode: Int,
        dailyMaxC: Double? = nil,
        dailyMinC: Double? = nil,
        fetchedAt: Date
    ) {
        self.temperatureC = temperatureC
        self.weatherCode = weatherCode
        self.dailyMaxC = dailyMaxC
        self.dailyMinC = dailyMinC
        self.fetchedAt = fetchedAt
    }

    /// WMO 天气代码 → (SF Symbol, 中文描述)。只覆盖 A8·WX-01 要求的主要档位；
    /// 85/86（雪阵）等未列入规格的代码归"未知"——宁缺勿错译。
    public static func symbolism(code: Int) -> (symbol: String, label: String) {
        switch code {
        case 0: return ("sun.max.fill", "晴")
        case 1...3: return ("cloud.sun.fill", "多云")
        case 45, 48: return ("cloud.fog.fill", "雾")
        case 51...67: return ("cloud.rain.fill", "雨")
        case 71...77: return ("cloud.snow.fill", "雪")
        case 80...82: return ("cloud.heavyrain.fill", "阵雨")
        case 95...99: return ("cloud.bolt.rain.fill", "雷暴")
        default: return ("questionmark.circle", "未知")
        }
    }
}

/// WX-05 单位切换：换算必须无状态纯函数，UI 层按设置选择展示口径
public enum WeatherUnits {
    public static func fahrenheit(fromCelsius celsius: Double) -> Double {
        celsius * 9.0 / 5.0 + 32.0
    }
}
