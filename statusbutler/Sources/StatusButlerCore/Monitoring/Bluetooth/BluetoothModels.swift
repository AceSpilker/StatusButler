// 蓝牙域模型（T-023 只读路径）：种类映射收纯函数，不 import IOBluetooth，无硬件也可单测。
// 依据 Bluetooth SIG Assigned Numbers "Baseband" 的 Class of Device 位布局：
// bits 0-1 格式类型 / bits 2-7 minor 设备类(6 位) / bits 8-12 major 设备类(5 位) / bits 13-23 服务类。
// 本类型只接收已提取的 (major, minor) 数值对；位提取在 IOBluetooth 侧完成，此处不做位运算。

/// 面板语义的设备种类（细于 CoD 的归类只到这一层，图标/文案选择由展示层决定）
public enum BluetoothDeviceKind: Sendable, Equatable {
    case keyboard
    case mouse
    case trackpad
    case gamepad
    case headphone
    case speaker
    case wearable
    case other

    /// - Parameters:
    ///   - deviceClass.major: 5 位 major 设备类（CoD bits 8-12），如 0x04=音视频、0x05=外设、0x07=穿戴
    ///   - deviceClass.minor: 6 位 minor 设备类（CoD bits 2-7），取值 0-63，
    ///     语义同 IOBluetooth kBluetoothDeviceClassMinor* 枚举的未移位值
    public static func kind(ofDeviceClass deviceClass: (major: UInt32, minor: UInt32)) -> BluetoothDeviceKind {
        switch deviceClass.major {
        case 0x04: // 音视频（kBluetoothDeviceClassMajorAudio）
            switch deviceClass.minor {
            case 0x01, 0x02, 0x06: // Headset / HandsFree / Headphones：贴耳出声即耳机
                return .headphone
            case 0x05, 0x07, 0x08, 0x0A, 0x0F: // Loudspeaker / Portable / Car / HiFi / 显示器自带喇叭
                return .speaker
            default: // 麦克风、摄像机等不出声或非佩戴的音视频设备
                return .other
            }
        case 0x05: // 外设（kBluetoothDeviceClassMajorPeripheral）
            // minor 的 bits 7-6（即值的 0x30 位）分键盘/指向/组合；bits 5-2（0x0F 位）为子型
            let category = deviceClass.minor & 0x30
            let subtype = deviceClass.minor & 0x0F
            if category == 0x00 && (subtype == 0x01 || subtype == 0x02) {
                return .gamepad // Joystick / Gamepad 子型只在"非键盘非指向"类别下出现
            }
            if category == 0x10 || category == 0x30 {
                return .keyboard // 键盘；组合（键盘+指向，如带小红点）以键盘为主形态
            }
            if category == 0x20 {
                // CoD 无法区分鼠标与妙控板（同为指向类），也不区分键盘与触控板
                // （实测两者类码并列），归鼠标；.trackpad 留给 T-023b 以名称/HID 特征细分
                return .mouse
            }
            return .other // 遥控器/数位板/读卡器等指向键盘之外的子型
        case 0x07: // 穿戴（kBluetoothDeviceClassMajorWearable）
            return .wearable // 手表/传呼/头盔/眼镜等全部 minor 都归穿戴
        default:
            // 电脑/电话/玩具/健康等域，以及 CoD=0 的设备：实测部分 BLE 配对件（儿童手表、
            // 平板）classOfDevice 报 0，类码缺失时如实归 other，不猜
            return .other
        }
    }
}

/// 配对设备快照行（值类型，可跨并发域；ObjC 对象绝不外泄出监控器）
public struct BluetoothDeviceInfo: Sendable, Equatable {
    /// 设备名；系统未给出时折叠为空串，"未命名设备"兜底文案归展示层
    public let name: String
    /// 形如 "xx-xx-xx-xx-xx-xx" 的地址串，作为设备唯一键（幽灵设备识别/排序依赖它）
    public let address: String
    public let kind: BluetoothDeviceKind
    public let isConnected: Bool

    public init(name: String, address: String, kind: BluetoothDeviceKind, isConnected: Bool) {
        self.name = name
        self.address = address
        self.kind = kind
        self.isConnected = isConnected
    }
}
