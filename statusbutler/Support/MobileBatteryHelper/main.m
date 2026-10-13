// A14-δ iDevice 电量 helper（T-053b 交付物落地；A2 电池下钻的数据源半场）。
//
// 形态：短命单发子进程——无参数执行，stdout 每行一个 JSON 对象，跑完 exit 0。
// 契约被主程序 MobileBattery/HelperReader.swift 钉死（字段名一字不差）：
//   {"name":"…","udid":"…","kind":"iPhone|iPad|Watch","batteryPercent":72,"charging":true}
// batteryPercent/charging 可省略（Watch 经 companion 通道读电量常失败，设备仍要
// 在面板里）；无设备时输出为空。诊断信息一律走 stderr——stdout 只属于契约。
//
// 路线：usbmuxd 枚举 → idevice_new_with_options(USBMUX) → lockdownd 握手 →
// 根域 DeviceClass/DeviceName + com.apple.mobile.battery 域的
// BatteryCurrentCapacity/BatteryIsCharging。License 边界由
// scripts/build-mobile-battery-helper.sh 承担：libimobiledevice 系 LGPL 库全部
// 关在本 helper 进程内，主程序零链接零分发责任。
//
// 本文件不进 SwiftPM 编译（Support/ 不在构建图里），由构建脚本用
// clang -fobjc-arc 链接六库产物单独编出 .build/mobile-battery/statusbutler-mobilebattery。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libusbmuxd/libusbmuxd.h>
#include <libplist/plist.h>

// usbmuxd 对同一设备可能多通道重复上报（USB/网络中继）：只发第一行，
// 与 Swift 侧"按 udid 去重首行胜出"的契约互为冗余。32 台封顶是防御性
// 上限（配对清单远达不到），溢出静默截断——多到溢出时面板也看不完。
#define MAX_EMITTED_DEVICES 32

static int was_emitted(const char **seen, int count, const char *udid) {
    for (int i = 0; i < count; i++) {
        if (strcmp(seen[i], udid) == 0) return 1;
    }
    return 0;
}

// JSON 字符串转义（RFC 8259 双引号串最小义务面）：设备名可含任意 Unicode，
// 控制字符转 \u 形态，UTF-8 字节原样透传（Swift 侧按 UTF-8 解码）。
static void json_print_string(const char *s) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; *p != '\0'; p++) {
        switch (*p) {
            case '"':  fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\b': fputs("\\b", stdout);  break;
            case '\f': fputs("\\f", stdout);  break;
            case '\n': fputs("\\n", stdout);  break;
            case '\r': fputs("\\r", stdout);  break;
            case '\t': fputs("\\t", stdout);  break;
            default:
                if (*p < 0x20) {
                    printf("\\u%04x", (unsigned)*p);
                } else {
                    putchar(*p);
                }
        }
    }
    putchar('"');
}

static void emit_line(const char *name, const char *udid, const char *kind,
                      int have_percent, unsigned long long percent,
                      int have_charging, int charging) {
    fputs("{\"name\":", stdout);
    // 契约：name 缺失时退到 kind 名（Swift 侧同规则），不省字段
    json_print_string((name != NULL && name[0] != '\0') ? name : kind);
    fputs(",\"udid\":", stdout);
    json_print_string(udid);
    fputs(",\"kind\":", stdout);
    json_print_string(kind);
    if (have_percent) {
        printf(",\"batteryPercent\":%llu", percent);
    }
    if (have_charging) {
        printf(",\"charging\":%s", charging ? "true" : "false");
    }
    fputs("}\n", stdout);
    fflush(stdout);  // 行级 flush：被超时杀掉时已输出的行仍然完整可解析
}

static void emit_device(lockdownd_client_t client, const char *udid) {
    plist_t node = NULL;

    // DeviceClass 是 kind 的唯一来源（iPod/AppleTV 等不在契约三列内，跳行并留痕）
    char *device_class = NULL;
    if (lockdownd_get_value(client, NULL, "DeviceClass", &node) != LOCKDOWN_E_SUCCESS || node == NULL) {
        fprintf(stderr, "skip %s: DeviceClass 不可读\n", udid);
        return;
    }
    plist_get_string_val(node, &device_class);
    plist_free(node);
    node = NULL;
    if (device_class == NULL) {
        fprintf(stderr, "skip %s: DeviceClass 非字符串\n", udid);
        return;
    }
    const char *kind = NULL;
    if (strcmp(device_class, "iPhone") == 0)      kind = "iPhone";
    else if (strcmp(device_class, "iPad") == 0)   kind = "iPad";
    else if (strcmp(device_class, "Watch") == 0)  kind = "Watch";
    if (kind == NULL) {
        fprintf(stderr, "skip %s: DeviceClass=%s 不在契约三列内\n", udid, device_class);
        free(device_class);
        return;
    }

    // 设备名（可选；读不到走 kind 兜底）
    char *name = NULL;
    if (lockdownd_get_value(client, NULL, "DeviceName", &node) == LOCKDOWN_E_SUCCESS && node != NULL) {
        plist_get_string_val(node, &name);
        plist_free(node);
        node = NULL;
    }

    // 电量域：百分比整数 + 充电布尔。任一失败只省对应字段，不省设备行
    // （锁屏/受信任未确认等场景读不到是常态）。
    int have_percent = 0;
    unsigned long long percent = 0;
    if (lockdownd_get_value(client, "com.apple.mobile.battery", "BatteryCurrentCapacity", &node)
            == LOCKDOWN_E_SUCCESS && node != NULL) {
        uint64_t value = 0;
        plist_get_uint_val(node, &value);
        plist_free(node);
        node = NULL;
        if (value <= 100) {  // 越界值不发射（Swift 侧会折叠 nil，源头就不编造）
            percent = (unsigned long long)value;
            have_percent = 1;
        }
    }
    int have_charging = 0;
    int charging = 0;
    if (lockdownd_get_value(client, "com.apple.mobile.battery", "BatteryIsCharging", &node)
            == LOCKDOWN_E_SUCCESS && node != NULL) {
        uint8_t flag = 0;
        plist_get_bool_val(node, &flag);
        plist_free(node);
        node = NULL;
        charging = flag ? 1 : 0;
        have_charging = 1;
    }

    emit_line(name, udid, kind, have_percent, percent, have_charging, charging);
    free(name);
    free(device_class);
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    usbmuxd_device_info_t *devices = NULL;
    const int count = usbmuxd_get_device_list(&devices, 0);
    if (count < 0) {
        // usbmuxd 不在/起不来 = 本轮"没有 iDevice"，空输出 exit 0；
        // 主程序把非零退出码整轮折叠 unavailable，这里不替它做可用性判断
        fprintf(stderr, "usbmuxd_get_device_list 失败: %d\n", count);
        return 0;
    }

    const char *seen[MAX_EMITTED_DEVICES];
    int seen_count = 0;
    for (int i = 0; i < count; i++) {
        const char *udid = devices[i].udid;
        if (udid == NULL || udid[0] == '\0') continue;
        if (was_emitted(seen, seen_count, udid)) continue;

        idevice_t phone = NULL;
        if (idevice_new_with_options(&phone, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
            continue;  // 通道瞬断/设备拔出：下一台
        }
        lockdownd_client_t client = NULL;
        // 握手失败 = 未受信任/锁屏：DeviceClass 无从谈起，跳行留痕
        if (lockdownd_client_new_with_handshake(phone, &client, "statusbutler-mobilebattery")
                != LOCKDOWN_E_SUCCESS) {
            fprintf(stderr, "skip %s: lockdownd 握手失败（未受信任/锁屏）\n", udid);
            idevice_free(phone);
            continue;
        }
        emit_device(client, udid);
        if (seen_count < MAX_EMITTED_DEVICES) {
            seen[seen_count++] = udid;  // 指向 devices 数组，list_free 前一直有效
        }
        lockdownd_client_free(client);
        idevice_free(phone);
    }

    usbmuxd_device_list_free(&devices);
    return 0;
}
