import Foundation

// T-201 / E5·S9·A8·WX-01：内置天气城市表（默认手动城市，无系统定位）。
// 纯数据 + 纯函数：无状态无副作用，搜索匹配是 GeneralPane 选择器与
// WeatherFeed location 闭包（集成侧）共用的唯一事实源。
//
// 集成注记（T-201 主线接线，LiveServices.swift 不在本任务改动面内）：
// LiveServices 里 `weatherFeed = WeatherFeed()` 改为注入 location 闭包：
//
//     weatherFeed = WeatherFeed(location: { [weak settings] in
//         guard let name = settings?.weatherCity,
//               let city = WeatherCityCatalog.city(named: name) else { return nil }
//         return (latitude: city.latitude, longitude: city.longitude)
//     })
//
// weatherCity == nil（未配置）→ location 返回 nil → WeatherFeed.tick 短路、
// 缓存为空 → 天气槽位按协议降级（天气静默），与 WX-01 "默认手动城市" 规格一致。

/// 内置城市条目。pinyin 是不带声调的全拼（全球城市用罗马化名），搜索匹配的第二键。
/// 坐标取城市参考点（OpenMeteo 对城市尺度内的取值差异无感知意义）
public struct WeatherCity: Equatable, Hashable, Sendable, Identifiable {
    /// 中文名（持久化键：SettingsStore.weatherCity 存这个）
    public let name: String
    /// 不带声调全拼 / 罗马化名（小写、无分隔符）
    public let pinyin: String
    public let latitude: Double
    public let longitude: Double

    public var id: String { name }

    public init(name: String, pinyin: String, latitude: Double, longitude: Double) {
        self.name = name
        self.pinyin = pinyin
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum WeatherCityCatalog {
    /// 中国主要城市在前、全球大城在后，各自按拼音序——展示顺序确定，
    /// 选择器的"无搜索默认列表"与测试共用同一份
    public static let all: [WeatherCity] = chinaCities + globalCities

    private static let chinaCities: [WeatherCity] = [
        WeatherCity(name: "北京", pinyin: "beijing", latitude: 39.9042, longitude: 116.4074),
        WeatherCity(name: "上海", pinyin: "shanghai", latitude: 31.2304, longitude: 121.4737),
        WeatherCity(name: "广州", pinyin: "guangzhou", latitude: 23.1291, longitude: 113.2644),
        WeatherCity(name: "深圳", pinyin: "shenzhen", latitude: 22.5431, longitude: 114.0579),
        WeatherCity(name: "杭州", pinyin: "hangzhou", latitude: 30.2741, longitude: 120.1551),
        WeatherCity(name: "成都", pinyin: "chengdu", latitude: 30.5728, longitude: 104.0668),
        WeatherCity(name: "重庆", pinyin: "chongqing", latitude: 29.5630, longitude: 106.5516),
        WeatherCity(name: "武汉", pinyin: "wuhan", latitude: 30.5928, longitude: 114.3055),
        WeatherCity(name: "西安", pinyin: "xian", latitude: 34.3416, longitude: 108.9398),
        WeatherCity(name: "南京", pinyin: "nanjing", latitude: 32.0603, longitude: 118.7969),
        WeatherCity(name: "天津", pinyin: "tianjin", latitude: 39.3434, longitude: 117.3616),
        WeatherCity(name: "苏州", pinyin: "suzhou", latitude: 31.2989, longitude: 120.5853),
        WeatherCity(name: "长沙", pinyin: "changsha", latitude: 28.2282, longitude: 112.9388),
        WeatherCity(name: "郑州", pinyin: "zhengzhou", latitude: 34.7466, longitude: 113.6254),
        WeatherCity(name: "青岛", pinyin: "qingdao", latitude: 36.0671, longitude: 120.3826),
        WeatherCity(name: "大连", pinyin: "dalian", latitude: 38.9140, longitude: 121.6147),
        WeatherCity(name: "厦门", pinyin: "xiamen", latitude: 24.4798, longitude: 118.0894),
        WeatherCity(name: "宁波", pinyin: "ningbo", latitude: 29.8683, longitude: 121.5440),
        WeatherCity(name: "无锡", pinyin: "wuxi", latitude: 31.4912, longitude: 120.3119),
        WeatherCity(name: "济南", pinyin: "jinan", latitude: 36.6512, longitude: 117.1201),
        WeatherCity(name: "福州", pinyin: "fuzhou", latitude: 26.0745, longitude: 119.2965),
        WeatherCity(name: "合肥", pinyin: "hefei", latitude: 31.8206, longitude: 117.2272),
        WeatherCity(name: "南昌", pinyin: "nanchang", latitude: 28.6820, longitude: 115.8579),
        WeatherCity(name: "哈尔滨", pinyin: "haerbin", latitude: 45.8038, longitude: 126.5349),
        WeatherCity(name: "沈阳", pinyin: "shenyang", latitude: 41.8057, longitude: 123.4315),
        WeatherCity(name: "长春", pinyin: "changchun", latitude: 43.8171, longitude: 125.3235),
        WeatherCity(name: "昆明", pinyin: "kunming", latitude: 24.8801, longitude: 102.8329),
        WeatherCity(name: "贵阳", pinyin: "guiyang", latitude: 26.6470, longitude: 106.6302),
        WeatherCity(name: "南宁", pinyin: "nanning", latitude: 22.8170, longitude: 108.3665),
        WeatherCity(name: "兰州", pinyin: "lanzhou", latitude: 36.0611, longitude: 103.8343),
        WeatherCity(name: "乌鲁木齐", pinyin: "wulumuqi", latitude: 43.8256, longitude: 87.6168),
        WeatherCity(name: "拉萨", pinyin: "lasa", latitude: 29.6520, longitude: 91.1721),
        WeatherCity(name: "海口", pinyin: "haikou", latitude: 20.0444, longitude: 110.1999),
        WeatherCity(name: "呼和浩特", pinyin: "huhehaote", latitude: 40.8424, longitude: 111.7500),
        WeatherCity(name: "太原", pinyin: "taiyuan", latitude: 37.8706, longitude: 112.5489),
        WeatherCity(name: "石家庄", pinyin: "shijiazhuang", latitude: 38.0428, longitude: 114.5149),
        WeatherCity(name: "西宁", pinyin: "xining", latitude: 36.6171, longitude: 101.7782),
        WeatherCity(name: "银川", pinyin: "yinchuan", latitude: 38.4872, longitude: 106.2309),
        WeatherCity(name: "佛山", pinyin: "foshan", latitude: 23.0218, longitude: 113.1219),
        WeatherCity(name: "东莞", pinyin: "dongguan", latitude: 23.0207, longitude: 113.7518),
        WeatherCity(name: "中国香港", pinyin: "xianggang", latitude: 22.3193, longitude: 114.1694),
        WeatherCity(name: "中国澳门", pinyin: "aomen", latitude: 22.1987, longitude: 113.5439),
        WeatherCity(name: "台北", pinyin: "taibei", latitude: 25.0330, longitude: 121.5654),
    ]

    private static let globalCities: [WeatherCity] = [
        WeatherCity(name: "东京", pinyin: "tokyo", latitude: 35.6762, longitude: 139.6503),
        WeatherCity(name: "大阪", pinyin: "osaka", latitude: 34.6937, longitude: 135.5023),
        WeatherCity(name: "首尔", pinyin: "seoul", latitude: 37.5665, longitude: 126.9780),
        WeatherCity(name: "新加坡", pinyin: "singapore", latitude: 1.3521, longitude: 103.8198),
        WeatherCity(name: "曼谷", pinyin: "bangkok", latitude: 13.7563, longitude: 100.5018),
        WeatherCity(name: "吉隆坡", pinyin: "kualalumpur", latitude: 3.1390, longitude: 101.6869),
        WeatherCity(name: "雅加达", pinyin: "jakarta", latitude: -6.2088, longitude: 106.8456),
        WeatherCity(name: "马尼拉", pinyin: "manila", latitude: 14.5995, longitude: 120.9842),
        WeatherCity(name: "孟买", pinyin: "mumbai", latitude: 19.0760, longitude: 72.8777),
        WeatherCity(name: "新德里", pinyin: "newdelhi", latitude: 28.6139, longitude: 77.2090),
        WeatherCity(name: "迪拜", pinyin: "dubai", latitude: 25.2048, longitude: 55.2708),
        WeatherCity(name: "利雅得", pinyin: "riyadh", latitude: 24.7136, longitude: 46.6753),
        WeatherCity(name: "伊斯坦布尔", pinyin: "istanbul", latitude: 41.0082, longitude: 28.9784),
        WeatherCity(name: "莫斯科", pinyin: "moscow", latitude: 55.7558, longitude: 37.6173),
        WeatherCity(name: "伦敦", pinyin: "london", latitude: 51.5074, longitude: -0.1278),
        WeatherCity(name: "巴黎", pinyin: "paris", latitude: 48.8566, longitude: 2.3522),
        WeatherCity(name: "柏林", pinyin: "berlin", latitude: 52.5200, longitude: 13.4050),
        WeatherCity(name: "慕尼黑", pinyin: "munich", latitude: 48.1351, longitude: 11.5820),
        WeatherCity(name: "罗马", pinyin: "rome", latitude: 41.9028, longitude: 12.4964),
        WeatherCity(name: "米兰", pinyin: "milan", latitude: 45.4642, longitude: 9.1900),
        WeatherCity(name: "马德里", pinyin: "madrid", latitude: 40.4168, longitude: -3.7038),
        WeatherCity(name: "巴塞罗那", pinyin: "barcelona", latitude: 41.3874, longitude: 2.1686),
        WeatherCity(name: "阿姆斯特丹", pinyin: "amsterdam", latitude: 52.3676, longitude: 4.9041),
        WeatherCity(name: "苏黎世", pinyin: "zurich", latitude: 47.3769, longitude: 8.5417),
        WeatherCity(name: "维也纳", pinyin: "vienna", latitude: 48.2082, longitude: 16.3738),
        WeatherCity(name: "斯德哥尔摩", pinyin: "stockholm", latitude: 59.3293, longitude: 18.0686),
        WeatherCity(name: "赫尔辛基", pinyin: "helsinki", latitude: 60.1699, longitude: 24.9384),
        WeatherCity(name: "都柏林", pinyin: "dublin", latitude: 53.3498, longitude: -6.2603),
        WeatherCity(name: "里斯本", pinyin: "lisbon", latitude: 38.7223, longitude: -9.1393),
        WeatherCity(name: "雅典", pinyin: "athens", latitude: 37.9838, longitude: 23.7275),
        WeatherCity(name: "开罗", pinyin: "cairo", latitude: 30.0444, longitude: 31.2357),
        WeatherCity(name: "约翰内斯堡", pinyin: "johannesburg", latitude: -26.2041, longitude: 28.0473),
        WeatherCity(name: "纽约", pinyin: "newyork", latitude: 40.7128, longitude: -74.0060),
        WeatherCity(name: "洛杉矶", pinyin: "losangeles", latitude: 34.0522, longitude: -118.2437),
        WeatherCity(name: "旧金山", pinyin: "sanfrancisco", latitude: 37.7749, longitude: -122.4194),
        WeatherCity(name: "西雅图", pinyin: "seattle", latitude: 47.6062, longitude: -122.3321),
        WeatherCity(name: "芝加哥", pinyin: "chicago", latitude: 41.8781, longitude: -87.6298),
        WeatherCity(name: "波士顿", pinyin: "boston", latitude: 42.3601, longitude: -71.0589),
        WeatherCity(name: "檀香山", pinyin: "honolulu", latitude: 21.3069, longitude: -157.8583),
        WeatherCity(name: "温哥华", pinyin: "vancouver", latitude: 49.2827, longitude: -123.1207),
        WeatherCity(name: "多伦多", pinyin: "toronto", latitude: 43.6532, longitude: -79.3832),
        WeatherCity(name: "墨西哥城", pinyin: "mexicocity", latitude: 19.4326, longitude: -99.1332),
        WeatherCity(name: "圣保罗", pinyin: "saopaulo", latitude: -23.5505, longitude: -46.6333),
        WeatherCity(name: "布宜诺斯艾利斯", pinyin: "buenosaires", latitude: -34.6037, longitude: -58.3816),
        WeatherCity(name: "悉尼", pinyin: "sydney", latitude: -33.8688, longitude: 151.2093),
        WeatherCity(name: "墨尔本", pinyin: "melbourne", latitude: -37.8136, longitude: 144.9631),
        WeatherCity(name: "奥克兰", pinyin: "auckland", latitude: -36.8485, longitude: 174.7633),
    ]

    /// 按中文名精确查找（SettingsStore.weatherCity → 坐标 的唯一通道）。
    /// 表更新删掉某城市时返回 nil → 集成侧 location 闭包得 nil → 天气静默降级
    public static func city(named name: String) -> WeatherCity? {
        all.first { $0.name == name }
    }

    /// 搜索：空查询（去空白后）返回全表（选择器默认列表），
    /// 否则按 match 过滤并保持表内顺序（同名前缀命中排前无需加权——表序即展示序）
    public static func search(_ query: String) -> [WeatherCity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { match($0, query: trimmed) }
    }

    /// 单城匹配纯函数：中文名或拼音的"前缀或包含"，两侧统一小写——
    /// 大小写与拼音不敏感（"Bei" == "bei"，"bj" 不命中 beijing 的前缀但 "bei"/"eiji" 命中包含）。
    /// 中文按整串 contains 处理（"京" 命中 北京/南京/东京 的包含）
    public static func match(_ city: WeatherCity, query: String) -> Bool {
        let q = query.lowercased()
        let name = city.name.lowercased()
        let pinyin = city.pinyin.lowercased()
        return name.hasPrefix(q) || name.contains(q)
            || pinyin.hasPrefix(q) || pinyin.contains(q)
    }
}
