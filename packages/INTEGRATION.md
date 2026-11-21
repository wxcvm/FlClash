# Karing 接入 FlClash

## 包结构

- [karing](<karing/pubspec.yaml>) 保留包名 karing 和原有 package:karing/... 导入。lib/app 存放业务模块、工具类及本地服务，lib/screens 存放可嵌入的页面和组件，lib/i18n 存放 Slang 源语言文件和已生成的 Dart 文件。
- [vpn_service](<vpn_service/pubspec.yaml>) 是纯 Dart shim。依赖关系为 fl_clash → karing → vpn_service。Karing 使用 ../vpn_service 路径依赖。宿主直接导入 VPN 类型时也需声明路径依赖。
- [build.yaml](<karing/build.yaml>) 及其 builder 按上游复制，用于生成构建时间。Slang 已生成文件记录的更新命令为 dart run slang。

## 页面调用

在 FlClash 路由或视图包装器中导入所需页面。例如导入 package:karing/screens/diversion_rules_screen.dart，在宿主 Navigator 中以 MaterialPageRoute 打开 const DiversionRulesScreen()。备份同步与二维码页面的参数以各页面构造函数为准。

在页面祖先中挂载 Karing 生成的 TranslationProvider，使 Translations.of(context) 可用，并让 FlClash 的语言设置同步到 LocaleSettings。由宿主注入页面依赖的设置、服务器数据和路径，避免启动 Karing 的完整应用引导流程及其独立后台服务。

## VPN 接口与下一步

[VPN 门面](<vpn_service/lib/vpn_service.dart>) 提供服务状态、配置、生命周期、系统代理、授权、平台查询及开机启动签名。未接入时状态为断开，启动返回结构化错误。ProxyConfig 已由 [Karing 的出站模型](<karing/lib/app/utils/proxy_conf_utils.dart>) 定义，调用点使用 shim 的 ProxyOption 和 ProxyManager。未发现 ProxyConfigItem 调用。

1. 原生桥接。将事件和请求接到桌面 Core 与 Android 服务中的既有生命周期入口，保留单一状态来源。现有 proxy 插件接受端口及绕过列表，缺少代理地址、状态查询及网卡排除能力。系统代理启停应接入宿主现有状态机。
2. 国际化。把宿主 Locale 映射到 Slang 的 AppLocale，补充缺失语言并从源 JSON 重新生成。运行相关页面前核对资源路径、字体和资源打包。
3. Riverpod。让宿主适配器把 Karing SettingManager / ServerManager 的读写和事件映射到 FlClash providers，明确状态和持久化的归属。

## 当前构建前置项

- 本地上游包含 101 个 screens 文件、66 个 utils 文件、28 个语言 JSON 和 29 个生成 Dart 文件。sentry_utils_private.dart 在工作区与 3c00ed64^ 历史中均缺失，本包增加了无遥测占位实现。
- 当前上游混用历史工具与较新页面，仍有 13 个内部导入缺少对应文件。本地 Git 历史亦未找到相应路径。缺口包括 app/private/app_url_utils_private.dart，app/utils/ 下的 accessibility_utils.dart、device_utils.dart、icon_utils.dart、move_to_background_utils.dart、notice_utils.dart、package_manager_android.dart、process_utils_macos.dart、singbox_outbound.dart、system_utils.dart、vpn_action_handler.dart 和 webdav_client_utils.dart，以及 screens/statistics_records_screen.dart。需补入与页面同版本的源码。
## 已知依赖冲突

| 依赖 | Karing 声明 | FlClash 声明 |
| --- | --- | --- |
| `win32` | `5.11.0` | `^6.4.0` |
| `win32_registry` | `1.1.5` | `^3.0.3` |
| `file_picker` | `11.0.3` | `^12.3.0` |
| `device_info_plus` | `11.3.0` | `^13.3.0` |
| `package_info_plus` | `9.0.0` | `^10.2.2` |
| `connectivity_plus` | `7.3.1` | `7.2.0` |
| `launch_at_startup` | `hosted 0.2.2` | `Git fork 0.5.1` |

Pub 解析时只应用根包的 overrides。接入时需统一上列依赖并复核 Karing Git forks 及 WebView Linux 的平台依赖。当前未运行 Flutter 依赖解算及编译。
